defmodule SmmMonitor.Fetchers.Instagram.FetchTest do
  @moduledoc """
  The whole live fetch path across all three sources, against a stub
  transport. No network, no token, no Business account.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias SmmMonitor.Fetchers.Instagram
  alias SmmMonitor.Fetchers.Instagram.{State, Throttle}
  alias SmmMonitor.InstagramStub

  @account_id "17841400000000000"
  @credentials [access_token: "IGQtest-token", business_account_id: @account_id]

  setup_all do
    {:ok,
     tags: fixture("instagram_tags"),
     media: fixture("instagram_media_comments"),
     hashtag_search: fixture("instagram_hashtag_search"),
     hashtag_media: fixture("instagram_hashtag_recent_media")}
  end

  describe "the tags source" do
    test "returns posts that @-tag the account", %{tags: tags} do
      InstagramStub.install(%{"/tags" => InstagramStub.ok(tags)})

      assert {:ok, mentions, _state} = Instagram.fetch(context(sources: [:tags]), State.new())

      assert length(mentions) == 2
      assert Enum.all?(mentions, &(&1.platform == :instagram))
    end

    test "asks the connected account's edge, with a token", %{tags: tags} do
      InstagramStub.install(%{"/tags" => InstagramStub.ok(tags)})

      Instagram.fetch(context(sources: [:tags]), State.new())

      assert InstagramStub.requested?("/#{@account_id}/tags")
      assert InstagramStub.query_params("/tags")["access_token"] == "IGQtest-token"
    end

    test "asks for the fields the mention struct needs", %{tags: tags} do
      InstagramStub.install(%{"/tags" => InstagramStub.ok(tags)})

      Instagram.fetch(context(sources: [:tags]), State.new())
      fields = InstagramStub.query_params("/tags")["fields"]

      assert fields =~ "caption"
      assert fields =~ "permalink"
      assert fields =~ "timestamp"
      assert fields =~ "username"
    end
  end

  describe "the comments source" do
    test "returns comments on the account's own posts", %{media: media} do
      InstagramStub.install(%{"/media" => InstagramStub.ok(media)})

      assert {:ok, mentions, _state} = Instagram.fetch(context(sources: [:comments]), State.new())

      assert length(mentions) == 3
      assert Enum.all?(mentions, &String.starts_with?(&1.id, "instagram-comment-"))
    end

    test "reads them in one request, not one per post", %{media: media} do
      # Field expansion nests the comments inside the media. Three posts
      # would otherwise be four requests against Meta's hourly allowance.
      InstagramStub.install(%{"/media" => InstagramStub.ok(media)})

      Instagram.fetch(context(sources: [:comments]), State.new())

      assert InstagramStub.request_count() == 1
      assert InstagramStub.query_params("/media")["fields"] =~ "comments{"
    end
  end

  describe "the hashtag source" do
    test "resolves the hashtag, then reads its recent media", %{
      hashtag_search: search,
      hashtag_media: media
    } do
      InstagramStub.install(%{
        "ig_hashtag_search" => InstagramStub.ok(search),
        "recent_media" => InstagramStub.ok(media)
      })

      assert {:ok, mentions, _state} = Instagram.fetch(context(sources: [:hashtag]), State.new())

      assert length(mentions) == 2
      assert InstagramStub.requested?("ig_hashtag_search")
      assert InstagramStub.requested?("/17843712345678901/recent_media")
    end

    test "sends the account id on both calls, as Meta requires", %{
      hashtag_search: search,
      hashtag_media: media
    } do
      InstagramStub.install(%{
        "ig_hashtag_search" => InstagramStub.ok(search),
        "recent_media" => InstagramStub.ok(media)
      })

      Instagram.fetch(context(sources: [:hashtag]), State.new())

      assert InstagramStub.query_params("ig_hashtag_search")["user_id"] == @account_id
      assert InstagramStub.query_params("recent_media")["user_id"] == @account_id
    end

    test "caches the hashtag id, so the next poll skips the lookup", %{
      hashtag_search: search,
      hashtag_media: media
    } do
      # Ids are stable, and each lookup is a request against the allowance.
      InstagramStub.install(%{
        "ig_hashtag_search" => InstagramStub.ok(search),
        "recent_media" => InstagramStub.ok(media)
      })

      {:ok, _mentions, state} = Instagram.fetch(context(sources: [:hashtag]), State.new())
      assert State.hashtag_id(state, "realoffice") == "17843712345678901"

      InstagramStub.install(%{"recent_media" => InstagramStub.ok(media)})
      assert {:ok, _mentions, _state} = Instagram.fetch(context(sources: [:hashtag]), state)

      refute InstagramStub.requested?("ig_hashtag_search")
    end

    test "a hashtag Meta doesn't know is reported, not crashed on", %{hashtag_media: media} do
      InstagramStub.install(%{
        "ig_hashtag_search" => InstagramStub.ok(%{"data" => []}),
        "recent_media" => InstagramStub.ok(media)
      })

      {result, _log} =
        with_log(fn -> Instagram.fetch(context(sources: [:hashtag]), State.new()) end)

      assert {:error, {:unknown_hashtag, "realoffice"}, _state} = result
    end
  end

  describe "several sources together" do
    test "returns mentions from all of them", %{
      tags: tags,
      media: media,
      hashtag_search: search,
      hashtag_media: hashtag_media
    } do
      InstagramStub.install(%{
        "/tags" => InstagramStub.ok(tags),
        "/media" => InstagramStub.ok(media),
        "ig_hashtag_search" => InstagramStub.ok(search),
        "recent_media" => InstagramStub.ok(hashtag_media)
      })

      assert {:ok, mentions, _state} = Instagram.fetch(context(sources: all_sources()), State.new())

      # 2 tagged + 3 comments + 2 hashtag.
      assert length(mentions) == 7
    end

    test "de-duplicates a post that arrives from two sources", %{tags: tags} do
      # A post can be both tagged and carrying the hashtag.
      InstagramStub.install(%{
        "/tags" => InstagramStub.ok(tags),
        "ig_hashtag_search" => InstagramStub.ok(%{"data" => [%{"id" => "999"}]}),
        "recent_media" => InstagramStub.ok(tags)
      })

      {:ok, mentions, _state} = Instagram.fetch(context(sources: [:tags, :hashtag]), State.new())

      assert length(mentions) == 2
      assert length(Enum.uniq_by(mentions, & &1.id)) == 2
    end

    test "one source failing doesn't lose the others", %{tags: tags} do
      # The normal state of a Meta token: granted for one edge, not another.
      InstagramStub.install(%{
        "/tags" => InstagramStub.ok(tags),
        "/media" => InstagramStub.missing_permission()
      })

      {result, log} =
        with_log(fn -> Instagram.fetch(context(sources: [:tags, :comments]), State.new()) end)

      assert {:ok, mentions, _state} = result
      assert length(mentions) == 2
      assert log =~ "comments"
      assert log =~ "failed"
    end

    test "only a poll where everything failed is an error" do
      InstagramStub.install(%{
        "/tags" => InstagramStub.missing_permission("tags"),
        "/media" => InstagramStub.missing_permission("comments")
      })

      {result, _log} =
        with_log(fn -> Instagram.fetch(context(sources: [:tags, :comments]), State.new()) end)

      assert {:error, {:missing_permission, _message}, _state} = result
    end

    test "an empty edge is a success with nothing in it" do
      InstagramStub.install(%{"/tags" => InstagramStub.empty()})

      assert {:ok, [], _state} = Instagram.fetch(context(sources: [:tags]), State.new())
    end

    test "configuring no sources is an error, not a silent no-op" do
      InstagramStub.install(%{any: InstagramStub.empty()})

      assert {:error, :no_sources_enabled, _state} =
               Instagram.fetch(context(sources: []), State.new())
    end

    test "defaults to the two sources a plain account token can read", %{
      tags: tags,
      media: media
    } do
      InstagramStub.install(%{
        "/tags" => InstagramStub.ok(tags),
        "/media" => InstagramStub.ok(media)
      })

      assert {:ok, _mentions, _state} = Instagram.fetch(context(), State.new())

      assert InstagramStub.requested?("/tags")
      assert InstagramStub.requested?("/media")
      # Hashtag search spends a 30-per-7-days budget, so it stays opt-in.
      refute InstagramStub.requested?("ig_hashtag_search")
    end
  end

  describe "credential and permission errors" do
    test "an expired long-lived token is named as such" do
      # A 60-day clock that fails silently is worth calling out: it is the
      # commonest way an Instagram integration stops working.
      InstagramStub.install(%{any: InstagramStub.expired_token()})

      {result, _log} = with_log(fn -> Instagram.fetch(context(sources: [:tags]), State.new()) end)

      assert {:error, {:expired_access_token, message}, _state} = result
      assert message =~ "Session has expired"
    end

    test "a missing permission is told apart from a bad token" do
      InstagramStub.install(%{any: InstagramStub.missing_permission()})

      {result, _log} = with_log(fn -> Instagram.fetch(context(sources: [:tags]), State.new()) end)

      assert {:error, {:missing_permission, message}, _state} = result
      assert message =~ "does not have permission"
    end

    test "an unexpected status is surfaced with its code" do
      InstagramStub.install(%{any: Req.Response.new(status: 502, body: "")})

      {result, _log} = with_log(fn -> Instagram.fetch(context(sources: [:tags]), State.new()) end)

      assert {:error, {:http_error, 502}, _state} = result
    end

    test "a transport failure is surfaced rather than raised" do
      InstagramStub.install(%{any: %Req.TransportError{reason: :closed}})

      {result, _log} = with_log(fn -> Instagram.fetch(context(sources: [:tags]), State.new()) end)

      assert {:error, {:transport, _reason}, _state} = result
    end

    test "an error leaves the state usable for the next poll", %{tags: tags} do
      InstagramStub.install(%{"/tags" => [InstagramStub.expired_token(), InstagramStub.ok(tags)]})

      {{:error, _reason, state}, _log} =
        with_log(fn -> Instagram.fetch(context(sources: [:tags]), State.new()) end)

      assert {:ok, mentions, _state} = Instagram.fetch(context(sources: [:tags]), state)
      assert length(mentions) == 2
    end
  end

  describe "Meta's rate limiting" do
    test "records the usage percentage Meta reports", %{tags: tags} do
      InstagramStub.install(%{
        "/tags" => InstagramStub.ok(tags, InstagramStub.usage_headers(42))
      })

      {:ok, _mentions, state} = Instagram.fetch(context(sources: [:tags]), State.new())

      assert state.throttle.usage == 42
      assert Throttle.summary(state.throttle) =~ "42%"
    end

    test "backs off before Meta cuts us off, without calling the API", %{tags: tags} do
      # The percentage is reported after the call that caused it, so 100
      # is too late to react to.
      InstagramStub.install(%{
        "/tags" => InstagramStub.ok(tags, InstagramStub.usage_headers(95))
      })

      {:ok, _mentions, state} = Instagram.fetch(context(sources: [:tags]), State.new())

      InstagramStub.install(%{"/tags" => InstagramStub.ok(tags)})
      assert {:error, {:rate_limited, wait_ms}, _state} = Instagram.fetch(context(), state)
      assert wait_ms > 0
      assert InstagramStub.request_count() == 0
    end

    test "a throttling error waits as long as Meta asked" do
      InstagramStub.install(%{any: InstagramStub.throttled(12)})

      {{:error, reason, state}, _log} =
        with_log(fn -> Instagram.fetch(context(sources: [:tags]), State.new()) end)

      assert reason == :rate_limited_by_meta
      assert {:backoff, wait_ms} = Throttle.check(state.throttle)
      assert_in_delta wait_ms, :timer.minutes(12), :timer.seconds(5)
    end

    test "the worker is told to retry, so a limit is never fatal", %{tags: tags} do
      InstagramStub.install(%{
        "/tags" => InstagramStub.ok(tags, InstagramStub.usage_headers(99))
      })

      {:ok, _mentions, state} = Instagram.fetch(context(sources: [:tags]), State.new())

      InstagramStub.install(%{"/tags" => InstagramStub.ok(tags)})
      {:error, reason, _state} = Instagram.fetch(context(sources: [:tags]), state)

      assert SmmMonitor.Fetchers.Fetcher.retry_after(reason) > 0
    end
  end

  describe "ready?/1" do
    test "needs both a token and the account it is scoped to" do
      refute Instagram.ready?(context(credentials: []))
      refute Instagram.ready?(context(credentials: [access_token: "IGQ"]))
      refute Instagram.ready?(context(credentials: [business_account_id: @account_id]))
      refute Instagram.ready?(context(credentials: [access_token: " ", business_account_id: " "]))

      assert Instagram.ready?(context(credentials: @credentials))
    end

    test "accepts the older INSTAGRAM_USER_ID name for the account id" do
      assert Instagram.ready?(context(credentials: [access_token: "IGQ", user_id: @account_id]))
    end
  end

  # --- helpers --------------------------------------------------------------

  defp context(overrides \\ []) do
    {credentials, overrides} = Keyword.pop(overrides, :credentials, @credentials)

    %{
      platform: :instagram,
      keywords: ["realoffice"],
      credentials: credentials,
      opts: [req_options: InstagramStub.req_options()] ++ overrides,
      poll_count: 0,
      interval_ms: :timer.minutes(15)
    }
  end

  defp all_sources, do: [:tags, :comments, :hashtag]

  defp fixture(name), do: "test/fixtures/#{name}.json" |> File.read!() |> Jason.decode!()
end
