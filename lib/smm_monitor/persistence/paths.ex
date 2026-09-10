defmodule SmmMonitor.Persistence.Paths do
  @moduledoc """
  Where the mention database lives.

  Defaults to `SmmMonitor.Paths.state_dir/0` — `/var/lib/smm-monitor`
  under systemd, `~/.local/share/smm_monitor` otherwise — and is
  overridden by `SMM_DB_PATH`.

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
  def default_database, do: SmmMonitor.Paths.state(@filename)
end
