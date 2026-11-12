defmodule SmmMonitor.Fetchers.Threads.Token do
  @moduledoc """
  Keeps the Threads access token alive.

  A long-lived Threads token lasts 60 days. Meta will swap it for a fresh
  60-day one (`GET /refresh_access_token`), with no app secret, as long as
  it is at least 24 hours old and hasn't expired yet. So the app does that
  itself and nobody has to paste a new token every two months, provided
  it runs at least once in any 60-day stretch.

  ## When

    * A token the app hasn't renewed yet (its age is unknown): first try
      24 hours after the app first used it, since a token younger than
      that can't be renewed.
    * After a renewal: again 7 days later, or sooner if the token would
      otherwise expire within 14 days.
    * A failed renewal is logged and tried again in 24 hours. The poll goes
      ahead with the current token either way.
    * Inside the last 7 days, a warning is logged (at most hourly) saying
      how long is left.

  ## Where the renewed token lives

  `threads_token.json`, next to the database, created `0600` through
  `SmmMonitor.Fetchers.CursorFile`. It holds the renewed token, when it
  was renewed and when it expires, and a SHA-256 hash of the token in
  `THREADS_ACCESS_TOKEN`. The env token itself is never written out: the
  hash is only there to notice when somebody pastes a different one, in
  which case the new env token wins and the file is replaced. Until the
  first renewal the file holds just that hash and when the token was first
  used, so the 24-hour wait survives a restart.

  `token_file: nil` turns the file off. Renewals then last until the app
  stops, and the next start goes back to the env token.
  """

  require Logger

  alias SmmMonitor.Fetchers.{CursorFile, MetaGraph}
  alias SmmMonitor.Fetchers.Threads.State

  @file_name "threads_token.json"
  @file_version 1

  @min_age_ms :timer.hours(24)
  @renew_every_ms :timer.hours(24 * 7)
  @renew_before_expiry_ms :timer.hours(24 * 14)
  @retry_after_failure_ms :timer.hours(24)
  @warn_within_ms :timer.hours(24 * 7)
  @warn_every_ms :timer.hours(1)

  # Meta says 60 days; used if a renewal response leaves it out.
  @default_lifetime_s 60 * 24 * 3_600

  @doc """
  The state with a usable token in it: loaded from the file or the env
  token on first use, renewed when it is due.
  """
  @spec current(State.t(), String.t(), keyword(), integer()) :: State.t()
  def current(%State{} = state, seed, settings, now_ms) do
    state =
      if state.seed_hash == hash(seed), do: state, else: load(state, seed, settings, now_ms)

    state
    |> maybe_renew(settings, now_ms)
    |> maybe_warn_expiry(now_ms)
  end

  @doc "The SHA-256 of a token, as lowercase hex. What the file stores."
  @spec hash(String.t()) :: String.t()
  def hash(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

  @doc "Where the token file lives for these settings, or nil when it is off."
  @spec path(keyword()) :: Path.t() | nil
  def path(settings) do
    case Keyword.fetch(settings, :token_file) do
      {:ok, path} -> path
      :error -> CursorFile.default_path(@file_name)
    end
  end

  # --- loading --------------------------------------------------------------

  defp load(state, seed, settings, now_ms) do
    seed_hash = hash(seed)
    path = path(settings)
    fresh = %{state | seed_hash: seed_hash, expiry_warned_at: nil}

    case read(path, seed_hash) do
      {:renewed, token, first_seen_at, refreshed_at, expires_at} ->
        schedule(%{
          fresh
          | token: token,
            first_seen_at: first_seen_at,
            refreshed_at: refreshed_at,
            expires_at: expires_at
        })

      {:seen, first_seen_at} ->
        schedule(%{
          fresh
          | token: seed,
            first_seen_at: first_seen_at,
            refreshed_at: nil,
            expires_at: nil
        })

      :none ->
        state =
          schedule(%{
            fresh
            | token: seed,
              first_seen_at: now_ms,
              refreshed_at: nil,
              expires_at: nil
          })

        save(state, path)
        state
    end
  end

  defp read(path, seed_hash) do
    with contents when is_binary(contents) <- CursorFile.read(path),
         {:ok, %{"version" => @file_version, "seed_sha256" => ^seed_hash} = file} <-
           Jason.decode(contents),
         first_seen_at when is_integer(first_seen_at) <- file["first_seen_at"] do
      token = file["access_token"]
      refreshed_at = file["refreshed_at"]
      expires_at = file["expires_at"]

      if valid_token?(token) and is_integer(refreshed_at) and is_integer(expires_at) do
        {:renewed, token, first_seen_at, refreshed_at, expires_at}
      else
        {:seen, first_seen_at}
      end
    else
      _missing_or_foreign -> :none
    end
  end

  defp save(state, path) do
    contents =
      %{
        "version" => @file_version,
        "seed_sha256" => state.seed_hash,
        "first_seen_at" => state.first_seen_at
      }
      |> then(fn file ->
        if state.refreshed_at do
          Map.merge(file, %{
            "access_token" => state.token,
            "refreshed_at" => state.refreshed_at,
            "expires_at" => state.expires_at
          })
        else
          file
        end
      end)
      |> Jason.encode!()

    case CursorFile.write(path, contents) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "threads: couldn't save the access token file (#{inspect(reason)}). A renewed " <>
            "token will be used until the app stops."
        )
    end
  end

  # --- renewing -------------------------------------------------------------

  defp schedule(%State{refreshed_at: nil, first_seen_at: first_seen_at} = state),
    do: %{state | next_refresh_at: first_seen_at + @min_age_ms}

  defp schedule(%State{refreshed_at: refreshed_at, expires_at: expires_at} = state) do
    by_age = refreshed_at + @renew_every_ms
    by_expiry = if expires_at, do: expires_at - @renew_before_expiry_ms, else: by_age
    %{state | next_refresh_at: min(by_age, by_expiry)}
  end

  defp maybe_renew(%State{next_refresh_at: due} = state, settings, now_ms) when now_ms >= due do
    if expired?(state, now_ms) do
      # Meta won't renew an expired token; the API call will say so.
      state
    else
      renew(state, settings, now_ms)
    end
  end

  defp maybe_renew(state, _settings, _now_ms), do: state

  defp renew(state, settings, now_ms) do
    case request_renewal(state.token, settings) do
      {:ok, token, lifetime_s} ->
        state =
          schedule(%{
            state
            | token: token,
              refreshed_at: now_ms,
              expires_at: now_ms + lifetime_s * 1_000,
              expiry_warned_at: nil
          })

        save(state, path(settings))

        Logger.info("threads: access token renewed; it now expires on #{date(state.expires_at)}")

        state

      {:error, reason} ->
        Logger.warning(
          "threads: couldn't renew the access token (#{describe(reason)}). Trying again in " <>
            "24 hours; polling carries on with the current token."
        )

        %{state | next_refresh_at: now_ms + @retry_after_failure_ms}
    end
  end

  defp request_renewal(token, settings) do
    host = Keyword.get(settings, :graph_host, "https://graph.threads.net")

    [
      url: "#{host}/refresh_access_token",
      params: [grant_type: "th_refresh_token", access_token: token],
      receive_timeout: 10_000,
      retry: false
    ]
    |> Kernel.++(Keyword.get(settings, :req_options, []))
    |> Req.new()
    |> Req.request()
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        if valid_token?(token), do: {:ok, token, lifetime(body)}, else: {:error, :bad_response}

      {:ok, %{status: 200}} ->
        {:error, :bad_response}

      {:ok, %{status: status, body: body}} ->
        {_kind, message} = MetaGraph.classify(body)
        {:error, {:http, status, message}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp lifetime(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0,
    do: seconds

  defp lifetime(_body), do: @default_lifetime_s

  defp describe(:bad_response), do: "Meta's answer had no usable token in it"
  defp describe({:http, status, nil}), do: "HTTP #{status}"
  defp describe({:http, status, message}), do: "HTTP #{status}: #{message}"
  # Only the reason: the exception's request would carry the token.
  defp describe({:transport, %{reason: reason}}), do: "network error: #{inspect(reason)}"
  defp describe({:transport, _exception}), do: "network error"

  # --- warning --------------------------------------------------------------

  defp maybe_warn_expiry(%State{expires_at: expires_at} = state, now_ms)
       when is_integer(expires_at) and expires_at > now_ms and
              expires_at - now_ms <= @warn_within_ms do
    if is_nil(state.expiry_warned_at) or now_ms - state.expiry_warned_at >= @warn_every_ms do
      days = Float.round((expires_at - now_ms) / :timer.hours(24), 1)

      Logger.warning(
        "threads: the access token expires in #{days} days (#{date(expires_at)}) and hasn't " <>
          "been renewed. Paste a new THREADS_ACCESS_TOKEN before then, or Threads stops."
      )

      %{state | expiry_warned_at: now_ms}
    else
      state
    end
  end

  defp maybe_warn_expiry(state, _now_ms), do: state

  defp expired?(%State{expires_at: expires_at}, now_ms),
    do: is_integer(expires_at) and expires_at <= now_ms

  # Printable ASCII with no spaces: what Meta's tokens look like, and
  # nothing that could break a file or a query string.
  defp valid_token?(token), do: is_binary(token) and token =~ ~r/\A[\x21-\x7E]{16,4096}\z/

  defp date(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()
end
