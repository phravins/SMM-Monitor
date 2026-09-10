defmodule SmmMonitor.PersistenceTest do
  @moduledoc """
  The durable log: storing, reading back the most recent N, and pruning.

  Retention is tested with an injected cutoff rather than by waiting real
  days — `Retention.cutoff/2` takes the current time as an argument for
  exactly this reason.
  """

  use SmmMonitor.DatabaseCase, async: true

  alias SmmMonitor.Mention
  alias SmmMonitor.Persistence.Retention

  describe "store/2" do
    test "writes mentions and reports how many landed" do
      assert {:ok, 2} = Persistence.store([mention(id: "a"), mention(id: "b")])
      assert Persistence.count() == 2
    end

    test "an empty batch is a no-op that touches no connection" do
      assert {:ok, 0} = Persistence.store([])
    end

    test "ignores a mention it already has" do
      # This is what makes re-storing after a restart free rather than a
      # source of duplicates.
      assert {:ok, 1} = Persistence.store([mention(id: "same", platform: :reddit)])
      assert {:ok, 0} = Persistence.store([mention(id: "same", platform: :reddit)])
      assert Persistence.count() == 1
    end

    test "treats the same id on different platforms as distinct" do
      # Ids are only unique within a platform.
      assert {:ok, 2} =
               Persistence.store([
                 mention(id: "123", platform: :reddit),
                 mention(id: "123", platform: :youtube)
               ])

      assert Persistence.count() == 2
    end

    test "stores every field the dashboard needs" do
      Persistence.store([
        mention(
          id: "full",
          platform: :youtube,
          author: "Some Channel",
          text: "a full mention",
          url: "https://example.test/v",
          sentiment: :positive,
          sentiment_score: 3
        )
      ])

      assert [stored] = Persistence.recent(:youtube, 10)
      assert stored.id == "full"
      assert stored.platform == :youtube
      assert stored.author == "Some Channel"
      assert stored.text == "a full mention"
      assert stored.url == "https://example.test/v"
    end

    test "keeps the sentiment the processing layer scored" do
      # Stored as scored, never recomputed: editing the word lists later
      # must not silently rewrite history.
      Persistence.store([mention(id: "s", sentiment: :negative, sentiment_score: -4)])

      assert [%Mention{sentiment: :negative, sentiment_score: -4}] = Persistence.recent(:reddit, 10)
    end

    test "handles timestamps that aren't microsecond precision" do
      # ISO8601 payloads routinely carry milliseconds or whole seconds,
      # and :utc_datetime_usec rejects both unless they're re-stamped.
      assert {:ok, 2} =
               Persistence.store([
                 mention(id: "ms", timestamp: ~U[2026-09-10 01:23:47.510Z]),
                 mention(id: "sec", timestamp: ~U[2026-09-10 01:23:47Z])
               ])

      assert Persistence.count() == 2
    end

    test "round-trips through Mention, so the TUI sees no difference" do
      Persistence.store([mention(id: "rt", platform: :twitter, sentiment: :positive)])

      assert [%Mention{} = restored] = Persistence.recent(:twitter, 10)
      assert restored.platform == :twitter
      assert %DateTime{} = restored.timestamp
    end
  end

  describe "recent/3" do
    setup do
      Persistence.store([
        mention(id: "old", platform: :reddit, minutes_ago: 300),
        mention(id: "mid", platform: :reddit, minutes_ago: 100),
        mention(id: "new", platform: :reddit, minutes_ago: 1),
        mention(id: "yt", platform: :youtube, minutes_ago: 5)
      ])

      :ok
    end

    test "returns newest first" do
      assert ["new", "mid", "old"] = Enum.map(Persistence.recent(:reddit, 10), & &1.id)
    end

    test "honours the limit, keeping the newest" do
      assert ["new", "mid"] = Enum.map(Persistence.recent(:reddit, 2), & &1.id)
    end

    test "filters by platform" do
      assert ["yt"] = Enum.map(Persistence.recent(:youtube, 10), & &1.id)
    end

    test "is empty for a platform with nothing stored" do
      assert [] = Persistence.recent(:instagram, 10)
    end
  end

  describe "recent_by_platform/3" do
    test "applies the limit per platform, not across all of them" do
      # Otherwise a chatty platform would crowd the others out of the
      # restored view after a restart.
      Persistence.store(
        for index <- 1..10 do
          mention(id: "r#{index}", platform: :reddit, minutes_ago: index)
        end
      )

      Persistence.store([mention(id: "y1", platform: :youtube, minutes_ago: 1)])

      restored = Persistence.recent_by_platform([:reddit, :youtube], 3)

      assert length(restored) == 4
      assert Enum.count(restored, &(&1.platform == :reddit)) == 3
      assert Enum.count(restored, &(&1.platform == :youtube)) == 1
    end

    test "skips platforms with nothing stored" do
      assert [] = Persistence.recent_by_platform([:reddit, :youtube], 10)
    end
  end

  describe "prune/2" do
    test "deletes mentions published before the cutoff" do
      Persistence.store([
        mention(id: "ancient", days_ago: 90),
        mention(id: "old", days_ago: 45),
        mention(id: "recent", days_ago: 1)
      ])

      assert {:ok, 2} = Persistence.prune(Retention.cutoff(30, DateTime.utc_now()))
      assert ["recent"] = Enum.map(Persistence.recent(:reddit, 10), & &1.id)
    end

    test "keeps everything inside the window" do
      Persistence.store([mention(id: "a", days_ago: 5), mention(id: "b", days_ago: 29)])

      assert {:ok, 0} = Persistence.prune(Retention.cutoff(30, DateTime.utc_now()))
      assert Persistence.count() == 2
    end

    test "keys on when the mention was published, not when it was stored" do
      # Backfilling a month of history must not earn it another 30 days.
      Persistence.store([mention(id: "backfilled", days_ago: 60)])

      assert {:ok, 1} = Persistence.prune(Retention.cutoff(30, DateTime.utc_now()))
      assert Persistence.count() == 0
    end

    test "a different window prunes differently" do
      Persistence.store([mention(id: "a", days_ago: 10), mention(id: "b", days_ago: 2)])

      assert {:ok, 1} = Persistence.prune(Retention.cutoff(7, DateTime.utc_now()))
      assert ["b"] = Enum.map(Persistence.recent(:reddit, 10), & &1.id)
    end
  end

  describe "count/1 and count/2" do
    test "count the whole table and one platform" do
      Persistence.store([
        mention(id: "a", platform: :reddit),
        mention(id: "b", platform: :reddit),
        mention(id: "c", platform: :youtube)
      ])

      assert Persistence.count() == 3
      assert Persistence.count(:reddit, []) == 2
      assert Persistence.count(:twitter, []) == 0
    end
  end

  describe "Retention.cutoff/2" do
    test "subtracts whole days from the given time" do
      assert Retention.cutoff(30, ~U[2026-03-31 12:00:00Z]) == ~U[2026-03-01 12:00:00Z]
      assert Retention.cutoff(1, ~U[2026-03-31 12:00:00Z]) == ~U[2026-03-30 12:00:00Z]
    end
  end
end
