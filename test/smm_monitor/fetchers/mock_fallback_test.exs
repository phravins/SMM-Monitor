defmodule SmmMonitor.Fetchers.MockFallbackTest do
  @moduledoc """
  The rule this file protects: a platform configured for live data but
  missing its credentials degrades to fixtures with a clear log message —
  it does not crash, and it does not leave that tab empty.

  Nothing here touches the network. In the fallback path the worker calls
  `mock_fetch/2`, which never makes an HTTP request; the live path is
  covered with a fake fetcher that returns canned data.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.Fetchers.{PlatformSupervisor, Reddit, Worker}
  alias SmmMonitor.Monitor

  setup do
    Monitor.reset()

    # Every test here changes global config, so snapshot and restore it.
    original_mock_platforms = Application.get_env(:smm_monitor, :mock_platforms)
    original_credentials = Application.get_env(:smm_monitor, :credentials)

    on_exit(fn ->
      restore(:mock_platforms, original_mock_platforms)
      restore(:credentials, original_credentials)
    end)

    :ok
  end

  describe "SmmMonitor.mock_platform?/1" do
    test "inherits the global setting when there is no override" do
      Application.put_env(:smm_monitor, :mock_platforms, [])

      assert SmmMonitor.mock_platform?(:reddit)
      assert SmmMonitor.mock_platform?(:youtube)
    end

    test "an unset override (nil) also inherits, rather than meaning 'live'" do
      # SMM_MOCK_REDDIT unset produces nil. Reading that as `false` would
      # silently put Reddit live for anyone who never set the variable.
      Application.put_env(:smm_monitor, :mock_platforms, reddit: nil)

      assert SmmMonitor.mock_platform?(:reddit)
    end

    test "a per-platform override wins over the global setting" do
      Application.put_env(:smm_monitor, :mock_platforms, reddit: false)

      refute SmmMonitor.mock_platform?(:reddit)
      # The others are untouched by Reddit's override.
      assert SmmMonitor.mock_platform?(:youtube)
      assert SmmMonitor.mock_platform?(:twitter)
      assert SmmMonitor.mock_platform?(:instagram)
    end
  end

  describe "a live-configured platform with no credentials" do
    setup do
      # Reddit is told to go live, but no credentials are configured.
      Application.put_env(:smm_monitor, :mock_platforms, reddit: false)
      Application.put_env(:smm_monitor, :credentials, reddit: [])
      :ok
    end

    test "falls back to mock data instead of crashing" do
      # The capture has to span the wait: the first poll fires after a
      # startup jitter, so it lands well after start_supervised! returns.
      log =
        capture_log(fn ->
          start_reddit_worker()
          assert eventually(fn -> polled?(:reddit) end)
        end)

      status = Worker.status(:reddit)
      assert status.mode == :mock
      # Falling back is not a failure: nothing errored, mentions still flowed.
      assert status.inserted > 0
      assert is_nil(status.last_error)
      assert Monitor.stats(:reddit).count > 0
      assert log =~ "credentials are missing"
    end

    test "says which platform and points at the README" do
      log =
        capture_log(fn ->
          start_reddit_worker()
          assert eventually(fn -> polled?(:reddit) end)
        end)

      assert log =~ "reddit"
      assert log =~ "falling back to mock data"
      assert log =~ "README"
    end

    test "a half-configured credential pair is treated as missing" do
      # A client id with no secret can't authenticate; better to fall back
      # than to fail every poll with a 401.
      Application.put_env(:smm_monitor, :credentials, reddit: [client_id: "id"])

      capture_log(fn ->
        start_reddit_worker()
        assert eventually(fn -> polled?(:reddit) end)
      end)

      assert Worker.status(:reddit).mode == :mock
    end

    test "the worker stays alive and keeps polling" do
      capture_log(fn ->
        start_reddit_worker()
        assert eventually(fn -> polled?(:reddit) end)
      end)

      pid = Process.whereis(Worker.name(:reddit))
      Worker.poll_now(:reddit)

      assert eventually(fn -> Worker.status(:reddit).poll_count > 1 end)
      assert Process.alive?(pid)
    end
  end

  describe "mock mode with credentials present" do
    test "still serves fixtures — the flag wins over having credentials" do
      Application.put_env(:smm_monitor, :mock_platforms, reddit: true)
      Application.put_env(:smm_monitor, :credentials, reddit: [client_id: "id", client_secret: "s"])

      log =
        capture_log(fn ->
          start_reddit_worker()
          assert eventually(fn -> polled?(:reddit) end)
        end)

      assert Worker.status(:reddit).mode == :mock
      # No warning: this is a deliberate choice, not a misconfiguration.
      refute log =~ "credentials are missing"
    end
  end

  describe "a live-configured platform with credentials" do
    test "resolves to live mode and calls fetch/2, not mock_fetch/2" do
      Application.put_env(:smm_monitor, :mock_platforms, fake: false)
      Application.put_env(:smm_monitor, :credentials, fake: [token: "present"])

      start_worker(:fake, SmmMonitor.FakeFetcher)
      assert eventually(fn -> polled?(:fake) end)

      status = Worker.status(:fake)
      assert status.mode == :live
      assert status.inserted > 0
      # The canned mention proves the live path ran.
      assert [%{author: "u/live_path"}] = Monitor.recent(:fake, 10)
    end
  end

  describe "Reddit.ready?/1" do
    test "is what decides live vs. fallback" do
      refute Reddit.ready?(context(credentials: []))
      refute Reddit.ready?(context(credentials: [client_id: "id"]))
      assert Reddit.ready?(context(credentials: [client_id: "id", client_secret: "secret"]))
    end
  end

  # --- helpers --------------------------------------------------------------

  defp start_reddit_worker, do: start_worker(:reddit, Reddit)

  defp start_worker(platform, module) do
    start_supervised!(
      {PlatformSupervisor, platform: platform, module: module, interval_ms: 60_000},
      id: {:worker, platform}
    )
  end

  defp polled?(platform) do
    match?(%{poll_count: count} when count > 0, Worker.status(platform))
  end

  defp context(overrides) do
    %{
      platform: :reddit,
      keywords: ["realoffice"],
      credentials: Keyword.fetch!(overrides, :credentials),
      opts: [],
      poll_count: 0
    }
  end

  defp restore(key, nil), do: Application.delete_env(:smm_monitor, key)
  defp restore(key, value), do: Application.put_env(:smm_monitor, key, value)

  defp eventually(check, attempts \\ 50)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
