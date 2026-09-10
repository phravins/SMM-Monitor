defmodule SmmMonitor.ClientsTest do
  @moduledoc """
  Managing the book of clients: adding, editing, pausing and removing.

  These drive the application's own `Clients` process, which is what the
  config screen and the fetchers both talk to.
  """

  use SmmMonitor.ClientCase, async: false

  describe "add/2" do
    test "adds a client and gives it a readable id" do
      set_clients([])

      assert {:ok, client} = Clients.add(%{name: "Acme Corp", keywords: "acme, acme corp"})

      assert client.id == "acme-corp"
      assert client.name == "Acme Corp"
      assert client.keywords == ["acme", "acme corp"]
      assert client.active
      assert %DateTime{} = client.created_at
    end

    test "accepts comma-separated terms as typed into the config screen" do
      set_clients([])

      {:ok, client} =
        Clients.add(%{name: "Acme", keywords: " acme , acme corp ", subreddits: "saas, startups"})

      assert client.keywords == ["acme", "acme corp"]
      assert client.subreddits == ["saas", "startups"]
    end

    test "appears in the list straight away" do
      set_clients([])
      {:ok, client} = Clients.add(%{name: "Acme", keywords: "acme"})

      assert Enum.map(Clients.list(), & &1.id) == [client.id]
      assert Clients.get(client.id).name == "Acme"
    end

    test "a second client with the same name gets its own id" do
      # Two clients called Acme is the operator's business, not something
      # to refuse — but they still need distinct ids.
      set_clients([])
      {:ok, first} = Clients.add(%{name: "Acme", keywords: "acme"})
      {:ok, second} = Clients.add(%{name: "Acme", keywords: "acme uk"})

      assert first.id == "acme"
      assert second.id == "acme-2"
      assert length(Clients.list()) == 2
    end

    test "a client with no name is refused" do
      set_clients([])

      assert {:error, :missing_name} = Clients.add(%{name: "   ", keywords: "acme"})
      assert Clients.list() == []
    end

    test "a client with no brand terms is refused" do
      # It would be polled for on every platform and match nothing — a
      # silent no-op that looks like a working client.
      set_clients([])

      assert {:error, :no_keywords} = Clients.add(%{name: "Acme", keywords: ""})
      assert Clients.list() == []
    end

    test "a name too long for the dashboard is refused" do
      set_clients([])
      long = String.duplicate("a", 61)

      assert {:error, :name_too_long} = Clients.add(%{name: long, keywords: "acme"})
    end

    test "a name with no ascii still produces a usable id" do
      set_clients([])

      assert {:ok, client} = Clients.add(%{name: "日本のブランド", keywords: "brand"})
      assert client.id != ""
      assert Clients.get(client.id)
    end
  end

  describe "update/3" do
    setup do
      set_clients([])
      {:ok, client} = Clients.add(%{name: "Acme", keywords: "acme", subreddits: "saas"})
      {:ok, client: client}
    end

    test "changes brand terms", %{client: client} do
      assert {:ok, updated} = Clients.update(client.id, %{keywords: "acme, acme corp"})

      assert updated.keywords == ["acme", "acme corp"]
      assert Clients.get(client.id).keywords == ["acme", "acme corp"]
    end

    test "changes subreddits, and empty means all of Reddit", %{client: client} do
      assert {:ok, updated} = Clients.update(client.id, %{subreddits: ""})
      assert updated.subreddits == []
    end

    test "renaming keeps the id, and so keeps the history", %{client: client} do
      # Mentions are keyed on the id. If a rename changed it, renaming a
      # client would orphan everything ever collected for them.
      assert {:ok, updated} = Clients.update(client.id, %{name: "Acme Corporation"})

      assert updated.id == client.id
      assert updated.name == "Acme Corporation"
    end

    test "keeps fields that weren't part of the update", %{client: client} do
      {:ok, updated} = Clients.update(client.id, %{name: "Renamed"})

      assert updated.keywords == client.keywords
      assert updated.subreddits == client.subreddits
      assert updated.created_at == client.created_at
    end

    test "refuses an update that would leave no brand terms", %{client: client} do
      assert {:error, :no_keywords} = Clients.update(client.id, %{keywords: "  "})
      assert Clients.get(client.id).keywords == ["acme"]
    end

    test "an unknown client is reported, not created" do
      assert {:error, :not_found} = Clients.update("nobody", %{name: "Ghost"})
    end
  end

  describe "pausing" do
    setup do
      set_clients([])
      {:ok, client} = Clients.add(%{name: "Acme", keywords: "acme"})
      {:ok, client: client}
    end

    test "a paused client drops out of the polling list", %{client: client} do
      assert Enum.map(Clients.active(), & &1.id) == [client.id]

      {:ok, paused} = Clients.set_active(client.id, false)

      refute paused.active
      assert Clients.active() == []
    end

    test "but keeps its place in the full list", %{client: client} do
      # Pausing is the non-destructive option: the history stays, and the
      # config screen still shows the row.
      Clients.set_active(client.id, false)

      assert Enum.map(Clients.list(), & &1.id) == [client.id]
    end

    test "and can be resumed", %{client: client} do
      Clients.set_active(client.id, false)
      {:ok, resumed} = Clients.set_active(client.id, true)

      assert resumed.active
      assert Enum.map(Clients.active(), & &1.id) == [client.id]
    end
  end

  describe "remove/2" do
    test "takes the client out of the list" do
      set_clients([])
      {:ok, client} = Clients.add(%{name: "Acme", keywords: "acme"})
      {:ok, _other} = Clients.add(%{name: "Beta", keywords: "beta"})

      assert {:ok, _deleted} = Clients.remove(client.id)

      assert Enum.map(Clients.list(), & &1.id) == ["beta"]
      assert Clients.get(client.id) == nil
    end

    test "an unknown client is reported rather than silently succeeding" do
      set_clients([])

      assert {:error, :not_found} = Clients.remove("nobody")
    end
  end

  describe "default_id/1" do
    test "is the first active client" do
      set_clients(["Acme", "Beta"])

      assert Clients.default_id() == "acme"
    end

    test "skips paused clients, since they collect nothing" do
      [acme, _beta] = set_clients(["Acme", "Beta"])
      Clients.replace([%{acme | active: false} | tl(Clients.list())])

      assert Clients.default_id() == "beta"
    end

    test "falls back to a paused client rather than to nothing" do
      [acme] = set_clients(["Acme"])
      Clients.replace([%{acme | active: false}])

      assert Clients.default_id() == "acme"
    end

    test "with no clients at all, names the holding client" do
      set_clients([])

      assert Clients.default_id() == SmmMonitor.Mention.default_client_id()
    end
  end

  describe "what reaches the database" do
    test "an added client is written, not just remembered" do
      set_clients([])
      {:ok, client} = Clients.add(%{name: "Acme", keywords: "acme, acme corp"})

      assert {:ok, stored} = SmmMonitor.Clients.Store.load()
      stored = Enum.find(stored, &(&1.id == client.id))

      assert stored.name == "Acme"
      assert stored.keywords == ["acme", "acme corp"]
    end

    test "an edit replaces the stored row rather than adding one" do
      set_clients([])
      {:ok, client} = Clients.add(%{name: "Acme", keywords: "acme"})
      {:ok, _updated} = Clients.update(client.id, %{keywords: "acme, acme corp"})

      {:ok, stored} = SmmMonitor.Clients.Store.load()
      matching = Enum.filter(stored, &(&1.id == client.id))

      assert [%{keywords: ["acme", "acme corp"]}] = matching
    end

    test "removing a client takes its mentions with it" do
      # A client row with no mentions, or mentions with no client, are
      # both states nothing else in the app knows how to render.
      set_clients([])
      {:ok, client} = Clients.add(%{name: "Acme", keywords: "acme"})

      mentions =
        for i <- 1..3 do
          SmmMonitor.Mention.new(%{
            id: "m#{i}",
            platform: :reddit,
            client_id: client.id,
            author: "u/x",
            text: "acme is great",
            timestamp: DateTime.utc_now()
          })
        end

      {:ok, 3} = SmmMonitor.Persistence.store(mentions)
      assert SmmMonitor.Persistence.count(:reddit, client: client.id) == 3

      assert {:ok, 3} = Clients.remove(client.id)

      assert SmmMonitor.Persistence.count(:reddit, client: client.id) == 0
      {:ok, stored} = SmmMonitor.Clients.Store.load()
      refute Enum.any?(stored, &(&1.id == client.id))
    end

    test "another client's mentions are left alone" do
      set_clients([])
      {:ok, acme} = Clients.add(%{name: "Acme", keywords: "acme"})
      {:ok, beta} = Clients.add(%{name: "Beta", keywords: "beta"})

      for client <- [acme, beta] do
        SmmMonitor.Persistence.store([
          SmmMonitor.Mention.new(%{
            id: "shared-post",
            platform: :reddit,
            client_id: client.id,
            author: "u/x",
            text: "acme and beta",
            timestamp: DateTime.utc_now()
          })
        ])
      end

      assert {:ok, 1} = Clients.remove(acme.id)

      assert SmmMonitor.Persistence.count(:reddit, client: beta.id) == 1
    end
  end

  describe "the seed and the migration have to agree" do
    test "a stored client list is used as it is, never re-seeded" do
      # This is the coupling that broke once: the migration used to write
      # a stub client row, `init` found the table non-empty, skipped the
      # seed, and the upgrade came up with an empty keyword list —
      # monitoring nothing. The migration now leaves the table empty and
      # lets the seed fill it in, which only works while this holds.
      set_clients([])
      {:ok, stored} = Clients.add(%{name: "Already Here", keywords: "existing"})

      {:ok, loaded} = SmmMonitor.Clients.Store.load()
      found = Enum.find(loaded, &(&1.id == stored.id))

      # Loaded straight back with its own terms — not replaced by a
      # seeded stub, and not left with an empty keyword list.
      assert found.name == "Already Here"
      assert found.keywords == ["existing"]
    end

    test "the seed's client uses the same id the migration backfills to" do
      # If these two disagreed, every mention collected before the
      # upgrade would sit in a second, invisible client.
      [seeded] = SmmMonitor.Clients.Seed.build(keywords: ["realoffice"])

      assert seeded.id == SmmMonitor.Mention.default_client_id()
    end
  end

  describe "the list as fetchers see it" do
    test "active/1 is what gets polled, list/1 is what gets displayed" do
      [acme, beta] = set_clients(["Acme", "Beta"])
      Clients.replace([acme, %{beta | active: false}])

      assert Enum.map(Clients.active(), & &1.id) == ["acme"]
      assert Enum.map(Clients.list(), & &1.id) == ["acme", "beta"]
    end

    test "ids/1 covers every client, for the boot-time history restore" do
      set_clients(["Acme", "Beta"])

      assert Clients.ids() == ["acme", "beta"]
    end
  end
end
