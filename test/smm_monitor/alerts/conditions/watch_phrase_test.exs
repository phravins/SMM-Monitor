defmodule SmmMonitor.Alerts.Conditions.WatchPhraseTest do
  @moduledoc """
  The condition that catches what the other two structurally cannot: one
  quiet mention that matters more than a hundred loud ones.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Alerts.Conditions.WatchPhrase
  alias SmmMonitor.Client.AlertConfig
  alias SmmMonitor.Mention

  describe "matching" do
    test "alerts on a phrase appearing in a mention" do
      assert [{:alert, details}] =
               evaluate(["thinking about a lawsuit honestly"], ["lawsuit", "refund"])

      assert details.kind == :watch_phrase
      assert details.phrase == "lawsuit"
      assert details.observed == 1
    end

    test "is case insensitive in both directions" do
      # "refund" has to catch "Refunded", and a phrase typed in capitals
      # has to catch lowercase text.
      assert [{:alert, _details}] = evaluate(["Still waiting on my REFUND"], ["refund"])
      assert [{:alert, _details}] = evaluate(["still waiting on my refund"], ["REFUND"])
    end

    test "matches inside a word, which is the v1 trade" do
      # "refund" must catch "refunds"; the cost is that "scam" catches
      # "scamper". The false positive is the cheaper mistake.
      assert [{:alert, _details}] = evaluate(["no refunds offered"], ["refund"])
    end

    test "stays quiet when no phrase appears" do
      assert [{:ok, :below_threshold}] = evaluate(["genuinely great product"], ["lawsuit"])
    end

    test "a client with no phrases configured is skipped entirely" do
      assert [{:ok, :no_phrases}] = evaluate(["lawsuit lawsuit lawsuit"], [])
    end

    test "handles a mention with no text" do
      config = AlertConfig.new(%{watch_phrases: ["lawsuit"]})
      mentions = [%{mention("placeholder") | text: nil}]

      assert [{:ok, :below_threshold}] = WatchPhrase.evaluate(%{mentions: mentions}, config)
    end
  end

  describe "one incident per phrase, not per mention" do
    test "ten mentions of one phrase are a single alert" do
      texts = List.duplicate("where is my refund", 10)

      assert [{:alert, details}] = evaluate(texts, ["refund"])
      assert details.observed == 10
    end

    test "two different phrases are two alerts" do
      # A lawsuit and a refund complaint are different problems and need
      # separate incidents.
      alerts = evaluate(["talk of a lawsuit", "still no refund"], ["lawsuit", "refund"])

      assert length(alerts) == 2
      phrases = Enum.map(alerts, fn {:alert, details} -> details.phrase end)
      assert Enum.sort(phrases) == ["lawsuit", "refund"]
    end

    test "one mention containing two phrases raises both" do
      alerts = evaluate(["no refund so I'm considering a lawsuit"], ["lawsuit", "refund"])

      assert length(alerts) == 2
    end
  end

  describe "evidence" do
    test "quotes the mention, since the phrase alone says nothing" do
      assert [{:alert, details}] =
               evaluate(["this is basically a scam, avoid"], ["scam"])

      assert details.excerpt == "this is basically a scam, avoid"
      assert %Mention{} = details.mention
    end

    test "quotes the newest matching mention" do
      config = AlertConfig.new(%{watch_phrases: ["refund"]})
      now = DateTime.utc_now()

      mentions = [
        %{mention("old refund complaint") | timestamp: DateTime.add(now, -3600)},
        %{mention("new refund complaint") | timestamp: now}
      ]

      assert [{:alert, details}] = WatchPhrase.evaluate(%{mentions: mentions}, config)
      assert details.excerpt == "new refund complaint"
    end

    test "trims a long mention to something a chat line can hold" do
      long = String.duplicate("a refund complaint that goes on and on. ", 20)

      assert [{:alert, details}] = evaluate([long], ["refund"])
      assert String.length(details.excerpt) <= 160
      assert String.ends_with?(details.excerpt, "…")
    end

    test "collapses newlines, which would break a chat message" do
      assert [{:alert, details}] = evaluate(["a refund\n\nplease  now"], ["refund"])

      assert details.excerpt == "a refund please now"
    end

    test "is always critical — somebody opted into this word" do
      assert [{:alert, %{severity: :critical}}] = evaluate(["a refund"], ["refund"])
    end
  end

  describe "cleared?/3" do
    test "clears once the phrase leaves the window" do
      config = AlertConfig.new(%{watch_phrases: ["refund"]})

      assert WatchPhrase.cleared?(%{mentions: [mention("all good now")]}, config, "refund")
    end

    test "stays open while the phrase is still in the window" do
      config = AlertConfig.new(%{watch_phrases: ["refund"]})

      refute WatchPhrase.cleared?(%{mentions: [mention("still no refund")]}, config, "refund")
    end

    test "an empty window clears" do
      config = AlertConfig.new(%{watch_phrases: ["refund"]})

      assert WatchPhrase.cleared?(%{mentions: []}, config, "refund")
    end
  end

  defp evaluate(texts, phrases) do
    config = AlertConfig.new(%{watch_phrases: phrases})
    WatchPhrase.evaluate(%{mentions: Enum.map(texts, &mention/1)}, config)
  end

  defp mention(text) do
    Mention.new(%{
      id: "m-#{System.unique_integer([:positive])}",
      platform: :reddit,
      client_id: "acme",
      author: "u/tester",
      text: text,
      timestamp: DateTime.utc_now()
    })
  end
end
