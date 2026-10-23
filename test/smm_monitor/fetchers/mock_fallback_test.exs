defmodule SmmMonitor.Fetchers.MockFallbackTest do
  @moduledoc """
  The rule this file protects: a platform configured for live data but
  missing its credentials collects **nothing**, says so once, and keeps
  the worker alive.

  It used to invent mentions instead, on the reasoning that an empty tab
  was worse than a full one. That was wrong. Invented posts are
  indistinguishable from collected ones once they are in the table, they
  are written to the same database, and they then skew the trends, the
  alerts and every report exported afterwards. Nothing about a missing
  key justifies making the numbers up.

  Nothing here touches the network: an unconfigured platform makes no
  request at all, and the live path is covered with a fake fetcher that
  returns canned data.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.Fetchers.{Instagram, PlatformSupervisor, Reddit, Twitter, Worker, YouTube}
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

    test "platforms are switched independently of one another" do
      Application.put_env(:smm_monitor, :mock_platforms, reddit: false, youtube: true)

      refute SmmMonitor.mock_platform?(:reddit)
      assert SmmMonitor.mock_platform?(:youtube)

      Application.put_env(:smm_monitor, :mock_platforms, reddit: true, youtube: false)

      assert SmmMonitor.mock_platform?(:reddit)
      refute SmmMonitor.mock_platform?(:youtube)
      # Whatever Reddit and YouTube are doing, the stubs stay mocked.
      assert SmmMonitor.mock_platform?(:twitter)
      assert SmmMonitor.mock_platform?(:instagram)
    end
  end

  describe "YouTube with no API key" do
    setup do
      Application.put_env(:smm_monitor, :mock_platforms, youtube: false)
      Application.put_env(:smm_monitor, :credentials, youtube: [])
      :ok
    end

    test "collects nothing, rather than inventing it" do
      log =
        capture_log(fn ->
          start_worker(:youtube, YouTube)
          assert eventually(fn -> polled?(:youtube) end)
        end)

      status = Worker.status(:youtube)
      assert status.mode == :unconfigured
      assert status.inserted == 0
      assert is_nil(status.last_error)
      assert Monitor.stats(:youtube).count == 0
      assert log =~ "youtube"
      assert log =~ "no credentials"
    end

    test "spends no API quota" do
      # The whole point: no key means no calls, so nothing to spend.
      capture_log(fn ->
        start_worker(:youtube, YouTube)
        assert eventually(fn -> polled?(:youtube) end)
      end)

      assert Worker.status(:youtube).mode == :unconfigured
    end

    test "a blank key is treated as missing" do
      Application.put_env(:smm_monitor, :credentials, youtube: [api_key: "   "])

      capture_log(fn ->
        start_worker(:youtube, YouTube)
        assert eventually(fn -> polled?(:youtube) end)
      end)

      assert Worker.status(:youtube).mode == :unconfigured
    end
  end

  describe "YouTube.ready?/1" do
    test "is what decides live vs. fallback" do
      refute YouTube.ready?(youtube_context(credentials: []))
      refute YouTube.ready?(youtube_context(credentials: [api_key: ""]))
      assert YouTube.ready?(youtube_context(credentials: [api_key: "key"]))
    end
  end

  describe "Twitter with no bearer token" do
    setup do
      Application.put_env(:smm_monitor, :mock_platforms, twitter: false)
      Application.put_env(:smm_monitor, :credentials, twitter: [])
      :ok
    end

    test "collects nothing, rather than inventing it" do
      log =
        capture_log(fn ->
          start_worker(:twitter, Twitter)
          assert eventually(fn -> polled?(:twitter) end)
        end)

      status = Worker.status(:twitter)
      assert status.mode == :unconfigured
      assert status.inserted == 0
      assert is_nil(status.last_error)
      assert Monitor.stats(:twitter).count == 0
      assert log =~ "twitter"
      assert log =~ "no credentials"
    end

    test "spends nothing from the monthly post cap" do
      # No token means no request, so there is no cap to spend.
      capture_log(fn ->
        start_worker(:twitter, Twitter)
        assert eventually(fn -> polled?(:twitter) end)
      end)

      assert Worker.status(:twitter).mode == :unconfigured
    end

    test "a blank token is treated as missing" do
      Application.put_env(:smm_monitor, :credentials, twitter: [bearer_token: "   "])

      capture_log(fn ->
        start_worker(:twitter, Twitter)
        assert eventually(fn -> polled?(:twitter) end)
      end)

      assert Worker.status(:twitter).mode == :unconfigured
    end
  end

  describe "Instagram with incomplete credentials" do
    setup do
      Application.put_env(:smm_monitor, :mock_platforms, instagram: false)
      :ok
    end

    test "collects nothing, rather than inventing it" do
      Application.put_env(:smm_monitor, :credentials, instagram: [])

      log =
        capture_log(fn ->
          start_worker(:instagram, Instagram)
          assert eventually(fn -> polled?(:instagram) end)
        end)

      status = Worker.status(:instagram)
      assert status.mode == :unconfigured
      assert status.inserted == 0
      assert is_nil(status.last_error)
      assert Monitor.stats(:instagram).count == 0
      assert log =~ "instagram"
      assert log =~ "no credentials"
    end

    test "a token without a business account id is treated as missing" do
      # Every Instagram endpoint here is scoped to one account, so a token
      # alone can't address anything.
      Application.put_env(:smm_monitor, :credentials, instagram: [access_token: "IGQ..."])

      capture_log(fn ->
        start_worker(:instagram, Instagram)
        assert eventually(fn -> polled?(:instagram) end)
      end)

      assert Worker.status(:instagram).mode == :unconfigured
    end

    test "a business account id without a token is treated as missing" do
      Application.put_env(:smm_monitor, :credentials, instagram: [business_account_id: "17841"])

      capture_log(fn ->
        start_worker(:instagram, Instagram)
        assert eventually(fn -> polled?(:instagram) end)
      end)

      assert Worker.status(:instagram).mode == :unconfigured
    end
  end

  describe "each platform's credentials are independent of the others" do
    test "one platform going live doesn't drag the others with it" do
      # The realistic state of a rollout: Reddit configured, the rest not.
      Application.put_env(:smm_monitor, :mock_platforms,
        reddit: false,
        twitter: false,
        instagram: false
      )

      Application.put_env(:smm_monitor, :credentials,
        reddit: [client_id: "id", client_secret: "secret"],
        twitter: [],
        instagram: []
      )

      assert Reddit.ready?(platform_context(:reddit))
      refute Twitter.ready?(platform_context(:twitter))
      refute Instagram.ready?(platform_context(:instagram))
    end
  end

  describe "a live-configured platform with no credentials" do
    setup do
      # Reddit is told to go live, but no credentials are configured.
      Application.put_env(:smm_monitor, :mock_platforms, reddit: false)
      Application.put_env(:smm_monitor, :credentials, reddit: [])
      :ok
    end

    test "collects nothing, rather than inventing it" do
      # The capture has to span the wait: the first poll fires after a
      # startup jitter, so it lands well after start_supervised! returns.
      log =
        capture_log(fn ->
          start_reddit_worker()
          assert eventually(fn -> polled?(:reddit) end)
        end)

      status = Worker.status(:reddit)
      assert status.mode == :unconfigured
      # Collecting nothing is not a failure: no error, no retry storm,
      # and above all nothing invented to fill the gap.
      assert status.inserted == 0
      assert is_nil(status.last_error)
      assert Monitor.stats(:reddit).count == 0
      assert log =~ "no credentials"
    end

    test "says which platform, and how to fix it" do
      log =
        capture_log(fn ->
          start_reddit_worker()
          assert eventually(fn -> polled?(:reddit) end)
        end)

      assert log =~ "reddit"
      assert log =~ "nothing is being collected"
      # The message has to name the fix, not just the fault.
      assert log =~ "c` then `S"
      assert log =~ "Nothing will be invented"
    end

    test "a half-configured credential pair is treated as missing" do
      # A client id with no secret cannot authenticate. Better to collect
      # nothing and say so than to fail every poll with a 401.
      Application.put_env(:smm_monitor, :credentials, reddit: [client_id: "id"])

      capture_log(fn ->
        start_reddit_worker()
        assert eventually(fn -> polled?(:reddit) end)
      end)

      assert Worker.status(:reddit).mode == :unconfigured
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
      refute log =~ "no credentials"
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

  describe "Twitter.ready?/1" do
    test "is what decides live vs. fallback" do
      refute Twitter.ready?(platform_context(:twitter, []))
      refute Twitter.ready?(platform_context(:twitter, bearer_token: nil))
      refute Twitter.ready?(platform_context(:twitter, bearer_token: ""))
      assert Twitter.ready?(platform_context(:twitter, bearer_token: "AAAA"))
    end
  end

  describe "Instagram.ready?/1" do
    test "needs both the token and the account it is scoped to" do
      refute Instagram.ready?(platform_context(:instagram, []))
      refute Instagram.ready?(platform_context(:instagram, access_token: "IGQ"))
      refute Instagram.ready?(platform_context(:instagram, business_account_id: "17841"))

      assert Instagram.ready?(
               platform_context(:instagram, access_token: "IGQ", business_account_id: "17841")
             )
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

  defp youtube_context(overrides) do
    %{
      platform: :youtube,
      keywords: ["realoffice"],
      credentials: Keyword.fetch!(overrides, :credentials),
      opts: [],
      poll_count: 0,
      interval_ms: :timer.minutes(18)
    }
  end

  # Credentials come from application config when not passed explicitly,
  # which is how the worker assembles them.
  defp platform_context(platform, credentials \\ nil) do
    credentials =
      credentials ||
        :smm_monitor |> Application.get_env(:credentials, []) |> Keyword.get(platform, [])

    %{
      platform: platform,
      keywords: ["realoffice"],
      credentials: credentials,
      opts: [],
      poll_count: 0,
      interval_ms: :timer.minutes(5)
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
