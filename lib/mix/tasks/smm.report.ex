defmodule Mix.Tasks.Smm.Report do
  @moduledoc """
  Generates a client report.

      mix smm.report --client acme-corp
      mix smm.report --client acme-corp --days 30
      mix smm.report --client acme-corp --from 2026-09-01 --to 2026-09-07
      mix smm.report --client acme-corp --format csv
      mix smm.report --all --days 7

  ## Options

    * `--client ID`   — which client, by id (see `--list`)
    * `--all`         — every active client, one report each
    * `--days N`      — the last N whole days, ending today. Default 7.
    * `--from DATE`   — start of an explicit range, `YYYY-MM-DD`
    * `--to DATE`     — end of that range, inclusive. Defaults to today.
    * `--format F`    — `pdf`, `csv`, or `both`. Default `both`.
    * `--out DIR`     — where to write. Defaults to the reports directory.
    * `--list`        — print the client ids and exit.

  PDF output needs `python3` and the `reportlab` package; CSV needs
  nothing. If the PDF toolchain is missing the task says exactly what to
  install rather than failing obscurely, and `--format csv` still works.
  """

  @shortdoc "Generates a PDF and CSV report for a client"

  use Mix.Task

  alias SmmMonitor.Reports
  alias SmmMonitor.Reports.{PDF, Period, Report, Writer}

  # Config only, so the app can be started with the collecting layer off
  # (see start_app/0). Generating a report must not fetch: it would add
  # mentions to the very period being reported on, and in live mode it
  # would spend API quota to produce a document about the past.
  @requirements ["app.config"]

  @switches [
    client: :string,
    all: :boolean,
    days: :integer,
    from: :string,
    to: :string,
    format: :string,
    out: :string,
    list: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    start_app()

    cond do
      opts[:list] -> list_clients()
      opts[:all] -> generate_all(opts)
      is_binary(opts[:client]) -> generate_one(opts[:client], opts)
      true -> usage()
    end
  end

  # Reporting reads history; it neither collects nor alerts. Starting
  # those would change the numbers under the report and, in live mode,
  # make API calls to produce a document about data already on disk.
  defp start_app do
    Application.put_env(:smm_monitor, :start_fetchers, false)
    Application.put_env(:smm_monitor, :start_tui, false)
    Application.put_env(:smm_monitor, :ssh_enabled, false)
    Application.put_env(:smm_monitor, :alerts_enabled, false)
    {:ok, _started} = Application.ensure_all_started(:smm_monitor)
  end

  # --- actions --------------------------------------------------------------

  defp list_clients do
    case SmmMonitor.Clients.list() do
      [] ->
        Mix.shell().info("No clients configured. Add one from the dashboard's clients screen (c).")

      clients ->
        Mix.shell().info("Clients:\n")

        Enum.each(clients, fn client ->
          state = if client.active, do: "", else: "  (paused)"
          Mix.shell().info("  #{String.pad_trailing(client.id, 24)} #{client.name}#{state}")
        end)
    end
  end

  defp generate_one(client_id, opts) do
    with {:ok, period} <- period(opts),
         {:ok, report} <- Reports.build(client_id, period),
         {:ok, paths} <- write(report, opts) do
      report_summary(report, paths)
    else
      {:error, :unknown_client} ->
        Mix.shell().error("No client with id #{inspect(client_id)}. Try: mix smm.report --list")
        exit({:shutdown, 1})

      {:error, reason} ->
        fail(reason)
    end
  end

  defp generate_all(opts) do
    case Reports.active_clients() do
      [] ->
        Mix.shell().error("No active clients to report on.")
        exit({:shutdown, 1})

      clients ->
        Enum.each(clients, fn client ->
          case period(opts) do
            {:ok, period} ->
              {:ok, report} = Reports.build(client, period)

              case write(report, opts) do
                {:ok, paths} -> report_summary(report, paths)
                {:error, reason} -> fail(reason, exit?: false)
              end

            {:error, reason} ->
              fail(reason)
          end
        end)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp period(opts) do
    cond do
      is_binary(opts[:from]) -> explicit_period(opts)
      true -> {:ok, Period.last_days(opts[:days] || 7)}
    end
  end

  defp explicit_period(opts) do
    with {:ok, from} <- parse_date(opts[:from]),
         {:ok, to} <- parse_date(opts[:to] || Date.to_iso8601(Date.utc_today())) do
      Period.between(from, to)
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, {:bad_date, value}}
    end
  end

  defp write(report, opts) do
    formats =
      case opts[:format] do
        "pdf" -> [:pdf]
        "csv" -> [:csv]
        nil -> [:pdf, :csv]
        "both" -> [:pdf, :csv]
        other -> {:error, {:bad_format, other}}
      end

    case formats do
      {:error, reason} -> {:error, reason}
      formats -> Writer.write(report, formats, write_opts(opts))
    end
  end

  defp write_opts(opts) do
    case opts[:out] do
      nil -> []
      dir -> [dir: dir]
    end
  end

  defp report_summary(report, paths) do
    Mix.shell().info("""

    #{report.client.name} — #{report.period.label}
      #{report.total} mentions, average sentiment #{format(report.average_sentiment)} (#{Report.trend_label(report.trend)})
    """)

    Enum.each(paths, &Mix.shell().info("  wrote #{&1}"))
  end

  defp fail(reason, opts \\ [])

  defp fail({:bad_date, value}, opts) do
    Mix.shell().error("#{inspect(value)} is not a date. Use YYYY-MM-DD.")
    maybe_exit(opts)
  end

  defp fail({:bad_format, value}, opts) do
    Mix.shell().error("Unknown format #{inspect(value)}. Use pdf, csv or both.")
    maybe_exit(opts)
  end

  defp fail(:inverted_range, opts) do
    Mix.shell().error("--from is after --to.")
    maybe_exit(opts)
  end

  defp fail({:write_failed, path, reason}, opts) do
    Mix.shell().error("Could not write #{path}: #{inspect(reason)}")
    maybe_exit(opts)
  end

  defp fail(reason, opts) do
    Mix.shell().error(PDF.explain(reason))
    maybe_exit(opts)
  end

  defp maybe_exit(opts) do
    unless Keyword.get(opts, :exit?, true) == false, do: exit({:shutdown, 1})
  end

  defp usage do
    Mix.shell().info(@moduledoc)
  end

  defp format(number), do: :erlang.float_to_binary(number / 1, decimals: 2)
end
