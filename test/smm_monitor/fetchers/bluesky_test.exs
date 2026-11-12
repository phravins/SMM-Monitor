defmodule SmmMonitor.Fetchers.BlueskyTest do
  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.Fetchers.{Bluesky, StreamWorker}
  alias SmmMonitor.{BlueskyStub, Monitor}

  @did "did:plc:eygmaihciaxprqvxpfvl6flk"

  # Recorded from Jetstream, with the text changed.
  @commit %{
    "did" => @did,
    "time_us" => 1_725_911_162_329_308,
    "kind" => "commit",
    "commit" => %{
      "rev" => "3l3qo2vutsw2b",
      "operation" => "create",
      "collection" => "app.bsky.feed.post",
      "rkey" => "3l3qo2vuowo2b",
      "record" => %{
        "$type" => "app.bsky.feed.post",
        "createdAt" => "2024-09-09T19:46:02.102Z",
        "langs" => ["en"],
        "text" => "Trying the new Acme kettle"
      },
      "cid" => "bafyreidwaivazkwu67xztlmuobx35hs2lnfh3kolmgfmucldvhd3sgzcqi"
    }
  }

  setup do
    settings = Application.get_env(:smm_monitor, Bluesky)
    on_exit(fn -> restore(Bluesky, settings) end)
    Application.put_env(:smm_monitor, Bluesky, enabled: true, cursor_file: nil)
    :ok
  end

  describe "handle_message/2" do
    test "turns a new post into a mention with a bsky.app link" do
      assert {:ok, [post], [], state} = Bluesky.handle_message(@commit, %Bluesky.State{})

      assert post == %{
               id: @did <> "/3l3qo2vuowo2b",
               platform: :bluesky,
               author: @did,
               text: "Trying the new Acme kettle",
               url: "https://bsky.app/profile/#{@did}/post/3l3qo2vuowo2b",
               # When Jetstream saw it, in milliseconds.
               timestamp: 1_725_911_162_329
             }

      assert state.cursor == 1_725_911_162_329_308
    end

    test "the post makes a valid mention" do
      {:ok, [post], [], _state} = Bluesky.handle_message(@commit, %Bluesky.State{})
      mention = SmmMonitor.Mention.new(Map.put(post, :client_id, "acme"))

      assert mention.platform == :bluesky
      assert mention.url =~ "https://bsky.app/profile/"
    end

    test "ignores deletes, edits and other collections, but still moves the cursor" do
      for change <- [
            put_in(@commit, ["commit", "operation"], "delete"),
            put_in(@commit, ["commit", "operation"], "update"),
            put_in(@commit, ["commit", "collection"], "app.bsky.feed.like"),
            Map.put(@commit, "kind", "account")
          ] do
        assert {:ok, [], [], state} = Bluesky.handle_message(change, %Bluesky.State{})
        assert state.cursor == @commit["time_us"]
      end
    end

    test "never goes backwards on an older message" do
      state = %Bluesky.State{cursor: @commit["time_us"] + 10}
      {:ok, _posts, [], state} = Bluesky.handle_message(@commit, state)
      assert state.cursor == @commit["time_us"] + 10
    end

    test "drops a post whose ids could be used to build a misleading link" do
      for {did, rkey} <- [
            {"did:plc:abc/../../evil", "3l3qo2vuowo2b"},
            {"https://evil.example", "3l3qo2vuowo2b"},
            {@did, "x/../../phish"},
            {@did, ""}
          ] do
        message =
          @commit
          |> Map.put("did", did)
          |> put_in(["commit", "rkey"], rkey)

        assert {:ok, [], [], _state} = Bluesky.handle_message(message, %Bluesky.State{}),
               "expected #{inspect({did, rkey})} to be dropped"
      end
    end

    test "survives a message with the wrong shape" do
      for message <- [%{}, %{"kind" => "commit"}, %{"kind" => "commit", "commit" => nil}, []] do
        assert {:ok, [], [], %Bluesky.State{}} = Bluesky.handle_message(message, %Bluesky.State{})
      end
    end

    test "remembers handles from identity events, lowercased and checked" do
      events = [
        %{
          "kind" => "identity",
          "identity" => %{"did" => "did:plc:a", "handle" => "Alice.bsky.social"}
        },
        %{
          "kind" => "identity",
          "identity" => %{"did" => "did:plc:b", "handle" => "handle.invalid"}
        },
        %{
          "kind" => "identity",
          "identity" => %{"did" => "did:plc:c", "handle" => "bad handle\e[31m"}
        }
      ]

      state =
        Enum.reduce(events, %Bluesky.State{}, fn event, state ->
          {:ok, [], [], state} = Bluesky.handle_message(event, state)
          state
        end)

      assert state.handles == %{"did:plc:a" => "alice.bsky.social"}
    end
  end

  describe "url/2" do
    test "asks only for posts" do
      {:ok, url} = Bluesky.url(%{}, %Bluesky.State{})
      uri = URI.parse(url)

      assert uri.scheme == "wss"
      assert uri.host == "jetstream2.us-east.bsky.network"
      assert URI.decode_query(uri.query) == %{"wantedCollections" => "app.bsky.feed.post"}
    end

    test "resumes from a few seconds before the saved position" do
      cursor = System.os_time(:microsecond) - 60_000_000
      {:ok, url} = Bluesky.url(%{}, %Bluesky.State{cursor: cursor})

      assert query(url)["cursor"] == Integer.to_string(cursor - 5_000_000)
    end

    test "never rewinds more than an hour" do
      {:ok, url} = Bluesky.url(%{}, %Bluesky.State{cursor: 1_000})
      resume = String.to_integer(query(url)["cursor"])
      an_hour_ago = System.os_time(:microsecond) - 3_600_000_000

      assert_in_delta resume, an_hour_ago, 5_000_000
    end

    test "uses a configured instance and keeps its own query" do
      Application.put_env(:smm_monitor, Bluesky,
        jetstream_url: "wss://jetstream.example.org/subscribe?compress=false"
      )

      {:ok, url} = Bluesky.url(%{}, %Bluesky.State{})

      assert URI.parse(url).host == "jetstream.example.org"
      assert query(url) == %{"compress" => "false", "wantedCollections" => "app.bsky.feed.post"}
    end

    test "refuses an unencrypted instance" do
      Application.put_env(:smm_monitor, Bluesky, jetstream_url: "ws://jetstream.example.org/")
      assert Bluesky.url(%{}, %Bluesky.State{}) == {:error, {:jetstream_url, :insecure_url}}
    end
  end

  describe "ready?/1" do
    test "follows SMM_BLUESKY_ENABLED" do
      assert Bluesky.ready?(%{})
      Application.put_env(:smm_monitor, Bluesky, enabled: false)
      refute Bluesky.ready?(%{})
      Application.put_env(:smm_monitor, Bluesky, [])
      refute Bluesky.ready?(%{})
    end
  end

  describe "the cursor file" do
    @describetag :tmp_dir

    test "is saved privately and read back on start", %{tmp_dir: dir} do
      file = Path.join(dir, "state/bluesky.cursor")
      Application.put_env(:smm_monitor, Bluesky, cursor_file: file)

      state = Bluesky.init_state(%{})
      assert state.cursor == nil

      {:ok, _posts, [], state} = Bluesky.handle_message(@commit, state)
      state = Bluesky.tick(state)

      assert File.read!(file) == Integer.to_string(@commit["time_us"])
      assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
      assert state.saved_cursor == @commit["time_us"]
      refute File.exists?(file <> ".tmp")

      assert Bluesky.init_state(%{}).cursor == @commit["time_us"]
    end

    test "is saved when the connection ends", %{tmp_dir: dir} do
      file = Path.join(dir, "bluesky.cursor")
      state = %Bluesky.State{cursor_file: file, cursor: 42}

      assert Bluesky.on_disconnect(state).saved_cursor == 42
      assert File.read!(file) == "42"
    end

    test "is not rewritten more than every 10 seconds", %{tmp_dir: dir} do
      file = Path.join(dir, "bluesky.cursor")
      state = Bluesky.tick(%Bluesky.State{cursor_file: file, cursor: 1})
      assert File.read!(file) == "1"

      state = Bluesky.tick(%{state | cursor: 2})
      assert File.read!(file) == "1"
      assert state.cursor == 2
    end

    test "a damaged file means starting from now", %{tmp_dir: dir} do
      file = Path.join(dir, "bluesky.cursor")
      Application.put_env(:smm_monitor, Bluesky, cursor_file: file)

      for contents <- ["", "abc", "-5", "12abc", "0"] do
        File.write!(file, contents)
        assert Bluesky.init_state(%{}).cursor == nil, "for #{inspect(contents)}"
      end
    end
  end

  describe "enrich/2" do
    test "shows authors by handle, looked up in one batch" do
      stub(fn request ->
        send(self(), {:lookup, URI.to_string(request.url)})

        profiles = [
          %{"did" => @did, "handle" => "Acme.Example"},
          %{"did" => "did:plc:other", "handle" => "other.bsky.social"}
        ]

        {200, %{"profiles" => profiles}}
      end)

      posts = [post(@did), post("did:plc:other"), post(@did)]
      {named, state} = Bluesky.enrich(posts, %Bluesky.State{})

      assert Enum.map(named, & &1.author) == [
               "@acme.example",
               "@other.bsky.social",
               "@acme.example"
             ]

      assert_received {:lookup, url}
      assert url =~ "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfiles?"
      assert url |> URI.parse() |> Map.get(:query) |> String.split("&") |> length() == 2
      refute_received {:lookup, _url}

      # Known now, so the next batch asks for nothing.
      {_named, _state} = Bluesky.enrich([post(@did)], state)
      refute_received {:lookup, _url}
    end

    test "asks for at most 25 at a time and 50 per batch" do
      stub(fn request ->
        send(self(), {:lookup, request.url.query})
        {200, %{"profiles" => []}}
      end)

      posts = for n <- 1..80, do: post("did:plc:user#{n}")
      Bluesky.enrich(posts, %Bluesky.State{})

      assert_received {:lookup, first}
      assert_received {:lookup, second}
      refute_received {:lookup, _third}
      assert length(String.split(first, "&")) == 25
      assert length(String.split(second, "&")) == 25
    end

    test "keeps the DID when the lookup fails" do
      stub(fn _request -> {503, ""} end)

      {[named], state} = Bluesky.enrich([post(@did)], %Bluesky.State{})
      assert named.author == @did
      assert state.handles == %{}
    end

    test "can be switched off" do
      BlueskyStub.install(fn _request -> flunk("no lookup expected") end)

      Application.put_env(:smm_monitor, Bluesky,
        resolve_handles: false,
        req_options: BlueskyStub.req_options()
      )

      assert {[%{author: @did}], _state} = Bluesky.enrich([post(@did)], %Bluesky.State{})
    end
  end

  describe "demo mode" do
    @describetag :tmp_dir

    test "stores fixture mentions without connecting", %{tmp_dir: dir} do
      Application.put_env(:smm_monitor, Bluesky, cursor_file: Path.join(dir, "bluesky.cursor"))
      mocks = Application.get_env(:smm_monitor, :mock_platforms)
      Application.put_env(:smm_monitor, :mock_platforms, bluesky: true)
      on_exit(fn -> restore(:mock_platforms, mocks) end)

      Monitor.reset()
      set_clients(["Acme"])
      start_supervised!({StreamWorker, module: Bluesky})
      StreamWorker.poll_now(:bluesky)

      assert eventually(fn -> Monitor.recent(:bluesky, 100, "acme") != [] end)

      status = StreamWorker.status(:bluesky)
      assert status.mode == :mock
      assert status.connection == :idle
      assert status.display_name == "Bluesky"
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp post(did) do
    %{id: did <> "/x", platform: :bluesky, author: did, text: "acme", url: nil, timestamp: 0}
  end

  defp query(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  # Routes the profile lookup to `fun`, which returns {status, body}.
  defp stub(fun) do
    BlueskyStub.install(fun)
    Application.put_env(:smm_monitor, Bluesky, req_options: BlueskyStub.req_options())
  end

  defp restore(key, nil), do: Application.delete_env(:smm_monitor, key)
  defp restore(key, value), do: Application.put_env(:smm_monitor, key, value)

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(30)
      eventually(check, attempts - 1)
    end
  end
end
