defmodule SmmMonitor.TUI.ReportKeyTest do
  @moduledoc """
  Generating a client's report from the dashboard.

  The point of the key is that an account manager can hand a client
  something without leaving the screen they were already looking at, so
  these tests care about which client the report is for and about what
  the footer says afterwards.
  """

  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.TUI.Model

  setup do
    dir = Path.join(System.tmp_dir!(), "smm-tui-reports-#{System.unique_integer([:positive])}")
    Application.put_env(:smm_monitor, :reports_dir, dir)

    on_exit(fn ->
      Application.delete_env(:smm_monitor, :reports_dir)
      File.rm_rf(dir)
    end)

    set_clients(["Acme Corp", "Globex"])

    %{dir: dir, model: Model.new()}
  end

  describe "R" do
    test "writes a report for the client on screen", %{dir: dir, model: model} do
      model = Model.handle_key(model, {:char, ?R})

      assert {:ok, message} = model.flash
      assert message =~ "acme-corp"
      assert Path.wildcard(Path.join(dir, "acme-corp*")) != []
    end

    test "follows the selected client rather than the first one", %{dir: dir, model: model} do
      # Two SSH sessions can be looking at different clients; the report
      # belongs to the one whose mentions are on screen.
      model = model |> Model.select_client("globex") |> Model.handle_key({:char, ?R})

      assert {:ok, message} = model.flash
      assert message =~ "globex"
      assert Path.wildcard(Path.join(dir, "acme-corp*")) == []
    end

    test "works from any tab, not only the config screen", %{model: model} do
      model = model |> Model.select_tab(:reddit) |> Model.handle_key({:char, ?R})

      assert {:ok, _message} = model.flash
    end

    test "names the files it wrote, so they can be found", %{model: model} do
      model = Model.handle_key(model, {:char, ?R})

      {:ok, message} = model.flash

      assert message =~ ".csv"
    end

    test "is refused in a read-only session", %{dir: dir} do
      # A remote viewer should not be able to write files onto the host's
      # disk by pressing a key.
      model = Model.new(%{read_only: true}) |> Model.handle_key({:char, ?R})

      assert {:error, message} = model.flash
      assert message =~ "read-only"
      refute File.exists?(dir)
    end

    test "says so rather than crashing when there are no clients" do
      set_clients([])

      model = Model.new() |> Model.handle_key({:char, ?R})

      assert {:error, "no client selected"} = model.flash
    end

    test "lowercase r is still refresh, not a file write", %{dir: dir, model: model} do
      # The two are one shift apart, and only one of them should put a
      # document on disk.
      model = Model.handle_key(model, {:char, ?r})

      assert model.flash == nil
      refute File.exists?(dir)
    end
  end
end
