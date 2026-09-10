defmodule SmmMonitor.Fetchers.Reddit.AuthTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Reddit.Auth
  alias SmmMonitor.RedditStub

  @credentials [client_id: "id", client_secret: "secret", user_agent: "smm_monitor/test"]

  describe "valid?/2" do
    test "an empty cache is not valid" do
      refute Auth.valid?(Auth.new())
    end

    test "a token well before expiry is valid" do
      auth = %Auth{token: "t", expires_at: now() + :timer.hours(1)}
      assert Auth.valid?(auth)
    end

    test "a token inside the refresh margin is not valid" do
      # Refreshed early on purpose: a poll should never have to fail with a
      # 401 to discover the token expired.
      auth = %Auth{token: "t", expires_at: now() + :timer.minutes(2)}
      refute Auth.valid?(auth)
    end

    test "an expired token is not valid" do
      refute Auth.valid?(%Auth{token: "t", expires_at: now() - 1_000})
    end
  end

  describe "token/3" do
    test "fetches and caches a token" do
      RedditStub.install(token: RedditStub.token(3_600))

      assert {:ok, "stub-token", auth} =
               Auth.token(Auth.new(), @credentials, RedditStub.req_options())

      assert auth.token == "stub-token"
      assert auth.refreshes == 1
      assert Auth.valid?(auth)
      assert length(RedditStub.token_requests()) == 1
    end

    test "reuses a cached token instead of asking again" do
      RedditStub.install(token: RedditStub.token())

      {:ok, _token, auth} = Auth.token(Auth.new(), @credentials, RedditStub.req_options())
      {:ok, _token, auth} = Auth.token(auth, @credentials, RedditStub.req_options())

      assert auth.refreshes == 1
      assert length(RedditStub.token_requests()) == 1
    end

    test "fetches a new token once the cached one nears expiry" do
      # A one-second token is already inside the refresh margin.
      RedditStub.install(token: [RedditStub.token(1), RedditStub.token(3_600, "fresh")])

      {:ok, _token, auth} = Auth.token(Auth.new(), @credentials, RedditStub.req_options())
      {:ok, token, auth} = Auth.token(auth, @credentials, RedditStub.req_options())

      assert token == "fresh"
      assert auth.refreshes == 2
      assert length(RedditStub.token_requests()) == 2
    end

    test "reports missing credentials without making a request" do
      RedditStub.install([])

      assert {:error, :missing_credentials, _auth} =
               Auth.token(Auth.new(), [], RedditStub.req_options())

      assert RedditStub.requests() == []
    end

    test "treats a blank credential as missing" do
      RedditStub.install([])

      assert {:error, :missing_credentials, _auth} =
               Auth.token(
                 Auth.new(),
                 [client_id: "id", client_secret: "   "],
                 RedditStub.req_options()
               )
    end

    test "reports a bad id/secret pair distinctly" do
      # The most common setup mistake, so it gets its own reason rather than
      # a generic failure.
      RedditStub.install(token: RedditStub.error(401))

      assert {:error, :invalid_credentials, _auth} =
               Auth.token(Auth.new(), @credentials, RedditStub.req_options())
    end

    test "reports being rate limited on the token endpoint" do
      RedditStub.install(token: RedditStub.error(429))

      assert {:error, :rate_limited_by_reddit, _auth} =
               Auth.token(Auth.new(), @credentials, RedditStub.req_options())
    end

    test "reports other failures with the status" do
      RedditStub.install(token: RedditStub.error(503))

      assert {:error, {:token_request_failed, 503, _body}, _auth} =
               Auth.token(Auth.new(), @credentials, RedditStub.req_options())
    end

    test "a failed refresh leaves the cache untouched" do
      RedditStub.install(token: [RedditStub.token(3_600), RedditStub.error(503)])

      {:ok, _token, auth} = Auth.token(Auth.new(), @credentials, RedditStub.req_options())

      {:error, _reason, after_failure} =
        Auth.token(Auth.invalidate(auth), @credentials, RedditStub.req_options())

      assert after_failure.refreshes == 1
    end

    test "defaults expires_in when Reddit omits it" do
      RedditStub.install(
        token:
          Req.Response.new(status: 200, body: %{"access_token" => "t", "token_type" => "bearer"})
      )

      assert {:ok, "t", auth} = Auth.token(Auth.new(), @credentials, RedditStub.req_options())
      assert Auth.valid?(auth)
    end

    test "rejects a 200 that carries no token" do
      RedditStub.install(token: Req.Response.new(status: 200, body: %{"error" => "nope"}))

      assert {:error, {:unexpected_token_response, _body}, _auth} =
               Auth.token(Auth.new(), @credentials, RedditStub.req_options())
    end
  end

  describe "invalidate/1" do
    test "drops the token so the next call refetches" do
      auth = %Auth{token: "t", expires_at: now() + :timer.hours(1)}

      refute Auth.valid?(Auth.invalidate(auth))
    end
  end

  describe "user_agent/1" do
    test "uses the configured agent" do
      assert Auth.user_agent(user_agent: "custom/1.0") == "custom/1.0"
    end

    test "falls back to a default, since Reddit rejects blank agents" do
      assert Auth.user_agent([]) =~ "smm_monitor"
      assert Auth.user_agent(user_agent: "") =~ "smm_monitor"
    end
  end

  defp now, do: System.system_time(:millisecond)
end
