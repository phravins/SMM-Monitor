defmodule SmmMonitor.Paths do
  @moduledoc """
  Where the app keeps its state and its configuration.

  Three layouts have to work, and the order of precedence is what makes
  that possible:

    1. **An explicit environment variable** — `SMM_DB_PATH`,
       `SMM_CONFIG_FILE` and friends always win.
    2. **systemd's directories** — a unit with `StateDirectory=` and
       `ConfigurationDirectory=` gets `/var/lib/smm-monitor` and
       `/etc/smm-monitor` created, owned and passed in as
       `$STATE_DIRECTORY` and `$CONFIGURATION_DIRECTORY`. Using those
       means the unit file and the app can't disagree about paths.
    3. **The per-user directories** — `~/.local/share` and `~/.config`,
       which is what a developer running `mix smm.tui` gets.

  ## Why not under the release root

  It is tempting to default to `RELEASE_ROOT`, since a release is
  self-contained. But a deploy *replaces* the release directory — that
  is what makes deploys safe to roll back — and anything stored inside it
  is destroyed with the old version. State has to outlive the code that
  wrote it, so it lives in `/var/lib`, which is exactly what that
  directory is for.

  The same reasoning already applies to the `priv` directory, and for the
  same reason.
  """

  @app_dir "smm_monitor"

  @doc """
  Directory for mutable state: the database, the SSH host key.

  `$STATE_DIRECTORY` (systemd) if set, otherwise `~/.local/share`.
  """
  @spec state_dir() :: Path.t()
  def state_dir do
    case first_directory(System.get_env("STATE_DIRECTORY")) do
      nil -> Path.join([user_data_home(), @app_dir])
      dir -> dir
    end
  end

  @doc """
  Directory for configuration: the runtime config file, authorized keys.

  `$CONFIGURATION_DIRECTORY` (systemd) if set, otherwise `~/.config`.
  """
  @spec config_dir() :: Path.t()
  def config_dir do
    case first_directory(System.get_env("CONFIGURATION_DIRECTORY")) do
      nil -> Path.join([user_config_home(), @app_dir])
      dir -> dir
    end
  end

  @doc "A file inside the state directory."
  @spec state(String.t()) :: Path.t()
  def state(name), do: Path.join(state_dir(), name)

  @doc "A file inside the config directory."
  @spec config(String.t()) :: Path.t()
  def config(name), do: Path.join(config_dir(), name)

  @doc """
  Creates `dir` if needed and makes sure only this account can open it.

  The directories behind the app hold API keys, the mention database and
  client reports. Created with the default umask they are world-readable
  on most systems, so every one is created through here.

  By default a directory that already exists is tightened too: these are
  the app's own directories. With `only_if_created: true` an existing
  directory is left as it is, for paths an operator chose (a reports
  directory might be a shared folder on purpose).
  """
  @spec ensure_private_dir(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_private_dir(dir, opts \\ []) do
    existed? = File.dir?(dir)

    with :ok <- File.mkdir_p(dir) do
      cond do
        existed? and Keyword.get(opts, :only_if_created, false) ->
          :ok

        true ->
          case File.chmod(dir, 0o700) do
            # A directory somebody else owns, such as /tmp: not ours to
            # tighten, and the files written into it are 0600 regardless.
            {:error, :eperm} when existed? -> :ok
            other -> other
          end
      end
    end
  end

  @doc """
  Restricts a file to its owner (mode 0600). Missing files are ignored.
  """
  @spec restrict_file(Path.t()) :: :ok | {:error, term()}
  def restrict_file(file) do
    case File.chmod(file, 0o600) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  @doc "Whether systemd is telling us where to put things."
  @spec systemd?() :: boolean()
  def systemd?, do: System.get_env("STATE_DIRECTORY") != nil

  # --- internals ------------------------------------------------------------

  # systemd passes a colon-separated list when several directories are
  # configured; the first is ours.
  defp first_directory(nil), do: nil

  defp first_directory(value) do
    case value |> String.split(":") |> Enum.reject(&(&1 == "")) do
      [] -> nil
      [dir | _rest] -> dir
    end
  end

  defp user_data_home do
    System.get_env("XDG_DATA_HOME") ||
      case System.user_home() do
        nil -> Path.join(".", ".local/share")
        home -> Path.join([home, ".local", "share"])
      end
  end

  defp user_config_home do
    System.get_env("XDG_CONFIG_HOME") ||
      case System.user_home() do
        nil -> Path.join(".", ".config")
        home -> Path.join(home, ".config")
      end
  end
end
