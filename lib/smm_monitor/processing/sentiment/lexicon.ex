defmodule SmmMonitor.Processing.Sentiment.Lexicon do
  @moduledoc """
  Loads the sentiment word lists from disk.

  The lists live in plain text files — one word per line, `#` for
  comments — rather than inline in the scoring code, so they can be tuned
  without touching logic. See `priv/sentiment/README.md`.

  ## Where they load from

  Packaged defaults ship in the release's `priv/sentiment`. Setting
  `SMM_SENTIMENT_DIR` (or `:sentiment_dir`) points at an override
  directory, and any file present there wins — so you can override one
  list and inherit the rest. That matters on a server: a deploy replaces
  the release directory, so tuned lists belong somewhere like
  `/etc/smm-monitor/sentiment`.

  ## Caching

  Scoring runs on every mention, so the lists are read once and held in
  `:persistent_term` — built for exactly this shape of data, read
  constantly and written approximately never. `reload/0` re-reads from
  disk after an edit.

  ## Failure

  Nothing here raises. A missing directory falls back to the packaged
  lists; a missing or unreadable individual file falls back to its
  packaged version and, failing that, to an empty list, with a warning
  naming the file. A word list you can't read is a reason to score less
  well, not a reason for the app to stop collecting.
  """

  require Logger

  @categories [
    :strong_positive,
    :mild_positive,
    :strong_negative,
    :mild_negative,
    :negators,
    :intensifiers,
    :downtoners
  ]

  @cache_key {__MODULE__, :lists}

  @type category ::
          :strong_positive
          | :mild_positive
          | :strong_negative
          | :mild_negative
          | :negators
          | :intensifiers
          | :downtoners

  @type t :: %{category() => MapSet.t(String.t())}

  @doc "The categories the scorer knows about, in file-name order."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc """
  Every list, as a map of category to a `MapSet` of words.

  Cached after the first call; `reload/0` refreshes it.
  """
  @spec lists() :: t()
  def lists do
    case :persistent_term.get(@cache_key, nil) do
      nil -> reload()
      lists -> lists
    end
  end

  @doc "The words in one category."
  @spec words(category()) :: MapSet.t(String.t())
  def words(category), do: Map.get(lists(), category, MapSet.new())

  @doc "Whether `word` is in `category`. The hot path during scoring."
  @spec member?(category(), String.t()) :: boolean()
  def member?(category, word), do: MapSet.member?(words(category), word)

  @doc """
  Re-reads every list from disk and replaces the cache.

  Call after editing a file; there is no file watcher, deliberately —
  re-reading on a change would mean scoring could shift mid-run with no
  record of why.
  """
  @spec reload() :: t()
  def reload do
    lists = Map.new(@categories, fn category -> {category, load(category)} end)
    :persistent_term.put(@cache_key, lists)
    lists
  end

  @doc "Drops the cache. Used by tests."
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  The override directory, if one is configured.

  `SMM_SENTIMENT_DIR` wins, then `:sentiment_dir`, then the per-user or
  systemd config directory if it happens to contain a `sentiment` folder.
  """
  @spec override_dir() :: Path.t() | nil
  def override_dir do
    explicit = System.get_env("SMM_SENTIMENT_DIR") || SmmMonitor.config(:sentiment_dir)

    cond do
      is_binary(explicit) and explicit != "" -> explicit
      File.dir?(conventional_dir()) -> conventional_dir()
      true -> nil
    end
  end

  @doc "Where the packaged lists live inside the app."
  @spec default_dir() :: Path.t()
  def default_dir do
    case :code.priv_dir(:smm_monitor) do
      {:error, _reason} -> Path.join(["priv", "sentiment"])
      dir -> Path.join([to_string(dir), "sentiment"])
    end
  end

  @doc """
  Where each category was actually read from — the override directory,
  the packaged default, or nowhere. Shown by the diagnostics in the
  README so a tuning session can confirm the file being edited is the
  file being used.
  """
  @spec sources() :: %{category() => Path.t() | :none}
  def sources do
    Map.new(@categories, fn category -> {category, source_for(category)} end)
  end

  @doc """
  Parses word-list content.

      iex> alias SmmMonitor.Processing.Sentiment.Lexicon
      iex> Lexicon.parse("# a comment\\n\\nGood\\n  great  \\n")
      ["good", "great"]
  """
  @spec parse(String.t()) :: [String.t()]
  def parse(contents) do
    contents
    |> String.split(["\n", "\r\n"])
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.uniq()
  end

  # --- internals ------------------------------------------------------------

  defp load(category) do
    case source_for(category) do
      :none ->
        Logger.warning(
          "sentiment: no word list found for #{category} (looked in " <>
            "#{inspect(override_dir())} and #{default_dir()}); scoring without it"
        )

        MapSet.new()

      path ->
        read(path, category)
    end
  end

  defp read(path, category) do
    case File.read(path) do
      {:ok, contents} ->
        MapSet.new(parse(contents))

      {:error, reason} ->
        Logger.warning(
          "sentiment: could not read #{path} for #{category} (#{inspect(reason)}); " <>
            "scoring without it"
        )

        MapSet.new()
    end
  end

  # An override file wins, but only if it is actually readable — a
  # half-written override shouldn't silently disable a whole category.
  defp source_for(category) do
    file = "#{category}.txt"
    override = if dir = override_dir(), do: Path.join(dir, file)
    packaged = Path.join(default_dir(), file)

    cond do
      override && File.regular?(override) -> override
      File.regular?(packaged) -> packaged
      true -> :none
    end
  end

  defp conventional_dir, do: SmmMonitor.Paths.config("sentiment")
end
