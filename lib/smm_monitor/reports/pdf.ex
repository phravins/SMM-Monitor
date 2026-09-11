defmodule SmmMonitor.Reports.PDF do
  @moduledoc """
  Renders a report as a branded PDF.

  ## Why this shells out to Python

  The house PDF style — the one client-facing OSWORKS documents already
  use — is defined as a ReportLab component library, and there is no
  Elixir equivalent that would produce the same document. Reimplementing
  the style in another toolchain would mean two definitions of the brand
  drifting apart, which is the one thing a brand style exists to prevent.
  So the library is vendored into `priv/reports` and driven by a small
  script: Elixir computes every number, writes them as JSON, and Python
  lays them out.

  **This makes `python3` and `reportlab` runtime dependencies** of the
  PDF path — the only part of the app that needs anything outside the
  release. They are checked for before use and reported precisely when
  missing, because "report failed" would send someone hunting through
  Elixir for a problem that is one `pip install` away. CSV export has no
  such dependency and keeps working regardless.

  ## Everything is computed before it leaves

  The script prints what it is given and does no arithmetic of its own.
  Two languages computing the same average is two chances to disagree,
  and the client is the one who would find out.
  """

  require Logger

  alias SmmMonitor.Alerts.Alert
  alias SmmMonitor.Persistence.AlertRecord
  alias SmmMonitor.Reports
  alias SmmMonitor.Reports.{Period, Report}

  @script "render_report.py"

  @doc """
  Writes the report to `path` as a PDF.

  Returns `{:ok, path}`, or `{:error, reason}` where the reason names
  what to install or fix.
  """
  @spec render(Report.t(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def render(%Report{} = report, path, opts \\ []) do
    with :ok <- available(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, payload_path} <- write_payload(report, opts) do
      try do
        run(payload_path, path, opts)
      after
        File.rm(payload_path)
      end
    end
  end

  @doc """
  Whether the PDF toolchain is present.

  Returns `:ok`, or `{:error, reason}` naming precisely what is missing —
  a mix task can then tell someone what to install rather than failing
  with a stack trace.
  """
  @spec available() :: :ok | {:error, term()}
  def available do
    cond do
      is_nil(python()) ->
        {:error, {:missing_python, "python3 is not on PATH"}}

      not File.exists?(script_path()) ->
        {:error, {:missing_script, script_path()}}

      not reportlab?() ->
        {:error,
         {:missing_reportlab,
          "the reportlab Python package is not installed (try: pip3 install reportlab)"}}

      true ->
        :ok
    end
  end

  @doc "A sentence explaining an `available/0` failure, for a human."
  @spec explain(term()) :: String.t()
  def explain({:missing_python, _detail}) do
    "PDF reports need python3 on PATH. Install Python 3, or use --format csv."
  end

  def explain({:missing_reportlab, _detail}) do
    "PDF reports need the reportlab Python package: pip3 install reportlab. " <>
      "Or use --format csv, which needs nothing extra."
  end

  def explain({:missing_script, path}) do
    "The report renderer is missing from the release at #{path}."
  end

  def explain({:render_failed, output}) do
    "The PDF renderer failed:\n#{output}"
  end

  def explain(reason), do: "PDF generation failed: #{inspect(reason)}"

  @doc """
  The JSON payload handed to the renderer.

  Public so its shape can be asserted without running Python — which is
  most of what there is to get wrong here.
  """
  @spec payload(Report.t()) :: map()
  def payload(%Report{} = report) do
    %{
      brand: brand(),
      generated_at: Calendar.strftime(report.generated_at, "%-d %b %Y at %H:%M UTC"),
      client: %{
        id: report.client.id,
        name: report.client.name,
        keywords: report.client.keywords
      },
      period: %{
        label: report.period.label,
        human_range: Period.human_range(report.period),
        days: report.period.days
      },
      headline: headline(report),
      summary_prose: summary_prose(report),
      trend_prose: trend_prose(report),
      summary: summary(report),
      platforms: platforms(report),
      daily: daily(report),
      top_positive: Enum.map(report.top_positive, &mention/1),
      top_negative: Enum.map(report.top_negative, &mention/1),
      alerts: alerts(report)
    }
  end

  @doc "Where the renderer script lives inside the release."
  @spec script_path() :: Path.t()
  def script_path, do: Path.join(reports_dir(), @script)

  # --- payload sections -----------------------------------------------------

  defp summary(report) do
    %{
      total: report.total,
      average: format(report.average_sentiment),
      volume_change: Report.volume_comparison(report),
      sentiment_change: sentiment_change(report),
      positive: report.sentiment_split.positive,
      neutral: report.sentiment_split.neutral,
      negative: report.sentiment_split.negative,
      positive_share: share(report.sentiment_split.positive, report.total),
      neutral_share: share(report.sentiment_split.neutral, report.total),
      negative_share: share(report.sentiment_split.negative, report.total)
    }
  end

  defp platforms(report) do
    report.by_platform
    |> Enum.sort_by(fn {_platform, count} -> -count end)
    |> Enum.map(fn {platform, count} ->
      %{platform: display_name(platform), count: count, share: share(count, report.total)}
    end)
  end

  # "Twitter/X" and "YouTube", not "twitter" and "youtube": the atoms are
  # how the app talks about platforms, and a document going to a client
  # should use how the platforms call themselves.
  defp display_name(platform) do
    :smm_monitor
    |> Application.get_env(:platforms, [])
    |> Keyword.get(platform, [])
    |> Keyword.get(:module)
    |> case do
      nil -> platform |> to_string() |> String.capitalize()
      module -> module.display_name()
    end
  rescue
    _error -> platform |> to_string() |> String.capitalize()
  end

  defp daily(report) do
    Enum.map(report.daily, fn day ->
      %{
        label: Calendar.strftime(day.date, "%a %-d %b"),
        date: Date.to_iso8601(day.date),
        count: day.count,
        average: day.average,
        average_text: if(day.count == 0, do: "no mentions", else: format(day.average))
      }
    end)
  end

  defp mention(mention) do
    %{
      platform: display_name(mention.platform),
      author: mention.author,
      when: Calendar.strftime(mention.timestamp, "%-d %b %Y %H:%M UTC"),
      sentiment: format(mention.sentiment_value),
      text: Reports.excerpt(mention, 600),
      url: mention.url
    }
  end

  # The section is skipped gracefully rather than omitted: a report that
  # silently has no alerts section leaves the reader wondering whether
  # nothing happened or nothing was watching.
  defp alerts(%Report{alerts_available: false}) do
    %{
      available: false,
      note: "Alerting was not running for this period, so no alert history is available.",
      rows: []
    }
  end

  defp alerts(%Report{alerts: []}) do
    %{available: true, note: "No alerts were raised in this period.", rows: []}
  end

  defp alerts(%Report{alerts: alerts}) do
    rows =
      Enum.map(alerts, fn alert ->
        %{
          when: Calendar.strftime(raised_at(alert), "%-d %b %H:%M"),
          kind: alert_kind(alert),
          detail: alert_detail(alert)
        }
      end)

    %{available: true, note: "", rows: rows}
  end

  # Reports normally read stored rows, which carry the message as it was
  # sent; a caller passing live alerts in (a TUI trigger, a test) hands
  # over Alert structs instead. Both render.
  defp raised_at(%AlertRecord{raised_at: at}), do: at
  defp raised_at(%{at: at}), do: at

  defp alert_kind(alert) do
    label = Alert.kind_label(kind_of(alert))
    if state_of(alert) == :resolved, do: "#{label} (resolved)", else: label
  end

  defp kind_of(%AlertRecord{} = record), do: AlertRecord.kind(record)
  defp kind_of(%{kind: kind}), do: kind

  defp state_of(%AlertRecord{} = record), do: AlertRecord.state(record)
  defp state_of(%{state: state}), do: state

  defp alert_detail(%AlertRecord{} = record), do: AlertRecord.message(record)
  defp alert_detail(alert), do: Alert.message(alert)

  # --- prose ----------------------------------------------------------------

  defp headline(%Report{total: 0} = report) do
    "No mentions were collected for #{report.client.name} in the #{report.period.label}. " <>
      "That may mean a quiet period, or that the brand terms need widening."
  end

  defp headline(report) do
    "#{report.total} mentions in the #{report.period.label}, averaging " <>
      "#{format(report.average_sentiment)} sentiment — #{Report.comparison(report)}."
  end

  defp summary_prose(%Report{total: 0}) do
    "Nothing was collected in this period, so there are no figures to compare."
  end

  defp summary_prose(report) do
    "#{report.total} mentions were collected across #{platform_count(report)} platforms, " <>
      "#{Report.volume_comparison(report)} on the previous #{report.period.days} days. " <>
      "Sentiment averaged #{format(report.average_sentiment)} on a scale of -1 to +1."
  end

  defp trend_prose(%Report{total: 0}) do
    "No mentions were collected, so there is no trend to show."
  end

  defp trend_prose(report) do
    "Daily average sentiment across the period. Sentiment is #{Report.comparison(report)}. " <>
      "A day with no mentions is plotted at zero."
  end

  defp sentiment_change(%Report{previous_average: nil}), do: "no prior period"

  defp sentiment_change(report) do
    delta = report.average_sentiment - report.previous_average
    "#{Report.trend_arrow(report.trend)} #{signed(delta)}"
  end

  defp platform_count(report) do
    Enum.count(report.by_platform, fn {_platform, count} -> count > 0 end)
  end

  # --- running the renderer -------------------------------------------------

  defp write_payload(report, opts) do
    dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    path = Path.join(dir, "smm-report-#{System.unique_integer([:positive])}.json")

    case File.write(path, Jason.encode!(payload(report))) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:payload_write_failed, reason}}
    end
  end

  defp run(payload_path, output_path, opts) do
    args = [script_path(), payload_path, output_path]

    case System.cmd(python(), args,
           stderr_to_stdout: true,
           cd: reports_dir(),
           env: python_env(opts)
         ) do
      {_output, 0} ->
        {:ok, output_path}

      {output, status} ->
        Logger.warning("reports: PDF renderer exited #{status}: #{output}")
        {:error, {:render_failed, String.trim(output)}}
    end
  end

  # The vendored component library sits next to the script, so the script
  # can import it wherever the release happens to be unpacked.
  defp python_env(opts) do
    existing = Keyword.get(opts, :env, [])
    [{"PYTHONPATH", reports_dir()} | existing]
  end

  defp reports_dir do
    case :code.priv_dir(:smm_monitor) do
      {:error, _reason} -> Path.join(["priv", "reports"])
      dir -> Path.join([to_string(dir), "reports"])
    end
  end

  defp python, do: System.find_executable("python3")

  defp reportlab? do
    case System.cmd(python(), ["-c", "import reportlab"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _failed -> false
    end
  rescue
    _error -> false
  end

  defp brand, do: SmmMonitor.config(:report_brand, "OSWORKS.IN")

  defp share(_count, 0), do: "—"

  defp share(count, total) do
    "#{Float.round(count / total * 100, 1)}%"
  end

  defp format(number), do: :erlang.float_to_binary(number / 1, decimals: 2)

  defp signed(number) when number >= 0, do: "+#{format(number)}"
  defp signed(number), do: format(number)
end
