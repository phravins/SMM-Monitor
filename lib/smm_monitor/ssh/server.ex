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
  `SmmMonitor.SSH.App`. Shell access, exec and every subsystem (SFTP
  included) are disabled, so a connecting client can draw the dashboard
  and nothing else. Sessions are read-only — the config screen renders
  but refuses edits.

  Erlang's `:ssh` turns SFTP *on* unless `subsystems` is given
  explicitly, which is why the option below is not optional: without it
  a "read-only" viewer could read and write any file the service account
  can, the API keys in its environment file included.

  ## Where it listens

  `127.0.0.1` unless `SMM_SSH_BIND` says otherwise. Remote viewers reach
  it over a VPN or an SSH tunnel; opening it to a network is a decision
  somebody makes by setting `SMM_SSH_BIND=0.0.0.0`, not a side effect of
  turning the feature on.

  ## Refusing a vulnerable runtime

  Erlang/OTP's SSH server had a pre-authentication remote code execution
  bug (CVE-2025-32433). On a runtime older than the fix the daemon is not
  started at all — collection and the local dashboard carry on, and the
  log says which OTP to install.

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
  @default_bind "127.0.0.1"

  # The first `ssh` application release on each maintained branch that
  # carries the fix for CVE-2025-32433 (pre-auth RCE). Shipped in OTP
  # 25.3.2.20, 26.2.5.11 and 27.3.3 respectively; anything from 5.3 on
  # was released after the fix.
  @patched_ssh %{{4, 15} => [4, 15, 3, 12], {5, 1} => [5, 1, 4, 8], {5, 2} => [5, 2, 10]}

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
      nil ->
        SmmMonitor.config(:ssh_port, @default_port)

      value ->
        case Integer.parse(String.trim(value)) do
          {port, ""} when port in 0..65_535 -> port
          _other -> raise ArgumentError, "SMM_SSH_PORT must be a port number, got #{inspect(value)}"
        end
    end
  end

  @doc """
  The address the daemon listens on, as a tuple `:ssh.daemon` accepts.

  `127.0.0.1` by default. `SMM_SSH_BIND` (or `config :smm_monitor,
  :ssh_bind`) takes any IPv4 or IPv6 literal, including `0.0.0.0` and
  `::` for every interface.
  """
  @spec bind_address() :: {:ok, :inet.ip_address()} | {:error, {:invalid_bind, String.t()}}
  def bind_address do
    SmmMonitor.config(:ssh_bind, @default_bind) |> parse_bind()
  end

  @doc false
  @spec parse_bind(String.t() | :inet.ip_address()) ::
          {:ok, :inet.ip_address()} | {:error, {:invalid_bind, String.t()}}
  def parse_bind(address) when is_tuple(address), do: {:ok, address}

  def parse_bind(address) when is_binary(address) do
    case address |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, {:invalid_bind, address}}
    end
  end

  @doc """
  Whether an `ssh` application version carries the CVE-2025-32433 fix.

  Takes the version string `Application.spec(:ssh, :vsn)` returns.
  """
  @spec patched_ssh?(String.t() | charlist()) :: boolean()
  def patched_ssh?(version) do
    parts =
      version
      |> to_string()
      |> String.split(".")
      |> Enum.map(&Integer.parse/1)
      |> Enum.map(fn
        {n, _} -> n
        :error -> 0
      end)

    case parts do
      [major, minor | _] ->
        case Map.fetch(@patched_ssh, {major, minor}) do
          {:ok, minimum} -> parts >= minimum
          :error -> {major, minor} > {5, 2}
        end

      _other ->
        false
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
          "ssh: dashboard available on #{bind_label(opts)}:#{state.port} " <>
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

  defp bind_label(opts) do
    case Keyword.get_lazy(opts, :bind, &bind_address/0) |> parse_bind() do
      {:ok, ip} -> ip |> :inet.ntoa() |> to_string()
      _other -> "?"
    end
  end

  # --- internals ------------------------------------------------------------

  defp start_daemon(port, opts) do
    authorized_keys = Keyword.get(opts, :authorized_keys) || AuthorizedKeys.path()

    with {:ok, _apps} <- Application.ensure_all_started(:ssh),
         :ok <- check_runtime(opts),
         {:ok, ip} <- Keyword.get_lazy(opts, :bind, &bind_address/0) |> parse_bind(),
         {:ok, system_dir} <- HostKey.ensure!(Keyword.get(opts, :system_dir)),
         {:ok, daemon} <- daemon(port, ip, system_dir, authorized_keys) do
      {:ok, daemon, system_dir, authorized_keys}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # `:allow_unpatched_ssh` exists for the test suite, which has to run on
  # whatever OTP the developer has installed. It is deliberately not wired
  # to any environment variable.
  defp check_runtime(opts) do
    version = Application.spec(:ssh, :vsn) |> to_string()

    cond do
      patched_ssh?(version) ->
        :ok

      Keyword.get(opts, :allow_unpatched_ssh, false) ->
        :ok

      true ->
        Logger.error(
          "ssh: refusing to start - this Erlang/OTP ships ssh #{version}, which has a " <>
            "pre-authentication remote code execution bug (CVE-2025-32433). Install " <>
            "OTP 27.3.3 or newer (or 26.2.5.11+, 25.3.2.20+) and restart."
        )

        {:error, {:unpatched_ssh, version}}
    end
  end

  defp daemon(port, ip, system_dir, authorized_keys) do
    :ssh.daemon(port, [
      {:ip, ip},
      {:system_dir, String.to_charlist(system_dir)},
      # Garnish is the whole session: the client gets the dashboard and
      # nothing else.
      {:ssh_cli, {Garnish, [app: {SmmMonitor.SSH.App, []}]}},
      # No shell, no exec, no subsystems. `subsystems` must be given
      # explicitly: left out, Erlang's daemon serves SFTP by default.
      {:shell, :disabled},
      {:exec, :disabled},
      {:subsystems, []},
      # Public key only. Password auth is never offered.
      {:auth_methods, ~c"publickey"},
      {:key_cb, {KeyAuth, [authorized_keys: authorized_keys]}},
      {:idle_time, :timer.hours(8)},
      # Limits on what an unauthenticated stranger can consume. Without
      # these, anyone who can reach the port can hold open as many
      # half-finished handshakes as they like: every one is a process and
      # a file descriptor on the machine that is also running the
      # collection. None of this weakens access - the key check is
      # unchanged - it just stops the door being used as a lever.
      {:max_sessions, 16},
      {:max_channels, 4},
      # A handshake that has not finished in half a minute is not a
      # person opening a dashboard.
      {:negotiation_timeout, :timer.seconds(30)},
      # Authenticate one connection at a time, so a flood of logins
      # cannot crowd out the operator's own.
      {:parallel_login, false}
    ])
  end
end
