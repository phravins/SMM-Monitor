defmodule SmmMonitor.ConfigTest do
  @moduledoc """
  Each test starts its own Config process against a temporary file, so
  they run concurrently and never touch a real config.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SmmMonitor.Config

  doctest Config

  setup context do
    path =
      Path.join(
        System.tmp_dir!(),
        "smm_config_test_#{:erlang.phash2(context.test)}_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm_rf(path) end)

    {:ok, path: path}
  end

  describe "defaults" do
    test "come from application env when there is no file", %{path: path} do
      config = start_config(path, keywords: ["seeded"], subreddits: ["seededsub"])

      assert Config.keywords(config) == ["seeded"]
      assert Config.subreddits(config) == ["seededsub"]
      assert Config.source(config) == :defaults
    end

    test "fall back to the app's configured values when none are given", %{path: path} do
      config = start_config(path)

      # config/config.exs seeds these; the point is that an untouched
      # install behaves exactly as its env vars say.
      assert Config.keywords(config) == SmmMonitor.config(:keywords, [])
      refute Config.subreddits(config) == []
    end
  end

  describe "put_keywords/2" do
    test "replaces the tracked terms", %{path: path} do
      config = start_config(path)

      assert {:ok, ["acme"]} = Config.put_keywords(config, ["acme"])
      assert Config.keywords(config) == ["acme"]
    end

    test "accepts the comma-separated string the config screen produces", %{path: path} do
      config = start_config(path)

      assert {:ok, ["acme", "acme corp"]} = Config.put_keywords(config, "acme, acme corp")
    end

    test "trims, drops blanks and de-duplicates", %{path: path} do
      config = start_config(path)

      assert {:ok, ["acme", "other"]} = Config.put_keywords(config, "  acme , , acme ,other")
    end

    test "refuses to leave nothing being monitored", %{path: path} do
      config = start_config(path, keywords: ["original"])

      assert {:error, :no_keywords} = Config.put_keywords(config, "")
      assert {:error, :no_keywords} = Config.put_keywords(config, "  ,  ")
      assert {:error, :no_keywords} = Config.put_keywords(config, [])

      # The previous value survives a rejected write.
      assert Config.keywords(config) == ["original"]
    end
  end

  describe "put_subreddits/2" do
    test "replaces the watched list", %{path: path} do
      config = start_config(path)

      assert {:ok, ["marketing", "saas"]} = Config.put_subreddits(config, "marketing, saas")
      assert Config.subreddits(config) == ["marketing", "saas"]
    end

    test "allows an empty list, which means search all of Reddit", %{path: path} do
      # Unlike keywords, this is a real choice rather than a mistake.
      config = start_config(path, subreddits: ["marketing"])

      assert {:ok, []} = Config.put_subreddits(config, "")
      assert Config.subreddits(config) == []
    end
  end

  describe "persistence" do
    test "writes changes to the file", %{path: path} do
      config = start_config(path)
      Config.put_keywords(config, "persisted")

      assert File.exists?(path)
      assert %{"keywords" => ["persisted"], "version" => 1} = read_json(path)
    end

    test "reloads what was saved, as a restart would", %{path: path} do
      first = start_config(path, keywords: ["default"])
      Config.put_keywords(first, "chosen")
      Config.put_subreddits(first, "chosensub")
      stop_config(first)

      # A fresh process against the same file: the saved values win over
      # the defaults, which is the whole point of persisting them.
      second = start_config(path, keywords: ["default"], subreddits: ["defaultsub"])

      assert Config.keywords(second) == ["chosen"]
      assert Config.subreddits(second) == ["chosensub"]
      assert Config.source(second) == :file
    end

    test "an empty saved subreddit list survives a reload", %{path: path} do
      # It has to be distinguishable from "no value saved", or clearing the
      # list would silently revert to the defaults on the next boot.
      first = start_config(path, subreddits: ["default"])
      Config.put_subreddits(first, "")
      stop_config(first)

      assert Config.subreddits(start_config(path, subreddits: ["default"])) == []
    end

    test "records when the change was made", %{path: path} do
      config = start_config(path)
      assert is_nil(Config.updated_at(config))

      Config.put_keywords(config, "acme")
      assert %DateTime{} = Config.updated_at(config)
    end

    test "leaves no temporary files behind", %{path: path} do
      config = start_config(path)
      Config.put_keywords(config, "acme")

      leftovers =
        path |> Path.dirname() |> File.ls!() |> Enum.filter(&String.contains?(&1, ".tmp-"))

      assert leftovers == []
    end
  end

  describe "a missing or unusable file" do
    test "a missing file is not an error", %{path: path} do
      refute File.exists?(path)
      config = start_config(path, keywords: ["default"])

      assert Config.keywords(config) == ["default"]
      assert Config.source(config) == :defaults
    end

    test "corrupt JSON falls back to defaults instead of refusing to boot", %{path: path} do
      File.write!(path, "{ this is not json")

      config = start_quietly(path, keywords: ["default"])

      assert Config.keywords(config) == ["default"]
      assert {:corrupt, _reason} = Config.source(config)
    end

    test "the unreadable file is kept rather than overwritten", %{path: path} do
      # Someone hand-edited that; losing it without a trace would be rude.
      File.write!(path, "{ broken")
      start_quietly(path)

      assert File.read!("#{path}.corrupt") == "{ broken"
      on_exit(fn -> File.rm_rf("#{path}.corrupt") end)
    end

    test "valid JSON of the wrong shape falls back too", %{path: path} do
      File.write!(path, ~s(["not", "an", "object"]))

      config = start_quietly(path, keywords: ["default"])
      assert Config.keywords(config) == ["default"]
      assert {:corrupt, _reason} = Config.source(config)
    end

    test "a single bad field doesn't discard the good ones", %{path: path} do
      File.write!(path, ~s({"version": 1, "keywords": ["kept"], "subreddits": "not a list"}))

      config = start_config(path, subreddits: ["default"])

      assert Config.keywords(config) == ["kept"]
      # The malformed field falls back rather than taking the file with it.
      assert Config.subreddits(config) == ["default"]
    end
  end

  describe "all/1 and reset/1" do
    test "all/1 returns everything editable", %{path: path} do
      config = start_config(path, keywords: ["k"], subreddits: ["s"])

      assert %{keywords: ["k"], subreddits: ["s"]} = Config.all(config)
    end

    test "reset/1 restores the compile-time defaults", %{path: path} do
      config = start_config(path)
      Config.put_keywords(config, "temporary")

      assert :ok = Config.reset(config)
      assert Config.keywords(config) == SmmMonitor.config(:keywords, [])
    end
  end

  describe "normalize/1" do
    test "handles lists, strings, nil and junk" do
      assert Config.normalize(["a", "b"]) == ["a", "b"]
      assert Config.normalize("a, b") == ["a", "b"]
      assert Config.normalize(nil) == []
      assert Config.normalize(42) == []
    end
  end

  defp start_config(path, opts \\ []) do
    name = :"config_#{System.unique_integer([:positive])}"
    start_supervised!({Config, [name: name, path: path] ++ opts}, id: name)
    name
  end

  defp stop_config(name), do: stop_supervised!(name)

  # Starting against a broken file logs a warning on purpose; capture it so
  # the suite's output stays readable.
  defp start_quietly(path, opts \\ []) do
    result = nil

    capture_log(fn -> send(self(), {:started, start_config(path, opts)}) end)

    receive do
      {:started, name} -> name
    after
      0 -> result
    end
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
end
