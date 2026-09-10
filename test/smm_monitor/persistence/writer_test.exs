defmodule SmmMonitor.Persistence.WriterTest do
  @moduledoc """
  The write path: fire-and-forget, batched per message, and unable to
  disturb anything when it fails.
  """

  use SmmMonitor.DatabaseCase, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.Persistence.Writer

  setup do
    writer = start_supervised!({Writer, name: :"writer_#{System.unique_integer([:positive])}"})
    # The writer runs in its own process, so it needs explicit permission
    # to use this test's sandboxed connection.
    Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), writer)
    {:ok, writer: writer}
  end

  describe "store/2" do
    test "writes queued mentions", %{writer: writer} do
      Writer.store(writer, [mention(id: "a"), mention(id: "b")])
      Writer.flush(writer)

      assert Persistence.count() == 2
      assert %{written: 2, failures: 0} = Writer.stats(writer)
    end

    test "returns immediately without waiting for the disk", %{writer: writer} do
      # The point of the cast: the caller has already updated ETS, so it
      # must never block on a write.
      assert :ok = Writer.store(writer, [mention(id: "a")])
    end

    test "an empty list doesn't even send a message", %{writer: writer} do
      assert :ok = Writer.store(writer, [])
      Writer.flush(writer)

      assert %{written: 0} = Writer.stats(writer)
    end

    test "a whole batch goes in as one statement", %{writer: writer} do
      # Batching comes from the caller sending a poll's worth at once, so
      # there's no flush timer and no durability window.
      Writer.store(writer, for(index <- 1..50, do: mention(id: "m#{index}")))
      Writer.flush(writer)

      assert Persistence.count() == 50
    end

    test "re-sending a stored mention costs nothing", %{writer: writer} do
      Writer.store(writer, [mention(id: "dup")])
      Writer.flush(writer)
      Writer.store(writer, [mention(id: "dup")])
      Writer.flush(writer)

      assert Persistence.count() == 1
    end

    test "survives a failing write and keeps serving", %{writer: writer} do
      # A mention whose text is not a string makes the insert fail. The
      # writer must log it and carry on, not crash: history gets a gap,
      # the dashboard doesn't.
      log =
        capture_log(fn ->
          Writer.store(writer, [mention(id: "bad", text: {:not, "a string"})])
          Writer.flush(writer)
        end)

      assert log =~ "could not store"
      assert Process.alive?(writer)
      assert %{failures: 1} = Writer.stats(writer)

      # And a good write still lands afterwards.
      Writer.store(writer, [mention(id: "good")])
      Writer.flush(writer)
      assert Persistence.count() == 1
    end
  end
end
