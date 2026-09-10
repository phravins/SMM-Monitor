defmodule SmmMonitor.SSH.HostKeyTest do
  @moduledoc """
  The server's identity. The property that matters: it is generated once
  and then never changes, because a host key that rotates every boot
  greets everyone with a scary warning and refuses the connection.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SmmMonitor.SSH.HostKey

  setup context do
    dir = Path.join(System.tmp_dir!(), "smm_hostkey_#{:erlang.phash2(context.test)}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "ensure!/1" do
    test "generates a key on first boot", %{dir: dir} do
      refute HostKey.exists?(dir)

      # The generation itself is the property; the log line announcing it
      # is at :info, which the test environment filters out.
      assert {:ok, ^dir} = capture_and_return(fn -> HostKey.ensure!(dir) end)
      assert HostKey.exists?(dir)
    end

    test "the generated key is usable by Erlang's ssh", %{dir: dir} do
      capture_log(fn -> HostKey.ensure!(dir) end)

      # If :ssh_file can't read it back, the daemon won't start.
      assert {:ok, _key} =
               :ssh_file.host_key(:"rsa-sha2-256", system_dir: String.to_charlist(dir))
    end

    test "keeps the existing key across restarts", %{dir: dir} do
      capture_log(fn -> HostKey.ensure!(dir) end)
      original = File.read!(HostKey.key_path(dir))

      # A second boot must not rotate it — clients have it in known_hosts.
      assert {:ok, ^dir} = HostKey.ensure!(dir)
      assert File.read!(HostKey.key_path(dir)) == original
    end

    test "writes the key so only the owner can read it", %{dir: dir} do
      capture_log(fn -> HostKey.ensure!(dir) end)

      %{mode: mode} = File.stat!(HostKey.key_path(dir))
      # :ssh refuses a host key other users can read.
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "creates the directory if it doesn't exist", %{dir: dir} do
      nested = Path.join([dir, "deeply", "nested"])

      assert {:ok, ^nested} = capture_and_return(fn -> HostKey.ensure!(nested) end)
      assert File.dir?(nested)
    end
  end

  defp capture_and_return(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, result} -> result
    after
      0 -> nil
    end
  end

  describe "dir/0" do
    test "prefers the environment variable" do
      System.put_env("SMM_SSH_HOST_KEY_DIR", "/tmp/from-env-hostkey")
      on_exit(fn -> System.delete_env("SMM_SSH_HOST_KEY_DIR") end)

      assert HostKey.dir() == "/tmp/from-env-hostkey"
    end

    test "falls back to a per-user path" do
      assert HostKey.default_dir() =~ "smm_monitor"
    end
  end
end
