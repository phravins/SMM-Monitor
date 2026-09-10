defmodule SmmMonitor.SSH.AuthorizedKeysTest do
  @moduledoc """
  Who may open a dashboard session.

  The important property here isn't that valid keys are accepted — it's
  that everything else is refused. A missing file, an empty file, a
  corrupt line: all of them must mean "nobody", never "everybody".
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SmmMonitor.SSH.AuthorizedKeys

  doctest AuthorizedKeys

  setup context do
    dir = Path.join(System.tmp_dir!(), "smm_ssh_#{:erlang.phash2(context.test)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir, keys_file: Path.join(dir, "authorized_keys")}
  end

  describe "parse/1" do
    test "reads a key line" do
      assert [_key] = AuthorizedKeys.parse(sample_key())
    end

    test "reads several keys" do
      assert [_a, _b] = AuthorizedKeys.parse(sample_key() <> "\n" <> other_key())
    end

    test "ignores blank lines and comments" do
      contents = """
      # our team's keys

      #{sample_key()}

      # end
      """

      assert [_key] = AuthorizedKeys.parse(contents)
    end

    test "tolerates CRLF, as a key pasted from Windows would have" do
      assert [_key] = AuthorizedKeys.parse(sample_key() <> "\r\n")
    end

    test "skips a corrupt line but keeps the good ones" do
      # One bad paste must not lock out the rest of the team.
      contents = "ssh-ed25519 THIS-IS-NOT-BASE64 broken\n" <> sample_key()

      assert capture_log(fn -> assert [_key] = AuthorizedKeys.parse(contents) end) =~ "skipping"
    end

    test "an empty or comment-only file yields no keys" do
      assert [] = AuthorizedKeys.parse("")
      assert [] = AuthorizedKeys.parse("# nothing here\n\n")
    end
  end

  describe "authorized?/2" do
    test "accepts a key that is in the file", %{keys_file: file} do
      File.write!(file, sample_key())

      assert AuthorizedKeys.authorized?(decode(sample_key()), file)
    end

    test "rejects a key that is not in the file", %{keys_file: file} do
      File.write!(file, sample_key())

      log = capture_log(fn -> refute AuthorizedKeys.authorized?(decode(other_key()), file) end)
      assert log == "" or is_binary(log)
    end

    test "accepts one of several listed keys", %{keys_file: file} do
      File.write!(file, sample_key() <> "\n" <> other_key())

      assert AuthorizedKeys.authorized?(decode(sample_key()), file)
      assert AuthorizedKeys.authorized?(decode(other_key()), file)
    end

    test "rejects everything when the file is missing", %{dir: dir} do
      missing = Path.join(dir, "does_not_exist")

      log = capture_log(fn -> refute AuthorizedKeys.authorized?(decode(sample_key()), missing) end)
      assert log =~ "no authorized keys file"
    end

    test "rejects everything when the file is empty", %{keys_file: file} do
      # Fails closed: "no keys configured" must never mean "allow anyone".
      File.write!(file, "")

      log = capture_log(fn -> refute AuthorizedKeys.authorized?(decode(sample_key()), file) end)
      assert log =~ "authorises no keys"
    end

    test "rejects everything when the file holds only comments", %{keys_file: file} do
      File.write!(file, "# a key used to be here\n")

      capture_log(fn -> refute AuthorizedKeys.authorized?(decode(sample_key()), file) end)
    end

    test "rejects when the file is unreadable", %{keys_file: file} do
      File.write!(file, sample_key())
      File.chmod!(file, 0o000)
      on_exit(fn -> File.chmod(file, 0o600) end)

      # Running as root defeats permission checks, so only assert when the
      # unreadable state is real.
      if match?({:error, _reason}, File.read(file)) do
        log = capture_log(fn -> refute AuthorizedKeys.authorized?(decode(sample_key()), file) end)
        assert log =~ "could not read"
      end
    end

    test "a revoked key stops working immediately", %{keys_file: file} do
      # The file is re-read per attempt, which is what makes revocation
      # take effect without a restart.
      File.write!(file, sample_key() <> "\n" <> other_key())
      assert AuthorizedKeys.authorized?(decode(other_key()), file)

      File.write!(file, sample_key())
      refute AuthorizedKeys.authorized?(decode(other_key()), file)
    end

    test "a newly added key works immediately", %{keys_file: file} do
      File.write!(file, sample_key())
      refute AuthorizedKeys.authorized?(decode(other_key()), file)

      File.write!(file, sample_key() <> "\n" <> other_key())
      assert AuthorizedKeys.authorized?(decode(other_key()), file)
    end
  end

  describe "count/1" do
    test "counts the keys in the file", %{keys_file: file} do
      File.write!(file, sample_key() <> "\n" <> other_key())
      assert AuthorizedKeys.count(file) == 2
    end

    test "is zero for a missing file", %{dir: dir} do
      assert AuthorizedKeys.count(Path.join(dir, "nope")) == 0
    end
  end

  describe "path/0" do
    test "prefers the environment variable" do
      System.put_env("SMM_SSH_AUTHORIZED_KEYS", "/tmp/from-env")
      on_exit(fn -> System.delete_env("SMM_SSH_AUTHORIZED_KEYS") end)

      assert AuthorizedKeys.path() == "/tmp/from-env"
    end

    test "falls back to a per-user path" do
      assert AuthorizedKeys.default_path() =~ "smm_monitor"
      assert AuthorizedKeys.default_path() =~ "authorized_keys"
    end
  end

  # Two real ed25519 public keys, generated for these tests.
  defp sample_key do
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILr1XhCNwAqeP7rNJQ8CMpgpMu+BjkH7k+oeohkeeghR alice@realoffice"
  end

  defp other_key do
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKDg7j0Ytlu6IMe7c7B0ji4cPUUEiMdqwvkKUwLCSk9M bob@realoffice"
  end

  defp decode(line), do: line |> AuthorizedKeys.parse() |> hd()
end
