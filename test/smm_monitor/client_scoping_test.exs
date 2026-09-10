defmodule SmmMonitor.ClientScopingTest do
  @moduledoc """
  Mentions belong to a client, and every read is scoped to one.

  The failure this file exists to prevent is the quiet one: a dashboard
  that adds two clients' numbers together and shows a total nobody can
  act on.
  """

  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.{Mention, Monitor}
  alias SmmMonitor.Processing.Store

  setup do
    Monitor.reset()
    :ok
  end

  describe "recording" do
    test "keeps each client's mentions apart" do
      record("acme", :reddit, "a1", "acme is great")
      record("acme", :reddit, "a2", "acme again")
      record("beta", :reddit, "b1", "beta is fine")

      assert length(Monitor.recent(:all, 100, "acme")) == 2
      assert length(Monitor.recent(:all, 100, "beta")) == 1
    end

    test "the same post collected for two clients is two mentions" do
      # A post mentioning both brands matches both clients' terms, and
      # each client's dashboard has to show it. Keying on platform and
      # id alone would drop the second.
      record("acme", :reddit, "shared", "acme and beta announce a partnership")
      record("beta", :reddit, "shared", "acme and beta announce a partnership")

      assert [%{client_id: "acme"}] = Monitor.recent(:all, 100, "acme")
      assert [%{client_id: "beta"}] = Monitor.recent(:all, 100, "beta")
      assert length(Monitor.recent(:all, 100, :all)) == 2
    end

    test "re-collecting the same post for the same client is still a duplicate" do
      record("acme", :reddit, "same", "acme")
      record("acme", :reddit, "same", "acme")

      assert length(Monitor.recent(:all, 100, "acme")) == 1
    end
  end

  describe "stats/3" do
    setup do
      record("acme", :reddit, "a1", "acme is excellent, brilliant work")
      record("acme", :reddit, "a2", "acme is excellent too")
      record("beta", :reddit, "b1", "beta is terrible, broken and useless")
      :ok
    end

    test "counts only the client asked for" do
      assert Monitor.stats(:all, nil, "acme").count == 2
      assert Monitor.stats(:all, nil, "beta").count == 1
    end

    test "sentiment is the client's own, not the book's average" do
      # This is the whole point: Acme is having a good week and Beta a
      # bad one, and averaging them describes neither.
      assert Monitor.stats(:all, nil, "acme").average > 0
      assert Monitor.stats(:all, nil, "beta").average < 0
    end

    test "reports which client it answered for" do
      assert Monitor.stats(:all, nil, "acme").client == "acme"
    end

    test "reading across every client is still possible, for the operator" do
      assert Monitor.stats(:all, nil, :all).count == 3
    end
  end

  describe "breakdown/2" do
    test "the tab counts belong to the selected client" do
      record("acme", :reddit, "a1", "acme")
      record("acme", :youtube, "a2", "acme")
      record("beta", :reddit, "b1", "beta")
      record("beta", :reddit, "b2", "beta")

      assert Monitor.breakdown(nil, "acme")[:reddit] == 1
      assert Monitor.breakdown(nil, "acme")[:youtube] == 1
      assert Monitor.breakdown(nil, "beta")[:reddit] == 2
      assert Monitor.breakdown(nil, "beta")[:youtube] == 0
    end
  end

  describe "the platform filter still works alongside the client filter" do
    setup do
      record("acme", :reddit, "a1", "acme")
      record("acme", :youtube, "a2", "acme")
      record("beta", :reddit, "b1", "beta")
      :ok
    end

    test "both narrow at once" do
      assert length(Monitor.recent(:reddit, 100, "acme")) == 1
      assert length(Monitor.recent(:youtube, 100, "acme")) == 1
      assert length(Monitor.recent(:twitter, 100, "acme")) == 0
      assert length(Monitor.recent(:reddit, 100, "beta")) == 1
    end

    test "a client with nothing on a platform reads as empty, not as everyone's" do
      assert Monitor.recent(:youtube, 100, "beta") == []
    end
  end

  describe "the ETS store directly" do
    test "counts are scoped by client" do
      table = SmmMonitor.Processing.Processor.table()

      assert Store.count(table, :all, client: "acme") == 0

      record("acme", :reddit, "a1", "acme")
      record("beta", :reddit, "b1", "beta")

      assert Store.count(table, :all, client: "acme") == 1
      assert Store.count(table, :all, client: :all) == 2
    end
  end

  defp record(client_id, platform, id, text) do
    {:ok, _result} =
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

    :ok
  end
end
