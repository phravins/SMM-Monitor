defmodule SmmMonitor.Fetchers.Reddit.Auth do
  @moduledoc """
  OAuth2 token handling for Reddit's "script" app type.

  Reddit's script apps use the `client_credentials` grant: POST the client
  id and secret as HTTP Basic auth, get back a bearer token that lasts
  about an hour. There is no user, no redirect and no approval wait, which
  is why it's the right fit for a monitoring tool.

  This module is a plain struct plus functions — no process of its own. The
  struct lives in the Reddit worker's GenServer state, so the token is
  cached across polls and a worker crash simply starts again with a fresh
  one.

  The token is refreshed when it is within five minutes of expiring rather
  than after a 401, so a poll never has to fail to discover the token died.
  """

  require Logger

  @token_url "https://www.reddit.com/api/v1/access_token"

  # Refresh this far ahead of the stated expiry. Reddit's tokens last an
  # hour and our poll interval is measured in seconds, so a generous margin
  # costs nothing and removes any chance of racing the expiry.
  @refresh_margin_ms :timer.minutes(5)

  # Reddit rejects requests with a generic or empty user agent.
  @default_user_agent "smm_monitor/0.1 (SMM Monitor)"

  defstruct token: nil, expires_at: nil, obtained_at: nil, refreshes: 0

  @type t :: %__MODULE__{
          token: String.t() | nil,
          expires_at: integer() | nil,
          obtained_at: DateTime.t() | nil,
          refreshes: non_neg_integer()
        }

  @doc "A new, empty token cache."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Returns a usable bearer token, fetching a new one only if needed.

  Returns `{:ok, token, auth}` or `{:error, reason, auth}`; the returned
  struct is carried into the next poll either way.
  """
  @spec token(t(), keyword(), keyword()) :: {:ok, String.t(), t()} | {:error, term(), t()}
  def token(%__MODULE__{} = auth, credentials, req_options \\ []) do
    if valid?(auth) do
      {:ok, auth.token, auth}
    else
      refresh(auth, credentials, req_options)
    end
  end

  @doc """
  Whether the cached token is present and not close to expiring.

  `now_ms` is injectable so tests can pin the clock.
  """
  @spec valid?(t(), integer()) :: boolean()
  def valid?(auth, now_ms \\ System.system_time(:millisecond))

  def valid?(%__MODULE__{token: nil}, _now_ms), do: false
  def valid?(%__MODULE__{expires_at: nil}, _now_ms), do: false

  def valid?(%__MODULE__{expires_at: expires_at}, now_ms) do
    now_ms < expires_at - @refresh_margin_ms
  end

  @doc """
  Discards the cached token, so the next call fetches a fresh one.

  Used when Reddit rejects a token we believed was still good (a 401),
  which can happen if it was revoked server-side.
  """
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{} = auth), do: %{auth | token: nil, expires_at: nil}

  @doc "Milliseconds until the cached token is considered stale."
  @spec expires_in_ms(t(), integer()) :: integer() | nil
  def expires_in_ms(auth, now_ms \\ System.system_time(:millisecond))
  def expires_in_ms(%__MODULE__{expires_at: nil}, _now_ms), do: nil
  def expires_in_ms(%__MODULE__{expires_at: expires_at}, now_ms), do: expires_at - now_ms

  @doc "The user agent to send, from config or a sensible default."
  @spec user_agent(keyword()) :: String.t()
  def user_agent(credentials) do
    case credentials[:user_agent] do
      agent when is_binary(agent) and agent != "" -> agent
      _missing -> @default_user_agent
    end
  end

  # --- internals ------------------------------------------------------------

  defp refresh(auth, credentials, req_options) do
    with {:ok, client_id, client_secret} <- credential_pair(credentials) do
      request =
        Req.new(
          [
            url: @token_url,
            method: :post,
            auth: {:basic, "#{client_id}:#{client_secret}"},
            form: [grant_type: "client_credentials"],
            headers: [{"user-agent", user_agent(credentials)}],
            receive_timeout: 10_000,
            # We do our own retrying: the worker polls again on a schedule.
            # Req's default would also retry a 429, which is exactly the
            # request we must not repeat.
            retry: false
          ] ++ req_options
        )

      request
      |> Req.request()
      |> handle_token_response(auth)
    else
      {:error, reason} -> {:error, reason, auth}
    end
  end

  defp handle_token_response({:ok, %{status: 200, body: body}}, auth) do
    case body do
      %{"access_token" => token} = decoded when is_binary(token) ->
        # Reddit reports expires_in in seconds; default to an hour if absent.
        expires_in_s = decoded["expires_in"] || 3_600

        auth = %{
          auth
          | token: token,
            expires_at: System.system_time(:millisecond) + expires_in_s * 1_000,
            obtained_at: DateTime.utc_now(),
            refreshes: auth.refreshes + 1
        }

        Logger.info("reddit: obtained OAuth token, valid for #{expires_in_s}s")
        {:ok, token, auth}

      other ->
        {:error, {:unexpected_token_response, other}, auth}
    end
  end

  # 401 here means the client id/secret pair itself is wrong — worth calling
  # out separately, because it's the most common setup mistake.
  defp handle_token_response({:ok, %{status: 401}}, auth) do
    {:error, :invalid_credentials, auth}
  end

  defp handle_token_response({:ok, %{status: 429}}, auth) do
    {:error, :rate_limited_by_reddit, auth}
  end

  defp handle_token_response({:ok, %{status: status, body: body}}, auth) do
    {:error, {:token_request_failed, status, body}, auth}
  end

  defp handle_token_response({:error, reason}, auth) do
    {:error, {:transport, reason}, auth}
  end

  defp credential_pair(credentials) do
    client_id = credentials[:client_id]
    client_secret = credentials[:client_secret]

    if present?(client_id) and present?(client_secret) do
      {:ok, client_id, client_secret}
    else
      {:error, :missing_credentials}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
