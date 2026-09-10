defmodule SmmMonitor.Fetchers.Reddit.RateLimit do
  @moduledoc """
  Tracks Reddit's OAuth rate limit: 60 requests per minute per client.

  Reddit reports the current window on every response:

    * `x-ratelimit-used`      — requests used in this window
    * `x-ratelimit-remaining` — requests left (a float string, e.g. `"58.0"`)
    * `x-ratelimit-reset`     — seconds until the window resets

  `observe/3` records those headers and `check/2` decides whether it is
  safe to make another request. We stop short of zero — five requests are
  held in reserve — so a burst from somewhere else using the same
  credentials can't push us into a hard 429.

  Until the first response comes back there are no headers to go on, so a
  local count of requests made in the last minute stands in. That matters
  on startup, where several polls could otherwise fire before we have ever
  seen a header.

  Like `Reddit.Auth`, this is a struct plus functions: it lives in the
  worker's state and needs no process of its own.
  """

  # Never spend the last few requests of a window.
  @reserve 5

  # Local ceiling used before Reddit has told us anything.
  @self_imposed_limit 55
  @window_ms :timer.minutes(1)

  defstruct remaining: nil,
            reset_at: nil,
            used: nil,
            observed_at: nil,
            # Monotonic-ish timestamps (ms) of recent requests, newest first.
            recent_requests: []

  @type t :: %__MODULE__{
          remaining: float() | nil,
          reset_at: integer() | nil,
          used: float() | nil,
          observed_at: integer() | nil,
          recent_requests: [integer()]
        }

  @type decision :: :ok | {:backoff, pos_integer()}

  @doc "A fresh, unobserved rate-limit tracker."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Whether another request is safe right now.

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

  @doc """
  Records that a request is about to be made.

  Feeds the local fallback counter, which is all we have before Reddit's
  headers arrive.
  """
  @spec record_request(t(), integer()) :: t()
  def record_request(rate_limit, now_ms \\ System.system_time(:millisecond)) do
    recent =
      [now_ms | rate_limit.recent_requests]
      |> Enum.filter(&(now_ms - &1 < @window_ms))

    %{rate_limit | recent_requests: recent}
  end

  @doc """
  Records the rate-limit headers from a response.

  Unparseable or absent headers leave the previous reading in place rather
  than resetting it — a malformed header shouldn't look like a fresh quota.
  """
  @spec observe(t(), Enumerable.t(), integer()) :: t()
  def observe(rate_limit, headers, now_ms \\ System.system_time(:millisecond)) do
    headers = normalize_headers(headers)

    remaining = parse_number(headers["x-ratelimit-remaining"])
    used = parse_number(headers["x-ratelimit-used"])
    reset_in_s = parse_number(headers["x-ratelimit-reset"])

    %{
      rate_limit
      | remaining: remaining || rate_limit.remaining,
        used: used || rate_limit.used,
        reset_at: if(reset_in_s, do: now_ms + trunc(reset_in_s * 1_000), else: rate_limit.reset_at),
        observed_at: if(remaining || used || reset_in_s, do: now_ms, else: rate_limit.observed_at)
    }
  end

  @doc """
  A short summary for logs and the dashboard's status line.

  `nil` before the first response has been seen.
  """
  @spec summary(t()) :: String.t() | nil
  def summary(%__MODULE__{remaining: nil}), do: nil

  def summary(%__MODULE__{remaining: remaining}) do
    "#{trunc(remaining)} requests left this minute"
  end

  # --- internals ------------------------------------------------------------

  # Reddit says we're near the end of the window and it hasn't reset yet.
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

  # Req lowercases header names and gives lists of values; be tolerant of
  # both that and a plain map, so this is easy to test.
  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), List.wrap(value) |> List.first()}
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
