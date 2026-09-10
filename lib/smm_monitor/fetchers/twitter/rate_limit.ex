defmodule SmmMonitor.Fetchers.Twitter.RateLimit do
  @moduledoc """
  Tracks X's per-15-minute request window for recent search.

  X reports the window on every response:

    * `x-rate-limit-limit`     — requests allowed in this window
    * `x-rate-limit-remaining` — requests left
    * `x-rate-limit-reset`     — **unix epoch seconds** when it resets

  That last one is the difference from Reddit, which reports *seconds
  until* reset. Reading X's absolute timestamp as a duration would put the
  reset somewhere in 2057 and stand the platform down forever, so it is
  converted here and nowhere else.

  The documented ceiling for recent search is 450 requests per 15 minutes
  per app, but it differs by access tier and X has changed it more than
  once. So the headers are believed over any number compiled in, and the
  local ceiling below is only a floor to sit behind until the first
  response arrives.

  Like Reddit's tracker this is a struct plus functions, living in the
  worker's state with no process of its own.
  """

  # Never spend the last few requests of a window: something else may share
  # these credentials, and a hard 429 costs more than a skipped poll.
  @reserve 5

  # Used only before X has told us anything. Deliberately far below the
  # documented 450: on a 30s poll interval a single poll per window is all
  # this app needs, so there is no reason to run near any tier's edge.
  @self_imposed_limit 45
  @window_ms :timer.minutes(15)

  defstruct limit: nil,
            remaining: nil,
            reset_at: nil,
            observed_at: nil,
            # Request timestamps (ms) inside the current window, newest first.
            recent_requests: []

  @type t :: %__MODULE__{
          limit: float() | nil,
          remaining: float() | nil,
          reset_at: integer() | nil,
          observed_at: integer() | nil,
          recent_requests: [integer()]
        }

  @type decision :: :ok | {:backoff, pos_integer()}

  @doc "A fresh, unobserved tracker."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Whether another search is safe right now.

  Returns `:ok`, or `{:backoff, ms}` with how long to wait.
  """
  @spec check(t(), integer()) :: decision()
  def check(rate_limit, now_ms \\ System.system_time(:millisecond)) do
    cond do
      exhausted?(rate_limit, now_ms) ->
        {:backoff, max(rate_limit.reset_at - now_ms, 1_000)}

      self_limited?(rate_limit, now_ms) ->
        {:backoff, @window_ms}

      true ->
        :ok
    end
  end

  @doc "Records that a request is about to be made."
  @spec record_request(t(), integer()) :: t()
  def record_request(rate_limit, now_ms \\ System.system_time(:millisecond)) do
    recent = Enum.filter([now_ms | rate_limit.recent_requests], &(now_ms - &1 < @window_ms))
    %{rate_limit | recent_requests: recent}
  end

  @doc """
  Records the rate-limit headers from a response.

  Absent or unparseable headers leave the previous reading alone: a
  malformed header must not look like a fresh window.
  """
  @spec observe(t(), Enumerable.t(), integer()) :: t()
  def observe(rate_limit, headers, now_ms \\ System.system_time(:millisecond)) do
    headers = normalize_headers(headers)

    limit = parse_number(headers["x-rate-limit-limit"])
    remaining = parse_number(headers["x-rate-limit-remaining"])
    reset_epoch_s = parse_number(headers["x-rate-limit-reset"])

    %{
      rate_limit
      | limit: limit || rate_limit.limit,
        remaining: remaining || rate_limit.remaining,
        reset_at: reset_at(reset_epoch_s, rate_limit.reset_at),
        observed_at:
          if(limit || remaining || reset_epoch_s, do: now_ms, else: rate_limit.observed_at)
    }
  end

  @doc """
  Milliseconds until the window resets, or `nil` if X hasn't said.

  Used as the backoff after a 429, where the reset time is the only
  honest answer to "when should we try again?".
  """
  @spec ms_until_reset(t(), integer()) :: pos_integer() | nil
  def ms_until_reset(rate_limit, now_ms \\ System.system_time(:millisecond))
  def ms_until_reset(%__MODULE__{reset_at: nil}, _now_ms), do: nil

  def ms_until_reset(%__MODULE__{reset_at: reset_at}, now_ms),
    do: max(reset_at - now_ms, 1_000)

  @doc """
  A short summary for logs and the dashboard.

  `nil` before the first response has been seen.
  """
  @spec summary(t()) :: String.t() | nil
  def summary(%__MODULE__{remaining: nil}), do: nil

  def summary(%__MODULE__{remaining: remaining, limit: nil}),
    do: "#{trunc(remaining)} requests left this window"

  def summary(%__MODULE__{remaining: remaining, limit: limit}),
    do: "#{trunc(remaining)}/#{trunc(limit)} requests left this window"

  # --- internals ------------------------------------------------------------

  defp exhausted?(%__MODULE__{remaining: nil}, _now_ms), do: false
  defp exhausted?(%__MODULE__{reset_at: nil}, _now_ms), do: false

  defp exhausted?(%__MODULE__{remaining: remaining, reset_at: reset_at}, now_ms) do
    remaining <= @reserve and now_ms < reset_at
  end

  defp self_limited?(%__MODULE__{recent_requests: recent}, now_ms) do
    recent
    |> Enum.count(&(now_ms - &1 < @window_ms))
    |> Kernel.>=(@self_imposed_limit)
  end

  # X sends an absolute epoch; Reddit sends a duration. This is the one
  # place that difference is allowed to matter.
  defp reset_at(nil, previous), do: previous
  defp reset_at(epoch_s, _previous), do: trunc(epoch_s * 1_000)

  # Req lowercases header names and gives lists of values; tolerate a plain
  # map too, so this is easy to test.
  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), value |> List.wrap() |> List.first()}
    end)
  end

  defp parse_number(nil), do: nil
  defp parse_number(value) when is_number(value), do: value * 1.0

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp parse_number(_value), do: nil
end
