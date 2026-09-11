defmodule SmmMonitor.Reports.Writer do
  @moduledoc """
  Puts a report on disk, under a name that says what it is.

  Filenames carry the client and the period — `acme-corp_2026-09-05_2026-09-11.pdf`
  — so a directory of them sorts sensibly and a file forwarded to a
  client still identifies itself after it has left the machine.

  ## Where they go

  `SMM_REPORTS_DIR` if set, otherwise a `reports` directory alongside the
  database. Deliberately *not* inside the release: a deploy replaces that
  directory, and a report someone generated last week should not vanish
  with an upgrade. Same reasoning that keeps the database out of `priv`.
  """

  alias SmmMonitor.Reports.{CSV, PDF, Period, Report}
  alias SmmMonitor.{Client, Paths}

  @doc "The directory reports are written to."
  @spec dir() :: Path.t()
  def dir do
    System.get_env("SMM_REPORTS_DIR") || SmmMonitor.config(:reports_dir) ||
      Paths.state("reports")
  end

  @doc """
  The filename for a report, without a directory.

      iex> alias SmmMonitor.Reports.{Period, Writer}
      iex> {:ok, period} = Period.between(~D[2026-09-05], ~D[2026-09-11])
      iex> Writer.filename(%SmmMonitor.Client{id: "acme-corp", name: "Acme"}, period, :pdf)
      "acme-corp_2026-09-05_2026-09-11.pdf"
  """
  @spec filename(Client.t(), Period.t(), :pdf | :csv) :: String.t()
  def filename(%Client{id: id}, %Period{} = period, format) do
    "#{id}_#{Period.slug(period)}.#{format}"
  end

  @doc """
  Writes a report in the requested formats.

  Returns `{:ok, paths}` with what was written, or `{:error, reason}`.
  Formats are written in order and the first failure stops the rest: a
  half-written pair is worse than a clear failure, since the missing one
  is the one nobody notices.
  """
  @spec write(Report.t(), [:pdf | :csv], keyword()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def write(%Report{} = report, formats, opts \\ []) do
    directory = Keyword.get(opts, :dir, dir())

    Enum.reduce_while(formats, {:ok, []}, fn format, {:ok, written} ->
      path = Path.join(directory, filename(report.client, report.period, format))

      case write_one(report, format, path, opts) do
        {:ok, path} -> {:cont, {:ok, written ++ [path]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_one(report, :csv, path, _opts) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, CSV.render(report)) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp write_one(report, :pdf, path, opts), do: PDF.render(report, path, opts)
end
