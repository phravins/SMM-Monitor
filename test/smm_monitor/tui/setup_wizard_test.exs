defmodule SmmMonitor.TUI.SetupWizardTest do
  @moduledoc """
  The first thing anybody sees after downloading the binary.

  Two things have to be true and stay true: somebody with no API keys
  can get to a working dashboard, and nobody is ever asked these
  questions twice.
  """

  # Not async: the wizard writes a settings file named by an environment
  # variable, and applies credentials to the application environment.
  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.Setup.Settings
  alias SmmMonitor.TUI.{Model, Setup}

  setup do
    file = Path.join(System.tmp_dir!(), "smm-wizard-#{System.unique_integer([:positive])}.json")
    System.put_env("SMM_SETTINGS_FILE", file)

    credentials = Application.get_env(:smm_monitor, :credentials, [])
    mocks = Application.get_env(:smm_monitor, :mock_platforms, [])

    # The suite opts out of the wizard globally (see config/test.exs);
    # this is the one file that wants it.
    complete = Application.get_env(:smm_monitor, :setup_complete)
    Application.put_env(:smm_monitor, :setup_complete, false)

    on_exit(fn ->
      System.delete_env("SMM_SETTINGS_FILE")
      File.rm(file)
      Application.put_env(:smm_monitor, :credentials, credentials)
      Application.put_env(:smm_monitor, :mock_platforms, mocks)
      Application.put_env(:smm_monitor, :setup_complete, complete)
    end)

    # What a fresh install looks like: one client, created by the seed
    # under the id it reserves for "nobody has chosen a brand yet".
    set_clients([build_client("Real office", id: "unassigned")])

    %{settings: file}
  end

  describe "first launch" do
    test "opens on the wizard rather than the dashboard" do
      model = Model.new()

      assert Model.setup?(model)
      assert model.setup.step == :brand
    end

    test "asks four questions and then shows what it will do" do
      assert Setup.position(Setup.new()) == {1, 5}
      assert Setup.steps() == [:brand, :reddit_id, :reddit_secret, :youtube_key, :review]
    end

    test "never asks a read-only SSH viewer" do
      # The wizard writes API keys to the host's disk. A viewer who
      # cannot change the config cannot run setup either.
      refute Model.setup?(Model.new(%{read_only: true}))
    end

    test "does not ask again once it has run" do
      :ok = Settings.save(%{credentials: %{}})

      refute Model.setup?(Model.new())
    end
  end

  describe "typing" do
    test "every printable key goes into the answer, q included" do
      # No single-letter shortcuts on this screen, on purpose: a brand
      # called "Quill" has to be typeable, and `q` must not quit
      # halfway through setup.
      model = type(Model.new(), "Quill & Co")

      assert Setup.value(model.setup) == "Quill & Co"
      refute model.quit
    end

    test "backspace deletes the last character" do
      model = Model.new() |> type("acme") |> Model.handle_key({:key, :backspace})

      assert Setup.value(model.setup) == "acm"
    end

    test "an empty brand is refused, with a way out offered" do
      model = Model.handle_key(Model.new(), {:key, :enter})

      assert model.setup.step == :brand
      assert model.setup.error =~ "Esc"
    end

    test "a brand moves on to the credentials" do
      model = Model.new() |> type("Acme Corp") |> Model.handle_key({:key, :enter})

      assert model.setup.step == :reddit_id
    end
  end

  describe "skipping everything" do
    setup do
      model =
        Model.new()
        |> Model.handle_key({:key, :escape})
        |> Model.handle_key({:key, :enter})

      %{model: model}
    end

    test "lands on a working dashboard", %{model: model} do
      refute Model.setup?(model)
      assert model.tab == :all
      assert Model.current_client(model) != nil
    end

    test "says clearly that the mentions are demo data", %{model: model} do
      assert {:ok, message} = model.flash
      assert message =~ "demo data"
    end

    test "leaves every platform on demo data", %{} do
      assert Enum.all?(SmmMonitor.platforms(), &SmmMonitor.mock_platform?/1)
    end

    test "does not ask again on the next launch", %{} do
      refute Model.setup?(Model.new())
    end

    test "writes down that setup ran", %{settings: file} do
      assert {:ok, %{completed_at: %DateTime{}}} = Settings.load(file)
    end
  end

  describe "answering the brand question" do
    test "watches what was typed" do
      model = finish_with_brand("Acme Corp")

      assert Model.current_client(model).name == "Acme Corp"
      assert Model.current_client(model).keywords == ["Acme Corp"]
    end

    test "replaces the placeholder client rather than adding a second" do
      # A fresh install already has one client so the dashboard has
      # something to show. Two clients on a first run, one of them a
      # leftover, is a confusing way to start.
      model = finish_with_brand("Acme Corp")

      assert length(model.clients) == 1
    end

    test "takes the placeholder over even once mock data has arrived" do
      # By the time somebody has read the wizard, the mock fetchers have
      # collected a few mentions. That must not turn the placeholder
      # into a client worth keeping beside the real one.
      SmmMonitor.Persistence.store([mention(client_id: "unassigned")])

      model = finish_with_brand("Acme Corp")

      assert length(model.clients) == 1
      assert Model.current_client(model).name == "Acme Corp"
    end

    test "renames rather than deletes, so nothing collected is lost" do
      SmmMonitor.Persistence.store([mention(client_id: "unassigned")])

      model = finish_with_brand("Acme Corp")

      assert Model.current_client(model).id == "unassigned"
      assert SmmMonitor.Persistence.count() == 1
    end

    test "adds a second client beside one somebody chose themselves" do
      set_clients([build_client("Globex")])

      model = finish_with_brand("Acme Corp")

      assert length(model.clients) == 2
      assert Model.current_client(model).name == "Acme Corp"
    end
  end

  describe "answering the credential questions" do
    setup do
      Application.put_env(:smm_monitor, :credentials, [])
      Application.put_env(:smm_monitor, :mock_platforms, [])

      model =
        Model.new()
        |> type("Acme Corp")
        |> Model.handle_key({:key, :enter})
        |> type("reddit-id")
        |> Model.handle_key({:key, :enter})
        |> type("reddit-secret")
        |> Model.handle_key({:key, :enter})
        |> type("youtube-key")
        |> Model.handle_key({:key, :enter})
        |> Model.handle_key({:key, :enter})

      %{model: model}
    end

    test "saves them", %{settings: file} do
      assert {:ok, settings} = Settings.load(file)
      assert settings.credentials.reddit.client_id == "reddit-id"
      assert settings.credentials.reddit.client_secret == "reddit-secret"
      assert settings.credentials.youtube.api_key == "youtube-key"
    end

    test "uses them without a restart" do
      # The fetchers read credentials from the application environment on
      # every poll, so the next one picks these up.
      credentials = Application.get_env(:smm_monitor, :credentials)

      assert credentials[:reddit][:client_id] == "reddit-id"
      assert credentials[:youtube][:api_key] == "youtube-key"
    end

    test "takes those platforms off demo data, and only those" do
      refute SmmMonitor.mock_platform?(:reddit)
      refute SmmMonitor.mock_platform?(:youtube)
      assert SmmMonitor.mock_platform?(:twitter)
      assert SmmMonitor.mock_platform?(:instagram)
    end

    test "says which platforms are live", %{model: model} do
      assert {:ok, message} = model.flash
      assert message =~ "live"
      assert message =~ "reddit"
    end
  end

  describe "skipping only the credentials" do
    test "still watches the brand, still on demo data" do
      model =
        Model.new()
        |> type("Acme Corp")
        |> Model.handle_key({:key, :enter})
        |> Model.handle_key({:key, :escape})
        |> Model.handle_key({:key, :escape})
        |> Model.handle_key({:key, :escape})
        |> Model.handle_key({:key, :enter})

      refute Model.setup?(model)
      assert Model.current_client(model).name == "Acme Corp"
      assert elem(model.flash, 1) =~ "demo data"
    end

    test "a Reddit id with no secret is not treated as configured" do
      setup =
        Setup.new()
        |> feed("Acme")
        |> Setup.handle_key({:key, :enter})
        |> feed("only-an-id")
        |> Setup.handle_key({:key, :enter})
        |> Setup.handle_key({:key, :escape})

      assert Setup.credentials(setup) == %{}
      assert Setup.live_platforms(setup) == []
    end
  end

  describe "running it again later" do
    test "S on the clients screen reopens it" do
      :ok = Settings.save(%{credentials: %{}})

      model = Model.new() |> Model.select_tab(:config) |> Model.handle_key({:char, ?S})

      assert Model.setup?(model)
    end

    test "and a read-only viewer is refused" do
      :ok = Settings.save(%{credentials: %{}})

      model =
        Model.new(%{read_only: true}) |> Model.select_tab(:config) |> Model.handle_key({:char, ?S})

      refute Model.setup?(model)
      assert {:error, message} = model.flash
      assert message =~ "read-only"
    end

    test "lowercase s still switches to the highlighted client" do
      :ok = Settings.save(%{credentials: %{}})

      model = Model.new() |> Model.select_tab(:config) |> Model.handle_key({:char, ?s})

      refute Model.setup?(model)
    end
  end

  describe "the summary" do
    test "spells out that nothing is real when no keys were given" do
      lines = Setup.new() |> Setup.handle_key({:key, :escape}) |> Setup.summary()

      assert Enum.any?(lines, &(&1 =~ "DEMO DATA"))
      assert Enum.any?(lines, &(&1 =~ "not collected"))
    end

    test "names what will be live when keys were given" do
      lines =
        Setup.new()
        |> feed("Acme")
        |> Setup.handle_key({:key, :enter})
        |> feed("id")
        |> Setup.handle_key({:key, :enter})
        |> feed("secret")
        |> Setup.handle_key({:key, :enter})
        |> Setup.handle_key({:key, :escape})
        |> Setup.summary()

      assert Enum.any?(lines, &(&1 =~ "Live: Reddit"))
      assert Enum.any?(lines, &(&1 =~ "Watching: Acme"))
    end
  end

  # --- helpers --------------------------------------------------------------

  defp type(model, text) do
    Enum.reduce(String.to_charlist(text), model, &Model.handle_key(&2, {:char, &1}))
  end

  defp feed(setup, text) do
    Enum.reduce(String.to_charlist(text), setup, &Setup.handle_key(&2, {:char, &1}))
  end

  defp finish_with_brand(brand) do
    Model.new()
    |> type(brand)
    |> Model.handle_key({:key, :enter})
    |> Model.handle_key({:key, :escape})
    |> Model.handle_key({:key, :escape})
    |> Model.handle_key({:key, :escape})
    |> Model.handle_key({:key, :enter})
  end

  defp mention(overrides) do
    defaults = [
      id: "m-#{System.unique_integer([:positive])}",
      platform: :reddit,
      author: "u/tester",
      text: "a mention",
      url: "https://example.test/p",
      timestamp: DateTime.utc_now(),
      sentiment: :neutral,
      sentiment_value: 0.0,
      sentiment_score: 0
    ]

    struct!(SmmMonitor.Mention, Keyword.merge(defaults, overrides))
  end
end
