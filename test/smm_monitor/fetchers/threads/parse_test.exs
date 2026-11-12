defmodule SmmMonitor.Fetchers.Threads.ParseTest do
  @moduledoc """
  Mapping Threads posts onto mention attrs: pure, against saved responses.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Threads
  alias SmmMonitor.ThreadsStub

  doctest SmmMonitor.Fetchers.Threads

  test "maps a recorded search response" do
    body = "test/fixtures/threads_search.json" |> File.read!() |> Jason.decode!()

    assert [first, _second, third] = Threads.parse_posts(body)

    assert first == %{
             id: "threads-18050206876707110",
             platform: :threads,
             author: "@maya.makes",
             text: "Switched the whole studio over to Acme this week and the onboarding was smooth",
             url: "https://www.threads.com/@maya.makes/post/DBa1Zx2yQ3k",
             timestamp: "2026-11-12T09:41:12+0000"
           }

    assert third.url == "https://www.threads.net/@thebrandroom/post/DBZz9kLm1Pq"
  end

  test "drops a post whose id isn't numeric" do
    body = %{
      "data" => [
        ThreadsStub.post(%{"id" => "../../me"}),
        ThreadsStub.post(%{"id" => 123}),
        Map.delete(ThreadsStub.post(), "id"),
        ThreadsStub.post()
      ]
    }

    assert [%{id: "threads-18000000000000001"}] = Threads.parse_posts(body)
  end

  test "a link anywhere but Threads, or not https, becomes no link" do
    for link <- [
          "http://www.threads.com/@a/post/1",
          "https://evil.example/@a/post/1",
          "https://user@threads.com/@a/post/1",
          "javascript:alert(1)",
          nil,
          42
        ] do
      assert [%{url: nil}] =
               Threads.parse_posts(%{"data" => [ThreadsStub.post(%{"permalink" => link})]})
    end
  end

  test "an unexpected or missing username becomes @unknown" do
    for name <- ["has space", "<script>", String.duplicate("a", 31), nil, 7] do
      assert [%{author: "@unknown"}] =
               Threads.parse_posts(%{"data" => [ThreadsStub.post(%{"username" => name})]})
    end
  end

  test "a post with no text gets empty text" do
    assert [%{text: ""}] =
             Threads.parse_posts(%{"data" => [Map.delete(ThreadsStub.post(), "text")]})
  end

  test "a post with no timestamp keeps nil" do
    assert [%{timestamp: nil}] =
             Threads.parse_posts(%{"data" => [Map.delete(ThreadsStub.post(), "timestamp")]})
  end

  test "anything but a list of posts is no posts" do
    assert Threads.parse_posts(%{"data" => "nope"}) == []
    assert Threads.parse_posts(%{}) == []
    assert Threads.parse_posts("<html>") == []
    assert Threads.parse_posts(nil) == []
  end
end
