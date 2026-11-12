defmodule SmmMonitor.Fetchers.MetaGraph do
  @moduledoc """
  What a Meta Graph API error means, for the fetchers that talk to Meta
  (Instagram and Threads).

  Both APIs answer a failed call with the same body,
  `{"error": {"message", "code", "error_subcode", "error_data"}}`, and the
  same codes mean the same things. Reading them in one place keeps the two
  fetchers from drifting apart on, say, which code means "throttled".
  """

  @typedoc "What went wrong, in the terms a fetcher acts on."
  @type kind ::
          :expired_token
          | {:throttled, minutes :: number() | nil}
          | :missing_permission
          | :other

  @doc """
  Classifies a Graph API error body.

  Returns the kind and Meta's message (or nil when there is none).

      iex> alias SmmMonitor.Fetchers.MetaGraph
      iex> MetaGraph.classify(%{"error" => %{"code" => 190, "message" => "expired"}})
      {:expired_token, "expired"}
      iex> MetaGraph.classify(%{"error" => %{"code" => 4, "error_data" => %{"estimated_time_to_regain_access" => 7}}})
      {{:throttled, 7}, nil}
      iex> MetaGraph.classify(%{"error" => %{"code" => 10, "message" => "no"}})
      {:missing_permission, "no"}
      iex> MetaGraph.classify("not json")
      {:other, nil}
  """
  @spec classify(term()) :: {kind(), String.t() | nil}
  def classify(body) do
    error = error(body)
    message = if is_binary(error["message"]), do: error["message"]

    kind =
      cond do
        # 190 (and the 463/467 subcodes): the token has expired or been
        # revoked. The commonest way a Meta integration stops working.
        expired_token?(error) -> :expired_token
        # 4 and 17 are app/user rate limits, 32 page-level, 613 per-edge.
        throttled?(error) -> {:throttled, regain_minutes(error)}
        # 10 and 200..299: the token is fine but this edge isn't granted.
        permission_error?(error) -> :missing_permission
        true -> :other
      end

    {kind, message}
  end

  @doc "The `error` object of a Graph API error body, or an empty map."
  @spec error(term()) :: map()
  def error(%{"error" => %{} = error}), do: error
  def error(_body), do: %{}

  defp expired_token?(%{"code" => 190}), do: true
  defp expired_token?(%{"error_subcode" => subcode}) when subcode in [463, 467], do: true
  defp expired_token?(_error), do: false

  defp throttled?(%{"code" => code}) when code in [4, 17, 32, 613], do: true
  defp throttled?(_error), do: false

  defp permission_error?(%{"code" => 10}), do: true
  defp permission_error?(%{"code" => code}) when code in 200..299, do: true
  defp permission_error?(_error), do: false

  defp regain_minutes(error) do
    case get_in(error, ["error_data", "estimated_time_to_regain_access"]) do
      minutes when is_number(minutes) and minutes > 0 -> minutes
      _other -> nil
    end
  end
end
