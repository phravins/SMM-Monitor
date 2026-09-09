defmodule SmmMonitor.Fetchers.ParsingTest do
  @moduledoc """
  Each platform's `parse/1` maps its API payload onto mention attrs. These
  are pure functions over saved payload shapes, so they're testable without
  credentials or HTTP — including for the two platforms whose live fetch is
  still stubbed.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.{Instagram, Reddit, Twitter, YouTube}
  alias SmmMonitor.Mention

  describe "Reddit.parse/1" do
    test "maps a listing onto mention attrs" do
      payload = %{
        "data" => %{
          "children" => [
            %{
              "data" => %{
                "id" => "abc123",
                "author" => "someone",
                "title" => "RealOffice review",
                "selftext" => "been using it for a month",
                "permalink" => "/r/saas/comments/abc123/",
                "created_utc" => 1_700_000_000.0
              }
            }
          ]
        }
      }

      assert [attrs] = Reddit.parse(payload)
      assert attrs.id == "reddit-abc123"
      assert attrs.platform == :reddit
      assert attrs.author == "u/someone"
      assert attrs.text == "RealOffice review — been using it for a month"
      assert attrs.url == "https://reddit.com/r/saas/comments/abc123/"

      # Round-trips into the shared struct.
      assert %Mention{platform: :reddit} = Mention.new(attrs)
    end

    test "omits an empty selftext" do
      payload = listing(%{"title" => "Just a title", "selftext" => ""})
      assert [%{text: "Just a title"}] = Reddit.parse(payload)
    end

    test "returns an empty list for an unexpected shape" do
      assert [] = Reddit.parse(%{"error" => "invalid_grant"})
      assert [] = Reddit.parse(%{})
    end

    defp listing(overrides) do
      post =
        Map.merge(
          %{
            "id" => "x",
            "author" => "a",
            "title" => "t",
            "selftext" => "",
            "permalink" => "/p",
            "created_utc" => 1_700_000_000
          },
          overrides
        )

      %{"data" => %{"children" => [%{"data" => post}]}}
    end
  end

  describe "YouTube.parse/1" do
    test "maps a search.list response onto mention attrs" do
      payload = %{
        "items" => [
          %{
            "id" => %{"videoId" => "vid123"},
            "snippet" => %{
              "channelTitle" => "Some Channel",
              "title" => "Reviewing RealOffice",
              "description" => "a walkthrough",
              "publishedAt" => "2024-03-01T12:00:00Z"
            }
          }
        ]
      }

      assert [attrs] = YouTube.parse(payload)
      assert attrs.id == "youtube-vid123"
      assert attrs.author == "Some Channel"
      assert attrs.text == "Reviewing RealOffice — a walkthrough"
      assert attrs.url == "https://www.youtube.com/watch?v=vid123"
      assert %Mention{} = Mention.new(attrs)
    end

    test "skips items that aren't videos" do
      # search.list returns channels and playlists too; those have no videoId.
      payload = %{
        "items" => [
          %{"id" => %{"channelId" => "chan1"}, "snippet" => %{"title" => "A channel"}},
          %{
            "id" => %{"videoId" => "vid1"},
            "snippet" => %{"title" => "A video", "channelTitle" => "c"}
          }
        ]
      }

      assert [%{id: "youtube-vid1"}] = YouTube.parse(payload)
    end

    test "returns an empty list for an unexpected shape" do
      assert [] = YouTube.parse(%{"error" => %{"code" => 403}})
    end
  end

  describe "Twitter.parse/1 (stubbed platform)" do
    test "resolves author usernames from the expansion" do
      payload = %{
        "data" => [
          %{
            "id" => "1",
            "author_id" => "u1",
            "text" => "hi",
            "created_at" => "2024-03-01T12:00:00Z"
          }
        ],
        "includes" => %{"users" => [%{"id" => "u1", "username" => "someone"}]}
      }

      assert [attrs] = Twitter.parse(payload)
      assert attrs.author == "@someone"
      assert attrs.id == "twitter-1"
    end

    test "falls back when the author expansion is missing" do
      payload = %{"data" => [%{"id" => "1", "author_id" => "u9", "text" => "hi"}]}
      assert [%{author: "@unknown"}] = Twitter.parse(payload)
    end
  end

  describe "Instagram.parse/1 (stubbed platform)" do
    test "maps a /tags payload onto mention attrs" do
      payload = %{
        "data" => [
          %{
            "id" => "ig1",
            "username" => "studio",
            "caption" => "loving this",
            "permalink" => "https://instagram.com/p/1",
            "timestamp" => "2024-03-01T12:00:00Z"
          }
        ]
      }

      assert [%{id: "instagram-ig1", author: "@studio"}] = Instagram.parse(payload)
    end
  end

  describe "stubbed fetchers" do
    test "report why they can't run live" do
      # Deliberate: these need paid or reviewed API access. The worker sees
      # ready?/1 == false and serves fixtures instead.
      context = context_for(:twitter)

      refute Twitter.ready?(context)
      refute Instagram.ready?(context)
      assert {:error, :requires_paid_api_access} = Twitter.fetch(context)
      assert {:error, :requires_business_account_and_app_review} = Instagram.fetch(context)
    end

    test "still produce mock mentions" do
      assert {:ok, mentions} = Twitter.mock_fetch(context_for(:twitter))
      assert length(mentions) > 0
      assert Enum.all?(mentions, &(&1.platform == :twitter))
      assert Enum.all?(mentions, & &1.mock)
    end
  end

  describe "readiness of implemented fetchers" do
    test "Reddit needs a client id and secret" do
      refute Reddit.ready?(context_for(:reddit, credentials: []))
      refute Reddit.ready?(context_for(:reddit, credentials: [client_id: "id"]))
      assert Reddit.ready?(context_for(:reddit, credentials: [client_id: "id", client_secret: "s"]))
    end

    test "YouTube needs an API key" do
      refute YouTube.ready?(context_for(:youtube, credentials: []))
      assert YouTube.ready?(context_for(:youtube, credentials: [api_key: "k"]))
    end
  end

  defp context_for(platform, overrides \\ []) do
    %{
      platform: platform,
      keywords: ["realoffice"],
      credentials: Keyword.get(overrides, :credentials, []),
      opts: [],
      poll_count: Keyword.get(overrides, :poll_count, 0)
    }
  end
end
