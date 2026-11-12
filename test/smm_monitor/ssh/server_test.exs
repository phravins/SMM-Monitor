defmodule SmmMonitor.SSH.ServerTest do
  @moduledoc """
  What a connecting SSH client can and cannot reach.

  These start a real daemon on an ephemeral port and connect to it with a
  throwaway key, because the property that matters - "a read-only viewer
  cannot read files" - is a property of the daemon's options, and only a
  real connection exercises them.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.SSH.Server

  @moduletag :ssh

  setup context do
    dir = Path.join(System.tmp_dir!(), "smm_ssh_server_#{:erlang.phash2(context.test)}")
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "client"))
    on_exit(fn -> File.rm_rf(dir) end)

    {client_dir, public_line} = client_key(Path.join(dir, "client"))
    keys_file = Path.join(dir, "authorized_keys")
    File.write!(keys_file, public_line)

    {:ok, _} = Application.ensure_all_started(:ssh)

    %{
      dir: dir,
      client_dir: client_dir,
      keys_file: keys_file,
      name: :"ssh_server_#{System.unique_integer([:positive])}"
    }
  end

  describe "a running daemon" do
    setup %{dir: dir, keys_file: keys_file, name: name} do
      capture_log(fn ->
        pid =
          start_supervised!(
            {Server,
             name: name,
             port: 0,
             bind: "127.0.0.1",
             system_dir: Path.join(dir, "host"),
             authorized_keys: keys_file,
             allow_unpatched_ssh: true}
          )

        send(self(), {:pid, pid})
        # handle_continue has run once a call returns.
        assert %{started?: true} = Server.status(name)
      end)

      assert_received {:pid, pid}
      {:ok, info} = :ssh.daemon_info(:sys.get_state(pid).daemon)

      %{port: Keyword.fetch!(info, :port), info: info}
    end

    test "listens on loopback only", %{info: info} do
      assert Keyword.get(info, :ip) == {127, 0, 0, 1}
    end

    test "refuses the SFTP subsystem", %{port: port, client_dir: client_dir} do
      # Without `subsystems: []` Erlang's daemon serves SFTP, and a
      # "read-only" viewer could fetch the environment file with every key.
      conn = connect!(port, client_dir)

      {:ok, channel} = :ssh_connection.session_channel(conn, 5_000)
      assert :ssh_connection.subsystem(conn, channel, ~c"sftp", 5_000) == :failure

      :ssh.close(conn)
    end

    test "has no SFTP channel to start", %{port: port, client_dir: client_dir} do
      conn = connect!(port, client_dir)

      assert {:error, _reason} = :ssh_sftp.start_channel(conn, timeout: 5_000)

      :ssh.close(conn)
    end

    test "turns away a key that is not authorised", %{port: port, dir: dir} do
      stranger = Path.join(dir, "stranger")
      File.mkdir_p!(stranger)
      {stranger_dir, _line} = client_key(stranger)

      assert {:error, _reason} = connect(port, stranger_dir)
    end
  end

  describe "an unpatched Erlang/OTP" do
    @tag :tmp_dir
    test "does not start the daemon unless it carries the CVE-2025-32433 fix", ctx do
      version = Application.spec(:ssh, :vsn) |> to_string()

      log =
        capture_log(fn ->
          start_supervised!(
            {Server,
             name: ctx.name,
             port: 0,
             bind: "127.0.0.1",
             system_dir: Path.join(ctx.dir, "host"),
             authorized_keys: ctx.keys_file}
          )

          status = Server.status(ctx.name)

          if Server.patched_ssh?(version) do
            assert status.started?
          else
            refute status.started?
            assert status.error == {:unpatched_ssh, version}
          end
        end)

      unless Server.patched_ssh?(version), do: assert(log =~ "CVE-2025-32433")
    end
  end

  describe "patched_ssh?/1" do
    test "knows the first fixed release on each branch" do
      assert Server.patched_ssh?("5.2.10")
      assert Server.patched_ssh?("5.2.11")
      assert Server.patched_ssh?("5.1.4.8")
      assert Server.patched_ssh?("4.15.3.12")
    end

    test "rejects the releases before them" do
      refute Server.patched_ssh?("5.2.9")
      refute Server.patched_ssh?("5.2.5")
      refute Server.patched_ssh?("5.1.4.7")
      refute Server.patched_ssh?("4.15.3.1")
      refute Server.patched_ssh?("4.14")
    end

    test "accepts anything newer than the 5.2 line" do
      assert Server.patched_ssh?("5.3")
      assert Server.patched_ssh?(~c"5.3.1")
      assert Server.patched_ssh?("6.0")
    end

    test "treats nonsense as unpatched" do
      refute Server.patched_ssh?("")
      refute Server.patched_ssh?("five")
    end
  end

  describe "parse_bind/1" do
    test "accepts IPv4 and IPv6 literals" do
      assert Server.parse_bind("127.0.0.1") == {:ok, {127, 0, 0, 1}}
      assert Server.parse_bind(" 0.0.0.0 ") == {:ok, {0, 0, 0, 0}}
      assert Server.parse_bind("::") == {:ok, {0, 0, 0, 0, 0, 0, 0, 0}}
    end

    test "passes a tuple through" do
      assert Server.parse_bind({10, 0, 0, 1}) == {:ok, {10, 0, 0, 1}}
    end

    test "refuses a hostname or garbage, rather than guessing" do
      assert Server.parse_bind("localhost") == {:error, {:invalid_bind, "localhost"}}
      assert Server.parse_bind("300.1.1.1") == {:error, {:invalid_bind, "300.1.1.1"}}
    end

    test "defaults to loopback" do
      original = Application.get_env(:smm_monitor, :ssh_bind)
      Application.delete_env(:smm_monitor, :ssh_bind)
      on_exit(fn -> if original, do: Application.put_env(:smm_monitor, :ssh_bind, original) end)

      assert Server.bind_address() == {:ok, {127, 0, 0, 1}}
    end
  end

  # --- helpers --------------------------------------------------------------

  defp connect!(port, client_dir) do
    {:ok, conn} = connect(port, client_dir)
    conn
  end

  defp connect(port, client_dir) do
    :ssh.connect(~c"127.0.0.1", port,
      user: ~c"viewer",
      user_dir: String.to_charlist(client_dir),
      auth_methods: ~c"publickey",
      silently_accept_hosts: true,
      save_accepted_host: false,
      user_interaction: false,
      connect_timeout: 5_000
    )
  end

  # An RSA client key in `dir/id_rsa`, and its authorized_keys line.
  defp client_key(dir) do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private)])
    File.write!(Path.join(dir, "id_rsa"), pem)
    File.chmod!(Path.join(dir, "id_rsa"), 0o600)

    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    line = :ssh_file.encode([{public, [comment: ~c"test"]}], :openssh_key)

    {dir, IO.iodata_to_binary(line)}
  end
end
