defmodule SmmMonitor.Setup.SettingsTest do
  @moduledoc """
  The file the first-run wizard writes, and how it reaches the fetchers.

  The rule that matters here is that the environment always wins. A
  server configured through systemd must behave exactly as it did before
  this file existed, whatever somebody typed into a wizard on their
  laptop.
  """

  # Not async: works on the application environment and SMM_* variables,
  # both of which are global.
  use ExUnit.Case, async: false

  alias SmmMonitor.Setup.Settings

  setup do
    file = Path.join(System.tmp_dir!(), "smm-settings-#{System.unique_integer([:positive])}.json")
    System.put_env("SMM_SETTINGS_FILE", file)

    credentials = Application.get_env(:smm_monitor, :credentials, [])
    mocks = Application.get_env(:smm_monitor, :mock_platforms, [])

    complete = Application.get_env(:smm_monitor, :setup_complete)
    Application.put_env(:smm_monitor, :setup_complete, false)

    on_exit(fn ->
      Application.put_env(:smm_monitor, :setup_complete, complete)
      System.delete_env("SMM_SETTINGS_FILE")
      System.delete_env("SMM_SETUP_COMPLETE")
      File.rm(file)
      Application.put_env(:smm_monitor, :credentials, credentials)
      Application.put_env(:smm_monitor, :mock_platforms, mocks)
    end)

    %{settings: file}
  end

  describe "save/2 and load/1" do
    test "round-trips what the wizard collected", %{settings: file} do
      :ok =
        Settings.save(%{
          completed_at: ~U[2026-09-11 10:00:00Z],
          credentials: %{reddit: %{client_id: "abc", client_secret: "shh"}}
        })

      assert {:ok, settings} = Settings.load(file)
      assert settings.completed_at == ~U[2026-09-11 10:00:00Z]
      assert settings.credentials.reddit.client_id == "abc"
      assert settings.credentials.reddit.client_secret == "shh"
    end

    test "keeps the file to itself", %{settings: file} do
      # It holds API keys. Anybody else with an account on the machine
      # has no business reading them.
      :ok = Settings.save(%{credentials: %{youtube: %{api_key: "k"}}})

      assert {:ok, %File.Stat{mode: mode}} = File.stat(file)
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "a missing file is the normal state of a fresh install", %{settings: file} do
      assert Settings.load(file) == :missing
    end

    test "a hand-mangled file is an error, not a crash", %{settings: file} do
      File.write!(file, "{ this is not json")

      assert {:error, {:invalid_json, _message}} = Settings.load(file)
    end

    test "ignores fields it doesn't recognise", %{settings: file} do
      File.write!(
        file,
        ~s({"version": 1, "credentials": {"reddit": {"client_id": "abc"}}, "wat": 1})
      )

      assert {:ok, settings} = Settings.load(file)
      assert settings.credentials.reddit == %{client_id: "abc"}
    end
  end

  describe "complete?/0" do
    test "is false before the wizard has run" do
      refute Settings.complete?()
    end

    test "is true once it has" do
      :ok = Settings.save(%{credentials: %{}})

      assert Settings.complete?()
    end

    test "is true when the environment already configures the app" do
      # Every install that predates the wizard is configured this way,
      # and none of them should be asked to run setup on the next
      # upgrade.
      System.put_env("YOUTUBE_API_KEY", "from-the-environment")
      on_exit(fn -> System.delete_env("YOUTUBE_API_KEY") end)

      assert Settings.complete?()
    end

    test "is true when a script says so" do
      System.put_env("SMM_SETUP_COMPLETE", "1")

      assert Settings.complete?()
    end

    test "is true under systemd, where nobody is at the keyboard" do
      System.put_env("STATE_DIRECTORY", "/var/lib/smm-monitor")
      on_exit(fn -> System.delete_env("STATE_DIRECTORY") end)

      assert Settings.complete?()
    end
  end

  describe "merge/1" do
    test "fills in a credential the environment didn't supply" do
      Application.put_env(:smm_monitor, :credentials, reddit: [client_id: nil, client_secret: nil])

      Settings.merge(%{reddit: %{client_id: "stored", client_secret: "also-stored"}})

      credentials = Application.get_env(:smm_monitor, :credentials)

      assert credentials[:reddit][:client_id] == "stored"
      assert credentials[:reddit][:client_secret] == "also-stored"
    end

    test "never overrides one that was set from the environment" do
      Application.put_env(:smm_monitor, :credentials,
        reddit: [client_id: "from-the-environment", client_secret: "env-secret"]
      )

      Settings.merge(%{reddit: %{client_id: "from-the-wizard", client_secret: "wizard-secret"}})

      assert Application.get_env(:smm_monitor, :credentials)[:reddit][:client_id] ==
               "from-the-environment"
    end

    test "takes a platform off demo data once it can actually poll" do
      Application.put_env(:smm_monitor, :credentials, [])
      Application.put_env(:smm_monitor, :mock_platforms, [])

      Settings.merge(%{youtube: %{api_key: "k"}})

      refute SmmMonitor.mock_platform?(:youtube)
      # And leaves the others alone: they still have no keys.
      assert SmmMonitor.mock_platform?(:twitter)
    end

    test "a half-configured Reddit app stays on demo data" do
      # An id with no secret cannot authenticate. Going live on it would
      # swap working demo data for a column of 401s.
      Application.put_env(:smm_monitor, :credentials, [])
      Application.put_env(:smm_monitor, :mock_platforms, [])

      Settings.merge(%{reddit: %{client_id: "abc"}})

      assert SmmMonitor.mock_platform?(:reddit)
    end
  end

  describe "apply/1" do
    test "loads stored credentials on boot", %{settings: file} do
      Application.put_env(:smm_monitor, :credentials, [])
      :ok = Settings.save(%{credentials: %{youtube: %{api_key: "stored-key"}}})

      :ok = Settings.apply(file)

      assert Application.get_env(:smm_monitor, :credentials)[:youtube][:api_key] == "stored-key"
    end

    test "does nothing at all when there is no file", %{settings: file} do
      before = Application.get_env(:smm_monitor, :credentials)

      assert :ok = Settings.apply(file)
      assert Application.get_env(:smm_monitor, :credentials) == before
    end
  end
end
