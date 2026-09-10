defmodule SmmMonitor.SSH.ReadOnlyTest do
  @moduledoc """
  Remote SSH sessions may look but not touch.

  The restriction lives in `TUI.Model`, not in the SSH layer, so it holds
  no matter which renderer is driving and is testable without a terminal
  or a network. The flag is set when the session is built rather than
  derived from the connection, so a session cannot argue its way out of
  it later.
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

    {:ok,
     remote: Model.new(%{read_only: true}) |> Model.select_tab(:config),
     local: Model.new(%{}) |> Model.select_tab(:config)}
  end

  describe "a read-only session" do
    test "can still see the config screen", %{remote: model} do
      # Viewing is the point; only changing is refused.
      assert model.tab == :config
      assert model.config.keywords == Config.keywords()
      assert Model.field_value(model, :keywords) != ""
    end

    test "can still browse mentions and switch tabs", %{remote: model} do
      assert Model.handle_key(model, {:char, ?r}).tab == :reddit
      assert Model.handle_key(model, {:char, ?a}).tab == :all
    end

    test "refuses to start editing", %{remote: model} do
      edited = Model.handle_key(model, {:char, ?e})

      refute Model.editing?(edited)
      assert {:error, message} = edited.flash
      assert message =~ "read-only"
    end

    test "refuses Enter as a way into the editor", %{remote: model} do
      refute model |> Model.handle_key({:key, :enter}) |> Model.editing?()
    end

    test "leaves the stored config untouched", %{remote: model} do
      Config.put_keywords("untouched")

      model
      |> Model.refresh()
      |> Model.handle_key({:char, ?e})
      |> Model.handle_key({:char, ?x})
      |> Model.handle_key({:key, :enter})

      assert Config.keywords() == ["untouched"]
    end

    test "fails closed even if an edit somehow began", %{remote: model} do
      Config.put_keywords("original")

      # Force the editing state the UI would never allow, and check the
      # write is still refused.
      forced = %{model | editing: :keywords, buffer: "smuggled"}
      committed = Model.commit_editing(forced)

      assert Config.keywords() == ["original"]
      refute Model.editing?(committed)
      assert {:error, _message} = committed.flash
    end

    test "still quits on q", %{remote: model} do
      # Read-only is about config, not about being trapped in the session.
      assert Model.handle_key(model, {:char, ?q}).quit
    end
  end

  describe "a local session" do
    test "can edit as before", %{local: model} do
      edited = Model.handle_key(model, {:char, ?e})

      assert Model.editing?(edited)
      assert edited.editing == :keywords
    end

    test "saves through to Config", %{local: model} do
      model
      |> Model.handle_key({:char, ?e})
      |> Map.put(:buffer, "locally set")
      |> Model.commit_editing()

      assert Config.keywords() == ["locally set"]
    end
  end

  describe "defaults" do
    test "a session is editable unless told otherwise" do
      # The local app passes no flag, so it must default to editable.
      refute Model.new(%{}).read_only
      refute Model.new().read_only
    end

    test "read-only survives a refresh", %{remote: model} do
      assert Model.refresh(model).read_only
      assert model |> Model.select_tab(:all) |> Model.select_tab(:config) |> Map.fetch!(:read_only)
    end
  end
end
