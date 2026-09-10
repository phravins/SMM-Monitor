defmodule SmmMonitor.Fetchers.Twitter.State do
  @moduledoc """
  What the Twitter fetcher carries between polls.

  Two limit trackers, because X applies two: the per-15-minute request
  window it reports in headers, and the monthly post cap it reports
  nowhere. Neither survives a worker restart, which is deliberate — a
  restarted worker re-reads the window from the next response, and the
  post budget resets conservatively low rather than optimistically high.

  There is no token to cache: app-only auth is a static bearer token read
  from the environment, so unlike Reddit there is nothing to refresh.
  """

  alias SmmMonitor.Fetchers.Twitter.{PostBudget, RateLimit}

  defstruct rate_limit: nil, post_budget: nil

  @type t :: %__MODULE__{rate_limit: RateLimit.t(), post_budget: PostBudget.t()}

  @doc "Fresh state with an unobserved window and an unspent post budget."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(monthly_post_budget \\ 10_000, cycle_day \\ 1) do
    %__MODULE__{
      rate_limit: RateLimit.new(),
      post_budget: PostBudget.new(monthly_post_budget, cycle_day)
    }
  end
end
