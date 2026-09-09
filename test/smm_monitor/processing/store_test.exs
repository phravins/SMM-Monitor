defmodule SmmMonitor.Processing.StoreTest do
  use ExUnit.Case, async: true

  import SmmMonitor.Factory

  alias SmmMonitor.Processing.Store

  setup context do
    # Each test gets its own named table so these can run concurrently and
    # independently of the application's processor.
    table = Store.new(:"store_test_#{:erlang.phash2(context.test)}")
    {:ok, table: table}
  end

  describe "insert/2" do
    test "stores a mention", %{table: table} do
      assert :inserted = Store.insert(table, mention(id: "a"))
      assert Store.size(table) == 1
    end

    test "rejects a mention already stored", %{table: table} do
      # Overlapping polls re-see the same posts; without this the counts
      # would climb every 30 seconds on an unchanged feed.
      assert :inserted = Store.insert(table, mention(id: "a", platform: :reddit))
      assert :duplicate = Store.insert(table, mention(id: "a", platform: :reddit))
      assert Store.size(table) == 1
    end

    test "treats the same id on different platforms as distinct", %{table: table} do
      assert :inserted = Store.insert(table, mention(id: "123", platform: :reddit))
      assert :inserted = Store.insert(table, mention(id: "123", platform: :youtube))
      assert Store.size(table) == 2
    end

    test "de-duplicates even when the timestamp differs", %{table: table} do
      assert :inserted = Store.insert(table, mention(id: "a", minutes_ago: 10))
      assert :duplicate = Store.insert(table, mention(id: "a", minutes_ago: 5))
      assert Store.size(table) == 1
    end
  end

  describe "recent/3" do
    setup %{table: table} do
      Store.insert(table, mention(id: "old", minutes_ago: 90, platform: :reddit))
      Store.insert(table, mention(id: "mid", minutes_ago: 30, platform: :youtube))
      Store.insert(table, mention(id: "new", minutes_ago: 1, platform: :reddit))
      :ok
    end

    test "returns mentions newest first", %{table: table} do
      assert ["new", "mid", "old"] = Enum.map(Store.recent(table), & &1.id)
    end

    test "filters by platform", %{table: table} do
      assert ["new", "old"] = Enum.map(Store.recent(table, :reddit), & &1.id)
    end

    test "honours the limit", %{table: table} do
      assert ["new"] = Enum.map(Store.recent(table, :all, limit: 1), & &1.id)
    end

    test "applies the limit after the platform filter", %{table: table} do
      # Not "the newest one, if it happens to be reddit" — the newest reddit one.
      assert ["new"] = Enum.map(Store.recent(table, :reddit, limit: 1), & &1.id)
    end

    test "excludes mentions older than :since", %{table: table} do
      since = ms_ago(60)
      assert ["new", "mid"] = Enum.map(Store.recent(table, :all, since: since), & &1.id)
    end

    test "returns an empty list for a platform with no mentions", %{table: table} do
      assert [] = Store.recent(table, :instagram)
    end
  end

  describe "count/3" do
    setup %{table: table} do
      Store.insert(table, mention(id: "a", platform: :reddit, minutes_ago: 5))
      Store.insert(table, mention(id: "b", platform: :reddit, minutes_ago: 120))
      Store.insert(table, mention(id: "c", platform: :youtube, minutes_ago: 5))
      :ok
    end

    test "counts everything by default", %{table: table} do
      assert Store.count(table) == 3
    end

    test "counts by platform", %{table: table} do
      assert Store.count(table, :reddit) == 2
      assert Store.count(table, :youtube) == 1
      assert Store.count(table, :twitter) == 0
    end

    test "counts within a window", %{table: table} do
      assert Store.count(table, :all, ms_ago(60)) == 2
      assert Store.count(table, :reddit, ms_ago(60)) == 1
    end
  end

  describe "prune/3" do
    test "drops mentions older than the cutoff", %{table: table} do
      Store.insert(table, mention(id: "old", minutes_ago: 200))
      Store.insert(table, mention(id: "new", minutes_ago: 1))

      assert 1 = Store.prune(table, ms_ago(60), 1_000)
      assert ["new"] = Enum.map(Store.recent(table), & &1.id)
    end

    test "trims the oldest rows when over capacity", %{table: table} do
      for index <- 1..10 do
        Store.insert(table, mention(id: "m#{index}", minutes_ago: 11 - index))
      end

      # Capacity bites even though nothing is old enough to expire.
      assert 7 = Store.prune(table, ms_ago(600), 3)
      assert ["m10", "m9", "m8"] = Enum.map(Store.recent(table), & &1.id)
    end

    test "is a no-op when within both bounds", %{table: table} do
      Store.insert(table, mention(id: "a", minutes_ago: 1))
      assert 0 = Store.prune(table, ms_ago(60), 10)
      assert Store.size(table) == 1
    end
  end

  describe "clear/1" do
    test "removes everything", %{table: table} do
      Store.insert(table, mention(id: "a"))
      assert :ok = Store.clear(table)
      assert Store.size(table) == 0
    end
  end

  defp ms_ago(minutes) do
    DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.to_unix(:millisecond)
  end
end
