defmodule SmmMonitor.Clients.SeedTest do
  @moduledoc """
  What happens on the first boot after the multi-client update.

  The install being upgraded was tracking one brand through the old JSON
  config file and `SMM_KEYWORDS`. Those settings have to become a client,
  or the upgrade would quietly stop monitoring what it was monitoring
  yesterday.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.Client
  alias SmmMonitor.Clients.Seed
  alias SmmMonitor.Config.Store, as: LegacyStore

  doctest Seed

  setup do
    # Half the point of the seed is that it says what it did, and the
    # "created a client from your old settings" line is at :info — below
    # the suite's level. Sync tests run alone, so raising it is safe.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    dir = Path.join(System.tmp_dir!(), "smm-seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.json")

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, path: path}
  end

  describe "upgrading an install that used the config file" do
    test "turns the saved brand terms into a client", %{path: path} do
      LegacyStore.save(path, %{
        keywords: ["realoffice", "real office"],
        subreddits: ["marketing", "smallbusiness"],
        updated_at: DateTime.utc_now()
      })

      assert [%Client{} = client] = capture(fn -> Seed.build(legacy_path: path) end)

      assert client.keywords == ["realoffice", "real office"]
      assert client.subreddits == ["marketing", "smallbusiness"]
      assert client.active
    end

    test "names the client from the brand term, so the header reads properly",
         %{path: path} do
      LegacyStore.save(path, %{keywords: ["realoffice", "real office"], subreddits: []})

      assert [%Client{name: "Real office"}] = capture(fn -> Seed.build(legacy_path: path) end)
    end

    test "gives it the holding client's id, so backfilled mentions land in it",
         %{path: path} do
      # The migration assigned existing mentions to "unassigned". If the
      # seed used a different id, every one of those mentions would sit
      # in a second, invisible client.
      LegacyStore.save(path, %{keywords: ["realoffice"], subreddits: []})

      assert [%Client{id: id}] = capture(fn -> Seed.build(legacy_path: path) end)
      assert id == SmmMonitor.Mention.default_client_id()
    end

    test "the config file outranks the environment", %{path: path} do
      # The file holds what someone actually chose from the config
      # screen; the environment holds what was deployed weeks ago.
      LegacyStore.save(path, %{keywords: ["chosen-later"], subreddits: []})

      assert [%Client{keywords: ["chosen-later"]}] =
               capture(fn -> Seed.build(legacy_path: path, keywords: ["deployed-earlier"]) end)
    end

    test "says what it did, since nobody asked for a client to appear", %{path: path} do
      LegacyStore.save(path, %{keywords: ["realoffice"], subreddits: []})

      log = capture_log(fn -> Seed.build(legacy_path: path) end)

      assert log =~ "no clients stored yet"
      assert log =~ "realoffice"
    end

    test "leaves the config file alone, so a rollback still has it", %{path: path} do
      LegacyStore.save(path, %{keywords: ["realoffice"], subreddits: ["marketing"]})
      before = File.read!(path)

      capture(fn -> Seed.build(legacy_path: path) end)

      assert File.read!(path) == before
    end
  end

  describe "a fresh install with no config file" do
    test "falls back to the environment's keywords", %{path: path} do
      assert [%Client{keywords: ["fromenv"]}] =
               capture(fn -> Seed.build(legacy_path: path, keywords: ["fromenv"]) end)
    end

    test "still produces a client when there is nothing to go on", %{path: path} do
      # A monitoring tool with no clients is a blank screen with no way
      # out of it: the config screen needs a row to edit.
      assert [%Client{} = client] = capture(fn -> Seed.build(legacy_path: path, keywords: []) end)

      assert client.keywords != []
      assert client.name != ""
    end

    test "says the placeholder is a placeholder", %{path: path} do
      log = capture_log(fn -> Seed.build(legacy_path: path, keywords: []) end)

      assert log =~ "placeholder"
      assert log =~ "config screen"
    end
  end

  describe "a config file that can't be read" do
    test "falls back to the environment rather than refusing to boot", %{path: path} do
      File.write!(path, "{ this is not json")

      assert [%Client{keywords: ["fromenv"]}] =
               capture(fn -> Seed.build(legacy_path: path, keywords: ["fromenv"]) end)
    end
  end

  describe "name_from/1" do
    test "prefers the longest term, which reads as a company name" do
      # "real office" reads as a business; "realoffice" reads as a handle.
      assert Seed.name_from(["realoffice", "real office"]) == "Real office"
    end

    test "falls back when there is nothing to name it after" do
      assert Seed.name_from([]) == "Unassigned"
    end
  end

  defp capture(fun) do
    {result, _log} = with_log(fun)
    result
  end
end
