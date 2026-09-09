defmodule SmmMonitor.MentionTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Mention

  describe "new/1" do
    test "builds from a map with atom keys" do
      mention = Mention.new(%{id: "a", platform: :reddit, author: "u/x", text: "hi"})

      assert mention.id == "a"
      assert mention.platform == :reddit
      assert mention.sentiment == :neutral
    end

    test "accepts string keys, as returned by JSON decoding" do
      mention = Mention.new(%{"id" => "a", "platform" => "reddit", "text" => "hi"})

      assert mention.id == "a"
      assert mention.platform == :reddit
    end

    test "accepts a keyword list" do
      assert %Mention{id: "a"} = Mention.new(id: "a", platform: :reddit)
    end

    test "defaults the author and text" do
      mention = Mention.new(%{id: "a", platform: :reddit})

      assert mention.author == "unknown"
      assert mention.text == ""
    end

    test "generates an id when none is given" do
      assert %Mention{id: id} = Mention.new(%{platform: :reddit})
      assert is_binary(id) and id != ""
    end
  end

  describe "timestamp parsing" do
    test "passes a DateTime through" do
      now = DateTime.utc_now()
      assert %Mention{timestamp: ^now} = Mention.new(%{platform: :reddit, timestamp: now})
    end

    test "reads unix seconds, as Reddit returns" do
      mention = Mention.new(%{platform: :reddit, timestamp: 1_700_000_000})
      assert DateTime.to_unix(mention.timestamp) == 1_700_000_000
    end

    test "reads unix milliseconds" do
      mention = Mention.new(%{platform: :reddit, timestamp: 1_700_000_000_000})
      assert DateTime.to_unix(mention.timestamp) == 1_700_000_000
    end

    test "reads ISO8601, as YouTube returns" do
      mention = Mention.new(%{platform: :youtube, timestamp: "2024-03-01T12:00:00Z"})
      assert DateTime.to_iso8601(mention.timestamp) == "2024-03-01T12:00:00Z"
    end

    test "falls back to now on an unparseable timestamp" do
      # A malformed timestamp from one post must not fail a whole poll.
      before = DateTime.utc_now()
      mention = Mention.new(%{platform: :reddit, timestamp: "not a date"})

      assert DateTime.compare(mention.timestamp, before) in [:gt, :eq]
    end

    test "defaults to now when absent" do
      assert %DateTime{} = Mention.new(%{platform: :reddit}).timestamp
    end
  end

  describe "time_ago/2" do
    test "renders each unit" do
      now = ~U[2024-03-01 12:00:00Z]

      assert time_ago_at(now, 30) == "30s ago"
      assert time_ago_at(now, 60 * 5) == "5m ago"
      assert time_ago_at(now, 3_600 * 3) == "3h ago"
      assert time_ago_at(now, 86_400 * 2) == "2d ago"
    end

    test "handles a timestamp in the future" do
      # Platform clocks can run ahead of ours; don't render "-3s ago".
      now = ~U[2024-03-01 12:00:00Z]
      assert time_ago_at(now, -60) == "just now"
    end
  end

  describe "epoch_ms/1" do
    test "returns the millisecond epoch" do
      mention = Mention.new(%{platform: :reddit, timestamp: ~U[2024-03-01 12:00:00Z]})
      assert Mention.epoch_ms(mention) == 1_709_294_400_000
    end
  end

  defp time_ago_at(now, seconds_ago) do
    %{platform: :reddit, timestamp: DateTime.add(now, -seconds_ago, :second)}
    |> Mention.new()
    |> Mention.time_ago(now)
  end
end
