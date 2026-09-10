defmodule SmmMonitor.TUI.ClientScreenTest do
  @moduledoc """
  The client management screen's behaviour, which all lives in
  `TUI.Model` — no terminal needed. Rendering itself still isn't tested.

  These drive the application's `Clients` process, so they restore
  whatever they change.
  """

  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.TUI.Model

  setup do
    set_clients(["Acme", "Beta"])
    {:ok, model: Model.new() |> Model.select_tab(:config)}
  end

  describe "reaching the screen" do
    test "'c' opens it" do
      assert Model.new() |> Model.handle_key({:char, ?c}) |> Map.fetch!(:tab) == :config
    end

    test "'a' goes back to the mentions view" do
      assert Model.new()
             |> Model.select_tab(:config)
             |> Model.handle_key({:char, ?a})
             |> Map.fetch!(:tab) == :all
    end

    test "it lists every client, paused ones included", %{model: model} do
      assert Enum.map(model.clients, & &1.id) == ["acme", "beta"]
    end
  end

  describe "moving around the grid" do
    test "j and k move between clients", %{model: model} do
      assert model.selected_client == 0

      model = Model.handle_key(model, {:char, ?j})
      assert Model.highlighted_client(model).id == "beta"

      model = Model.handle_key(model, {:char, ?k})
      assert Model.highlighted_client(model).id == "acme"
    end

    test "moving past the end wraps", %{model: model} do
      model = model |> Model.handle_key({:char, ?j}) |> Model.handle_key({:char, ?j})

      assert Model.highlighted_client(model).id == "acme"
    end

    test "h and l move between a client's fields", %{model: model} do
      assert model.selected_field == :name

      model = Model.handle_key(model, {:char, ?l})
      assert model.selected_field == :keywords

      model = Model.handle_key(model, {:char, ?l})
      assert model.selected_field == :subreddits

      model = Model.handle_key(model, {:char, ?h})
      assert model.selected_field == :keywords
    end

    test "arrow keys do the same as j/k/h/l", %{model: model} do
      assert Model.handle_key(model, {:key, :arrow_down}).selected_client == 1
      assert Model.handle_key(model, {:key, :arrow_right}).selected_field == :keywords
    end
  end

  describe "editing a field" do
    test "'e' seeds the buffer with the current value, so an edit is a correction",
         %{model: model} do
      model = model |> Model.handle_key({:char, ?l}) |> Model.handle_key({:char, ?e})

      assert model.editing == :keywords
      assert model.buffer == "acme"
    end

    test "typing appends and Enter saves", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?l})
        |> Model.handle_key({:char, ?e})
        |> type(", acme corp")
        |> Model.handle_key({:key, :enter})

      assert model.editing == nil
      assert Clients.get("acme").keywords == ["acme", "acme corp"]
      assert {:ok, message} = model.flash
      assert message =~ "next poll"
    end

    test "Escape abandons the edit and leaves the value alone", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?l})
        |> Model.handle_key({:char, ?e})
        |> type("something else")
        |> Model.handle_key({:key, :escape})

      assert model.editing == nil
      assert Clients.get("acme").keywords == ["acme"]
    end

    test "a rejected value keeps the editor open with the reason", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?l})
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> Model.handle_key({:key, :enter})

      # Still editing, so what was typed isn't lost.
      assert model.editing == :keywords
      assert {:error, message} = model.flash
      assert message =~ "brand term"
      assert Clients.get("acme").keywords == ["acme"]
    end

    test "renaming keeps the client's id, and says so", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("Acme Corporation")
        |> Model.handle_key({:key, :enter})

      assert Clients.get("acme").name == "Acme Corporation"
      assert {:ok, message} = model.flash
      assert message =~ "history"
    end

    test "editing subreddits to empty is allowed — it means all of Reddit",
         %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?l})
        |> Model.handle_key({:char, ?l})
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> Model.handle_key({:key, :enter})

      assert model.editing == nil
      assert Clients.get("acme").subreddits == []
    end

    test "while editing, tab shortcuts are typed rather than acted on", %{model: model} do
      # A brand term containing a 'c' would otherwise be unreachable.
      model =
        model
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("acme")

      assert model.tab == :config
      assert model.buffer == "acme"
      refute model.quit
    end
  end

  describe "editing alert settings" do
    test "the alert fields sit after the monitoring ones" do
      # The order they get set up in: decide what to watch, then decide
      # what is worth being woken for.
      assert Model.config_fields() == [
               :name,
               :keywords,
               :subreddits,
               :watch_phrases,
               :sentiment_threshold,
               :volume_multiple,
               :webhook_url
             ]
    end

    test "watch phrases are edited like any other list", %{model: model} do
      model =
        model
        |> to_field(:watch_phrases)
        |> Model.handle_key({:char, ?e})
        |> type("lawsuit, refund")
        |> Model.handle_key({:key, :enter})

      assert Clients.get("acme").alerts.watch_phrases == ["lawsuit", "refund"]
      assert {:ok, message} = model.flash
      assert message =~ "alerting picks this up"
    end

    test "phrases are stored lowercased, so matching is case insensitive",
         %{model: model} do
      model
      |> to_field(:watch_phrases)
      |> Model.handle_key({:char, ?e})
      |> type("Lawsuit, REFUND")
      |> Model.handle_key({:key, :enter})

      assert Clients.get("acme").alerts.watch_phrases == ["lawsuit", "refund"]
    end

    test "a sentiment threshold is saved as a number", %{model: model} do
      model
      |> to_field(:sentiment_threshold)
      |> Model.handle_key({:char, ?e})
      |> clear_buffer()
      |> type("-0.55")
      |> Model.handle_key({:key, :enter})

      assert Clients.get("acme").alerts.sentiment_threshold == -0.55
    end

    test "a threshold outside the sentiment range is refused with the reason",
         %{model: model} do
      # Sentiment runs -1.0..1.0, so -5 is always-on and 5 is never-on.
      model =
        model
        |> to_field(:sentiment_threshold)
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("-5")
        |> Model.handle_key({:key, :enter})

      assert {:error, message} = model.flash
      assert message =~ "-1.00 to 1.00"
      assert Clients.get("acme").alerts.sentiment_threshold == -0.3
    end

    test "something that isn't a number is refused", %{model: model} do
      model =
        model
        |> to_field(:volume_multiple)
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("lots")
        |> Model.handle_key({:key, :enter})

      assert {:error, message} = model.flash
      assert message =~ "needs a number"
    end

    test "a volume multiple of 1x or less is refused", %{model: model} do
      # It would alert on every ordinary hour.
      model =
        model
        |> to_field(:volume_multiple)
        |> Model.handle_key({:char, ?e})
        |> clear_buffer()
        |> type("1")
        |> Model.handle_key({:key, :enter})

      assert {:error, message} = model.flash
      assert message =~ "every ordinary hour"
    end

    test "a client's own Slack webhook is saved", %{model: model} do
      model
      |> to_field(:webhook_url)
      |> Model.handle_key({:char, ?e})
      |> type("https://hooks.slack.com/services/T/B/x")
      |> Model.handle_key({:key, :enter})

      assert Clients.get("acme").alerts.webhook_url ==
               "https://hooks.slack.com/services/T/B/x"
    end

    test "a webhook that isn't https is refused", %{model: model} do
      model =
        model
        |> to_field(:webhook_url)
        |> Model.handle_key({:char, ?e})
        |> type("hooks.slack.com/services/T/B/x")
        |> Model.handle_key({:key, :enter})

      assert {:error, message} = model.flash
      assert message =~ "https://"
    end

    test "clearing the webhook falls back to the global one", %{model: model} do
      model
      |> to_field(:webhook_url)
      |> Model.handle_key({:char, ?e})
      |> type("https://hooks.slack.com/services/T/B/x")
      |> Model.handle_key({:key, :enter})

      Model.new()
      |> Model.select_tab(:config)
      |> to_field(:webhook_url)
      |> Model.handle_key({:char, ?e})
      |> clear_buffer()
      |> Model.handle_key({:key, :enter})

      assert Clients.get("acme").alerts.webhook_url == nil
    end

    test "the screen shows the thresholds in force", %{model: model} do
      assert Model.field_value(Model.highlighted_client(model), :sentiment_threshold) == "-0.30"
      assert Model.field_value(Model.highlighted_client(model), :volume_multiple) == "3.0"
    end

    test "a read-only session cannot change them" do
      model = Model.new(%{read_only: true}) |> Model.select_tab(:config)

      edited = model |> to_field(:watch_phrases) |> Model.handle_key({:char, ?e})

      refute Model.editing?(edited)
      assert {:error, message} = edited.flash
      assert message =~ "read-only"
    end
  end

  describe "adding a client" do
    test "'+' opens a name editor", %{model: model} do
      model = Model.handle_key(model, {:char, ?+})

      assert model.editing == :new_client
      assert model.buffer == ""
    end

    test "Enter creates it, using the name as its first brand term", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?+})
        |> type("Gamma Industries")
        |> Model.handle_key({:key, :enter})

      client = Clients.get("gamma-industries")

      assert client.name == "Gamma Industries"
      assert client.keywords == ["Gamma Industries"]
      assert {:ok, message} = model.flash
      assert message =~ "brand terms"
    end

    test "the new client is highlighted with its terms selected, ready to fix",
         %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?+})
        |> type("Gamma")
        |> Model.handle_key({:key, :enter})

      assert Model.highlighted_client(model).id == "gamma"
      assert model.selected_field == :keywords
    end

    test "a nameless client is refused with a reason", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?+})
        |> Model.handle_key({:key, :enter})

      assert {:error, message} = model.flash
      assert message =~ "name"
      assert length(Clients.list()) == 2
    end

    test "Escape abandons it", %{model: model} do
      model =
        model
        |> Model.handle_key({:char, ?+})
        |> type("Gamma")
        |> Model.handle_key({:key, :escape})

      assert model.editing == nil
      assert length(Clients.list()) == 2
    end
  end

  describe "removing a client" do
    test "'d' asks first rather than removing", %{model: model} do
      model = Model.handle_key(model, {:char, ?d})

      assert model.confirm_remove == "acme"
      assert {:warning, message} = model.flash
      assert message =~ "press d again"
      # Nothing gone yet.
      assert length(Clients.list()) == 2
    end

    test "a second 'd' carries it out", %{model: model} do
      model = model |> Model.handle_key({:char, ?d}) |> Model.handle_key({:char, ?d})

      assert Enum.map(Clients.list(), & &1.id) == ["beta"]
      assert model.confirm_remove == nil
      assert {:ok, message} = model.flash
      assert message =~ "removed"
    end

    test "any other key cancels the pending removal", %{model: model} do
      model = model |> Model.handle_key({:char, ?d}) |> Model.handle_key({:char, ?j})

      assert model.confirm_remove == nil
      assert length(Clients.list()) == 2
    end

    test "leaving the screen cancels it too", %{model: model} do
      model = model |> Model.handle_key({:char, ?d}) |> Model.handle_key({:char, ?a})

      assert model.confirm_remove == nil
      assert length(Clients.list()) == 2
    end
  end

  describe "pausing a client" do
    test "'p' pauses it, and it stops being polled for", %{model: model} do
      model = Model.handle_key(model, {:char, ?p})

      refute Clients.get("acme").active
      assert Enum.map(Clients.active(), & &1.id) == ["beta"]
      assert {:ok, message} = model.flash
      assert message =~ "paused"
    end

    test "'p' again resumes it", %{model: model} do
      model = model |> Model.handle_key({:char, ?p}) |> Model.handle_key({:char, ?p})

      assert Clients.get("acme").active
      assert {:ok, message} = model.flash
      assert message =~ "resumed"
    end
  end

  describe "choosing which client to view" do
    test "'s' switches the dashboard to the highlighted one", %{model: model} do
      model = model |> Model.handle_key({:char, ?j}) |> Model.handle_key({:char, ?s})

      assert model.client_id == "beta"
      assert {:ok, message} = model.flash
      assert message =~ "viewing"
    end
  end

  describe "an empty book of clients" do
    setup do
      set_clients([])
      {:ok, model: Model.new() |> Model.select_tab(:config)}
    end

    test "the screen still opens", %{model: model} do
      assert model.tab == :config
      assert model.clients == []
    end

    test "editing says there is nothing to edit yet", %{model: model} do
      model = Model.handle_key(model, {:char, ?e})

      assert {:error, message} = model.flash
      assert message =~ "press + to add"
    end

    test "adding still works", %{model: model} do
      _model =
        model
        |> Model.handle_key({:char, ?+})
        |> type("First Client")
        |> Model.handle_key({:key, :enter})

      assert Enum.map(Clients.list(), & &1.id) == ["first-client"]
    end
  end

  # Walks the field cursor onto `field` with the same key the operator
  # would use, rather than reaching into the model.
  defp to_field(model, field) do
    steps = Enum.find_index(Model.config_fields(), &(&1 == field))
    Enum.reduce(1..steps//1, model, fn _step, acc -> Model.handle_key(acc, {:char, ?l}) end)
  end

  defp type(model, text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(model, fn char, acc -> Model.handle_key(acc, {:char, char}) end)
  end

  defp clear_buffer(model) do
    Enum.reduce(1..String.length(model.buffer)//1, model, fn _i, acc ->
      Model.handle_key(acc, {:key, :backspace})
    end)
  end
end
