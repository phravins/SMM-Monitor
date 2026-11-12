defmodule SmmMonitor.Fetchers.Threads.FetchTest do
  @moduledoc """
  The whole live fetch path, against a stub transport. No network, no
  token, no Meta app.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias SmmMonitor.Fetchers.{Fetcher, Threads}
  alias SmmMonitor.Fetchers.Threads.{QueryBudget, State}
  alias SmmMonitor.ThreadsStub

  @token "THAAtesttoken000000000000000"
  @user_id "17841400000000001"
  @now_ms DateTime.to_unix(~U[2026-11-12 12:00:00Z], :millisecond)
  @now_s div(@now_ms, 1_000)

  setup_all do
    {:ok, search: fixture("threads_search"), mentions: fixture("threads_mentions")}
  end

  describe "keyword search" do
    test "returns the posts Meta finds for a brand term", %{search: search} do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.ok(search)})

      assert {:ok, mentions, _state} = Threads.fetch(context(sources: [:search]), new_state())

      assert length(mentions) == 3
      assert Enum.all?(mentions, &(&1.platform == :threads))
      assert "threads-18050206876707110" in Enum.map(mentions, & &1.id)
    end

    test "asks for recent posts from the last day on the first poll", %{search: search} do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.ok(search)})

      Threads.fetch(context(sources: [:search]), new_state())
      params = ThreadsStub.query_params("/keyword_search")

      assert params["q"] == "acme"
      assert params["search_type"] == "RECENT"
      assert params["limit"] == "50"
      assert params["access_token"] == @token
      assert params["since"] == Integer.to_string(@now_s - 86_400)
      assert params["fields"] =~ "permalink"
      assert params["fields"] =~ "username"
    end

    test "goes to graph.threads.net v1.0", %{search: search} do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.ok(search)})

      Threads.fetch(context(sources: [:search]), new_state())

      assert [url] = ThreadsStub.requests_to("/keyword_search")
      assert url =~ ~r{\Ahttps://graph\.threads\.net/v1\.0/keyword_search\?}
    end

    test "the next poll starts a little before the newest post seen", %{search: search} do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.ok(search)})

      {:ok, _mentions, state} = Threads.fetch(context(sources: [:search]), new_state())
      {:ok, _mentions, _state} = Threads.fetch(context(sources: [:search]), state)

      newest = DateTime.to_unix(~U[2026-11-12 09:41:12Z])
      assert [_first, second] = ThreadsStub.all_query_params("/keyword_search")
      assert second["since"] == Integer.to_string(newest - 600)
    end

    test "an empty answer leaves the read position where it was" do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.empty()})

      {:ok, [], state} = Threads.fetch(context(sources: [:search]), new_state())
      {:ok, [], _state} = Threads.fetch(context(sources: [:search]), state)

      assert [first, second] = ThreadsStub.all_query_params("/keyword_search")
      assert first["since"] == second["since"]
    end

    test "searches each brand term once" do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.empty()})

      Threads.fetch(
        context(sources: [:search], keywords: ["acme", "Acme", "acme corp"]),
        new_state()
      )

      assert Enum.map(ThreadsStub.all_query_params("/keyword_search"), & &1["q"]) ==
               ["acme", "acme corp"]
    end

    test "caps the terms searched per client" do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.empty()})
      keywords = for n <- 1..15, do: "term#{n}"

      Threads.fetch(context(sources: [:search], keywords: keywords), new_state())

      assert length(ThreadsStub.requests_to("/keyword_search")) == 10
    end

    test "each client keeps its own read position", %{search: search} do
      ThreadsStub.install(%{"/keyword_search" => [ThreadsStub.ok(search), ThreadsStub.empty()]})

      {:ok, _mentions, state} = Threads.fetch(context(sources: [:search]), new_state())

      other = %SmmMonitor.Client{id: "globex", name: "Globex", keywords: ["acme"]}
      {:ok, _mentions, _state} = Threads.fetch(context(sources: [:search], client: other), state)

      assert [_acme, globex] = ThreadsStub.all_query_params("/keyword_search")
      assert globex["since"] == Integer.to_string(@now_s - 86_400)
    end

    test "every search counts against the budget" do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.empty()})

      {:ok, [], state} =
        Threads.fetch(context(sources: [:search], keywords: ["a1", "b2", "c3"]), new_state())

      assert QueryBudget.remaining(state.budget, @now_ms) == QueryBudget.default_budget() - 3
    end

    test "a spent budget stops search and says how long until a query frees up" do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.empty()})

      budget =
        QueryBudget.new(2) |> QueryBudget.spend(@now_ms - 60_000) |> QueryBudget.spend(@now_ms)

      state = %{new_state() | budget: budget}

      {result, log} = with_log(fn -> Threads.fetch(context(sources: [:search]), state) end)

      assert {:error, {:quota_exhausted, wait_ms}, state} = result
      assert wait_ms == :timer.hours(24) - 60_000
      assert Fetcher.retry_after({:quota_exhausted, wait_ms}) == wait_ms
      refute ThreadsStub.requested?("/keyword_search")
      assert log =~ "keyword-search budget spent"

      # Said once per exhaustion, not on every poll or client.
      {_result, log} = with_log(fn -> Threads.fetch(context(sources: [:search]), state) end)
      refute log =~ "budget spent"
    end

    test "a spent budget doesn't stop mentions", %{mentions: mentions} do
      ThreadsStub.install(%{
        "/me?" => ThreadsStub.me(),
        "/mentions" => ThreadsStub.ok(mentions)
      })

      budget = QueryBudget.new(1) |> QueryBudget.spend(@now_ms)
      state = %{new_state() | budget: budget}

      {result, _log} = with_log(fn -> Threads.fetch(context(), state) end)

      assert {:ok, [_one], _state} = result
    end

    test "terms that answered are kept when a later one fails", %{search: search} do
      ThreadsStub.install(%{
        "q=acme&" => ThreadsStub.ok(search),
        "q=globex" => ThreadsStub.error(400, 100, "Invalid parameter")
      })

      {result, log} =
        with_log(fn ->
          Threads.fetch(context(sources: [:search], keywords: ["acme", "globex"]), new_state())
        end)

      assert {:ok, mentions, _state} = result
      assert length(mentions) == 3
      refute log =~ "search"
    end
  end

  describe "mentions" do
    test "keeps only the mentions that name this client's brand", %{mentions: mentions} do
      ThreadsStub.install(%{"/me?" => ThreadsStub.me(), "/mentions" => ThreadsStub.ok(mentions)})

      assert {:ok, [mention], _state} = Threads.fetch(context(sources: [:mentions]), new_state())

      assert mention.id == "threads-18061234500000001"
      assert mention.author == "@priya_writes"
    end

    test "asks for the connected account's mentions since the last day", %{mentions: mentions} do
      ThreadsStub.install(%{"/me?" => ThreadsStub.me(), "/mentions" => ThreadsStub.ok(mentions)})

      Threads.fetch(context(sources: [:mentions]), new_state())
      params = ThreadsStub.query_params("/mentions")

      assert ThreadsStub.requested?("/#{@user_id}/mentions")
      assert params["since"] == Integer.to_string(@now_s - 86_400)
      assert params["access_token"] == @token
    end

    test "looks the account up once", %{mentions: mentions} do
      ThreadsStub.install(%{"/me?" => ThreadsStub.me(), "/mentions" => ThreadsStub.ok(mentions)})

      {:ok, _mentions, state} = Threads.fetch(context(sources: [:mentions]), new_state())
      {:ok, _mentions, state} = Threads.fetch(context(sources: [:mentions]), state)

      assert length(ThreadsStub.requests_to("/me?")) == 1
      assert state.user_id == @user_id
      assert state.username == "@acme"
    end

    test "a different client gets the mentions that name its brand", %{mentions: mentions} do
      ThreadsStub.install(%{"/me?" => ThreadsStub.me(), "/mentions" => ThreadsStub.ok(mentions)})
      other = %SmmMonitor.Client{id: "othercorp", name: "Other", keywords: ["lunch"]}

      assert {:ok, [mention], _state} =
               Threads.fetch(
                 context(sources: [:mentions], client: other, keywords: ["lunch"]),
                 new_state()
               )

      assert mention.id == "threads-18061234500000002"
    end

    test "an account id that isn't numeric is refused" do
      ThreadsStub.install(%{"/me?" => ThreadsStub.me("../../evil")})

      {result, _log} = with_log(fn -> Threads.fetch(context(sources: [:mentions]), new_state()) end)

      assert {:error, :bad_user_id, _state} = result
      refute ThreadsStub.requested?("/mentions")
    end
  end

  describe "replies" do
    test "are off unless asked for", %{search: search, mentions: mentions} do
      ThreadsStub.install(%{
        "/keyword_search" => ThreadsStub.ok(search),
        "/me?" => ThreadsStub.me(),
        "/mentions" => ThreadsStub.ok(mentions)
      })

      assert {:ok, _mentions, _state} = Threads.fetch(context(), new_state())

      refute ThreadsStub.requested?("/replies")
      refute ThreadsStub.requested?("/threads?")
    end

    test "when on, read the replies under the account's own posts" do
      ThreadsStub.install(%{
        "/me?" => ThreadsStub.me(),
        "/#{@user_id}/threads" =>
          ThreadsStub.ok(%{
            "data" => [
              %{"id" => "18100000000000001", "has_replies" => true},
              %{"id" => "18100000000000002", "has_replies" => false},
              %{"id" => "not-a-number", "has_replies" => true}
            ]
          }),
        "/replies" =>
          ThreadsStub.posts([ThreadsStub.post(%{"id" => "18200000000000001", "text" => "thanks!"})])
      })

      assert {:ok, [reply], _state} = Threads.fetch(context(sources: [:replies]), new_state())

      assert reply.id == "threads-18200000000000001"
      assert ThreadsStub.requests_to("/replies") |> length() == 1
      assert ThreadsStub.requested?("/18100000000000001/replies")
    end
  end

  describe "when something goes wrong" do
    test "one source failing doesn't lose the other", %{search: search} do
      ThreadsStub.install(%{
        "/keyword_search" => ThreadsStub.ok(search),
        "/me?" => ThreadsStub.me(),
        "/mentions" => ThreadsStub.missing_permission("threads_manage_mentions")
      })

      {result, log} = with_log(fn -> Threads.fetch(context(), new_state()) end)

      assert {:ok, mentions, _state} = result
      assert length(mentions) == 3
      assert log =~ "mentions"
      assert log =~ "threads_manage_mentions"
    end

    test "every source failing is an error" do
      ThreadsStub.install(%{
        "/keyword_search" => ThreadsStub.missing_permission("threads_keyword_search"),
        "/me?" => ThreadsStub.me(),
        "/mentions" => ThreadsStub.missing_permission("threads_manage_mentions")
      })

      {result, _log} = with_log(fn -> Threads.fetch(context(), new_state()) end)

      assert {:error, {:missing_permission, message}, _state} = result
      assert message =~ "threads_keyword_search"
    end

    test "no sources is an error" do
      assert {:error, :no_sources_enabled, _state} =
               Threads.fetch(context(sources: []), new_state())
    end

    test "an expired token stops the poll without calling anything else" do
      ThreadsStub.install(%{
        "/keyword_search" => ThreadsStub.expired_token(),
        :any => ThreadsStub.empty()
      })

      {result, log} = with_log(fn -> Threads.fetch(context(), new_state()) end)

      assert {:error, {:expired_access_token, _message}, _state} = result
      assert ThreadsStub.request_count() == 1
      assert log =~ "THREADS_ACCESS_TOKEN"
    end

    for code <- [4, 17, 32, 613] do
      test "throttling code #{code} waits as long as Meta says" do
        ThreadsStub.install(%{
          "/keyword_search" => ThreadsStub.throttled(unquote(code), 12),
          :any => ThreadsStub.empty()
        })

        {result, _log} = with_log(fn -> Threads.fetch(context(), new_state()) end)

        assert {:error, {:rate_limited, 720_000}, _state} = result
        assert ThreadsStub.request_count() == 1
      end
    end

    test "throttling with no stated wait waits 15 minutes" do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.error(400, 4, "Too many calls")})

      {result, _log} = with_log(fn -> Threads.fetch(context(sources: [:search]), new_state()) end)

      assert {:error, {:rate_limited, 900_000}, _state} = result
    end

    test "a 429 honours retry-after" do
      ThreadsStub.install(%{
        "/keyword_search" =>
          Req.Response.new(status: 429, body: "", headers: [{"retry-after", "90"}])
      })

      {result, _log} = with_log(fn -> Threads.fetch(context(sources: [:search]), new_state()) end)

      assert {:error, {:rate_limited, 90_000}, _state} = result
      assert Fetcher.retry_after({:rate_limited, 90_000}) == 90_000
    end

    test "a 5xx is an HTTP error" do
      ThreadsStub.install(%{"/keyword_search" => Req.Response.new(status: 503, body: "")})

      {result, _log} = with_log(fn -> Threads.fetch(context(sources: [:search]), new_state()) end)

      assert {:error, {:http_error, 503}, _state} = result
    end

    test "a 200 that isn't JSON is a bad response" do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.ok("<html>")})

      {result, _log} = with_log(fn -> Threads.fetch(context(sources: [:search]), new_state()) end)

      assert {:error, :bad_response, _state} = result
    end
  end

  describe "the token" do
    test "never reaches a log line" do
      ThreadsStub.install(%{
        "/keyword_search" => ThreadsStub.missing_permission(),
        "/me?" => ThreadsStub.me(),
        "/mentions" => Req.Response.new(status: 500, body: "")
      })

      {_result, log} = with_log(fn -> Threads.fetch(context(), new_state()) end)

      assert log != ""
      refute log =~ @token
    end

    test "is left out of the state's inspect output" do
      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.empty()})

      {:ok, [], state} = Threads.fetch(context(sources: [:search]), new_state())

      assert state.token == @token
      refute inspect(state) =~ @token
    end
  end

  describe "ready?/1" do
    test "needs an access token" do
      assert Threads.ready?(%{credentials: [access_token: @token]})
      refute Threads.ready?(%{credentials: [access_token: nil]})
      refute Threads.ready?(%{credentials: [access_token: "  "]})
      refute Threads.ready?(%{credentials: []})
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp new_state, do: State.new()

  defp context(overrides \\ []) do
    {client, overrides} = Keyword.pop(overrides, :client, acme())
    {keywords, overrides} = Keyword.pop(overrides, :keywords, client.keywords)

    %{
      platform: :threads,
      client: client,
      keywords: keywords,
      subreddits: [],
      credentials: [access_token: @token],
      opts:
        [req_options: ThreadsStub.req_options(), token_file: nil, clock: fn -> @now_ms end] ++
          overrides,
      poll_count: 1,
      interval_ms: :timer.minutes(5)
    }
  end

  defp acme, do: %SmmMonitor.Client{id: "acme", name: "Acme", keywords: ["acme"]}

  defp fixture(name) do
    "test/fixtures/#{name}.json" |> File.read!() |> Jason.decode!()
  end
end
