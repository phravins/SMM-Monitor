defmodule SmmMonitor.Fetchers.Instagram.Throttle do
  @moduledoc """
  Tracks Meta's platform rate limiting for the Instagram Graph API.

  Meta doesn't report a request budget the way Reddit and X do. It
  reports **percentages of an opaque limit**, in one of two headers:

    * `x-business-use-case-usage` — per business account, an object keyed
      by account id whose entries carry `call_count`, `total_cputime` and
      `total_time` as percentages of the hour's allowance, plus
      `estimated_time_to_regain_access` in minutes once throttled;
    * `x-app-usage` — the same three percentages for the app as a whole.

  So there is no "requests remaining" to count down. What there is: a
  number that reaches 100 and a stated number of minutes to wait when it
  does. This backs off at 90% rather than at 100, because the percentage
  is reported *after* the call that pushed it there.

  A struct plus functions, living in the worker's state.
  """

  # Back off before Meta does. Crossing 100 costs the account access for
  # a stated number of minutes, which is far worse than a skipped poll.
  @backoff_threshold 90

  # Used when Meta throttles without saying for how long.
  @default_wait_ms :timer.minutes(5)

  defstruct usage: nil,
            blocked_until: nil,
            observed_at: nil

  @type t :: %__MODULE__{
          usage: non_neg_integer() | nil,
          blocked_until: integer() | nil,
          observed_at: integer() | nil
        }

  @type decision :: :ok | {:backoff, pos_integer()}

  @doc "A fresh, unobserved tracker."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Whether another request is safe right now.

  Returns `:ok`, or `{:backoff, ms}` with how long to wait.
  """
  @spec check(t(), integer()) :: decision()
  def check(throttle, now_ms \\ System.system_time(:millisecond))

  def check(%__MODULE__{blocked_until: blocked_until}, now_ms)
      when is_integer(blocked_until) and blocked_until > 0 do
    if now_ms < blocked_until do
      {:backoff, max(blocked_until - now_ms, 1_000)}
    else
      :ok
    end
  end

  def check(%__MODULE__{usage: usage}, _now_ms)
      when is_integer(usage) and usage >= @backoff_threshold do
    {:backoff, @default_wait_ms}
  end

  def check(%__MODULE__{}, _now_ms), do: :ok

  @doc """
  Records Meta's usage headers from a response.

  Both header shapes are accepted, and the highest percentage across the
  three metrics wins: hitting the CPU-time limit throttles just as hard
  as hitting the call-count one.
  """
  @spec observe(t(), Enumerable.t(), integer()) :: t()
  def observe(throttle, headers, now_ms \\ System.system_time(:millisecond)) do
    headers = normalize_headers(headers)

    usage =
      parse_business_usage(headers["x-business-use-case-usage"]) ||
        parse_app_usage(headers["x-app-usage"])

    case usage do
      nil ->
        throttle

      {percent, regain_minutes} ->
        %{
          throttle
          | usage: percent,
            blocked_until: blocked_until(regain_minutes, now_ms, throttle.blocked_until),
            observed_at: now_ms
        }
    end
  end

  @doc """
  Records that Meta has throttled us outright, with an optional wait in
  minutes taken from the error payload.
  """
  @spec block(t(), number() | nil, integer()) :: t()
  def block(throttle, minutes \\ nil, now_ms \\ System.system_time(:millisecond)) do
    wait_ms =
      case minutes do
        m when is_number(m) and m > 0 -> trunc(m * 60_000)
        _none -> @default_wait_ms
      end

    %{throttle | usage: 100, blocked_until: now_ms + wait_ms, observed_at: now_ms}
  end

  @doc "A short summary for logs. `nil` before anything has been observed."
  @spec summary(t()) :: String.t() | nil
  def summary(%__MODULE__{usage: nil}), do: nil
  def summary(%__MODULE__{usage: usage}), do: "#{usage}% of Meta's hourly allowance used"

  # --- internals ------------------------------------------------------------

  defp blocked_until(minutes, now_ms, _previous) when is_number(minutes) and minutes > 0,
    do: now_ms + trunc(minutes * 60_000)

  defp blocked_until(_minutes, _now_ms, previous), do: previous

  # {"<business-id>": [{"type": "instagram", "call_count": 28, ...}]}
  defp parse_business_usage(nil), do: nil

  defp parse_business_usage(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) ->
        decoded
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&is_map/1)
        |> Enum.map(&{peak_percent(&1), &1["estimated_time_to_regain_access"]})
        |> Enum.reject(fn {percent, _minutes} -> is_nil(percent) end)
        |> Enum.max_by(fn {percent, _minutes} -> percent end, fn -> nil end)

      _other ->
        nil
    end
  end

  defp parse_business_usage(_value), do: nil

  # {"call_count": 28, "total_cputime": 5, "total_time": 10}
  defp parse_app_usage(nil), do: nil

  defp parse_app_usage(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) ->
        case peak_percent(decoded) do
          nil -> nil
          percent -> {percent, nil}
        end

      _other ->
        nil
    end
  end

  defp parse_app_usage(_value), do: nil

  # Any one of the three metrics reaching the limit throttles the account,
  # so the worst is the one that matters.
  defp peak_percent(entry) do
    ~w(call_count total_cputime total_time)
    |> Enum.map(&Map.get(entry, &1))
    |> Enum.filter(&is_number/1)
    |> case do
      [] -> nil
      percents -> percents |> Enum.max() |> trunc()
    end
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), value |> List.wrap() |> List.first()}
    end)
  end
end
