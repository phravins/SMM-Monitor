defmodule SmmMonitor.ReportsTest do
  @moduledoc """
  Turning a week of stored mentions into the numbers a client reads.

  Every test here stores rows and reads them back through the real
  durable log, because a report that only works against in-memory
  fixtures is a report that breaks the first time it is handed to
  somebody.
  """

  use SmmMonitor.DatabaseCase, async: true

  alias SmmMonitor.Reports
  alias SmmMonitor.Reports.{Period, Report}

  @today ~D[2026-09-11]

  setup do
    client = build_client("Acme Corp")

    %{client: client, period: Period.last_days(7, @today), opts: [clients: [client]]}
  end

  describe "build/3" do
    test "refuses an id that belongs to nobody", %{period: period, opts: opts} do
      # A typo should not quietly produce an empty report that then gets
      # emailed to a client.
      assert {:error, :unknown_client} = Reports.build("acme-korp", period, opts)
    end

    test "accepts the client's id", %{client: client, period: period, opts: opts} do
      assert {:ok, report} = Reports.build(client.id, period, opts)
      assert report.client.id == client.id
    end

    test "counts only this client's mentions", %{client: client, period: period, opts: opts} do
      store(client, days_ago: 1)
      store(client, days_ago: 2)
      store(%{id: "other-brand"}, days_ago: 1)

      {:ok, report} = Reports.build(client, period, opts)

      assert report.total == 2
    end

    test "counts only mentions inside the period", %{client: client, period: period, opts: opts} do
      store(client, on: ~D[2026-09-05])
      store(client, on: ~D[2026-09-11])
      store(client, on: ~D[2026-09-04])
      store(client, on: ~D[2026-09-12])

      {:ok, report} = Reports.build(client, period, opts)

      assert report.total == 2
    end

    test "includes a mention posted late on the final day", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, at: ~U[2026-09-11 23:58:00Z])

      {:ok, report} = Reports.build(client, period, opts)

      assert report.total == 1
    end

    test "an empty period is a report, not a failure", %{
      client: client,
      period: period,
      opts: opts
    } do
      {:ok, report} = Reports.build(client, period, opts)

      assert report.total == 0
      assert report.trend == :flat
      assert Enum.all?(report.daily, &(&1.count == 0))
    end
  end

  describe "platform breakdown" do
    test "names every configured platform, including the quiet ones", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, platform: :reddit, days_ago: 1)
      store(client, platform: :reddit, days_ago: 2)
      store(client, platform: :youtube, days_ago: 1)

      {:ok, report} = Reports.build(client, period, opts)

      # A platform with nothing on it is a finding — a missing row just
      # looks like the report forgot about it.
      assert report.by_platform[:reddit] == 2
      assert report.by_platform[:youtube] == 1
      assert Map.keys(report.by_platform) |> Enum.sort() == Enum.sort(SmmMonitor.platforms())
      assert report.by_platform[:instagram] == 0
    end
  end

  describe "the daily series" do
    test "has one entry per day of the period", %{client: client, period: period, opts: opts} do
      {:ok, report} = Reports.build(client, period, opts)

      assert length(report.daily) == 7
      assert Enum.map(report.daily, & &1.date) == Period.dates(period)
    end

    test "a silent day is a zero, not a gap", %{client: client, period: period, opts: opts} do
      store(client, on: ~D[2026-09-05])
      store(client, on: ~D[2026-09-11])

      {:ok, report} = Reports.build(client, period, opts)

      counts = Enum.map(report.daily, & &1.count)

      assert counts == [1, 0, 0, 0, 0, 0, 1]
    end

    test "averages sentiment within the day", %{client: client, period: period, opts: opts} do
      store(client, on: ~D[2026-09-07], sentiment_value: 1.0, sentiment: :positive)
      store(client, on: ~D[2026-09-07], sentiment_value: 0.0)

      {:ok, report} = Reports.build(client, period, opts)

      day = Enum.find(report.daily, &(&1.date == ~D[2026-09-07]))

      assert day.average == 0.5
    end
  end

  describe "sentiment" do
    test "averages across the period", %{client: client, period: period, opts: opts} do
      store(client, days_ago: 1, sentiment_value: 0.8, sentiment: :positive)
      store(client, days_ago: 2, sentiment_value: 0.2, sentiment: :positive)

      {:ok, report} = Reports.build(client, period, opts)

      assert report.average_sentiment == 0.5
    end

    test "splits the period into positive, neutral and negative", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, days_ago: 1, sentiment: :positive, sentiment_value: 0.6)
      store(client, days_ago: 1, sentiment: :negative, sentiment_value: -0.6)
      store(client, days_ago: 2, sentiment: :negative, sentiment_value: -0.4)
      store(client, days_ago: 2, sentiment: :neutral, sentiment_value: 0.0)

      {:ok, report} = Reports.build(client, period, opts)

      assert report.sentiment_split == %{positive: 1, neutral: 1, negative: 2}
    end

    test "no mentions last period means no trend claimed", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, days_ago: 1, sentiment_value: 0.9, sentiment: :positive)

      {:ok, report} = Reports.build(client, period, opts)

      # A first report has nothing to compare against; saying "improving"
      # would be inventing a baseline.
      assert report.previous_average == nil
      assert report.trend == :flat
    end

    test "improves when sentiment rises beyond the noise floor", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, on: ~D[2026-09-01], sentiment_value: 0.0)
      store(client, on: ~D[2026-09-08], sentiment_value: 0.5, sentiment: :positive)

      {:ok, report} = Reports.build(client, period, opts)

      assert report.trend == :up
      assert Report.trend_label(report.trend) == "improving"
    end

    test "declines when sentiment falls beyond the noise floor", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, on: ~D[2026-09-01], sentiment_value: 0.5, sentiment: :positive)
      store(client, on: ~D[2026-09-08], sentiment_value: 0.0)

      {:ok, report} = Reports.build(client, period, opts)

      assert report.trend == :down
      assert Report.trend_label(report.trend) == "declining"
    end

    test "a couple of hundredths is not a change of direction", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, on: ~D[2026-09-01], sentiment_value: 0.30, sentiment: :positive)
      store(client, on: ~D[2026-09-08], sentiment_value: 0.32, sentiment: :positive)

      {:ok, report} = Reports.build(client, period, opts)

      assert report.trend == :flat
      assert Report.trend_label(report.trend) == "steady"
    end
  end

  describe "volume against the previous period" do
    test "compares against the same number of days immediately before", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, on: ~D[2026-08-29])
      store(client, on: ~D[2026-09-04])
      store(client, on: ~D[2026-08-28])

      {:ok, report} = Reports.build(client, period, opts)

      # 29 Aug to 4 Sep is the comparison window; 28 Aug falls outside it.
      assert report.previous_total == 2
    end

    test "rises when volume climbs by more than a tenth", %{
      client: client,
      period: period,
      opts: opts
    } do
      for _ <- 1..10, do: store(client, on: ~D[2026-09-01])
      for _ <- 1..12, do: store(client, on: ~D[2026-09-08])

      {:ok, report} = Reports.build(client, period, opts)

      assert report.volume_trend == :up
      assert Report.percentage_change(12, 10) == 20
    end

    test "holds steady on a small wobble", %{client: client, period: period, opts: opts} do
      for _ <- 1..10, do: store(client, on: ~D[2026-09-01])
      for _ <- 1..10, do: store(client, on: ~D[2026-09-08])

      {:ok, report} = Reports.build(client, period, opts)

      assert report.volume_trend == :flat
    end

    test "a first report does not claim a volume direction", %{
      client: client,
      period: period,
      opts: opts
    } do
      for _ <- 1..20, do: store(client, on: ~D[2026-09-08])

      {:ok, report} = Reports.build(client, period, opts)

      assert report.previous_total == 0
      assert report.volume_trend == :flat
    end
  end

  describe "top mentions" do
    test "are the strongest in each direction, best first", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, id: "mild", days_ago: 1, sentiment: :positive, sentiment_value: 0.2)
      store(client, id: "best", days_ago: 1, sentiment: :positive, sentiment_value: 0.9)
      store(client, id: "worst", days_ago: 1, sentiment: :negative, sentiment_value: -0.9)
      store(client, id: "meh", days_ago: 1, sentiment: :neutral, sentiment_value: 0.0)

      {:ok, report} = Reports.build(client, period, opts)

      assert Enum.map(report.top_positive, & &1.id) == ["best", "mild"]
      assert Enum.map(report.top_negative, & &1.id) == ["worst"]
    end

    test "a neutral mention is neither a highlight nor a complaint", %{
      client: client,
      period: period,
      opts: opts
    } do
      store(client, days_ago: 1, sentiment: :neutral, sentiment_value: 0.0)

      {:ok, report} = Reports.build(client, period, opts)

      assert report.top_positive == []
      assert report.top_negative == []
    end

    test "are capped so the report stays readable", %{
      client: client,
      period: period,
      opts: opts
    } do
      for n <- 1..12 do
        store(client, days_ago: 1, sentiment: :positive, sentiment_value: n / 20)
      end

      {:ok, report} = Reports.build(client, period, opts)

      assert length(report.top_positive) == Reports.top_count()
    end
  end

  describe "alerts" do
    test "are skipped with a note when nothing was ever watching", %{
      client: client,
      period: period,
      opts: opts
    } do
      {:ok, report} = Reports.build(client, period, opts)

      # "No alerts" and "no alerting" are different facts, and only one
      # of them is reassuring.
      refute report.alerts_available
      assert report.alerts == []
    end

    test "are listed for the period when alerting has run", %{
      client: client,
      period: period,
      opts: opts
    } do
      :ok = Persistence.store_alert(alert(client, ~U[2026-09-08 09:00:00Z]))
      :ok = Persistence.store_alert(alert(client, ~U[2026-08-01 09:00:00Z]))

      {:ok, report} = Reports.build(client, period, opts)

      assert report.alerts_available
      assert Enum.map(report.alerts, &DateTime.to_date(&1.raised_at)) == [~D[2026-09-08]]
    end

    test "belonging to another client stay out of this report", %{
      client: client,
      period: period,
      opts: opts
    } do
      :ok = Persistence.store_alert(alert(%{id: "other-brand"}, ~U[2026-09-08 09:00:00Z]))

      {:ok, report} = Reports.build(client, period, opts)

      assert report.alerts_available
      assert report.alerts == []
    end
  end

  describe "generate/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "smm-generate-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      %{dir: dir}
    end

    test "builds and writes in one call", %{client: client, dir: dir, opts: opts} do
      store(client, days_ago: 1)

      assert {:ok, paths} = Reports.generate(client, opts ++ [days: 7, formats: [:csv], dir: dir])

      assert [path] = paths
      assert File.read!(path) =~ "acme-corp"
    end

    test "covers the last seven days unless told otherwise", %{
      client: client,
      dir: dir,
      opts: opts
    } do
      {:ok, [path]} = Reports.generate(client, opts ++ [formats: [:csv], dir: dir])

      today = Date.utc_today()

      assert Path.basename(path) == "acme-corp_#{Date.add(today, -6)}_#{today}.csv"
    end

    test "takes an explicit period", %{client: client, dir: dir, opts: opts, period: period} do
      {:ok, [path]} = Reports.generate(client, opts ++ [period: period, formats: [:csv], dir: dir])

      assert Path.basename(path) == "acme-corp_2026-09-05_2026-09-11.csv"
    end

    test "refuses an unknown client rather than writing a file", %{dir: dir, opts: opts} do
      assert {:error, :unknown_client} =
               Reports.generate("nobody", opts ++ [formats: [:csv], dir: dir])

      refute File.exists?(dir)
    end
  end

  describe "available_formats/0" do
    test "always includes the data, whatever this machine can render" do
      # Losing the formatted document to a missing Python install is a
      # nuisance; losing the numbers is a failure.
      assert :csv in Reports.available_formats()
    end
  end

  describe "excerpt/2" do
    test "collapses the whitespace a forum post arrives with" do
      mention = mention(text: "line one\n\n   line   two")

      assert Reports.excerpt(mention) == "line one line two"
    end

    test "trims a rambling post rather than letting it take a page" do
      mention = mention(text: String.duplicate("a", 500))

      excerpt = Reports.excerpt(mention, 40)

      assert String.length(excerpt) == 40
      assert String.ends_with?(excerpt, "…")
    end

    test "survives a mention with no text at all" do
      assert Reports.excerpt(mention(text: nil)) == ""
    end
  end

  # --- helpers --------------------------------------------------------------

  defp store(client, overrides) do
    {at, overrides} = Keyword.pop(overrides, :at)
    {on, overrides} = Keyword.pop(overrides, :on)

    overrides =
      case {at, on} do
        {nil, nil} -> overrides
        {%DateTime{} = at, _} -> Keyword.put(overrides, :timestamp, at)
        {_, %Date{} = on} -> Keyword.put(overrides, :timestamp, noon(on))
      end

    {:ok, 1} =
      Persistence.store([mention(Keyword.put(overrides, :client_id, client.id))])
  end

  defp noon(date), do: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

  defp build_client(name) do
    {:ok, client} = SmmMonitor.Client.new(%{name: name, keywords: ["acme"]})
    client
  end

  defp alert(client, at) do
    %SmmMonitor.Alerts.Alert{
      client_id: client.id,
      client_name: "Acme Corp",
      kind: :sentiment_drop,
      state: :firing,
      severity: :warning,
      at: at,
      opened_at: at,
      window_ms: 3_600_000,
      details: %{observed: -0.42, threshold: -0.3, count: 24}
    }
  end
end
