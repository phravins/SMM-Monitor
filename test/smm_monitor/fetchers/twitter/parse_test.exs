defmodule SmmMonitor.Fetchers.Twitter.ParseTest do
  @moduledoc """
  Parsing a saved v2 recent-search response. No network, no token.

  The fixture is a real-shaped payload including the awkward parts:
  a tweet whose author is missing from the expansion, and a next_token
  we deliberately ignore.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Twitter
  alias SmmMonitor.Mention

  setup_all do
    {:ok, body: "test/fixtures/twitter_search_recent.json" |> File.read!() |> Jason.decode!()}
  end

  describe "parse/1" do
    test "maps every tweet in the payload", %{body: body} do
      assert length(Twitter.parse(body)) == 3
    end

    test "maps the fields the mention struct needs", %{body: body} do
      [first | _rest] = Twitter.parse(body)

      assert first.id == "twitter-1834729501234567890"
      assert first.platform == :twitter
      assert first.author == "@maya_builds"
      assert first.text =~ "content calendar over to realoffice"
      assert first.url == "https://x.com/maya_builds/status/1834729501234567890"
      assert first.timestamp == "2026-09-09T14:22:41.000Z"
    end

    test "joins author handles from the includes.users expansion", %{body: body} do
      authors = body |> Twitter.parse() |> Enum.map(& &1.author)

      assert "@maya_builds" in authors
      assert "@ops_owen" in authors
    end

    test "keeps a tweet whose author is missing from the expansion", %{body: body} do
      # Deleted and protected accounts drop out of expansions. The text is
      # the mention; losing it over a missing handle would hide a real post.
      orphan = Enum.find(Twitter.parse(body), &(&1.id == "twitter-1834688999888777666"))

      assert orphan.author == "@unknown"
      assert orphan.url == "https://x.com/i/web/status/1834688999888777666"
      assert orphan.text =~ "canva"
    end

    test "produces attrs the mention struct accepts", %{body: body} do
      mentions = Enum.map(Twitter.parse(body), &Mention.new/1)

      assert Enum.all?(mentions, &match?(%Mention{platform: :twitter}, &1))
      assert Enum.all?(mentions, &match?(%DateTime{}, &1.timestamp))
      assert Enum.all?(mentions, &(&1.id != nil))
    end

    test "ids are prefixed, so they can't collide with another platform", %{body: body} do
      assert Enum.all?(Twitter.parse(body), &String.starts_with?(&1.id, "twitter-"))
    end

    test "an empty result set parses to no mentions" do
      # A search with no matches has no `data` key at all.
      assert Twitter.parse(%{"meta" => %{"result_count" => 0}}) == []
    end

    test "a tweet with no id is dropped rather than stored unlinkable" do
      body = %{"data" => [%{"text" => "no id here"}, %{"id" => "1", "text" => "fine"}]}

      assert [%{id: "twitter-1"}] = Twitter.parse(body)
    end

    test "survives payloads that aren't the documented shape" do
      assert Twitter.parse(%{}) == []
      assert Twitter.parse(%{"data" => "not a list"}) == []
      assert Twitter.parse(nil) == []
      assert Twitter.parse("") == []
    end

    test "a tweet with no text becomes an empty mention rather than nil" do
      assert [%{text: ""}] = Twitter.parse(%{"data" => [%{"id" => "1"}]})
    end
  end

  describe "posts_returned/1" do
    test "counts the posts the monthly cap will be charged for", %{body: body} do
      # The cap counts posts delivered, not the page size requested.
      assert Twitter.posts_returned(body) == 3
    end

    test "an empty result set costs nothing" do
      assert Twitter.posts_returned(%{"meta" => %{"result_count" => 0}}) == 0
      assert Twitter.posts_returned(%{}) == 0
      assert Twitter.posts_returned(nil) == 0
    end
  end

  describe "build_query/2" do
    test "ORs the shared brand terms and quotes phrases" do
      assert Twitter.build_query(["realoffice"]) == "(realoffice) -is:retweet"

      assert Twitter.build_query(["realoffice", "real office"]) ==
               ~s|(realoffice OR "real office") -is:retweet|
    end

    test "always excludes retweets" do
      assert Twitter.build_query(["realoffice"]) =~ "-is:retweet"
    end

    test "ignores blank keywords" do
      assert Twitter.build_query(["realoffice", "  ", ""]) == "(realoffice) -is:retweet"
    end

    test "an explicit query wins, for X's own search syntax" do
      assert Twitter.build_query(["ignored"], query: "from:realoffice has:links") ==
               "from:realoffice has:links"
    end
  end
end
