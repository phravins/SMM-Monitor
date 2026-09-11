defmodule SmmMonitor.Reports.CSVTest do
  @moduledoc """
  The raw-data export. A spreadsheet that opens wrong is worse than no
  export at all, so most of this is about text that fights back.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Reports.{CSV, Period, Report}
  alias SmmMonitor.{Client, Mention}

  doctest CSV

  @client %Client{id: "acme-corp", name: "Acme Corp", keywords: ["acme"]}

  describe "render/1" do
    test "starts with the header row" do
      [header | _] = lines(render([]))

      assert header == Enum.join(CSV.headers(), ",")
    end

    test "has a header even with nothing in the period" do
      # A file with no header looks like a failed export; a header with
      # no rows plainly says "nothing was said this week".
      assert lines(render([])) == [Enum.join(CSV.headers(), ",")]
    end

    test "writes one line per mention" do
      csv = render([mention(id: "a"), mention(id: "b")])

      assert length(lines(csv)) == 3
    end

    test "uses CRLF line endings, as the format says" do
      # Excel on Windows is the most likely destination for this file.
      csv = render([mention(id: "a")])

      assert String.ends_with?(csv, "\r\n")
      assert csv |> String.split("\r\n") |> length() == 3
    end

    test "carries the client on every row, so exports can be concatenated" do
      csv = render([mention(id: "a")])
      [_header, row] = lines(csv)

      assert String.starts_with?(row, "acme-corp,Acme Corp,")
    end
  end

  describe "row/2" do
    test "is in header order, one value per column" do
      row = CSV.row(mention(id: "m-1"), @client)

      assert length(row) == length(CSV.headers())
    end

    test "carries the values a spreadsheet would want to sort and filter on" do
      mention =
        mention(
          id: "m-1",
          platform: :youtube,
          author: "someone",
          text: "great service",
          url: "https://example.test/v",
          timestamp: ~U[2026-09-08 12:00:00Z],
          sentiment: :positive,
          sentiment_value: 0.625,
          sentiment_score: 3
        )

      assert CSV.row(mention, @client) == [
               "acme-corp",
               "Acme Corp",
               "youtube",
               "m-1",
               "someone",
               "great service",
               "https://example.test/v",
               "2026-09-08T12:00:00Z",
               "positive",
               "0.625",
               "3",
               "false"
             ]
    end

    test "marks a mock mention as such" do
      # Otherwise sample data is indistinguishable from real coverage
      # once it is out of the app and in a spreadsheet.
      row = CSV.row(mention(id: "m-1", mock: true), @client)

      assert List.last(row) == "true"
    end

    test "survives a mention with no text or url" do
      row = CSV.row(mention(id: "m-1", text: nil, url: nil), @client)

      assert Enum.at(row, 5) == ""
      assert Enum.at(row, 6) == ""
    end
  end

  describe "escaping" do
    test "quotes a field containing a comma" do
      csv = render([mention(id: "a", text: "good, mostly")])

      assert csv =~ ~s("good, mostly")
    end

    test "doubles quotes inside a quoted field" do
      csv = render([mention(id: "a", text: ~s(they said "fine"))])

      assert csv =~ ~s("they said ""fine""")
    end

    test "keeps a multi-line post as one row" do
      # This is the failure that matters: an unescaped newline splits the
      # row and shifts every column after it, silently.
      csv = render([mention(id: "a", text: "first line\nsecond line")])

      assert length(lines(csv)) == 2
      assert csv =~ ~s("first line\nsecond line")
    end

    test "keeps every mention on its own row, however awkward the text" do
      csv = render([mention(id: "a", text: ~s(a "quoted", multi\nline post)), mention(id: "b")])

      assert length(lines(csv)) == 3
    end

    test "leaves an ordinary field alone" do
      assert CSV.escape("plain text") == "plain text"
    end

    test "treats a missing value as empty rather than the word nil" do
      assert CSV.escape(nil) == ""
    end
  end

  # --- helpers --------------------------------------------------------------

  defp render(mentions) do
    CSV.render(%Report{
      client: @client,
      period: Period.last_days(7, ~D[2026-09-11]),
      generated_at: ~U[2026-09-11 09:00:00Z],
      total: length(mentions),
      mentions: mentions
    })
  end

  # Splits on the row separator, which is not the separator inside a
  # quoted field — so a quoted newline does not look like a new row.
  defp lines(csv) do
    csv |> String.trim_trailing("\r\n") |> String.split("\r\n")
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
      client_id: "acme-corp",
      mock: false
    ]

    struct!(Mention, Keyword.merge(defaults, overrides))
  end
end
