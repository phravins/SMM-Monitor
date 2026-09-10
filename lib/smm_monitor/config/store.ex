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

  `~/.config/smm_monitor/config.json` by default (honouring
  `XDG_CONFIG_HOME`), overridable with the `SMM_CONFIG_FILE` environment
  variable or the `:config_file` application setting.

  Deliberately *not* under the app's `priv` directory, which is the
  obvious-looking choice: `:code.priv_dir/1` resolves to the **build**
  copy (`_build/dev/lib/smm_monitor/priv/`), not the source tree, so
  settings saved there are a build artifact — `mix clean` or a fresh
  checkout would silently discard them, and a release replaces its `priv`
  directory wholesale on upgrade. Somebody's saved brand terms should
  outlive a rebuild.

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
  @default_filename "config.json"

  @doc """
  Where the config file lives.

  `SMM_CONFIG_FILE` wins, then the `:config_file` application setting,
  then the per-user config directory.
  """
  @spec default_path() :: Path.t()
  def default_path do
    System.get_env("SMM_CONFIG_FILE") ||
      Application.get_env(:smm_monitor, :config_file) ||
      user_config_path()
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

  @doc """
  The per-user config path: `$XDG_CONFIG_HOME/smm_monitor/config.json`,
  or `~/.config/smm_monitor/config.json`.

  Falls back to a directory beside the working directory on the rare
  system with no home directory, so this never returns something
  unwritable-by-construction.
  """
  @spec user_config_path() :: Path.t()
  def user_config_path, do: SmmMonitor.Paths.config(@default_filename)

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
