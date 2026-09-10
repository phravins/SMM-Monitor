defmodule SmmMonitor.Fetchers.Instagram.ParseTest do
  @moduledoc """
  Parsing saved Graph API responses for each of the three sources. No
  network, no token, no Business account.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Instagram
  alias SmmMonitor.Mention

  setup_all do
    {:ok,
     tags: fixture("instagram_tags"),
     media: fixture("instagram_media_comments"),
     hashtag_media: fixture("instagram_hashtag_recent_media")}
  end

  describe "parse_media/1 — posts that @-tag the account" do
    test "maps every tagged post", %{tags: tags} do
      assert length(Instagram.parse_media(tags)) == 2
    end

    test "maps the fields the mention struct needs", %{tags: tags} do
      [first | _rest] = Instagram.parse_media(tags)

      assert first.id == "instagram-17925384756102938"
      assert first.platform == :instagram
      assert first.author == "@maya.makes"
      assert first.text =~ "scheduling everything through @realoffice"
      assert first.url == "https://www.instagram.com/p/CyR4nXqLm2A/"
      assert first.timestamp == "2026-09-09T15:41:07+0000"
    end

    test "Meta's +0000 offset survives the trip into a DateTime", %{tags: tags} do
      # Meta writes the offset without a colon, unlike everyone else here.
      [first | _rest] = tags |> Instagram.parse_media() |> Enum.map(&Mention.new/1)

      assert first.timestamp == ~U[2026-09-09 15:41:07Z]
    end

    test "produces attrs the mention struct accepts", %{tags: tags} do
      mentions = tags |> Instagram.parse_media() |> Enum.map(&Mention.new/1)

      assert Enum.all?(mentions, &match?(%Mention{platform: :instagram}, &1))
      assert Enum.all?(mentions, &match?(%DateTime{}, &1.timestamp))
    end

    test "a post with no caption becomes an empty mention, not nil" do
      body = %{"data" => [%{"id" => "1", "username" => "someone"}]}

      assert [%{text: "", author: "@someone"}] = Instagram.parse_media(body)
    end

    test "a post with no id is dropped rather than stored undedupable" do
      body = %{"data" => [%{"caption" => "no id"}, %{"id" => "1", "caption" => "fine"}]}

      assert [%{id: "instagram-1"}] = Instagram.parse_media(body)
    end

    test "survives payloads that aren't the documented shape" do
      assert Instagram.parse_media(%{}) == []
      assert Instagram.parse_media(%{"data" => "not a list"}) == []
      assert Instagram.parse_media(nil) == []
    end
  end

  describe "parse_comments/1 — comments on the account's own posts" do
    test "pulls comments out of every post that has them", %{media: media} do
      # Three posts in the fixture, one of which has no comments at all.
      assert length(Instagram.parse_comments(media)) == 3
    end

    test "maps the comment, not the post it sits under", %{media: media} do
      [first | _rest] = Instagram.parse_comments(media)

      assert first.id == "instagram-comment-17900000000000101"
      assert first.author == "@ops_owen"
      assert first.text == "this is genuinely useful, thank you"
      assert first.timestamp == "2026-09-08T09:42:13+0000"
    end

    test "links a comment to its parent post, since it has no link of its own",
         %{media: media} do
      assert Enum.all?(
               Instagram.parse_comments(media),
               &String.starts_with?(&1.url, "https://www.instagram.com/p/")
             )

      [first | _rest] = Instagram.parse_comments(media)
      assert first.url == "https://www.instagram.com/p/CyQ9xLpAbcD/"
    end

    test "comment ids can't collide with media ids", %{media: media} do
      # Both are Instagram-issued numbers from different id spaces.
      assert Enum.all?(
               Instagram.parse_comments(media),
               &String.starts_with?(&1.id, "instagram-comment-")
             )
    end

    test "a post with no comments contributes nothing", %{media: media} do
      texts = media |> Instagram.parse_comments() |> Enum.map(& &1.text)

      refute Enum.any?(texts, &(&1 =~ "A quiet post"))
    end

    test "survives posts with an empty or missing comments edge" do
      body = %{
        "data" => [
          %{"id" => "1", "permalink" => "https://x", "comments" => %{"data" => []}},
          %{"id" => "2", "permalink" => "https://y"}
        ]
      }

      assert Instagram.parse_comments(body) == []
    end

    test "survives payloads that aren't the documented shape" do
      assert Instagram.parse_comments(%{}) == []
      assert Instagram.parse_comments(nil) == []
    end
  end

  describe "parse_hashtag_media/2 — public posts carrying a hashtag" do
    test "maps every post", %{hashtag_media: hashtag_media} do
      assert length(Instagram.parse_hashtag_media(hashtag_media, "realoffice")) == 2
    end

    test "attributes posts to the hashtag, because Meta returns no author",
         %{hashtag_media: hashtag_media} do
      # Hashtag search deliberately returns no personally identifying
      # information. "@unknown" would imply we looked and failed.
      mentions = Instagram.parse_hashtag_media(hashtag_media, "realoffice")

      assert Enum.all?(mentions, &(&1.author == "#realoffice"))
    end

    test "keeps caption, link and time", %{hashtag_media: hashtag_media} do
      [first | _rest] = Instagram.parse_hashtag_media(hashtag_media, "realoffice")

      assert first.id == "instagram-17925999888777666"
      assert first.text =~ "swapped three tools for one"
      assert first.url == "https://www.instagram.com/p/CyS7pQrMnOp/"
      assert first.timestamp == "2026-09-09T17:22:00+0000"
    end

    test "produces attrs the mention struct accepts", %{hashtag_media: hashtag_media} do
      mentions =
        hashtag_media
        |> Instagram.parse_hashtag_media("realoffice")
        |> Enum.map(&Mention.new/1)

      assert Enum.all?(mentions, &match?(%Mention{platform: :instagram}, &1))
    end

    test "survives payloads that aren't the documented shape" do
      assert Instagram.parse_hashtag_media(%{}, "realoffice") == []
      assert Instagram.parse_hashtag_media(nil, "realoffice") == []
    end
  end

  describe "hashtags/2" do
    test "derives tags from the brand keywords, stripping spaces" do
      # "real office" is #realoffice on Instagram — hashtags have no spaces.
      assert Instagram.hashtags(["realoffice", "real office"], []) == ["realoffice"]
    end

    test "an explicit list wins, with or without the leading #" do
      assert Instagram.hashtags(["ignored"], hashtags: ["#realofficeapp", "realofficehq"]) ==
               ["realofficeapp", "realofficehq"]
    end

    test "strips punctuation a hashtag can't contain" do
      assert Instagram.hashtags(["real-office!"], []) == ["realoffice"]
    end

    test "lowercases, since hashtag search is case insensitive" do
      assert Instagram.hashtags(["RealOffice"], []) == ["realoffice"]
    end

    test "drops blanks rather than searching for nothing" do
      assert Instagram.hashtags(["realoffice", "  ", "#"], []) == ["realoffice"]
    end
  end

  defp fixture(name), do: "test/fixtures/#{name}.json" |> File.read!() |> Jason.decode!()
end
