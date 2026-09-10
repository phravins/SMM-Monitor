defmodule SmmMonitor.Persistence.RetentionTest do
  @moduledoc """
  The retention job. Pruning is driven through an injected cutoff, so
  nothing here waits real days.
  """

  use SmmMonitor.DatabaseCase, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.Persistence.Retention

  setup do
    original = Application.get_env(:smm_monitor, :db_retention_days)
    on_exit(fn -> restore(:db_retention_days, original) end)
    :ok
  end

  describe "prune_now/1" do
    test "deletes what's outside the window and keeps what isn't" do
      Application.put_env(:smm_monitor, :db_retention_days, 30)
      Persistence.store([mention(id: "old", days_ago: 60), mention(id: "fresh", days_ago: 2)])

      retention = start_retention()

      assert {:ok, 1} = capture_log_value(fn -> Retention.prune_now(retention) end)
      assert ["fresh"] = Enum.map(Persistence.recent(:reddit, 10), & &1.id)
    end

    test "honours a changed retention window" do
      Application.put_env(:smm_monitor, :db_retention_days, 7)
      Persistence.store([mention(id: "a", days_ago: 10), mention(id: "b", days_ago: 3)])

      retention = start_retention()
      capture_log(fn -> Retention.prune_now(retention) end)

      assert ["b"] = Enum.map(Persistence.recent(:reddit, 10), & &1.id)
    end

    test "is a no-op when nothing is old enough" do
      Application.put_env(:smm_monitor, :db_retention_days, 30)
      Persistence.store([mention(id: "a", days_ago: 1)])

      retention = start_retention()

      assert {:ok, 0} = Retention.prune_now(retention)
      assert Persistence.count() == 1
    end
  end

  describe "stats/1" do
    test "reports what the job has done and the window it uses" do
      Application.put_env(:smm_monitor, :db_retention_days, 14)
      Persistence.store([mention(id: "old", days_ago: 30)])

      retention = start_retention()
      capture_log(fn -> Retention.prune_now(retention) end)

      assert %{deleted: 1, runs: 1, retention_days: 14, last_run_at: %DateTime{}} =
               Retention.stats(retention)
    end
  end

  describe "scheduling" do
    test "does not prune on its own when scheduling is off" do
      # Every other test here drives prune_now/1 directly; this proves the
      # timer is what would otherwise fire it.
      Persistence.store([mention(id: "old", days_ago: 90)])
      start_retention()
      Process.sleep(50)

      assert Persistence.count() == 1
    end

    test "schedules its first pass shortly after boot, not a day later" do
      # A long-stopped instance should tidy up when it comes back rather
      # than carrying stale rows until its first anniversary.
      Application.put_env(:smm_monitor, :db_retention_days, 30)
      Persistence.store([mention(id: "old", days_ago: 90)])

      retention =
        start_supervised!(
          {Retention, name: unique_name(), initial_delay_ms: 10, interval_ms: 60_000},
          id: :scheduled_retention
        )

      Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), retention)

      capture_log(fn -> assert eventually(fn -> Persistence.count() == 0 end) end)
    end
  end

  describe "cutoff/2" do
    test "is what makes pruning testable without waiting days" do
      assert Retention.cutoff(30, ~U[2026-06-30 12:00:00Z]) == ~U[2026-05-31 12:00:00Z]
    end
  end

  defp start_retention do
    retention =
      start_supervised!({Retention, name: unique_name(), schedule?: false}, id: :retention)

    Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), retention)
    retention
  end

  defp unique_name, do: :"retention_#{System.unique_integer([:positive])}"

  defp capture_log_value(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:value, fun.()}) end)

    receive do
      {:value, value} -> value
    after
      0 -> nil
    end
  end

  defp restore(key, nil), do: Application.delete_env(:smm_monitor, key)
  defp restore(key, value), do: Application.put_env(:smm_monitor, key, value)

  defp eventually(check, attempts \\ 50)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
