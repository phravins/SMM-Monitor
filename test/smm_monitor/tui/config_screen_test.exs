defmodule SmmMonitor.TUI.ConfigScreenTest do
  @moduledoc """
  The config screen's behaviour, which all lives in `TUI.Model` — no
  terminal needed. Rendering itself still isn't tested.

  These share the application's Config process, so they restore whatever
  they change.
  """

  use ExUnit.Case, async: false

  alias SmmMonitor.Config
  alias SmmMonitor.TUI.Model

  setup do
    original = Config.all()

    on_exit(fn ->
      Config.put_keywords(original.keywords)
      Config.put_subreddits(original.subreddits)
    end)

    {:ok, model: Model.new() |> Model.select_tab(:config)}
  end

  describe "reaching the screen" do
    test "'c' opens the config tab" do
      assert Model.new() |> Model.handle_key({:char, ?c}) |> Map.fetch!(:tab) == :config
    end

    test "'a' goes back to the mentions view", %{model: model} do
      assert Model.handle_key(model, {:char, ?a}).tab == :all
    end

    test "the config tab has no mention count" do
      # It isn't a view over mentions, so "(0)" would be meaningless.
      assert Model.tab_label(Model.new(), :config) == "config"
    end

    test "it shows the current settings", %{model: model} do
      Config.put_keywords("shown, also shown")
      model = Model.refresh(model)

      assert model.config.keywords == ["shown", "also shown"]
      assert Model.field_value(model, :keywords) == "shown, also shown"
    end

    test "it shows each platform's mode read-only", %{model: model} do
      assert length(model.statuses) == length(SmmMonitor.platforms())
      assert Enum.all?(model.statuses, &Map.has_key?(&1, :mode))
    end
  end

  describe "selecting a field" do
    test "j/k and arrows move between fields, wrapping", %{model: model} do
      assert model.selected_field == :keywords

      down = Model.handle_key(model, {:char, ?j})
      assert down.selected_field == :subreddits

      # Wraps rather than sticking at the end.
      assert Model.handle_key(down, {:char, ?j}).selected_field == :keywords
      assert Model.handle_key(model, {:key, :arrow_up}).selected_field == :subreddits
    end
  end

  describe "editing" do
    test "'e' starts editing, seeded with the current value", %{model: model} do
      Config.put_keywords("current terms")
      model = model |> Model.refresh() |> Model.handle_key({:char, ?e})

      assert model.editing == :keywords
      # Seeded, so an edit is a correction rather than a retype.
      assert model.buffer == "current terms"
      assert Model.editing?(model)
    end

    test "Enter also starts editing", %{model: model} do
      assert Model.handle_key(model, {:key, :enter}).editing == :keywords
    end

    test "typed characters go into the buffer", %{model: model} do
      model = model |> Model.handle_key({:char, ?e}) |> clear_buffer()
      model = type(model, "acme")

      assert model.buffer == "acme"
    end

    test "backspace deletes the last character", %{model: model} do
      model = model |> Model.handle_key({:char, ?e}) |> clear_buffer() |> type("acme")

      assert Model.handle_key(model, {:key, :backspace}).buffer == "acm"
    end

    test "backspace on an empty buffer is harmless", %{model: model} do
      model = model |> Model.handle_key({:char, ?e}) |> clear_buffer()

      assert Model.handle_key(model, {:key, :backspace}).buffer == ""
    end
  end

  describe "keys that would otherwise do something else" do
    test "tab shortcuts are typed, not acted on", %{model: model} do
      # 'a', 't', 'i', 'r', 'y' and 'c' are all tab shortcuts. A brand term
      # containing any of them must still be typeable.
      model = model |> Model.handle_key({:char, ?e}) |> clear_buffer() |> type("clarity")

      assert model.buffer == "clarity"
      assert model.tab == :config
      assert model.editing == :keywords
    end

    test "'q' is typed rather than quitting", %{model: model} do
      # This is why 'q' isn't a Ratatouille quit event: the runtime checks
      # those before the app sees the key, so "quiet" would be untypeable
      # and the app would exit mid-word.
      model = model |> Model.handle_key({:char, ?e}) |> clear_buffer() |> type("quiet")

      assert model.buffer == "quiet"
      refute model.quit
    end

    test "'j' and 'k' are typed rather than moving the selection", %{model: model} do
      model = model |> Model.handle_key({:char, ?e}) |> clear_buffer() |> type("jkjk")

      assert model.buffer == "jkjk"
      assert model.selected_field == :keywords
    end

    test "'q' still quits when not editing", %{model: model} do
      assert Model.handle_key(model, {:char, ?q}).quit
    end
  end

  describe "saving" do
    test "Enter writes the value through to Config", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("saved term")
        |> Model.handle_key({:key, :enter})

      assert Config.keywords() == ["saved term"]
      refute Model.editing?(model)
      assert {:ok, message} = model.flash
      # Answers the question anyone has at that moment.
      assert message =~ "next poll"
    end

    test "saving subreddits writes the subreddit list", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?j})
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("marketing, saas")
        |> Model.handle_key({:key, :enter})

      assert Config.subreddits() == ["marketing", "saas"]
      assert model.config.subreddits == ["marketing", "saas"]
    end

    test "an empty subreddit list is accepted", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?j})
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> Model.handle_key({:key, :enter})

      assert Config.subreddits() == []
      assert match?({:ok, _message}, model.flash)
    end

    test "empty brand terms are refused, keeping the editor open", %{model: model} do
      Config.put_keywords("kept")

      model =
        model
        |> Model.refresh()
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> Model.handle_key({:key, :enter})

      # Still editing, so what was typed isn't thrown away.
      assert model.editing == :keywords
      assert {:error, message} = model.flash
      assert message =~ "at least one brand term"
      assert Config.keywords() == ["kept"]
    end
  end

  describe "cancelling" do
    test "Esc abandons the edit and leaves the stored value alone", %{model: model} do
      Config.put_keywords("original")

      model =
        model
        |> Model.refresh()
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("discarded")
        |> Model.handle_key({:key, :escape})

      refute Model.editing?(model)
      assert model.buffer == ""
      assert Config.keywords() == ["original"]
    end

    test "leaving the tab abandons a half-typed edit", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("half typed")
        |> Model.select_tab(:all)

      refute Model.editing?(model)
      assert model.buffer == ""
    end
  end

  defp type(model, text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(model, fn char, acc -> Model.handle_key(acc, {:char, char}) end)
  end

  # Editing seeds the buffer with the current value; most tests want to
  # start from empty.
  defp clear_buffer(model), do: %{model | buffer: ""}
end
