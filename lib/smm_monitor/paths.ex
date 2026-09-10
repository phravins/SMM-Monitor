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
