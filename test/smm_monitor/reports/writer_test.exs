defmodule SmmMonitor.Reports.WriterTest do
  @moduledoc """
  Naming and placing the files. A report that lands somewhere nobody
  looks, under a name nobody can read, has not really been delivered.
  """

  # Not async: one test sets SMM_REPORTS_DIR, which is process-wide.
  use ExUnit.Case, async: false

  alias SmmMonitor.Reports.{CSV, Period, Report, Writer}
  alias SmmMonitor.Client

  doctest Writer

  @client %Client{id: "acme-corp", name: "Acme Corp", keywords: ["acme"]}

  setup do
    dir = Path.join(System.tmp_dir!(), "smm-reports-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  describe "filename/3" do
    test "says whose report it is and what it covers" do
      # The file gets forwarded, renamed folders and all; it has to
      # identify itself once it is out of the reports directory.
      {:ok, period} = Period.between(~D[2026-09-05], ~D[2026-09-11])

      assert Writer.filename(@client, period, :pdf) == "acme-corp_2026-09-05_2026-09-11.pdf"
      assert Writer.filename(@client, period, :csv) == "acme-corp_2026-09-05_2026-09-11.csv"
    end

    test "sorts chronologically within a client in a directory listing" do
      {:ok, earlier} = Period.between(~D[2026-08-31], ~D[2026-09-06])
      {:ok, later} = Period.between(~D[2026-09-07], ~D[2026-09-13])

      names =
        Enum.sort([Writer.filename(@client, later, :csv), Writer.filename(@client, earlier, :csv)])

      assert names == [
               "acme-corp_2026-08-31_2026-09-06.csv",
               "acme-corp_2026-09-07_2026-09-13.csv"
             ]
    end
  end

  describe "dir/0" do
    test "follows the environment when one is set" do
      System.put_env("SMM_REPORTS_DIR", "/srv/reports")
      on_exit(fn -> System.delete_env("SMM_REPORTS_DIR") end)

      assert Writer.dir() == "/srv/reports"
    end

    test "otherwise sits beside the database, not inside the release" do
      # A deploy replaces the release directory; last week's report
      # should survive an upgrade.
      refute String.contains?(Writer.dir(), "_build/")
      assert String.ends_with?(Writer.dir(), "reports")
    end
  end

  describe "write/3" do
    test "creates the directory if it is not there yet", %{dir: dir} do
      refute File.exists?(dir)

      assert {:ok, [path]} = Writer.write(report(), [:csv], dir: dir)
      assert File.exists?(path)
    end

    test "returns the paths it wrote", %{dir: dir} do
      {:ok, [path]} = Writer.write(report(), [:csv], dir: dir)

      assert Path.basename(path) == "acme-corp_2026-09-05_2026-09-11.csv"
      assert Path.dirname(path) == dir
    end

    test "writes the report's own content, not an empty file", %{dir: dir} do
      {:ok, [path]} = Writer.write(report(), [:csv], dir: dir)

      assert File.read!(path) == CSV.render(report())
    end

    test "stops at the first failure rather than leaving half a pair", %{dir: dir} do
      # Half a delivery is worse than none: the missing half is the one
      # nobody notices until a client asks for it.
      File.mkdir_p!(dir)
      blocked = Path.join(dir, "acme-corp_2026-09-05_2026-09-11.csv")
      File.mkdir_p!(blocked)

      assert {:error, {:write_failed, ^blocked, _reason}} =
               Writer.write(report(), [:csv], dir: dir)
    end
  end

  defp report do
    %Report{
      client: @client,
      period: Period.last_days(7, ~D[2026-09-11]),
      generated_at: ~U[2026-09-11 09:00:00Z],
      total: 0,
      mentions: []
    }
  end
end
