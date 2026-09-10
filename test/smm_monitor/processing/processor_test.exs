defmodule SmmMonitor.Processing.ProcessorTest do
  # Shares the application's processor, so not async.
  use ExUnit.Case, async: false

  import SmmMonitor.Factory

  alias SmmMonitor.Processing.{Processor, Store}

  setup do
    Processor.reset()
    :ok
  end

  describe "ingest/2" do
    test "stores mentions and reports what it did" do
      assert {:ok, %{inserted: 2, duplicates: 0}} =
               Processor.ingest([attrs(id: "a"), attrs(id: "b")])
    end

    test "scores sentiment on the way in" do
      # Scoring happens once, on write, so reads stay pure lookups.
      Processor.ingest([attrs(id: "a", text: "absolutely fantastic support")])

      assert [mention] = Store.recent(Processor.table(), :all)
      assert mention.sentiment == :positive
      assert mention.sentiment_value > 0
      assert mention.sentiment_score > 0
    end

    test "counts repeat mentions as duplicates without storing them" do
      Processor.ingest([attrs(id: "dup")])

      assert {:ok, %{inserted: 0, duplicates: 1}} = Processor.ingest([attrs(id: "dup")])
      assert Store.size(Processor.table()) == 1
    end

    test "accepts Mention structs as well as attrs maps" do
      assert {:ok, %{inserted: 1}} = Processor.ingest([mention(id: "struct")])
    end

    test "handles an empty batch" do
      assert {:ok, %{inserted: 0, duplicates: 0}} = Processor.ingest([])
    end
  end

  describe "totals/1" do
    test "counts lifetime ingests per platform" do
      Processor.ingest([
        attrs(id: "a", platform: :reddit),
        attrs(id: "b", platform: :reddit),
        attrs(id: "c", platform: :youtube)
      ])

      assert %{reddit: 2, youtube: 1} = Processor.totals()
    end

    test "does not count duplicates" do
      Processor.ingest([attrs(id: "a", platform: :reddit)])
      Processor.ingest([attrs(id: "a", platform: :reddit)])

      assert %{reddit: 1} = Processor.totals()
    end

    test "survives pruning" do
      # Totals are the lifetime record; the table is only the recent window.
      Processor.ingest([attrs(id: "ancient", platform: :reddit, minutes_ago: 60 * 24 * 365)])
      Processor.prune_now()

      assert %{reddit: 1} = Processor.totals()
      assert Store.size(Processor.table()) == 0
    end
  end

  describe "prune_now/1" do
    test "drops mentions past the retention window" do
      Processor.ingest([
        attrs(id: "ancient", minutes_ago: 60 * 24 * 365),
        attrs(id: "fresh", minutes_ago: 1)
      ])

      assert {:ok, 1} = Processor.prune_now()
      assert ["fresh"] = Enum.map(Store.recent(Processor.table(), :all), & &1.id)
    end
  end

  describe "resilience" do
    test "ignores unexpected messages rather than crashing" do
      # The processor owns the ETS table; a stray message must never be able
      # to take it (and every stored mention) down.
      pid = Process.whereis(Processor)
      send(pid, :something_unexpected)

      assert {:ok, %{inserted: 1}} = Processor.ingest([attrs(id: "still-alive")])
      assert Process.alive?(pid)
    end
  end
end
