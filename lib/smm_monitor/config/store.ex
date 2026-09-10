defmodule SmmMonitor.Config.Store do
  @moduledoc """
  Reads and writes the runtime config file.

  A small JSON document holding only the settings a person can change from
  the dashboard:

      {
        "version": 1,
        "keywords": ["realoffice", "real office"],
        "subreddits": ["marketing", "smallbusiness"],
        "updated_at": "2026-09-10T09:15:00Z"
      }

  Credentials are deliberately *not* in here. They stay in the environment,
  so this file is safe to read, diff, and hand to someone.

  ## Where it lives

  `priv/runtime_config.json` by default, overridable with the
  `SMM_CONFIG_FILE` environment variable or the `:config_file` application
  setting. The override matters for releases: a release replaces its `priv`
  directory on upgrade, so config stored there would not survive one. Point
  `SMM_CONFIG_FILE` somewhere outside the release for anything long-lived.

  ## Failure handling

  Nothing here raises. A missing file is `:missing` (the normal state
  before anyone changes anything); anything unreadable is `{:error,
  reason}`, and the caller falls back to defaults rather than refusing to
  boot. Writes go to a temporary file and are renamed into place, so a
  crash mid-write leaves the previous file intact rather than a truncated
  one.
  """

  require Logger

  @version 1
  @default_filename "runtime_config.json"

  @doc """
  Where the config file lives.

  `SMM_CONFIG_FILE` wins, then the `:config_file` application setting,
  then `priv/runtime_config.json`.
  """
  @spec default_path() :: Path.t()
  def default_path do
    System.get_env("SMM_CONFIG_FILE") ||
      Application.get_env(:smm_monitor, :config_file) ||
      priv_path()
  end

  @doc """
  Loads the config file.

  Returns `{:ok, map}` with atom keys, `:missing` if there is no file, or
  `{:error, reason}` if one exists but can't be used.
  """
  @spec load(Path.t()) :: {:ok, map()} | :missing | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes the config file, creating its directory if needed.

  The write is atomic: contents go to a temporary file which is then
  renamed over the target, so an interrupted write can't leave a
  half-written file behind.
  """
  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(path, %{} = config) do
    document = %{
      "version" => @version,
      "keywords" => config[:keywords] || [],
      "subreddits" => config[:subreddits] || [],
      "updated_at" => config |> Map.get(:updated_at, DateTime.utc_now()) |> DateTime.to_iso8601()
    }

    with {:ok, json} <- encode(document),
         :ok <- File.mkdir_p(Path.dirname(path)),
         temp = temp_path(path),
         :ok <- File.write(temp, json),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Moves an unusable config file aside so it isn't silently overwritten.

  Someone hand-edited that file; losing it without a trace would be rude,
  and keeping it in place would mean re-reading the same broken file on
  every boot.
  """
  @spec quarantine(Path.t()) :: :ok
  def quarantine(path) do
    target = "#{path}.corrupt"

    case File.rename(path, target) do
      :ok ->
        Logger.info("config: moved unreadable config to #{target}")
        :ok

      {:error, reason} ->
        Logger.warning("config: could not move #{path} aside (#{inspect(reason)})")
        :ok
    end
  end

  @doc "The default path under the application's priv directory."
  @spec priv_path() :: Path.t()
  def priv_path do
    case :code.priv_dir(:smm_monitor) do
      {:error, _reason} -> Path.join(["priv", @default_filename])
      dir -> Path.join(to_string(dir), @default_filename)
    end
  end

  # --- internals ------------------------------------------------------------

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = document} -> {:ok, to_config(document)}
      {:ok, other} -> {:error, {:unexpected_document, other}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp encode(document) do
    case Jason.encode(document, pretty: true) do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  # Only known keys are read, and a key of the wrong type is treated as
  # absent so one bad field can't take the whole file down with it.
  defp to_config(document) do
    %{
      keywords: string_list(document["keywords"]),
      subreddits: string_list(document["subreddits"]),
      updated_at: timestamp(document["updated_at"])
    }
  end

  defp string_list(value) when is_list(value) do
    Enum.filter(value, &is_binary/1)
  end

  defp string_list(_value), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp temp_path(path), do: "#{path}.tmp-#{System.unique_integer([:positive])}"
end
