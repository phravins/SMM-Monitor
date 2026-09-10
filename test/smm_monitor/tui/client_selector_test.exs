defmodule SmmMonitor.TUI.ClientSelectorTest do
  @moduledoc """
  Switching which client the dashboard is showing.

  The selection lives in the model rather than in `Clients`, which is
  what lets two SSH sessions watch different clients at once. These
  tests pin that down along with the scoping it drives.
  """

  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.{Mention, Monitor}
  alias SmmMonitor.TUI.Model

  setup do
    Monitor.reset()
    set_clients(["Acme", "Beta", "Gamma"])
    {:ok, model: Model.new()}
  end

  describe "the default selection" do
    test "is the first client", %{model: model} do
      assert model.client_id == "acme"
      assert Model.current_client(model).name == "Acme"
    end

    test "skips a paused client", %{} do
      [acme, beta, gamma] = Clients.list()
      Clients.replace([%{acme | active: false}, beta, gamma])

      assert Model.new().client_id == "beta"
    end

    test "can be set explicitly, which is how an SSH session opens on one" do
      assert Model.new(%{client_id: "gamma"}).client_id == "gamma"
    end

    test "with no clients at all, nothing is selected rather than crashing" do
      set_clients([])

      model = Model.new()

      assert model.client_id == nil
      assert Model.current_client(model) == nil
      assert model.mentions == []
    end
  end

  describe "cycling" do
    test "] moves forward and [ moves back", %{model: model} do
      model = Model.handle_key(model, {:char, ?]})
      assert model.client_id == "beta"

      model = Model.handle_key(model, {:char, ?]})
      assert model.client_id == "gamma"

      model = Model.handle_key(model, {:char, ?[})
      assert model.client_id == "beta"
    end

    test "wraps at both ends", %{model: model} do
      wrapped =
        model
        |> Model.handle_key({:char, ?]})
        |> Model.handle_key({:char, ?]})
        |> Model.handle_key({:char, ?]})

      assert wrapped.client_id == "acme"
      assert Model.handle_key(model, {:char, ?[}).client_id == "gamma"
    end

    test "works from any tab, not just the client screen", %{model: model} do
      model = model |> Model.select_tab(:reddit) |> Model.handle_key({:char, ?]})

      assert model.client_id == "beta"
      # And stays on the tab you were reading.
      assert model.tab == :reddit
    end

    test "the number keys jump straight to one", %{model: model} do
      assert Model.handle_key(model, {:char, ?3}).client_id == "gamma"
      assert Model.handle_key(model, {:char, ?1}).client_id == "acme"
    end

    test "a number beyond the list does nothing", %{model: model} do
      assert Model.handle_key(model, {:char, ?9}).client_id == "acme"
    end

    test "the header knows where it is in the list", %{model: model} do
      assert Model.client_position(model) == {1, 3}
      assert model |> Model.handle_key({:char, ?]}) |> Model.client_position() == {2, 3}
    end
  end

  describe "what the selection scopes" do
    setup do
      record("acme", :reddit, "a1", "acme is excellent")
      record("acme", :youtube, "a2", "acme again")
      record("beta", :reddit, "b1", "beta is terrible and broken")
      record("beta", :reddit, "b2", "beta again, broken")
      :ok
    end

    test "the mention list", %{model: model} do
      model = Model.refresh(model)
      assert length(model.mentions) == 2
      assert Enum.all?(model.mentions, &(&1.client_id == "acme"))

      model = Model.handle_key(model, {:char, ?]})
      assert length(model.mentions) == 2
      assert Enum.all?(model.mentions, &(&1.client_id == "beta"))
    end

    test "the summary stats", %{model: model} do
      model = Model.refresh(model)
      assert model.stats.count == 2
      assert model.stats.average > 0

      model = Model.handle_key(model, {:char, ?]})
      assert model.stats.average < 0
    end

    test "the tab counts", %{model: model} do
      model = Model.refresh(model)
      assert model.breakdown[:reddit] == 1
      assert model.breakdown[:youtube] == 1

      model = Model.handle_key(model, {:char, ?]})
      assert model.breakdown[:reddit] == 2
      assert model.breakdown[:youtube] == 0
    end

    test "the 'all' tab means all of this client's platforms, not all clients",
         %{model: model} do
      # The failure this prevents: an "all" view that silently adds two
      # clients' numbers together.
      model = model |> Model.select_tab(:all) |> Model.refresh()

      assert model.tab == :all
      assert model.stats.count == 2
    end

    test "the header's brand terms follow the selection", %{model: model} do
      assert Model.refresh(model).keywords == ["acme"]
      assert model |> Model.handle_key({:char, ?]}) |> Map.fetch!(:keywords) == ["beta"]
    end

    test "switching resets the scroll, since it is a different list", %{model: model} do
      model = %{model | offset: 1}

      assert Model.handle_key(model, {:char, ?]}).offset == 0
    end
  end

  describe "when the selected client disappears" do
    test "the dashboard falls back rather than showing an empty scope", %{model: model} do
      # Another session — or another operator — removed it.
      [_acme, beta, gamma] = Clients.list()
      Clients.replace([beta, gamma])

      model = Model.refresh(model)

      assert model.client_id == "beta"
      assert Model.current_client(model).name == "Beta"
    end
  end

  defp record(client_id, platform, id, text) do
    Monitor.record(
      Mention.new(%{
        id: id,
        platform: platform,
        client_id: client_id,
        author: "u/tester",
        text: text,
        timestamp: DateTime.utc_now()
      })
    )
  end
end
