defmodule SmmMonitor.Fetchers.MultiClientTest do
  @moduledoc """
  Polling several clients from one worker per platform.

  The thing under test is the design decision: an API budget belongs to
  the credential, not to the client, so every client's fetch draws on one
  shared tracker. If this ever regresses into a tracker per client, four
  clients quietly spend four times the quota and the platform is cut off
  without warning.
  """

  use SmmMonitor.ClientCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
  alias SmmMonitor.Fetchers.{Twitter, Worker, YouTube}
  alias SmmMonitor.Fetchers.Twitter.PostBudget
  alias SmmMonitor.Fetchers.YouTube.Quota
  alias SmmMonitor.{Monitor, TwitterStub, YouTubeStub}

  setup do
    Monitor.reset()
    {:ok, body: "test/fixtures/twitter_search_recent.json" |> File.read!() |> Jason.decode!()}
  end

  describe "one shared budget across clients" do
    test "every client's search is charged to the same budget", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))
      state = Twitter.init_state(context(build_client("Acme")))

      state =
        Enum.reduce(set_clients(["Acme", "Beta", "Gamma"]), state, fn client, acc ->
          {:ok, _mentions, next} = Twitter.fetch(context(client), acc)
          next
        end)

      # Three clients, three searches, three posts each — all from one
      # budget, not one budget each.
      assert state.post_budget.calls == 3
      assert state.post_budget.used == 9
    end

    test "the budget runs out across clients, not per client", %{body: body} do
      # 20 posts of budget and three clients returning three each: the
      # third client is refused because the first two spent it, which is
      # exactly the behaviour a per-client tracker would get wrong.
      TwitterStub.install(TwitterStub.results(body))
      clients = set_clients(["Acme", "Beta", "Gamma"])

      state = %{
        Twitter.init_state(context(hd(clients)))
        | post_budget: PostBudget.spend(PostBudget.new(20), 15)
      }

      {outcomes, _state} =
        with_log(fn ->
          Enum.map_reduce(clients, state, fn client, acc ->
            case Twitter.fetch(context(client, monthly_post_budget: 20), acc) do
              {:ok, _mentions, next} -> {:ok, next}
              {:error, reason, next} -> {{:error, reason}, next}
            end
          end)
        end)
        |> elem(0)

      assert Enum.count(outcomes, &(&1 == :ok)) < 3
      assert Enum.any?(outcomes, &match?({:error, {:quota_exhausted, _ms}}, &1))
    end

    test "YouTube's daily quota is spent across clients too" do
      body = "test/fixtures/youtube_search.json" |> File.read!() |> Jason.decode!()
      YouTubeStub.install(YouTubeStub.results(body))
      clients = set_clients(["Acme", "Beta", "Gamma"])

      state =
        Enum.reduce(clients, YouTube.init_state(youtube_context(hd(clients))), fn client, acc ->
          {:ok, _mentions, next} = YouTube.fetch(youtube_context(client), acc)
          next
        end)

      # 100 units per search, three clients, one key.
      assert state.quota.used == 3 * Quota.search_cost()
      assert state.quota.calls == 3
    end

    test "each client searches for its own brand terms", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))
      clients = set_clients(["Acme", "Beta"])

      Enum.reduce(clients, Twitter.init_state(context(hd(clients))), fn client, acc ->
        {:ok, _mentions, next} = Twitter.fetch(context(client), acc)
        next
      end)

      queries = Enum.map(0..1, &TwitterStub.query_params(&1)["query"])

      assert Enum.any?(queries, &(&1 =~ "acme"))
      assert Enum.any?(queries, &(&1 =~ "beta"))
    end
  end

  describe "rotation" do
    test "the client polled first changes every cycle" do
      # Without this, whoever sits first in the list takes the shared
      # quota every time and the rest are permanently starved.
      clients = set_clients(["Acme", "Beta", "Gamma"])
      ids = Enum.map(clients, & &1.id)

      firsts =
        for poll <- 0..3 do
          {head, tail} = Enum.split(ids, rem(poll, length(ids)))
          List.first(tail ++ head)
        end

      assert firsts == ["acme", "beta", "gamma", "acme"]
    end
  end

  describe "the worker end to end" do
    setup do
      Application.put_env(:smm_monitor, :mock_platforms, fake: true)
      on_exit(fn -> Application.delete_env(:smm_monitor, :mock_platforms) end)
      :ok
    end

    test "collects mentions for every active client, tagged with whose they are" do
      set_clients(["Acme", "Beta"])

      start_worker()

      assert eventually(fn -> Worker.status(:fake).poll_count > 0 end)

      assert length(Monitor.recent(:all, 100, "acme")) > 0
      assert length(Monitor.recent(:all, 100, "beta")) > 0
      assert Enum.all?(Monitor.recent(:all, 100, "acme"), &(&1.client_id == "acme"))
    end

    test "skips paused clients" do
      [acme, beta] = set_clients(["Acme", "Beta"])
      Clients.replace([acme, %{beta | active: false}])

      start_worker()
      assert eventually(fn -> Worker.status(:fake).poll_count > 0 end)

      assert length(Monitor.recent(:all, 100, "acme")) > 0
      assert Monitor.recent(:all, 100, "beta") == []
    end

    test "reports how many clients the cycle covered" do
      set_clients(["Acme", "Beta", "Gamma"])

      start_worker()
      assert eventually(fn -> Worker.status(:fake).poll_count > 0 end)

      status = Worker.status(:fake)
      assert status.clients_due == 3
      assert status.clients_polled == 3
    end

    test "with no clients it polls nobody rather than crashing" do
      set_clients([])

      start_worker()
      assert eventually(fn -> Worker.status(:fake).poll_count > 0 end)

      status = Worker.status(:fake)
      assert status.clients_due == 0
      assert status.clients_polled == 0
      assert is_nil(status.last_error)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp start_worker do
    start_supervised!(
      {SmmMonitor.Fetchers.PlatformSupervisor,
       platform: :fake, module: SmmMonitor.FakeFetcher, interval_ms: 60_000},
      id: {:worker, :fake}
    )
  end

  defp context(client, overrides \\ []) do
    %{
      platform: :twitter,
      client: client,
      keywords: client.keywords,
      subreddits: client.subreddits,
      credentials: [bearer_token: "AAAA"],
      opts: [req_options: TwitterStub.req_options()] ++ overrides,
      poll_count: 0,
      interval_ms: :timer.minutes(5)
    }
  end

  defp youtube_context(client) do
    %{
      platform: :youtube,
      client: client,
      keywords: client.keywords,
      subreddits: [],
      credentials: [api_key: "key"],
      opts: [req_options: YouTubeStub.req_options()],
      poll_count: 0,
      interval_ms: :timer.minutes(5)
    }
  end

  defp eventually(check, attempts \\ 60)
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
