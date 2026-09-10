defmodule SmmMonitor.Persistence.Paths do
  @moduledoc """
  Where the mention database lives.

  Defaults to the per-user data directory —
  `~/.local/share/smm_monitor/mentions.db`, honouring `XDG_DATA_HOME` —
  and is overridden by `SMM_DB_PATH`.

  Deliberately *not* under the app's `priv` directory, for the same reason
  the runtime config file isn't: `:code.priv_dir/1` resolves to the
  **build** copy (`_build/dev/lib/smm_monitor/priv/`), not the source
  tree. A database there is a build artifact, so `mix clean` would delete
  months of collected history without warning, and a release replaces its
  `priv` directory wholesale on upgrade. History that survives a restart
  but not a rebuild is not really durable.
  """

  @filename "mentions.db"

  @doc "The default database path."
  @spec default_database() :: Path.t()
  def default_database do
    base =
      System.get_env("XDG_DATA_HOME") ||
        case System.user_home() do
          nil -> ".smm_monitor"
          home -> Path.join([home, ".local", "share"])
        end

    Path.join([base, "smm_monitor", @filename])
  end
end
