defmodule SmmMonitor.Setup.Settings do
  @moduledoc """
  What the first-run wizard writes down, and how it reaches the app.

  Somebody who downloaded a binary has no `.env` file to edit and no
  service manager to configure. They have a terminal window with a
  dashboard in it. So the wizard asks its questions on screen and saves
  the answers here:

      ~/.config/smm_monitor/settings.json

  Brand terms are *not* in this file. Clients live in the database
  alongside the mentions that reference them, which is where the
  dashboard already reads and edits them. What is here is the handful of
  things that were environment variables and now need somewhere else to
  live: API credentials, and a note that setup has run.

  ## The environment still wins

  `apply/0` fills in credentials the environment didn't supply — it
  never overrides one. A server with `REDDIT_CLIENT_ID` in its systemd
  unit behaves exactly as it did before this file existed, whatever is
  written here.

  ## Failure handling

  Nothing here raises. A missing file means "setup hasn't run", which is
  the normal state of a fresh install; an unreadable one is logged and
  treated the same way, rather than stopping the app from starting.
  """

  require Logger

  alias SmmMonitor.Paths

  @filename "settings.json"
  @version 1

  # Only these reach the fetchers. Twitter and Instagram are deliberately
  # absent: their setup is long enough that a wizard would be the wrong
  # place for it, and the README walks through both.
  @credential_fields [
    {:reddit, :client_id},
    {:reddit, :client_secret},
    {:youtube, :api_key}
  ]

  @doc "Where the file lives. `SMM_SETTINGS_FILE` overrides it."
  @spec path() :: Path.t()
  def path do
    System.get_env("SMM_SETTINGS_FILE") ||
      SmmMonitor.config(:settings_file) ||
      Paths.config(@filename)
  end

  @doc """
  Loads the settings, or `:missing` when setup has never run.
  """
  @spec load(Path.t()) :: {:ok, map()} | :missing | {:error, term()}
  def load(file \\ path()) do
    case File.read(file) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes the settings file atomically.

  Mode 0600: it holds API keys, and a file of credentials that anybody
  on the machine can read is a bad habit to ship.
  """
  @spec save(map(), Path.t()) :: :ok | {:error, term()}
  def save(settings, file \\ path()) do
    document = %{
      "version" => @version,
      "completed_at" => DateTime.to_iso8601(settings[:completed_at] || DateTime.utc_now()),
      "credentials" => encode_credentials(settings[:credentials] || %{})
    }

    temporary = "#{file}.tmp-#{System.unique_integer([:positive])}"

    with {:ok, json} <- Jason.encode(document, pretty: true),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(temporary, json <> "\n"),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, file) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        Logger.warning("setup: could not save settings (#{inspect(reason)})")
        {:error, reason}
    end
  end

  @doc """
  Whether the wizard has already run.

  Several ways to be finished, and only one of them involves the wizard:

    * `:setup_complete` is configured, which is how the test suite opts
      out of a wizard it never wanted;
    * the settings file says so;
    * `SMM_SETUP_COMPLETE` is set, for scripted installs and CI;
    * systemd is telling us where to put things, so this is a server
      and there is nobody at a keyboard to answer questions;
    * credentials are already in the environment, which is how every
      install before this feature was configured.
  """
  @spec complete?() :: boolean()
  def complete? do
    cond do
      SmmMonitor.config(:setup_complete) == true -> true
      System.get_env("SMM_SETUP_COMPLETE") not in [nil, "", "0", "false"] -> true
      Paths.systemd?() -> true
      configured_by_environment?() -> true
      true -> match?({:ok, %{completed_at: %DateTime{}}}, load())
    end
  end

  @doc """
  Copies stored credentials into the application environment.

  Called once on boot, before the fetchers start. Values already set
  from the environment are left alone.
  """
  @spec apply(Path.t()) :: :ok
  def apply(file \\ path()) do
    case load(file) do
      {:ok, %{credentials: credentials}} when credentials != %{} -> merge(credentials)
      _other -> :ok
    end
  end

  @doc """
  Merges credentials into the application environment, and takes any
  platform they unlock off mock data.

  Used by boot and by the wizard itself, so a key typed in at the
  dashboard starts working on the next poll rather than the next
  restart.
  """
  @spec merge(map()) :: :ok
  def merge(credentials) do
    existing = Application.get_env(:smm_monitor, :credentials, [])

    merged =
      Enum.reduce(@credential_fields, existing, fn {platform, field}, accumulator ->
        stored = get_in(credentials, [platform, field])
        current = accumulator |> Keyword.get(platform, []) |> Keyword.get(field)

        if blank?(current) and not blank?(stored) do
          platform_credentials =
            accumulator |> Keyword.get(platform, []) |> Keyword.put(field, stored)

          Keyword.put(accumulator, platform, platform_credentials)
        else
          accumulator
        end
      end)

    Application.put_env(:smm_monitor, :credentials, merged)

    Enum.each([:reddit, :youtube], fn platform ->
      if ready?(merged, platform), do: go_live(platform)
    end)

    :ok
  end

  @doc "The credentials stored for a platform, for the config screen to show."
  @spec stored(atom()) :: map()
  def stored(platform) do
    case load() do
      {:ok, %{credentials: credentials}} -> Map.get(credentials, platform, %{})
      _other -> %{}
    end
  end

  # --- internals ------------------------------------------------------------

  # A platform whose credentials just arrived should start using them.
  # Only that platform: turning the global mock switch off would put
  # three other platforms into a live mode they have no keys for.
  defp go_live(platform) do
    overrides = Application.get_env(:smm_monitor, :mock_platforms, [])

    Application.put_env(
      :smm_monitor,
      :mock_platforms,
      Keyword.put(overrides, platform, false)
    )
  end

  defp ready?(credentials, :reddit) do
    reddit = Keyword.get(credentials, :reddit, [])
    not blank?(reddit[:client_id]) and not blank?(reddit[:client_secret])
  end

  defp ready?(credentials, :youtube) do
    not blank?(credentials |> Keyword.get(:youtube, []) |> Keyword.get(:api_key))
  end

  defp configured_by_environment? do
    Enum.any?(
      ~w(REDDIT_CLIENT_ID YOUTUBE_API_KEY TWITTER_BEARER_TOKEN INSTAGRAM_ACCESS_TOKEN),
      &(not blank?(System.get_env(&1)))
    )
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = document} ->
        {:ok,
         %{
           completed_at: timestamp(document["completed_at"]),
           credentials: decode_credentials(document["credentials"])
         }}

      {:ok, other} ->
        {:error, {:unexpected_document, other}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp decode_credentials(%{} = credentials) do
    for {platform, fields} <- @credential_fields |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
        stored = Map.get(credentials, to_string(platform)),
        is_map(stored),
        into: %{} do
      {platform,
       for(
         field <- fields,
         value = Map.get(stored, to_string(field)),
         is_binary(value) and value != "",
         into: %{},
         do: {field, value}
       )}
    end
  end

  defp decode_credentials(_other), do: %{}

  defp encode_credentials(credentials) do
    for {platform, fields} <- credentials, is_map(fields), into: %{} do
      {to_string(platform),
       for({field, value} <- fields, is_binary(value), into: %{}, do: {to_string(field), value})}
    end
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_value), do: nil
end
