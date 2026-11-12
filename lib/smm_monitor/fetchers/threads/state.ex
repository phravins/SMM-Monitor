defmodule SmmMonitor.Fetchers.Threads.State do
  @moduledoc """
  What the Threads fetcher carries between polls.

    * the access token in use, and when it was last renewed and expires
      (see `SmmMonitor.Fetchers.Threads.Token`);
    * the connected account's id and username, looked up once;
    * how far each client has read: the newest post time seen per search
      term and in the mentions feed, so a poll asks only for what is new;
    * the keyword-search budget.

  The token is left out of `inspect/1`, so it can't reach a log line or a
  crash report through this struct. The worker redacts its whole platform
  state from status and crash output as well.

  Times are Unix milliseconds, except the read positions, which are Unix
  seconds because that is what the API's `since` takes.
  """

  alias SmmMonitor.Fetchers.Threads.QueryBudget

  @derive {Inspect, except: [:token]}
  defstruct token: nil,
            seed_hash: nil,
            first_seen_at: nil,
            refreshed_at: nil,
            expires_at: nil,
            next_refresh_at: nil,
            expiry_warned_at: nil,
            user_id: nil,
            username: nil,
            cursors: %{},
            matchers: %{},
            budget: nil,
            cadence_checked: false

  @type t :: %__MODULE__{
          token: String.t() | nil,
          seed_hash: String.t() | nil,
          first_seen_at: integer() | nil,
          refreshed_at: integer() | nil,
          expires_at: integer() | nil,
          next_refresh_at: integer() | nil,
          expiry_warned_at: integer() | nil,
          user_id: String.t() | nil,
          username: String.t() | nil,
          cursors: %{optional(term()) => integer()},
          matchers: %{optional(term()) => SmmMonitor.Matching.t()},
          budget: QueryBudget.t(),
          cadence_checked: boolean()
        }

  @doc "Fresh state with the given keyword-search budget."
  @spec new(integer() | nil) :: t()
  def new(budget \\ nil), do: %__MODULE__{budget: QueryBudget.new(budget)}

  @doc "The read position stored under `key`, in Unix seconds, or nil."
  @spec cursor(t(), term()) :: integer() | nil
  def cursor(%__MODULE__{cursors: cursors}, key), do: Map.get(cursors, key)

  @doc "Moves the read position under `key` forward, never back."
  @spec advance_cursor(t(), term(), integer() | nil) :: t()
  def advance_cursor(state, _key, nil), do: state

  def advance_cursor(%__MODULE__{cursors: cursors} = state, key, seconds) do
    %{state | cursors: Map.update(cursors, key, seconds, &max(&1, seconds))}
  end
end
