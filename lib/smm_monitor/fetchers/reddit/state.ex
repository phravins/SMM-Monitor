defmodule SmmMonitor.Fetchers.Reddit.State do
  @moduledoc """
  What the Reddit fetcher carries between polls.

  Just the OAuth token cache and the rate-limit tracker, both plain
  structs. This lives in the Reddit worker's GenServer state, so it is
  private to that process and discarded if the worker restarts.
  """

  alias SmmMonitor.Fetchers.Reddit.{Auth, RateLimit}

  defstruct auth: nil, rate_limit: nil

  @type t :: %__MODULE__{auth: Auth.t(), rate_limit: RateLimit.t()}

  @doc "Fresh state: no token, no observed quota."
  @spec new() :: t()
  def new, do: %__MODULE__{auth: Auth.new(), rate_limit: RateLimit.new()}
end
