defmodule SmmMonitor.TUI.TrendsScreenTest do
  @moduledoc """
  The trends screen as a screen: which key opens it, whose history it
  shows, and how the window toggle behaves.

  The numbers themselves are `SmmMonitor.TrendsTest`'s job and the
  glyphs are `SmmMonitor.TUI.ChartTest`'s; what is left here is the
  behaviour a finger actually drives.
  """

  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.{Mention, Persistence}
  alias SmmMonitor.TUI.{Chart, Model}

  setup do
    set_clients(["Acme Corp", "Globex"])

    %{model: Model.new()}
  end

  describe "opening the screen" do
    test "h switches to it from the mentions list", %{model: model} do
      model = Model.handle_key(model, {:char, ?h})

      assert model.tab == :trends
    end

    test "h works from a platform tab too", %{model: model} do
      model = model |> Model.select_tab(:reddit) |> Model.handle_key({:char, ?h})

      assert model.tab == :trends
    end

    test "it sits with the other non-list screens, at the end of the tabs", %{model: model} do
      assert Enum.take(model.tabs, -2) == [:trends, :config]
    end

    test "the tab says which window it is showing", %{model: model} do
      model = Model.handle_key(model, {:char, ?h})

      assert Model.tab_label(model, :trends) == "trends (14d)"
    end

    test "a is still the way back to the mentions list", %{model: model} do
      model = model |> Model.handle_key({:char, ?h}) |> Model.handle_key({:char, ?a})

      assert model.tab == :all
    end

    test "q still quits from it", %{model: model} do
      model = model |> Model.handle_key({:char, ?h}) |> Model.handle_key({:char, ?q})

      assert model.quit
    end

    test "h on the clients screen still steps between a client's fields", %{model: model} do
      # `h`/`l` were the way across that grid before this screen existed,
      # and the arrow keys do the same job there — so the config screen
      # is the one place the tab shortcut yields.
      model = model |> Model.select_tab(:config) |> Model.handle_key({:char, ?h})

      assert model.tab == :config
    end
  end

  describe "whose history it shows" do
    setup do
      store("acme-corp", 3)
      store("globex", 1)

      :ok
    end

    test "the client on screen, not every client added together", %{model: model} do
      model = Model.handle_key(model, {:char, ?h})

      assert model.trends.client_id == "acme-corp"
      assert model.trends.total == 3
    end

    test "follows the selection when the client changes", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?h})
        |> Model.handle_key({:char, ?]})

      assert model.trends.client_id == "globex"
      assert model.trends.total == 1
    end

    test "is read from the database, not from the live window", %{model: model} do
      # The live window is hours old at most; this screen is the only one
      # that can see a fortnight, and it can only see it on disk.
      model = Model.handle_key(model, {:char, ?h})

      assert model.trends.total == 3
      assert model.mentions == []
    end

    test "is left alone while another tab is open", %{model: model} do
      # No database query per tick for a screen nobody is looking at.
      model = Model.refresh(model)

      assert model.trends.days == []
      assert model.trends_read_at == nil
    end

    test "a read-only session can look at it", %{} do
      # Nothing here writes anything, so there is nothing to refuse.
      model = Model.new(%{read_only: true}) |> Model.handle_key({:char, ?h})

      assert model.tab == :trends
      assert model.trends.total == 3
    end
  end

  describe "the window toggle" do
    test "starts on a fortnight", %{model: model} do
      assert model.trend_window == 14
    end

    test "w widens it, and wraps round", %{model: model} do
      model = Model.handle_key(model, {:char, ?h})

      windows =
        Enum.map_reduce(1..3, model, fn _step, acc ->
          acc = Model.handle_key(acc, {:char, ?w})
          {acc.trend_window, acc}
        end)
        |> elem(0)

      assert windows == [30, 7, 14]
    end

    test "W narrows it", %{model: model} do
      model = model |> Model.handle_key({:char, ?h}) |> Model.handle_key({:char, ?W})

      assert model.trend_window == 7
    end

    test "reloads the series under the keypress that asked for it", %{model: model} do
      store("acme-corp", 2)

      model = model |> Model.handle_key({:char, ?h}) |> Model.handle_key({:char, ?w})

      assert model.trend_window == 30
      assert model.trends.window_days == 30
      assert length(model.trends.days) == 30
    end

    test "the panel title follows it", %{model: model} do
      model = model |> Model.handle_key({:char, ?h}) |> Model.handle_key({:char, ?w})

      assert Model.trend_window_label(model) == "last 30 days"
    end

    test "w on another screen is not a keystroke that changes a hidden setting", %{model: model} do
      model = Model.handle_key(model, {:char, ?w})

      assert model.trend_window == 14
      assert model.tab == :all
    end
  end

  describe "fitting the terminal" do
    test "the charts share the space the mentions table would have had" do
      tall = Model.new(%{window: %{height: 50, width: 120}})
      short = Model.new(%{window: %{height: 20, width: 80}})

      {tall_volume, tall_sentiment} = Model.trend_chart_heights(tall)
      {short_volume, short_sentiment} = Model.trend_chart_heights(short)

      assert tall_volume > short_volume
      assert tall_sentiment >= short_sentiment
      assert short_volume >= 3
      assert short_sentiment >= 1
    end

    test "a tiny terminal still gets a chart rather than nothing" do
      {volume, sentiment} = Model.trend_chart_heights(Model.new(%{window: %{height: 10}}))

      assert volume >= 3
      assert sentiment >= 1
    end

    test "columns widen on a roomy terminal and narrow for a long window" do
      store("acme-corp", 1)

      wide = trends_model(%{window: %{height: 40, width: 160}}, 7)
      narrow = trends_model(%{window: %{height: 40, width: 80}}, 30)

      assert Model.trend_column_width(wide) == 4
      assert Model.trend_column_width(narrow) == 1
    end

    test "the chart never grows wider than the terminal it is drawn in" do
      store("acme-corp", 1)

      for width <- [60, 72, 80, 120, 200], window <- [7, 14, 30] do
        model = trends_model(%{window: %{height: 40, width: width}}, window)
        drawn = model |> Model.trend_days() |> length()
        column = Model.trend_column_width(model)

        assert Chart.width(drawn, width: column) <= width - 6,
               "a #{window}-day window overflowed a #{width}-column terminal"
      end
    end

    test "a narrow terminal loses the oldest days, not the newest" do
      # Clipping would cut the right-hand end off, which is this week.
      store("acme-corp", 1)

      model = trends_model(%{window: %{height: 40, width: 60}}, 30)
      drawn = Model.trend_days(model)

      assert Model.trend_days_dropped(model) > 0
      assert List.last(drawn).date == Date.utc_today()
      assert length(drawn) < 30
    end

    test "a terminal with room drops nothing" do
      store("acme-corp", 1)

      model = trends_model(%{window: %{height: 40, width: 100}}, 30)

      assert Model.trend_days_dropped(model) == 0
      assert length(Model.trend_days(model)) == 30
    end
  end

  # --- helpers --------------------------------------------------------------

  defp trends_model(context, window) do
    model = context |> Model.new() |> Model.handle_key({:char, ?h})

    Enum.reduce_while(1..3, model, fn _step, acc ->
      if acc.trend_window == window,
        do: {:halt, acc},
        else: {:cont, Model.handle_key(acc, {:char, ?w})}
    end)
  end

  defp store(client_id, count) do
    mentions =
      for n <- 1..count do
        %Mention{
          id: "t-#{client_id}-#{n}-#{System.unique_integer([:positive])}",
          platform: :reddit,
          author: "u/tester",
          text: "a mention",
          url: "https://example.test/p",
          timestamp: DateTime.add(DateTime.utc_now(), -n * 3600, :second),
          client_id: client_id,
          sentiment: :neutral,
          sentiment_value: 0.0,
          sentiment_score: 0
        }
      end

    {:ok, _count} = Persistence.store(mentions)
  end
end
