defmodule SmmMonitor.Processing.Store do
  @moduledoc """
  ETS-backed storage for recent mentions.

  Pure functions over a table; the table itself is owned by
  `SmmMonitor.Processing.Processor` so that its lifetime is tied to a
  supervised process. Writes go through the processor (serialised, so
  de-duplication and pruning stay consistent); reads hit ETS directly from
  the caller's process, which keeps the TUI's 1s refresh off the GenServer's
  mailbox.

  The table is an `:ordered_set` keyed by `{epoch_ms, platform, client_id,
  id}`, which gives us chronological iteration for free: "most recent N"
  is a walk backwards from the last key, and pruning by age is a walk
  forwards from the first.

  The platform is in the key because ids are only unique *within* a
  platform — a bare `{epoch_ms, id}` would let a Reddit and a YouTube
  mention sharing an id overwrite one another. The client is in the key
  for the same reason one level up: one post can match two clients' brand
  terms, and each client's dashboard has to show it.

  Nothing is persisted — restarting the app starts from an empty table.
  """

  alias SmmMonitor.Mention

  @table :smm_monitor_mentions

  @type table :: :ets.table()

  @doc "Default table name."
  @spec table_name() :: atom()
  def table_name, do: @table

  @doc """
  Creates the table. Called by the processor during `init/1`.

  `:public` + `read_concurrency` because many readers (TUI, tests) hit it
  concurrently while a single writer (the processor) owns mutation.
  """
  @spec new(atom()) :: table()
  def new(name \\ @table) do
    :ets.new(name, [:ordered_set, :public, :named_table, read_concurrency: true])
  end

  @doc """
  Inserts a mention unless its `{platform, id}` pair is already stored.

  Returns `:inserted` or `:duplicate`. Polls overlap by design (a 30s poll
  against a "last 25 items" endpoint re-sees most of them), so this is the
  guard that keeps counts honest.
  """
  @spec insert(table(), Mention.t()) :: :inserted | :duplicate
  def insert(table, %Mention{} = mention) do
    if member?(table, mention) do
      :duplicate
    else
      :ets.insert(table, {key(mention), mention})
      :inserted
    end
  end

  @doc "Whether the same mention is already stored for the same client."
  @spec member?(table(), Mention.t()) :: boolean()
  def member?(table, %Mention{id: id, platform: platform, client_id: client_id}) do
    # Matches on id, platform and client but *not* timestamp: a platform
    # that re-reports a post with a nudged timestamp is still the same
    # mention, while the same post matched for a second client is not.
    match = [{{{:_, platform, client_id, id}, :_}, [], [true]}]
    :ets.select_count(table, match) > 0
  end

  @doc """
  Most recent mentions, newest first.

  `platform` is either `:all` or a platform atom. Options are `:limit`,
  `:since` (a millisecond epoch) and `:client` — a client id, or `:all`
  to read across every client.
  """
  @spec recent(table(), atom(), keyword()) :: [Mention.t()]
  def recent(table, platform \\ :all, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    since = Keyword.get(opts, :since, 0)
    client = Keyword.get(opts, :client, :all)

    table
    |> walk_back(:ets.last(table), {platform, client}, since, limit, [])
    |> Enum.reverse()
  end

  @doc """
  Every stored mention for a platform within a window, newest first.

  Unbounded by design — callers are aggregating, not rendering.
  """
  @spec all(table(), atom(), keyword()) :: [Mention.t()]
  def all(table, platform \\ :all, opts \\ []) do
    recent(table, platform, Keyword.put(opts, :limit, :infinity))
  end

  @doc "Number of stored mentions matching a platform, client and window."
  @spec count(table(), atom(), keyword()) :: non_neg_integer()
  def count(table, platform \\ :all, opts \\ []) do
    since = Keyword.get(opts, :since, 0)
    client = Keyword.get(opts, :client, :all)
    :ets.select_count(table, count_spec(platform, client, since))
  end

  @doc "Total rows in the table, regardless of platform or age."
  @spec size(table()) :: non_neg_integer()
  def size(table), do: :ets.info(table, :size)

  @doc """
  Drops mentions older than `cutoff` (ms epoch), then trims the oldest rows
  until at most `max` remain. Returns the number of rows deleted.

  Both bounds matter: the age bound keeps the window meaningful, the size
  bound keeps memory flat if a platform floods us inside the window.
  """
  @spec prune(table(), integer(), pos_integer()) :: non_neg_integer()
  def prune(table, cutoff, max) do
    expired = delete_older_than(table, cutoff)
    over_capacity = trim_to(table, max)
    expired + over_capacity
  end

  @doc "Removes everything. Used by tests."
  @spec clear(table()) :: :ok
  def clear(table) do
    :ets.delete_all_objects(table)
    :ok
  end

  # --- internals ------------------------------------------------------------

  defp key(%Mention{id: id, platform: platform, client_id: client_id} = mention) do
    {Mention.epoch_ms(mention), platform, client_id, id}
  end

  # Backwards traversal of the ordered_set: newest keys first. Stops as soon
  # as we hit the window boundary or the limit, so a long-lived table doesn't
  # make the TUI's read O(table).
  defp walk_back(_table, :"$end_of_table", _scope, _since, _remaining, acc), do: acc
  defp walk_back(_table, _key, _scope, _since, 0, acc), do: acc

  defp walk_back(table, {timestamp, _platform, _client, _id} = key, scope, since, remaining, acc)
       when timestamp >= since do
    {acc, remaining} =
      case :ets.lookup(table, key) do
        [{^key, mention}] ->
          if matches?(mention, scope),
            do: {[mention | acc], decrement(remaining)},
            else: {acc, remaining}

        [] ->
          {acc, remaining}
      end

    walk_back(table, :ets.prev(table, key), scope, since, remaining, acc)
  end

  # First key older than the window — everything before it is older still.
  defp walk_back(_table, _key, _scope, _since, _remaining, acc), do: acc

  defp decrement(:infinity), do: :infinity
  defp decrement(remaining), do: remaining - 1

  defp matches?(%Mention{} = mention, {platform, client}) do
    matches_platform?(mention, platform) and matches_client?(mention, client)
  end

  defp matches_platform?(%Mention{}, :all), do: true
  defp matches_platform?(%Mention{platform: platform}, platform), do: true
  defp matches_platform?(%Mention{}, _platform), do: false

  defp matches_client?(%Mention{}, :all), do: true
  defp matches_client?(%Mention{client_id: client_id}, client_id), do: true
  defp matches_client?(%Mention{}, _client), do: false

  # The timestamp, platform and client all live in the key, so counting
  # never has to look at the stored struct.
  defp count_spec(platform, client, since) do
    pattern = {{:"$1", match_or_any(platform), match_or_any(client), :_}, :_}
    [{pattern, [{:>=, :"$1", since}], [true]}]
  end

  defp match_or_any(:all), do: :_
  defp match_or_any(value), do: value

  defp delete_older_than(table, cutoff) do
    spec = [{{{:"$1", :_, :_, :_}, :_}, [{:<, :"$1", cutoff}], [true]}]
    :ets.select_delete(table, spec)
  end

  defp trim_to(table, max) do
    excess = size(table) - max
    if excess > 0, do: delete_oldest(table, excess, 0), else: 0
  end

  defp delete_oldest(_table, 0, deleted), do: deleted

  defp delete_oldest(table, remaining, deleted) do
    case :ets.first(table) do
      :"$end_of_table" ->
        deleted

      key ->
        :ets.delete(table, key)
        delete_oldest(table, remaining - 1, deleted + 1)
    end
  end
end
