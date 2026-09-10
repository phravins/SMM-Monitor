defmodule SmmMonitor.SSH.Server do
  @moduledoc """
  Serves the dashboard over SSH.

  Wraps `:ssh.daemon` with Garnish as the channel implementation, so
  `ssh host -p 2222` opens the live dashboard in the caller's own
  terminal. Every session gets its own Garnish channel process, and
  therefore its own view of the shared data.

  Off by default: `SMM_SSH_ENABLED=true` turns it on. A dashboard that
  starts listening on a port because someone upgraded is not a pleasant
  surprise, so opening the port is always a deliberate act.

  ## What is and isn't exposed

  The daemon serves exactly one thing: the Garnish channel running
  `SmmMonitor.SSH.App`. Shell access, exec and SFTP are all disabled, so
  a connecting client can draw the dashboard and nothing else. Sessions
  are read-only — the config screen renders but refuses edits.

  ## Failure policy

  If the daemon cannot start — port in use, unwritable host key
  directory, no authorized keys — it is logged and the app carries on
  without SSH. Losing remote viewing should not cost the operator their
  local dashboard or their collection.
  """

  use GenServer

  require Logger

  alias SmmMonitor.SSH.{AuthorizedKeys, HostKey, KeyAuth}

  @default_port 2222

  defmodule State do
    @moduledoc false
    defstruct [:daemon, :port, :system_dir, :authorized_keys, started?: false, error: nil]
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether the SSH server is meant to run at all."
  @spec enabled?() :: boolean()
  def enabled?, do: SmmMonitor.config(:ssh_enabled, false)

  @doc "The port the daemon listens on."
  @spec port() :: pos_integer()
  def port do
    case System.get_env("SMM_SSH_PORT") do
      nil -> SmmMonitor.config(:ssh_port, @default_port)
      value -> String.to_integer(value)
    end
  end

  @doc "Current status, for the dashboard and for tests."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %State{port: Keyword.get(opts, :port, port())}, {:continue, {:listen, opts}}}
  end

  @impl true
  def handle_continue({:listen, opts}, state) do
    case start_daemon(state.port, opts) do
      {:ok, daemon, system_dir, authorized_keys} ->
        Logger.info(
          "ssh: dashboard available on port #{state.port} " <>
            "(#{AuthorizedKeys.count(authorized_keys)} authorised key(s))"
        )

        {:noreply,
         %{
           state
           | daemon: daemon,
             system_dir: system_dir,
             authorized_keys: authorized_keys,
             started?: true
         }}

      {:error, reason} ->
        # Not fatal: the local dashboard and the collectors are unaffected.
        Logger.warning("ssh: could not start on port #{state.port} (#{inspect(reason)})")
        {:noreply, %{state | error: reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       started?: state.started?,
       port: state.port,
       system_dir: state.system_dir,
       authorized_keys: state.authorized_keys,
       authorized_key_count: AuthorizedKeys.count(state.authorized_keys),
       error: state.error
     }, state}
  end

  @impl true
  def terminate(_reason, %State{daemon: daemon}) when not is_nil(daemon) do
    :ssh.stop_daemon(daemon)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- internals ------------------------------------------------------------

  defp start_daemon(port, opts) do
    authorized_keys = Keyword.get(opts, :authorized_keys) || AuthorizedKeys.path()

    with {:ok, _apps} <- Application.ensure_all_started(:ssh),
         {:ok, system_dir} <- HostKey.ensure!(Keyword.get(opts, :system_dir)),
         {:ok, daemon} <- daemon(port, system_dir, authorized_keys) do
      {:ok, daemon, system_dir, authorized_keys}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp daemon(port, system_dir, authorized_keys) do
    :ssh.daemon(port, [
      {:system_dir, String.to_charlist(system_dir)},
      # Garnish is the whole session: the client gets the dashboard and
      # nothing else.
      {:ssh_cli, {Garnish, [app: {SmmMonitor.SSH.App, []}]}},
      # No shell, no exec, no SFTP.
      {:shell, :disabled},
      {:exec, :disabled},
      # Public key only. Password auth is never offered.
      {:auth_methods, ~c"publickey"},
      {:key_cb, {KeyAuth, [authorized_keys: authorized_keys]}},
      {:idle_time, :timer.hours(8)}
    ])
  end
end
