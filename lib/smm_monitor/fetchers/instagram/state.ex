defmodule SmmMonitor.Fetchers.Instagram.State do
  @moduledoc """
  What the Instagram fetcher carries between polls.

  Meta's throttle reading, and the hashtag ids resolved so far.

  Hashtag ids are cached because resolving one costs a request and the
  ids are stable — `#realoffice` has the same id tomorrow. It is a cache
  and not a source of truth: a worker restart simply resolves them again.
  """

  alias SmmMonitor.Fetchers.Instagram.Throttle

  defstruct throttle: nil, hashtag_ids: %{}

  @type t :: %__MODULE__{throttle: Throttle.t(), hashtag_ids: %{String.t() => String.t()}}

  @doc "Fresh state: nothing observed, nothing resolved."
  @spec new() :: t()
  def new, do: %__MODULE__{throttle: Throttle.new(), hashtag_ids: %{}}

  @doc "Remembers the id Meta gave for a hashtag."
  @spec put_hashtag_id(t(), String.t(), String.t()) :: t()
  def put_hashtag_id(%__MODULE__{} = state, hashtag, id) do
    %{state | hashtag_ids: Map.put(state.hashtag_ids, hashtag, id)}
  end

  @doc "The cached id for a hashtag, or `nil`."
  @spec hashtag_id(t(), String.t()) :: String.t() | nil
  def hashtag_id(%__MODULE__{} = state, hashtag), do: Map.get(state.hashtag_ids, hashtag)
end
