defmodule SmmMonitor.Fetchers.SupervisionTest do
  @moduledoc """
  Checks the property the whole fetching layer is shaped around: one
  platform failing must not disturb the others, or the stored mentions.

  Tests run with `start_fetchers: false` (see config/test.exs), so these
  start their own supervisors rather than fighting the application's.
  """

  use ExUnit.Case, async: false

  alias SmmMonitor.Fetchers.{PlatformSupervisor, Reddit, Worker, YouTube}
  alias SmmMonitor.Monitor

  setup do
    Monitor.reset()

    # A long interval: these tests are about supervision, not polling. The
    # startup poll still runs, which is what populates the store below.
    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {PlatformSupervisor, platform: :reddit, module: Reddit, interval_ms: 60_000},
          {PlatformSupervisor, platform: :youtube, module: YouTube, interval_ms: 60_000}
        ],
        strategy: :one_for_one
      )

    on_exit(fn ->
      # `Process.exit/2` rather than `Supervisor.stop/1` so a supervisor that
      # already died doesn't fail the test in teardown.
      if Process.alive?(supervisor), do: Process.exit(supervisor, :normal)
    end)

    {:ok, supervisor: supervisor}
  end

  test "each platform gets its own worker" do
    assert is_pid(Process.whereis(Worker.name(:reddit)))
    assert is_pid(Process.whereis(Worker.name(:youtube)))
    refute Process.whereis(Worker.name(:reddit)) == Process.whereis(Worker.name(:youtube))
  end

  test "a crashing worker is restarted without disturbing the other platform" do
    reddit = Process.whereis(Worker.name(:reddit))
    youtube = Process.whereis(Worker.name(:youtube))

    ref = Process.monitor(reddit)
    Process.exit(reddit, :kill)
    assert_receive {:DOWN, ^ref, :process, ^reddit, :killed}

    # The Reddit worker comes back...
    assert eventually(fn ->
             pid = Process.whereis(Worker.name(:reddit))
             is_pid(pid) and pid != reddit
           end)

    # ...and YouTube never noticed.
    assert Process.whereis(Worker.name(:youtube)) == youtube
    assert Process.alive?(youtube)
  end

  test "a crashing worker does not take the stored mentions with it" do
    assert eventually(fn -> Monitor.stats(:all).count > 0 end)
    count_before = Monitor.stats(:all).count

    Process.exit(Process.whereis(Worker.name(:reddit)), :kill)

    # The processor is a sibling of the fetcher tree, not a child, so a
    # worker crash can't reach the ETS table.
    assert Monitor.stats(:all).count >= count_before
  end

  test "workers report their status for the dashboard" do
    # Wait for the startup poll to land, not just for the process to exist.
    assert eventually(fn -> match?(%{poll_count: count} when count > 0, Worker.status(:reddit)) end)

    status = Worker.status(:reddit)

    assert status.platform == :reddit
    assert status.display_name == "Reddit"
    # No credentials configured in tests, so the worker serves fixtures.
    assert status.mode == :mock
    assert status.inserted > 0
    assert is_nil(status.last_error)
  end

  test "status/1 reports :unavailable for a platform that isn't running" do
    # The dashboard has to render a restarting platform, not crash with it.
    assert Worker.status(:mastodon) == :unavailable
  end

  # Restarts and the startup poll are asynchronous; poll briefly rather than
  # sleeping a fixed amount.
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
