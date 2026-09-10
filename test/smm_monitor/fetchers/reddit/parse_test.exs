defmodule SmmMonitor.Fetchers.Reddit.ParseTest do
  @moduledoc """
  Parsing tests run against a saved Reddit search payload
  (`test/fixtures/reddit_search.json`) rather than the live API, so they
  need no credentials and no network.

  The fixture mirrors the documented `Listing` / `t3` response shape,
  including the fields that trip mapping up in practice: an empty
  `selftext`, a `[deleted]` author, a link post whose `url` points off
  Reddit, and a body long enough to need truncating.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Reddit
  alias SmmMonitor.Mention

  @fixture "test/fixtures/reddit_search.json"

  setup_all do
    {:ok, listing: @fixture |> File.read!() |> Jason.decode!()}
  end

  describe "parse/1 against the saved payload" do
    test "maps every post in the listing", %{listing: listing} do
      assert length(Reddit.parse(listing)) == 5
    end

    test "preserves the listing's order", %{listing: listing} do
      assert [
               "reddit-1a2b3c",
               "reddit-1a2b3d",
               "reddit-1a2b3e",
               "reddit-1a2b3f",
               "reddit-1a2b3g"
             ] = Enum.map(Reddit.parse(listing), & &1.id)
    end

    test "maps a self post onto mention attrs", %{listing: listing} do
      [post | _rest] = Reddit.parse(listing)

      assert post.id == "reddit-1a2b3c"
      assert post.platform == :reddit
      assert post.author == "u/agency_amy"
      assert post.text =~ "RealOffice six months in"
      # Title and body are joined, title first.
      assert post.text =~ "We moved our client reporting"
      assert String.starts_with?(post.text, "RealOffice six months in")

      assert post.url ==
               "https://reddit.com/r/smallbusiness/comments/1a2b3c/realoffice_six_months_in_worth_it_for_a_small/"

      assert post.timestamp == 1_760_227_200
    end

    test "uses the title alone when there is no selftext", %{listing: listing} do
      post = Enum.find(Reddit.parse(listing), &(&1.id == "reddit-1a2b3d"))

      assert post.text ==
               "Anyone else seeing real office scheduling tools converge on the same feature set?"

      # No trailing separator from the empty body.
      refute post.text =~ "—"
    end

    test "prefixes authors with u/, including [deleted]", %{listing: listing} do
      authors = Enum.map(Reddit.parse(listing), & &1.author)

      assert "u/agency_amy" in authors
      assert "u/[deleted]" in authors
      assert Enum.all?(authors, &String.starts_with?(&1, "u/"))
    end

    test "always links back to Reddit, even for a link post", %{listing: listing} do
      # The off-site `url` is where the post points; the permalink is where
      # the mention lives, and that's what an operator needs to open.
      post = Enum.find(Reddit.parse(listing), &(&1.id == "reddit-1a2b3g"))

      assert post.url ==
               "https://reddit.com/r/smallbusiness/comments/1a2b3g/posted_a_walkthrough_of_our_realoffice_setup/"
    end

    test "truncates a long body", %{listing: listing} do
      post = Enum.find(Reddit.parse(listing), &(&1.id == "reddit-1a2b3f"))

      assert String.length(post.text) <= 500
      assert String.starts_with?(post.text, "Tool comparison writeup")
    end

    test "every parsed post survives Mention.new/1", %{listing: listing} do
      # The whole point of the mapping: the processing layer and TUI never
      # see a Reddit-shaped map.
      mentions = Enum.map(Reddit.parse(listing), &Mention.new/1)

      assert length(mentions) == 5
      assert Enum.all?(mentions, &match?(%Mention{platform: :reddit}, &1))
      assert Enum.all?(mentions, &(%DateTime{} = &1.timestamp))
    end

    test "timestamps land in the right era", %{listing: listing} do
      # created_utc is unix *seconds* and arrives as a float; reading it as
      # milliseconds would put every mention in 1970.
      [post | _rest] = listing |> Reddit.parse() |> Enum.map(&Mention.new/1)

      assert post.timestamp.year == 2025
    end
  end

  describe "parse/1 edge cases" do
    test "drops posts with no id or no author" do
      listing = %{
        "data" => %{
          "children" => [
            %{"data" => %{"id" => "ok1", "author" => "someone", "title" => "fine"}},
            %{"data" => %{"author" => "someone", "title" => "no id"}},
            %{"data" => %{"id" => "no_author", "title" => "no author"}}
          ]
        }
      }

      assert [%{id: "reddit-ok1"}] = Reddit.parse(listing)
    end

    test "falls back to the post url when there is no permalink" do
      listing =
        children([%{"id" => "x", "author" => "a", "title" => "t", "url" => "https://e.test/p"}])

      assert [%{url: "https://e.test/p"}] = Reddit.parse(listing)
    end

    test "tolerates a missing timestamp" do
      listing = children([%{"id" => "x", "author" => "a", "title" => "t"}])

      assert [%{timestamp: nil}] = Reddit.parse(listing)
      # Mention.new/1 then defaults it to now rather than blowing up.
      assert %Mention{} = listing |> Reddit.parse() |> hd() |> Mention.new()
    end

    test "returns an empty list for error and unexpected shapes" do
      assert [] = Reddit.parse(%{"error" => 403, "message" => "Forbidden"})
      assert [] = Reddit.parse(%{"data" => %{"children" => []}})
      assert [] = Reddit.parse(%{})
      assert [] = Reddit.parse("not json at all")
      assert [] = Reddit.parse(nil)
    end
  end

  describe "build_query/2" do
    test "quotes multi-word phrases and ORs the terms" do
      assert Reddit.build_query(["realoffice"]) == "realoffice"
      assert Reddit.build_query(["realoffice", "real office"]) == ~s(realoffice OR "real office")
    end

    test "ignores blank keywords" do
      assert Reddit.build_query(["realoffice", "", "  "]) == "realoffice"
    end

    test "an explicit :query setting wins" do
      assert Reddit.build_query(["ignored"], query: "title:realoffice") == "title:realoffice"
    end
  end

  describe "search_path/1" do
    test "combines subreddits into a single multireddit request" do
      # One request per poll regardless of how many subreddits are watched,
      # which is what keeps us clear of the 60/minute budget.
      assert Reddit.search_path(["marketing", "smallbusiness"]) ==
               "/r/marketing+smallbusiness/search"
    end

    test "searches site-wide when no subreddits are configured" do
      assert Reddit.search_path([]) == "/search"
      assert Reddit.search_path(nil) == "/search"
    end

    test "tolerates r/ prefixes, blanks and whitespace" do
      assert Reddit.search_path(["r/marketing", " smallbusiness ", ""]) ==
               "/r/marketing+smallbusiness/search"
    end
  end

  defp children(posts) do
    %{"data" => %{"children" => Enum.map(posts, &%{"data" => &1})}}
  end
end
