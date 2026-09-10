defmodule SmmMonitor.SSH.ReadOnlyTest do
  @moduledoc """
  Remote SSH sessions may look but not touch.

  The restriction lives in `TUI.Model`, not in the SSH layer, so it holds
  no matter which renderer is driving and is testable without a terminal
  or a network. The flag is set when the session is built rather than
  derived from the connection, so a session cannot argue its way out of
  it later.
  """

  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.TUI.Model

  setup do
    set_clients(["Acme", "Beta"])

    {:ok,
     remote: Model.new(%{read_only: true}) |> Model.select_tab(:config),
     local: Model.new(%{}) |> Model.select_tab(:config)}
  end

  describe "a read-only session" do
    test "can still see the client screen", %{remote: model} do
      # Viewing is the point; only changing is refused.
      assert model.tab == :config
      assert Enum.map(model.clients, & &1.id) == ["acme", "beta"]
      assert Model.field_value(Model.highlighted_client(model), :keywords) != ""
    end

    test "can still switch which client it is watching", %{remote: model} do
      # Read-only is about changing the configuration, not about being
      # stuck on one client's numbers.
      assert Model.handle_key(model, {:char, ?]}).client_id == "beta"
      assert Model.handle_key(model, {:char, ?2}).client_id == "beta"
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

    test "leaves the stored clients untouched", %{remote: model} do
      model
      |> Model.refresh()
      |> Model.handle_key({:char, ?e})
      |> Model.handle_key({:char, ?x})
      |> Model.handle_key({:key, :enter})

      assert Clients.get("acme").keywords == ["acme"]
    end

    test "refuses to add a client", %{remote: model} do
      added = Model.handle_key(model, {:char, ?+})

      refute Model.editing?(added)
      assert {:error, message} = added.flash
      assert message =~ "read-only"
      assert length(Clients.list()) == 2
    end

    test "refuses to remove a client", %{remote: model} do
      removed = model |> Model.handle_key({:char, ?d}) |> Model.handle_key({:char, ?d})

      assert {:error, _message} = removed.flash
      assert length(Clients.list()) == 2
    end

    test "refuses to pause a client", %{remote: model} do
      paused = Model.handle_key(model, {:char, ?p})

      assert {:error, _message} = paused.flash
      assert Clients.get("acme").active
    end

    test "fails closed even if an edit somehow began", %{remote: model} do
      # Force the editing state the UI would never allow, and check the
      # write is still refused.
      forced = %{model | editing: :keywords, buffer: "smuggled"}
      committed = Model.commit_editing(forced)

      assert Clients.get("acme").keywords == ["acme"]
      refute Model.editing?(committed)
      assert {:error, _message} = committed.flash
    end

    test "fails closed on a forced removal too", %{remote: model} do
      forced = %{model | confirm_remove: "acme"}

      assert {:error, _message} = Model.confirm_remove(forced).flash
      assert length(Clients.list()) == 2
    end

    test "still quits on q", %{remote: model} do
      # Read-only is about config, not about being trapped in the session.
      assert Model.handle_key(model, {:char, ?q}).quit
    end
  end

  describe "a local session" do
    test "can edit as before", %{local: model} do
      edited = model |> Model.handle_key({:char, ?l}) |> Model.handle_key({:char, ?e})

      assert Model.editing?(edited)
      assert edited.editing == :keywords
    end

    test "saves through to Clients", %{local: model} do
      model
      |> Model.handle_key({:char, ?l})
      |> Model.handle_key({:char, ?e})
      |> Map.put(:buffer, "locally set")
      |> Model.commit_editing()

      assert Clients.get("acme").keywords == ["locally set"]
    end

    test "can add and remove clients", %{local: model} do
      model
      |> Model.handle_key({:char, ?+})
      |> Map.put(:buffer, "Gamma")
      |> Model.commit_editing()

      assert Clients.get("gamma")
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
