defmodule SmmMonitor.Fetchers.Threads.TokenTest do
  @moduledoc """
  Token renewal and the private token file, with a stub transport and a
  fixed clock.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias SmmMonitor.Fetchers.Threads
  alias SmmMonitor.Fetchers.Threads.{State, Token}
  alias SmmMonitor.ThreadsStub

  @moduletag :tmp_dir

  @seed "THAAseedtoken0000000000000000"
  @renewed "THAArenewedtoken0000000000"
  @hour :timer.hours(1)
  @day :timer.hours(24)
  @t0 DateTime.to_unix(~U[2026-11-12 12:00:00Z], :millisecond)

  setup %{tmp_dir: dir} do
    {:ok, path: Path.join(dir, "threads_token.json")}
  end

  describe "first use" do
    test "writes a private file with the seed's hash and no token", %{path: path} do
      state = Token.current(State.new(), @seed, settings(path), @t0)

      assert state.token == @seed
      assert state.first_seen_at == @t0
      assert state.next_refresh_at == @t0 + @day

      contents = File.read!(path)
      refute contents =~ @seed
      file = Jason.decode!(contents)
      assert file["seed_sha256"] == Token.hash(@seed)
      assert file["first_seen_at"] == @t0
      refute Map.has_key?(file, "access_token")
      assert mode(path) == 0o600
    end

    test "doesn't renew a token younger than a day", %{path: path} do
      ThreadsStub.install(%{"/refresh_access_token" => ThreadsStub.renewed()})

      state = Token.current(State.new(), @seed, settings(path), @t0)
      state = Token.current(state, @seed, settings(path), @t0 + 23 * @hour)

      assert state.token == @seed
      refute ThreadsStub.requested?("/refresh_access_token")
    end

    test "the day's wait survives a restart", %{path: path} do
      ThreadsStub.install(%{"/refresh_access_token" => ThreadsStub.renewed()})

      Token.current(State.new(), @seed, settings(path), @t0)
      state = Token.current(State.new(), @seed, settings(path), @t0 + 12 * @hour)

      assert state.first_seen_at == @t0
      assert state.next_refresh_at == @t0 + @day
      refute ThreadsStub.requested?("/refresh_access_token")
    end
  end

  describe "renewal" do
    test "after a day, swaps the token and saves the new one", %{path: path} do
      ThreadsStub.install(%{"/refresh_access_token" => ThreadsStub.renewed(@renewed, 5_184_000)})

      state = Token.current(State.new(), @seed, settings(path), @t0)
      now = @t0 + @day
      state = Token.current(state, @seed, settings(path), now)

      assert state.token == @renewed
      assert state.refreshed_at == now
      assert state.expires_at == now + 5_184_000 * 1_000
      assert state.next_refresh_at == now + 7 * @day

      params = ThreadsStub.query_params("/refresh_access_token")
      assert params["grant_type"] == "th_refresh_token"
      assert params["access_token"] == @seed

      file = path |> File.read!() |> Jason.decode!()
      assert file["access_token"] == @renewed
      assert file["seed_sha256"] == Token.hash(@seed)
      assert mode(path) == 0o600
    end

    test "the renewed token is used by the next request", %{path: path} do
      ThreadsStub.install(%{
        "/refresh_access_token" => ThreadsStub.renewed(@renewed),
        "/keyword_search" => ThreadsStub.empty()
      })

      state = Token.current(State.new(), @seed, settings(path), @t0)

      {:ok, [], _state} = Threads.fetch(context(path, @t0 + @day), state)

      assert ThreadsStub.query_params("/keyword_search")["access_token"] == @renewed
    end

    test "renews again within 14 days of expiry", %{path: path} do
      ThreadsStub.install(%{"/refresh_access_token" => ThreadsStub.renewed(@renewed, 10 * 86_400)})

      state = Token.current(State.new(), @seed, settings(path), @t0)
      now = @t0 + @day
      state = Token.current(state, @seed, settings(path), now)

      # Expires in 10 days, already inside the 14-day margin: next poll.
      assert state.next_refresh_at == now + 10 * @day - 14 * @day
    end

    test "a failure is retried a day later and doesn't stop the poll", %{path: path} do
      ThreadsStub.install(%{
        "/refresh_access_token" => ThreadsStub.error(400, 1, "An unknown error occurred"),
        "/keyword_search" => ThreadsStub.empty()
      })

      state = Token.current(State.new(), @seed, settings(path), @t0)
      now = @t0 + @day

      {result, log} = with_log(fn -> Threads.fetch(context(path, now), state) end)

      assert {:ok, [], state} = result
      assert state.token == @seed
      assert state.next_refresh_at == now + @day
      assert log =~ "couldn't renew the access token"
      assert log =~ "An unknown error occurred"
      refute log =~ @seed
      assert ThreadsStub.query_params("/keyword_search")["access_token"] == @seed
    end

    test "an answer without a usable token is a failure", %{path: path} do
      ThreadsStub.install(%{
        "/refresh_access_token" => ThreadsStub.ok(%{"access_token" => "short"})
      })

      state = Token.current(State.new(), @seed, settings(path), @t0)
      {state, log} = with_log(fn -> Token.current(state, @seed, settings(path), @t0 + @day) end)

      assert state.token == @seed
      assert log =~ "no usable token"
    end

    test "an expired token isn't sent for renewal", %{path: path} do
      ThreadsStub.install(%{"/refresh_access_token" => ThreadsStub.renewed()})
      state = %{loaded() | expires_at: @t0 - 1, next_refresh_at: @t0 - @day}

      state = Token.current(state, @seed, settings(path), @t0)

      assert state.token == @renewed
      refute ThreadsStub.requested?("/refresh_access_token")
    end
  end

  describe "the token file" do
    test "a renewed token is picked up after a restart", %{path: path} do
      write_file(path, %{
        "seed_sha256" => Token.hash(@seed),
        "access_token" => @renewed,
        "refreshed_at" => @t0 - @day,
        "expires_at" => @t0 + 59 * @day
      })

      state = Token.current(State.new(), @seed, settings(path), @t0)

      assert state.token == @renewed
      assert state.next_refresh_at == @t0 + 6 * @day
    end

    test "a new env token replaces the file", %{path: path} do
      write_file(path, %{
        "seed_sha256" => Token.hash("THAAsomeoldtoken00000000000"),
        "access_token" => @renewed,
        "refreshed_at" => @t0 - @day,
        "expires_at" => @t0 + 59 * @day
      })

      state = Token.current(State.new(), @seed, settings(path), @t0)

      assert state.token == @seed
      file = path |> File.read!() |> Jason.decode!()
      assert file["seed_sha256"] == Token.hash(@seed)
      refute Map.has_key?(file, "access_token")
    end

    test "changing the env token while running switches to it", %{path: path} do
      state = Token.current(State.new(), @seed, settings(path), @t0)
      other = "THAAanothertoken000000000000"

      state = Token.current(state, other, settings(path), @t0 + @hour)

      assert state.token == other
      assert state.first_seen_at == @t0 + @hour
    end

    test "a corrupt file is ignored", %{path: path} do
      File.write!(path, "{not json")

      state = Token.current(State.new(), @seed, settings(path), @t0)

      assert state.token == @seed
      assert state.first_seen_at == @t0
    end

    test "a file with a malformed token falls back to the env token", %{path: path} do
      write_file(path, %{
        "seed_sha256" => Token.hash(@seed),
        "first_seen_at" => @t0,
        "access_token" => "has spaces in it and is bad",
        "refreshed_at" => @t0 - @day,
        "expires_at" => @t0 + 59 * @day
      })

      state = Token.current(State.new(), @seed, settings(path), @t0)

      assert state.token == @seed
    end

    test "no file at all when it is turned off" do
      state = Token.current(State.new(), @seed, [token_file: nil], @t0)

      assert state.token == @seed
      assert Token.path(token_file: nil) == nil
    end
  end

  describe "expiry warning" do
    test "is logged inside the last week, at most hourly", %{path: path} do
      state = %{loaded() | expires_at: @t0 + 3 * @day, next_refresh_at: @t0 + @day}

      {state, log} = with_log(fn -> Token.current(state, @seed, settings(path), @t0) end)
      assert log =~ "expires in 3.0 days"
      refute log =~ @renewed

      {state, log} =
        with_log(fn -> Token.current(state, @seed, settings(path), @t0 + 30 * 60_000) end)

      assert log == ""

      {_state, log} = with_log(fn -> Token.current(state, @seed, settings(path), @t0 + @hour) end)
      assert log =~ "expires in"
    end

    test "isn't logged with more than a week left", %{path: path} do
      state = %{loaded() | expires_at: @t0 + 8 * @day, next_refresh_at: @t0 + @day}

      {_state, log} = with_log(fn -> Token.current(state, @seed, settings(path), @t0) end)

      assert log == ""
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp settings(path), do: [token_file: path, req_options: ThreadsStub.req_options()]

  # A state that has already loaded the seed and holds a renewed token.
  defp loaded() do
    %{
      State.new()
      | token: @renewed,
        seed_hash: Token.hash(@seed),
        first_seen_at: @t0 - 30 * @day,
        refreshed_at: @t0 - 2 * @day
    }
  end

  defp write_file(path, fields) do
    File.write!(
      path,
      Jason.encode!(Map.merge(%{"version" => 1, "first_seen_at" => @t0 - 30 * @day}, fields))
    )
  end

  defp context(path, now) do
    %{
      platform: :threads,
      client: %SmmMonitor.Client{id: "acme", name: "Acme", keywords: ["acme"]},
      keywords: ["acme"],
      subreddits: [],
      credentials: [access_token: @seed],
      opts: [sources: [:search], clock: fn -> now end] ++ settings(path),
      poll_count: 1,
      interval_ms: :timer.minutes(5)
    }
  end

  defp mode(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    Bitwise.band(mode, 0o777)
  end
end
