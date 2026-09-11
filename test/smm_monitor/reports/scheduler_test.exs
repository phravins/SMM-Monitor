defmodule SmmMonitor.Reports.SchedulerTest do
  @moduledoc """
  The unprompted weekly run.

  The calendar arithmetic is tested exhaustively because it decides
  whether a client gets their Monday report at all, and the failure mode
  is silence — nobody notices a report that was never written.
  """

  # Not async: starts a scheduler that reads the shared client list.
  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.Reports.{Scheduler, Writer}

  doctest Scheduler

  setup do
    dir = Path.join(System.tmp_dir!(), "smm-weekly-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    Application.put_env(:smm_monitor, :reports_dir, dir)
    on_exit(fn -> Application.delete_env(:smm_monitor, :reports_dir) end)

    %{dir: dir}
  end

  describe "due?/2" do
    test "is true in the configured hour of the configured day" do
      assert Scheduler.due?(~U[2026-09-14 07:00:00Z], day: 1, hour: 7)
      assert Scheduler.due?(~U[2026-09-14 07:59:00Z], day: 1, hour: 7)
    end

    test "is false the rest of that day" do
      refute Scheduler.due?(~U[2026-09-14 06:59:00Z], day: 1, hour: 7)
      refute Scheduler.due?(~U[2026-09-14 08:00:00Z], day: 1, hour: 7)
    end

    test "is false on every other day of the week" do
      # Monday 14 Sep 2026 through Sunday 20 Sep.
      for day <- 15..20 do
        at = DateTime.new!(Date.new!(2026, 9, day), ~T[07:30:00], "Etc/UTC")

        refute Scheduler.due?(at, day: 1, hour: 7), "expected 2026-09-#{day} not to be due"
      end
    end

    test "follows a different day and hour when configured" do
      # Nobody else's week starts when ours does.
      assert Scheduler.due?(~U[2026-09-18 17:15:00Z], day: 5, hour: 17)
      refute Scheduler.due?(~U[2026-09-14 17:15:00Z], day: 5, hour: 17)
    end

    test "fires within an hour-wide window, matching the hourly check" do
      # The check runs hourly, so the slot has to be an hour wide or a
      # run could fall between two checks and be missed entirely.
      due = for m <- [0, 17, 31, 59], do: Scheduler.due?(minute(m), day: 1, hour: 7)

      assert Enum.all?(due)
    end
  end

  describe "run_now/1" do
    test "writes a file per active client", %{dir: dir} do
      set_clients(["Acme Corp", "Globex"])
      {:ok, scheduler} = start_scheduler()

      {:ok, paths} = Scheduler.run_now(scheduler)

      assert length(paths) >= 2
      assert Enum.all?(paths, &File.exists?/1)
      assert Enum.any?(paths, &String.contains?(&1, "acme-corp"))
      assert Enum.any?(paths, &String.contains?(&1, "globex"))
      assert Path.dirname(hd(paths)) == dir
    end

    test "always writes the data, even where the PDF toolchain is missing", %{dir: dir} do
      # A server without Python should still get its weekly numbers
      # rather than nothing at all.
      set_clients(["Acme Corp"])
      {:ok, scheduler} = start_scheduler()

      {:ok, _paths} = Scheduler.run_now(scheduler)

      assert [_csv] = Path.wildcard(Path.join(dir, "*.csv"))
    end

    test "skips a paused client" do
      set_clients([
        build_client("Acme Corp"),
        build_client("Dormant Ltd", active: false)
      ])

      {:ok, scheduler} = start_scheduler()

      {:ok, paths} = Scheduler.run_now(scheduler)

      refute Enum.any?(paths, &String.contains?(&1, "dormant"))
    end

    test "covers the last seven days", %{dir: dir} do
      set_clients(["Acme Corp"])
      {:ok, scheduler} = start_scheduler()

      {:ok, _paths} = Scheduler.run_now(scheduler)

      today = Date.utc_today()
      expected = "#{Date.add(today, -6)}_#{today}"

      assert [file] = Path.wildcard(Path.join(dir, "*.csv"))
      assert String.contains?(file, expected)
    end

    test "counts its runs, so the dashboard can show when one last happened" do
      set_clients(["Acme Corp"])
      {:ok, scheduler} = start_scheduler()

      assert Scheduler.stats(scheduler).runs == 0

      {:ok, _paths} = Scheduler.run_now(scheduler)
      stats = Scheduler.stats(scheduler)

      assert stats.runs == 1
      assert stats.written > 0
      assert stats.last_run_at != nil
      assert stats.directory == Writer.dir()
    end
  end

  describe "enabled?/0" do
    test "is off unless it has been switched on" do
      # A process that writes files unprompted should be something you
      # asked for.
      refute Scheduler.enabled?()
    end
  end

  defp start_scheduler do
    start_supervised(
      {Scheduler, name: :"scheduler-#{System.unique_integer([:positive])}", schedule?: false}
    )
  end

  defp minute(m), do: DateTime.new!(~D[2026-09-14], Time.new!(7, m, 0), "Etc/UTC")
end
