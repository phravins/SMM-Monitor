defmodule SmmMonitor.Fetchers.YouTube.ParseTest do
  @moduledoc """
  Parsing runs against a saved `search.list` payload
  (`test/fixtures/youtube_search.json`) rather than the live API, so it
  needs no key and spends no quota.

  The fixture carries the shape that actually matters here: `search.list`
  returns channels and playlists alongside videos, and only videos have a
  `videoId`.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.YouTube
  alias SmmMonitor.Mention

  setup_all do
    {:ok, body: "test/fixtures/youtube_search.json" |> File.read!() |> Jason.decode!()}
  end

  describe "parse/1 against the saved payload" do
    test "keeps only the videos", %{body: body} do
      # Five items in, three videos out: the channel and playlist results
      # have no videoId and can't be opened as a mention.
      assert length(YouTube.parse(body)) == 3
    end

    test "preserves the API's ordering", %{body: body} do
      assert ["youtube-dQw4w9WgXcQ", "youtube-9bZkp7q19f0", "youtube-kJQP7kiw5Fk"] =
               Enum.map(YouTube.parse(body), & &1.id)
    end

    test "maps a video onto mention attrs", %{body: body} do
      [video | _rest] = YouTube.parse(body)

      assert video.id == "youtube-dQw4w9WgXcQ"
      assert video.platform == :youtube
      # author is the channel, which is who "said" it.
      assert video.author == "Tool Teardown"
      assert String.starts_with?(video.text, "RealOffice review after 6 months")
      assert video.text =~ "We moved all our client reporting"
      assert video.url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
      assert video.timestamp == "2026-09-08T14:32:11Z"
    end

    test "uses the title alone when a video has no description", %{body: body} do
      video = Enum.find(YouTube.parse(body), &(&1.id == "youtube-9bZkp7q19f0"))

      assert video.text == "Why we cancelled RealOffice"
      refute video.text =~ "—"
    end

    test "truncates a long description", %{body: body} do
      video = Enum.find(YouTube.parse(body), &(&1.id == "youtube-kJQP7kiw5Fk"))

      assert String.length(video.text) <= 500
      assert String.starts_with?(video.text, "Social media scheduling tools compared")
    end

    test "every parsed video survives Mention.new/1", %{body: body} do
      mentions = Enum.map(YouTube.parse(body), &Mention.new/1)

      assert length(mentions) == 3
      assert Enum.all?(mentions, &match?(%Mention{platform: :youtube}, &1))
      assert Enum.all?(mentions, &match?(%DateTime{}, &1.timestamp))
    end

    test "ISO8601 timestamps are read as real datetimes", %{body: body} do
      [video | _rest] = body |> YouTube.parse() |> Enum.map(&Mention.new/1)

      assert DateTime.to_iso8601(video.timestamp) == "2026-09-08T14:32:11Z"
    end
  end

  describe "parse/1 edge cases" do
    test "falls back when a channel title is missing or blank" do
      assert [%{author: "unknown channel"}] =
               YouTube.parse(
                 items([%{"id" => %{"videoId" => "v"}, "snippet" => %{"title" => "t"}}])
               )

      assert [%{author: "unknown channel"}] =
               YouTube.parse(
                 items([
                   %{
                     "id" => %{"videoId" => "v"},
                     "snippet" => %{"title" => "t", "channelTitle" => ""}
                   }
                 ])
               )
    end

    test "drops items with no snippet" do
      assert [] = YouTube.parse(items([%{"id" => %{"videoId" => "v"}}]))
    end

    test "returns an empty list for error and unexpected shapes" do
      assert [] = YouTube.parse(%{"error" => %{"code" => 403}})
      assert [] = YouTube.parse(%{"items" => []})
      assert [] = YouTube.parse(%{})
      assert [] = YouTube.parse(nil)
      assert [] = YouTube.parse("not json")
    end
  end

  describe "build_query/1" do
    test "uses YouTube's OR syntax and quotes phrases" do
      assert YouTube.build_query(["realoffice"]) == "realoffice"
      assert YouTube.build_query(["realoffice", "real office"]) == ~s(realoffice | "real office")
    end

    test "ignores blank keywords" do
      assert YouTube.build_query(["realoffice", "", "  "]) == "realoffice"
    end

    test "handles an empty keyword list" do
      assert YouTube.build_query([]) == ""
      assert YouTube.build_query(nil) == ""
    end
  end

  defp items(list), do: %{"items" => list}
end
