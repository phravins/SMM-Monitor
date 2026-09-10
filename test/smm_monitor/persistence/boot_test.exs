defmodule SmmMonitor.Persistence.BootTest do
  @moduledoc """
  What happens on startup: history is restored into ETS, and a database
  that doesn't exist yet is created and migrated with no manual step.
  """

  use SmmMonitor.DatabaseCase, async: false

  alias SmmMonitor.Persistence.Migrator
  alias SmmMonitor.Processing.{Processor, Store}

  describe "restoring history into ETS" do
    setup do
      # Only the name: the processor creates the table itself in init/1,
      # and creating it here first would collide.
      {:ok, table: :"boot_test_#{System.unique_integer([:positive])}"}
    end

    test "puts stored mentions back so the dashboard isn't empty", %{table: table} do
      Persistence.store([
        mention(id: "stored1", platform: :reddit, minutes_ago: 5),
        mention(id: "stored2", platform: :youtube, minutes_ago: 10)
      ])

      processor = start_processor(table)

      assert Processor.restored(processor) == 2
      assert Store.count(table) == 2
      assert ["stored1"] = Enum.map(Store.recent(table, :reddit), & &1.id)
    end

    test "restores at most the configured limit per platform", %{table: table} do
      Persistence.store(for index <- 1..20, do: mention(id: "r#{index}", minutes_ago: index))

      processor = start_processor(table, history_limit: 5)

      assert Processor.restored(processor) == 5
      # The newest five, not an arbitrary five.
      assert ["r1", "r2", "r3", "r4", "r5"] = Enum.map(Store.recent(table, :reddit), & &1.id)
    end

    test "restored mentions keep their stored sentiment", %{table: table} do
      # Not recomputed on the way back in: the score is history.
      Persistence.store([mention(id: "s", sentiment: :positive, sentiment_score: 3)])

      start_processor(table)

      assert [%{sentiment: :positive, sentiment_score: 3}] = Store.recent(table, :reddit)
    end

    test "an empty database restores nothing and is not an error", %{table: table} do
      processor = start_processor(table)

      assert Processor.restored(processor) == 0
      assert Store.count(table) == 0
    end

    test "can be turned off", %{table: table} do
      Persistence.store([mention(id: "stored")])

      processor = start_processor(table, load_history?: false)

      assert Processor.restored(processor) == 0
      assert Store.count(table) == 0
    end

    test "restored mentions don't get written back to the database", %{table: table} do
      # They came *from* there; re-storing them would be pure churn.
      Persistence.store([mention(id: "stored")])
      before = Persistence.count()

      start_processor(table)

      assert Persistence.count() == before
    end

    test "a restored mention that gets re-fetched doesn't duplicate", %{table: table} do
      # The case that matters after a restart: the first poll re-sees a
      # post we already restored from disk.
      Persistence.store([mention(id: "dup", platform: :reddit)])

      processor = start_processor(table)
      assert Processor.restored(processor) == 1

      assert {:ok, %{inserted: 0, duplicates: 1}} =
               Processor.ingest(processor, [
                 %{id: "dup", platform: :reddit, author: "u/x", text: "same post"}
               ])

      assert Store.count(table) == 1
    end
  end

  describe "a fresh database" do
    setup do
      # These migrate a second (and third) repo in the same VM, so Ecto
      # loads the migration file again and Elixir warns about redefining
      # the module. Expected here, and only here.
      previous = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)
      on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, previous || false) end)
      :ok
    end

    test "is created and migrated with no manual step" do
      path = Path.join(System.tmp_dir!(), "smm_fresh_#{System.unique_integer([:positive])}.db")
      refute File.exists?(path)

      on_exit(fn -> Enum.each(Path.wildcard("#{path}*"), &File.rm/1) end)

      # A repo of its own, pointed at a path that doesn't exist yet.
      {:ok, repo} = start_isolated_repo(path)

      assert {:ok, versions} = Migrator.migrate(repo)
      assert length(versions) >= 1
      assert File.exists?(path)

      # And it's immediately usable.
      assert {:ok, 1} = Persistence.store([mention(id: "first")], repo: repo)
      assert [%{id: "first"}] = Persistence.recent(:reddit, 10, repo: repo)
    end

    test "migrating twice is a no-op" do
      path = Path.join(System.tmp_dir!(), "smm_twice_#{System.unique_integer([:positive])}.db")
      on_exit(fn -> Enum.each(Path.wildcard("#{path}*"), &File.rm/1) end)

      {:ok, repo} = start_isolated_repo(path)

      assert {:ok, [_version | _rest]} = Migrator.migrate(repo)
      # Idempotent, which is what makes running it on every boot safe.
      assert {:ok, []} = Migrator.migrate(repo)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp start_processor(table, opts \\ []) do
    {history_limit, opts} = Keyword.pop(opts, :history_limit)

    if history_limit do
      original = Application.get_env(:smm_monitor, :history_limit)
      Application.put_env(:smm_monitor, :history_limit, history_limit)
      on_exit(fn -> Application.put_env(:smm_monitor, :history_limit, original) end)
    end

    name = :"processor_#{System.unique_integer([:positive])}"

    processor =
      start_supervised!(
        {Processor,
         [
           name: name,
           table: table,
           persist?: false,
           load_history?: Keyword.get(opts, :load_history?, true)
         ]},
        id: name
      )

    Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), processor)
    # The load runs in handle_continue, so wait for it to have happened.
    _ = Processor.restored(processor)
    processor
  end

  # A second repo module, so a genuinely fresh file can be migrated without
  # disturbing the suite's sandboxed one.
  defp start_isolated_repo(path) do
    repo = Module.concat(__MODULE__, :"Repo#{System.unique_integer([:positive])}")

    Code.eval_quoted(
      quote do
        defmodule unquote(repo) do
          use Ecto.Repo, otp_app: :smm_monitor, adapter: Ecto.Adapters.SQLite3
        end
      end
    )

    Application.put_env(:smm_monitor, repo, database: path, pool_size: 1)
    pid = start_supervised!({repo, []}, id: repo)
    on_exit(fn -> if Process.alive?(pid), do: :ok end)

    {:ok, repo}
  end
end
