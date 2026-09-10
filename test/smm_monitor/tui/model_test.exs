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

  setup do
    Monitor.reset()
    :ok
  end

  describe "new/1" do
    test "starts on the 'all' tab with every configured platform" do
      model = Model.new()

      assert model.tab == :all
      # Config sits at the end, after the platform tabs.
      assert model.tabs == [:all | SmmMonitor.platforms()] ++ [:config]
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
      assert Model.select_tab(model, :mastodon) == model
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
end
