defmodule SmmMonitor.TUI.ModelTest do
  @moduledoc """
  Tests the dashboard's state transitions. The rendering itself isn't
  tested — that's the renderer's job and needs a terminal — but everything
  the renderer *reads* is exercised here.
  """

  use ExUnit.Case, async: false

  import SmmMonitor.Factory

  alias SmmMonitor.Monitor
  alias SmmMonitor.TUI.Model

  doctest SmmMonitor.TUI.Model, only: [mask_webhook: 2, freshness: 2]

  setup do
    Monitor.reset()
    :ok
  end

  describe "new/1" do
    test "starts on the 'all' tab with every configured platform" do
      model = Model.new()

      assert model.tab == :all
      # The two screens that aren't a mention list sit at the end, after
      # the platform tabs.
      assert model.tabs == [:all | SmmMonitor.platforms()] ++ [:trends, :config]
      assert model.offset == 0
    end

    test "sizes the table from the terminal height" do
      tall = Model.new(%{window: %{height: 60}})
      short = Model.new(%{window: %{height: 20}})

      assert tall.rows > short.rows
    end

    test "never sizes the table below a usable minimum" do
      assert Model.new(%{window: %{height: 5}}).rows >= 3
    end
  end

  describe "tab selection" do
    setup do
      Monitor.record_many([
        attrs(id: "r1", platform: :reddit, text: "excellent"),
        attrs(id: "r2", platform: :reddit, text: "terrible"),
        attrs(id: "y1", platform: :youtube, text: "excellent")
      ])

      {:ok, model: Model.new()}
    end

    test "t/i/r/y select their platform and a selects all", %{model: model} do
      assert Model.handle_key(model, {:char, ?r}).tab == :reddit
      assert Model.handle_key(model, {:char, ?y}).tab == :youtube
      assert Model.handle_key(model, {:char, ?t}).tab == :twitter
      assert Model.handle_key(model, {:char, ?i}).tab == :instagram

      assert model
             |> Model.handle_key({:char, ?r})
             |> Model.handle_key({:char, ?a})
             |> Map.fetch!(:tab) ==
               :all
    end

    test "switching tabs re-reads mentions and stats for that platform", %{model: model} do
      reddit = Model.handle_key(model, {:char, ?r})

      assert reddit.stats.count == 2
      assert Enum.map(reddit.mentions, & &1.id) |> Enum.sort() == ["r1", "r2"]
    end

    test "the breakdown covers every platform regardless of the active tab", %{model: model} do
      reddit = Model.handle_key(model, {:char, ?r})

      assert reddit.breakdown[:reddit] == 2
      assert reddit.breakdown[:youtube] == 1
    end

    test "an unknown key is a no-op", %{model: model} do
      assert Model.handle_key(model, {:char, ?z}) == model
      assert Model.handle_key(model, {:key, :f1}) == model
    end

    test "selecting an unconfigured platform is a no-op", %{model: model} do
      assert Model.select_tab(model, :tiktok) == model
    end

    test "switching tabs resets the scroll" do
      Monitor.record_many(for index <- 1..40, do: attrs(id: "m#{index}", platform: :reddit))

      model = Model.new(%{window: %{height: 20}}) |> Model.scroll(5)
      assert model.offset == 5

      assert Model.handle_key(model, {:char, ?r}).offset == 0
    end
  end

  describe "scrolling" do
    setup do
      Monitor.record_many(for index <- 1..40, do: attrs(id: "m#{index}", minutes_ago: index))
      {:ok, model: Model.new(%{window: %{height: 20}})}
    end

    test "j and the down arrow move down a row", %{model: model} do
      assert Model.handle_key(model, {:char, ?j}).offset == 1
      assert Model.handle_key(model, {:key, :arrow_down}).offset == 1
    end

    test "k and the up arrow move back up", %{model: model} do
      scrolled = Model.scroll(model, 3)

      assert Model.handle_key(scrolled, {:char, ?k}).offset == 2
      assert Model.handle_key(scrolled, {:key, :arrow_up}).offset == 2
    end

    test "page keys move a screen at a time", %{model: model} do
      assert Model.handle_key(model, {:key, :page_down}).offset == model.rows
    end

    test "never scrolls above the top", %{model: model} do
      assert Model.scroll(model, -50).offset == 0
    end

    test "never scrolls past the last screen of mentions", %{model: model} do
      scrolled = Model.scroll(model, 1_000)

      assert scrolled.offset == length(scrolled.mentions) - scrolled.rows
      assert length(Model.visible_mentions(scrolled)) == scrolled.rows
    end

    test "g and home jump back to the top", %{model: model} do
      scrolled = Model.scroll(model, 5)

      assert Model.handle_key(scrolled, {:char, ?g}).offset == 0
      assert Model.handle_key(scrolled, {:key, :home}).offset == 0
    end

    test "visible_mentions/1 returns the on-screen slice", %{model: model} do
      visible = model |> Model.scroll(2) |> Model.visible_mentions()

      assert length(visible) == model.rows
      assert hd(visible).id == "m3"
    end

    test "a refresh that shrinks the list pulls the offset back into range", %{model: model} do
      scrolled = Model.scroll(model, 20)
      Monitor.reset()
      Monitor.record_many(for index <- 1..3, do: attrs(id: "s#{index}"))

      # Otherwise the table would render blank after a prune.
      assert Model.refresh(scrolled).offset == 0
    end

    test "scrollable?/1 reflects whether the list overflows the table" do
      Monitor.reset()
      Monitor.record_many(for index <- 1..3, do: attrs(id: "few#{index}"))
      refute Model.new(%{window: %{height: 40}}) |> Model.scrollable?()

      Monitor.record_many(for index <- 1..100, do: attrs(id: "many#{index}"))
      assert Model.new(%{window: %{height: 20}}) |> Model.scrollable?()
    end
  end

  describe "sentiment_percentages/1" do
    test "are zero when there is nothing to show" do
      assert %{positive: 0, neutral: 0, negative: 0} =
               Model.sentiment_percentages(Model.new())
    end

    test "sum to 100 even when the division doesn't come out evenly" do
      # Three mentions is 33.3% each; the largest bucket takes the remainder.
      Monitor.record_many([
        attrs(id: "a", text: "excellent"),
        attrs(id: "b", text: "excellent"),
        attrs(id: "c", text: "terrible")
      ])

      percentages = Model.sentiment_percentages(Model.new())

      assert percentages.positive + percentages.neutral + percentages.negative == 100
      assert percentages.positive == 67
    end
  end

  describe "sentiment_bar/2" do
    test "is empty with no mentions" do
      assert {0, 0, 0} = Model.sentiment_bar(Model.new(), 30)
    end

    test "splits the width proportionally and uses all of it" do
      Monitor.record_many([
        attrs(id: "a", text: "excellent"),
        attrs(id: "b", text: "terrible"),
        attrs(id: "c", text: "a plain update"),
        attrs(id: "d", text: "a plain update again")
      ])

      {positive, neutral, negative} = Model.sentiment_bar(Model.new(), 40)

      assert positive + neutral + negative == 40
      assert neutral == 20
    end
  end

  describe "sentiment_gauge/2" do
    test "sits at the centre with no mentions" do
      assert {12, 0, 0, 12} = Model.sentiment_gauge(Model.new(), 25)
    end

    test "fills to the right of centre when the mean is positive" do
      Monitor.record_many([
        attrs(id: "a", text: "excellent, brilliant work"),
        attrs(id: "b", text: "fantastic support")
      ])

      {left_pad, negative, positive, right_pad} = Model.sentiment_gauge(Model.new(), 25)

      assert negative == 0
      assert positive > 0
      assert left_pad == 12
      assert positive + right_pad == 12
    end

    test "fills to the left of centre when the mean is negative" do
      Monitor.record_many([
        attrs(id: "a", text: "terrible, the worst"),
        attrs(id: "b", text: "broken and useless")
      ])

      {left_pad, negative, positive, right_pad} = Model.sentiment_gauge(Model.new(), 25)

      assert positive == 0
      assert negative > 0
      assert right_pad == 12
      assert left_pad + negative == 12
    end

    test "never rounds a real opinion down to an empty bar" do
      # A faint mean is still a mean; showing nothing would read as "no
      # feeling either way", which is a different claim.
      model = %Model{Model.new() | stats: %{Model.new().stats | count: 1, average: 0.01}}

      assert {12, 0, 1, 11} = Model.sentiment_gauge(model, 25)
    end

    test "the label matches the scorer's own neutral band" do
      Monitor.record_many([attrs(id: "a", text: "excellent, brilliant work")])

      assert Model.average_label(Model.new()) == :positive
    end
  end

  describe "tab_label/2" do
    test "shows per-platform counts, and their total for 'all'" do
      Monitor.record_many([
        attrs(id: "a", platform: :reddit),
        attrs(id: "b", platform: :reddit),
        attrs(id: "c", platform: :youtube)
      ])

      model = Model.new()

      assert Model.tab_label(model, :reddit) == "reddit (2)"
      assert Model.tab_label(model, :youtube) == "youtube (1)"
      assert Model.tab_label(model, :twitter) == "twitter (0)"
      assert Model.tab_label(model, :all) == "all (3)"
    end
  end

  describe "resize/2" do
    test "recomputes the row count and keeps the offset in range" do
      Monitor.record_many(for index <- 1..40, do: attrs(id: "m#{index}"))

      model = Model.new(%{window: %{height: 60}}) |> Model.scroll(1_000)
      resized = Model.resize(model, %{window: %{height: 20}})

      assert resized.rows < model.rows
      assert resized.offset <= length(resized.mentions) - resized.rows
    end
  end

  describe "moving between tabs" do
    # The trends screen reads the database.
    setup do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SmmMonitor.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    end

    test "the right arrow walks the tabs in order" do
      model = Model.refresh(Model.new())

      # Up to the config screen, where the arrows move between fields.
      {visited, _model} =
        Enum.map_reduce(tl(model.tabs), model, fn _tab, model ->
          next = Model.handle_key(model, {:key, :arrow_right})
          {next.tab, next}
        end)

      assert visited == tl(model.tabs)
    end

    test "the left arrow goes backwards from the first tab to the last" do
      model = Model.refresh(Model.new())
      assert Model.handle_key(model, {:key, :arrow_left}).tab == List.last(model.tabs)
    end

    test "on the config screen the arrows still move between fields" do
      model = Model.handle_key(Model.new(), {:char, ?c})
      assert model.tab == :config
      assert Model.handle_key(model, {:key, :arrow_right}).tab == :config
    end
  end

  describe "a platform that is off until switched on" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      bluesky = Application.get_env(:smm_monitor, SmmMonitor.Fetchers.Bluesky)
      mocks = Application.get_env(:smm_monitor, :mock_platforms)

      Application.put_env(:smm_monitor, SmmMonitor.Fetchers.Bluesky,
        enabled: false,
        cursor_file: Path.join(dir, "bluesky.cursor")
      )

      Application.put_env(:smm_monitor, :mock_platforms, bluesky: false)

      # Demo mode stores mentions from the worker's own process.
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SmmMonitor.Repo, shared: true)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
        restore_env(SmmMonitor.Fetchers.Bluesky, bluesky)
        restore_env(:mock_platforms, mocks)
      end)

      start_supervised!({SmmMonitor.Fetchers.StreamWorker, module: SmmMonitor.Fetchers.Bluesky})
      SmmMonitor.Fetchers.StreamWorker.poll_now(:bluesky)
      :ok
    end

    test "has no tab, and its key does nothing, while it is off" do
      model = Model.refresh(Model.new())

      refute :bluesky in model.tabs
      # The original platforms keep theirs, connected or not.
      assert Enum.all?([:twitter, :instagram, :reddit, :youtube], &(&1 in model.tabs))
      assert Model.handle_key(model, {:char, ?b}).tab == :all
    end

    test "gets a tab, selected with b, once it is showing data" do
      Application.put_env(:smm_monitor, :mock_platforms, bluesky: true)
      SmmMonitor.Fetchers.StreamWorker.poll_now(:bluesky)

      model = Model.refresh(Model.new())
      assert :bluesky in model.tabs
      assert Model.handle_key(model, {:char, ?b}).tab == :bluesky
    end

    test "keeps its tab while it is being looked at" do
      Application.put_env(:smm_monitor, :mock_platforms, bluesky: true)
      SmmMonitor.Fetchers.StreamWorker.poll_now(:bluesky)
      model = Model.handle_key(Model.refresh(Model.new()), {:char, ?b})

      Application.put_env(:smm_monitor, :mock_platforms, bluesky: false)
      SmmMonitor.Fetchers.StreamWorker.poll_now(:bluesky)

      model = Model.refresh(model)
      assert model.tab == :bluesky
      assert :bluesky in model.tabs

      # Once the user moves away, it goes.
      model = Model.handle_key(model, {:char, ?a})
      refute :bluesky in model.tabs
    end
  end

  describe "Discord's tab" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      saved =
        for key <- [SmmMonitor.Fetchers.Discord, :credentials, :mock_platforms],
            do: {key, Application.get_env(:smm_monitor, key)}

      Application.put_env(:smm_monitor, SmmMonitor.Fetchers.Discord,
        cursor_file: Path.join(dir, "discord.cursor")
      )

      # No token: not connected, so no tab until demo data is asked for.
      Application.put_env(:smm_monitor, :credentials, [])
      Application.put_env(:smm_monitor, :mock_platforms, discord: false)
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SmmMonitor.Repo, shared: true)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
        Enum.each(saved, fn {key, value} -> restore_env(key, value) end)
      end)

      start_supervised!({SmmMonitor.Fetchers.StreamWorker, module: SmmMonitor.Fetchers.Discord})
      SmmMonitor.Fetchers.StreamWorker.poll_now(:discord)
      :ok
    end

    test "is hidden, and d does nothing, without a bot token" do
      model = Model.refresh(Model.new())

      refute :discord in model.tabs
      assert Model.handle_key(model, {:char, ?d}).tab == :all
    end

    test "is selected with d once it is showing data" do
      Application.put_env(:smm_monitor, :mock_platforms, discord: true)
      SmmMonitor.Fetchers.StreamWorker.poll_now(:discord)

      model = Model.refresh(Model.new())
      assert :discord in model.tabs
      assert Model.handle_key(model, {:char, ?d}).tab == :discord
    end

    test "d on the config screen still removes a client rather than opening Discord" do
      Application.put_env(:smm_monitor, :mock_platforms, discord: true)
      SmmMonitor.Fetchers.StreamWorker.poll_now(:discord)

      model = Model.refresh(Model.new()) |> Model.handle_key({:char, ?c})
      model = Model.handle_key(model, {:char, ?d})

      assert model.tab == :config
      assert model.confirm_remove != nil
    end
  end

  describe "Threads' tab" do
    setup do
      saved =
        for key <- [:credentials, :mock_platforms],
            do: {key, Application.get_env(:smm_monitor, key)}

      # No token: not connected, so no tab until demo data is asked for.
      Application.put_env(:smm_monitor, :credentials, [])
      Application.put_env(:smm_monitor, :mock_platforms, threads: false)
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SmmMonitor.Repo, shared: true)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
        Enum.each(saved, fn {key, value} -> restore_env(key, value) end)
      end)

      start_supervised!(
        {SmmMonitor.Fetchers.Worker, module: SmmMonitor.Fetchers.Threads, interval_ms: 3_600_000}
      )

      SmmMonitor.Fetchers.Worker.poll_now(:threads)
      :ok
    end

    test "is hidden, and e does nothing, without an access token" do
      model = Model.refresh(Model.new())

      refute :threads in model.tabs
      assert Model.handle_key(model, {:char, ?e}).tab == :all
    end

    test "is selected with e once it is showing data" do
      Application.put_env(:smm_monitor, :mock_platforms, threads: true)
      SmmMonitor.Fetchers.Worker.poll_now(:threads)

      model = Model.refresh(Model.new())
      assert :threads in model.tabs
      assert Model.handle_key(model, {:char, ?e}).tab == :threads
    end

    test "e on the config screen still edits a client rather than opening Threads" do
      Application.put_env(:smm_monitor, :mock_platforms, threads: true)
      SmmMonitor.Fetchers.Worker.poll_now(:threads)

      model = Model.refresh(Model.new()) |> Model.handle_key({:char, ?c})
      edited = Model.handle_key(model, {:char, ?e})

      assert edited.tab == :config
      assert edited.editing != nil
    end
  end

  describe "Mastodon's tab" do
    setup do
      saved =
        for key <- [SmmMonitor.Fetchers.Mastodon, :credentials, :mock_platforms],
            do: {key, Application.get_env(:smm_monitor, key)}

      Application.put_env(:smm_monitor, SmmMonitor.Fetchers.Mastodon, cursor_file: nil)
      # No token or server: not connected, so no tab until demo data is asked for.
      Application.put_env(:smm_monitor, :credentials, [])
      Application.put_env(:smm_monitor, :mock_platforms, mastodon: false)
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SmmMonitor.Repo, shared: true)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
        Enum.each(saved, fn {key, value} -> restore_env(key, value) end)
      end)

      start_supervised!({SmmMonitor.Fetchers.StreamWorker, module: SmmMonitor.Fetchers.Mastodon})
      SmmMonitor.Fetchers.StreamWorker.poll_now(:mastodon)
      :ok
    end

    test "is hidden, and m does nothing, without a server and token" do
      model = Model.refresh(Model.new())

      refute :mastodon in model.tabs
      assert Model.handle_key(model, {:char, ?m}).tab == :all
    end

    test "is selected with m once it is showing data" do
      Application.put_env(:smm_monitor, :mock_platforms, mastodon: true)
      SmmMonitor.Fetchers.StreamWorker.poll_now(:mastodon)

      model = Model.refresh(Model.new())
      assert :mastodon in model.tabs
      assert Model.handle_key(model, {:char, ?m}).tab == :mastodon
    end
  end

  describe "News's tab" do
    setup do
      saved =
        for key <- [SmmMonitor.Fetchers.News, :mock_platforms],
            do: {key, Application.get_env(:smm_monitor, key)}

      # No feeds and no search: not connected, so no tab until demo data is asked for.
      Application.put_env(:smm_monitor, SmmMonitor.Fetchers.News, feeds: [], search: :off)
      Application.put_env(:smm_monitor, :mock_platforms, news: false)
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SmmMonitor.Repo, shared: true)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
        Enum.each(saved, fn {key, value} -> restore_env(key, value) end)
      end)

      start_supervised!(
        {SmmMonitor.Fetchers.Worker, module: SmmMonitor.Fetchers.News, interval_ms: 3_600_000}
      )

      SmmMonitor.Fetchers.Worker.poll_now(:news)
      :ok
    end

    test "is hidden, and n does nothing, without feeds or search" do
      model = Model.refresh(Model.new())

      refute :news in model.tabs
      assert Model.handle_key(model, {:char, ?n}).tab == :all
    end

    test "is selected with n once it is showing data" do
      Application.put_env(:smm_monitor, :mock_platforms, news: true)
      SmmMonitor.Fetchers.Worker.poll_now(:news)

      model = Model.refresh(Model.new())
      assert :news in model.tabs
      assert Model.handle_key(model, {:char, ?n}).tab == :news
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:smm_monitor, key)
  defp restore_env(key, value), do: Application.put_env(:smm_monitor, key, value)
end
