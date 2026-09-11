defmodule SmmMonitor.Reports.PDFTest do
  @moduledoc """
  The payload handed to the Python renderer.

  Rendering itself needs python3 and reportlab, which a test run cannot
  assume; what a test *can* pin down is the data going across that
  boundary, which is where the mistakes that reach a client live —
  a lowercase platform name, a missing section, a number formatted for
  a machine rather than a reader.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Persistence.AlertRecord
  alias SmmMonitor.Reports.{PDF, Period, Report}
  alias SmmMonitor.{Client, Mention}

  @client %Client{id: "acme-corp", name: "Acme Corp", keywords: ["acme", "acme corp"]}

  describe "payload/1" do
    test "identifies the client and the period on the cover" do
      payload = PDF.payload(report())

      assert payload.client.name == "Acme Corp"
      assert payload.client.keywords == ["acme", "acme corp"]
      assert payload.period.human_range == "5 Sep 2026 – 11 Sep 2026"
      assert payload.period.days == 7
    end

    test "dates the document, so a forwarded copy says when it was made" do
      payload = PDF.payload(report(generated_at: ~U[2026-09-11 09:05:00Z]))

      assert payload.generated_at == "11 Sep 2026 at 09:05 UTC"
    end

    test "serialises to JSON, since that is how it crosses to Python" do
      # Every value has to survive the trip; a struct or a tuple left in
      # here fails at render time, on a client's report.
      assert {:ok, json} = Jason.encode(PDF.payload(report()))
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["client"]["name"] == "Acme Corp"
    end
  end

  describe "the summary section" do
    test "counts the period and splits it by sentiment" do
      payload =
        PDF.payload(
          report(
            total: 4,
            average_sentiment: 0.25,
            sentiment_split: %{positive: 2, neutral: 1, negative: 1}
          )
        )

      assert payload.summary.total == 4
      assert payload.summary.positive == 2
      assert payload.summary.neutral == 1
      assert payload.summary.negative == 1
    end

    test "gives shares as percentages of the period" do
      payload =
        PDF.payload(report(total: 4, sentiment_split: %{positive: 3, neutral: 1, negative: 0}))

      assert payload.summary.positive_share == "75.0%"
      assert payload.summary.negative_share == "0.0%"
    end

    test "says plainly when there is no prior period to compare against" do
      payload = PDF.payload(report(total: 12, previous_total: 0, previous_average: nil))

      assert payload.summary.volume_change == "no prior period"
    end

    test "says how a quiet period might not be good news" do
      # A report reading "0 mentions" and nothing else invites the reader
      # to assume the tool is broken — or that silence is success.
      payload = PDF.payload(report(total: 0))

      assert payload.headline =~ "No mentions"
      assert payload.headline =~ "brand terms"
    end
  end

  describe "the platform breakdown" do
    test "uses the names the platforms call themselves" do
      # "twitter" in a document going to a client is a typo with a
      # deadline.
      payload = PDF.payload(report(by_platform: %{twitter: 3, youtube: 1}))

      names = Enum.map(payload.platforms, & &1.platform)

      assert "Twitter/X" in names
      assert "YouTube" in names
    end

    test "puts the busiest platform first" do
      payload =
        PDF.payload(report(total: 10, by_platform: %{reddit: 2, youtube: 7, instagram: 1}))

      assert Enum.map(payload.platforms, & &1.count) == [7, 2, 1]
    end

    test "keeps a platform with nothing on it" do
      payload = PDF.payload(report(total: 3, by_platform: %{reddit: 3, instagram: 0}))

      assert Enum.any?(payload.platforms, &(&1.count == 0))
    end
  end

  describe "the daily series" do
    test "labels each day for a chart axis" do
      payload = PDF.payload(report())

      assert Enum.map(payload.daily, & &1.label) |> List.first() == "Sat 5 Sep"
      assert length(payload.daily) == 7
    end

    test "says 'no mentions' rather than showing a day as neutral" do
      # A silent day averaging 0.0 would otherwise be drawn as a day of
      # perfectly balanced opinion.
      payload = PDF.payload(report())

      assert Enum.all?(payload.daily, &(&1.average_text == "no mentions"))
    end
  end

  describe "the top mentions" do
    test "carry the quote and where it came from" do
      mention = mention(author: "u/happy", text: "brilliant service", sentiment_value: 0.8)
      payload = PDF.payload(report(top_positive: [mention]))

      assert [top] = payload.top_positive
      assert top.text == "brilliant service"
      assert top.author == "u/happy"
      assert top.platform == "Reddit"
      assert top.url == "https://example.test/p"
      assert top.when == "8 Sep 2026 12:00 UTC"
    end

    test "trim a rambling post so one mention cannot take a page" do
      payload = PDF.payload(report(top_negative: [mention(text: String.duplicate("a", 900))]))

      assert [top] = payload.top_negative
      assert String.length(top.text) == 600
    end
  end

  describe "the alerts section" do
    test "distinguishes a quiet week from a week with nothing watching" do
      not_watching = PDF.payload(report(alerts_available: false)).alerts
      watching = PDF.payload(report(alerts_available: true, alerts: [])).alerts

      refute not_watching.available
      assert not_watching.note =~ "not running"

      assert watching.available
      assert watching.note =~ "No alerts were raised"
    end

    test "lists a stored alert with its message as it was sent" do
      payload = PDF.payload(report(alerts_available: true, alerts: [alert_record()]))

      assert [row] = payload.alerts.rows
      assert row.when == "8 Sep 09:00"
      assert row.detail == "Acme: sentiment fell"
      assert row.kind == "sentiment"
    end

    test "marks a resolved alert as resolved" do
      payload =
        PDF.payload(report(alerts_available: true, alerts: [alert_record(state: "resolved")]))

      assert [row] = payload.alerts.rows
      assert row.kind =~ "(resolved)"
    end

    test "renders an alert kind stored before its module was loaded" do
      # Reports are generated from a `mix` run with alerting switched
      # off, where the atom for a stored kind may not exist yet. This
      # used to crash the whole report.
      payload =
        PDF.payload(report(alerts_available: true, alerts: [alert_record(kind: "volume_spike")]))

      assert [_row] = payload.alerts.rows
    end
  end

  describe "available/0" do
    test "either finds the toolchain or names exactly what is missing" do
      case PDF.available() do
        :ok ->
          assert File.exists?(PDF.script_path())

        {:error, reason} ->
          # The point of the reason is that it can be read out to a
          # person who then knows what to install.
          assert PDF.explain(reason) =~ ~r/python3|reportlab|renderer/
      end
    end

    test "explains an unrecognised failure without crashing" do
      assert PDF.explain(:something_new) =~ "PDF generation failed"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp report(overrides \\ []) do
    defaults = [
      client: @client,
      period: Period.last_days(7, ~D[2026-09-11]),
      generated_at: ~U[2026-09-11 09:00:00Z],
      total: 0,
      by_platform: %{reddit: 0},
      daily: daily(),
      average_sentiment: 0.0,
      previous_average: nil,
      previous_total: 0,
      trend: :flat,
      volume_trend: :flat,
      sentiment_split: %{positive: 0, neutral: 0, negative: 0},
      top_positive: [],
      top_negative: [],
      alerts: [],
      alerts_available: false,
      mentions: []
    ]

    struct!(Report, Keyword.merge(defaults, overrides))
  end

  defp daily do
    7
    |> Period.last_days(~D[2026-09-11])
    |> Period.dates()
    |> Enum.map(&%{date: &1, count: 0, average: 0.0})
  end

  defp mention(overrides) do
    defaults = [
      id: "m-1",
      platform: :reddit,
      author: "u/tester",
      text: "a mention",
      url: "https://example.test/p",
      timestamp: ~U[2026-09-08 12:00:00Z],
      sentiment: :neutral,
      sentiment_value: 0.0,
      sentiment_score: 0,
      client_id: "acme-corp"
    ]

    struct!(Mention, Keyword.merge(defaults, overrides))
  end

  defp alert_record(overrides \\ []) do
    defaults = [
      client_id: "acme-corp",
      kind: "sentiment_drop",
      state: "firing",
      severity: "warning",
      message: "Acme: sentiment fell",
      raised_at: ~U[2026-09-08 09:00:00Z],
      opened_at: ~U[2026-09-08 09:00:00Z],
      window_ms: 3_600_000
    ]

    struct!(AlertRecord, Keyword.merge(defaults, overrides))
  end
end
