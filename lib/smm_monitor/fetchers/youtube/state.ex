defmodule SmmMonitor.Fetchers.YouTube.State do
  @moduledoc """
  What the YouTube fetcher carries between polls: its quota tracker.

  There is no token to cache — the Data API takes a plain API key in the
  query string — so this is thinner than Reddit's equivalent. It exists so
  the day's quota spend survives from one poll to the next, and is
  discarded if the worker restarts.
  """

  alias SmmMonitor.Fetchers.YouTube.Quota

  defstruct quota: nil

  @type t :: %__MODULE__{quota: Quota.t()}

  @doc "Fresh state with an unspent quota budget for today."
  @spec new(pos_integer()) :: t()
  def new(budget \\ 8_000), do: %__MODULE__{quota: Quota.new(budget)}
end
