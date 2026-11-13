defmodule SmmMonitor.Fetchers.Reddit.State do
  @moduledoc """
  What the Reddit fetcher carries between polls.

    * `auth` and `rate_limit`: the OAuth token cache and the quota Reddit
      last reported;
    * `listings`: the subreddit listings already read and the items not
      yet handed to every client (`Reddit.Listings`);
    * `searched_at`: per client, when site-wide search last ran, so it
      keeps its own slower cadence;
    * `bad_subs`: subreddits Reddit refused (private, banned, misspelt),
      left out for an hour;
    * `warned`: names already warned about, so a log says it once.

  This lives in the Reddit worker's GenServer state, so it is private to
  that process and discarded if the worker restarts.
  """

  alias SmmMonitor.Fetchers.Reddit.{Auth, Listings, RateLimit}

  defstruct auth: nil,
            rate_limit: nil,
            listings: %Listings{},
            searched_at: %{},
            bad_subs: %{},
            warned: MapSet.new()

  @type t :: %__MODULE__{
          auth: Auth.t(),
          rate_limit: RateLimit.t(),
          listings: Listings.t(),
          searched_at: %{optional(term()) => integer()},
          bad_subs: %{optional(String.t()) => {term(), integer()}},
          warned: MapSet.t()
        }

  @doc "Fresh state: no token, no observed quota, nothing read yet."
  @spec new() :: t()
  def new, do: %__MODULE__{auth: Auth.new(), rate_limit: RateLimit.new()}
end
