defmodule SmmMonitor.Reports.CSV do
  @moduledoc """
  The period's mentions as a CSV, for when someone wants the data rather
  than the document.

  Written by hand rather than with a library: this is one well-understood
  format with one shape of row, and the escaping rules fit in twenty
  lines. A dependency would be more to explain than to write.

  ## Escaping

  RFC 4180: fields containing a comma, a quote or a newline are wrapped
  in double quotes, and quotes inside them are doubled. Mention text
  routinely contains all three, so this is the part that matters — an
  unescaped newline turns one row into two and silently corrupts every
  column after it.
  """

  alias SmmMonitor.Mention
  alias SmmMonitor.Reports.Report

  @headers ~w(
    client_id client_name platform mention_id author text url
    published_at sentiment sentiment_value sentiment_score mock
  )

  @doc "The column headers, in order."
  @spec headers() :: [String.t()]
  def headers, do: @headers

  @doc """
  Renders a report's mentions as CSV text, newest first.

  Includes a header row always — a CSV with no rows and no header is
  indistinguishable from a broken export, where a header alone clearly
  says "nothing in this period".
  """
  @spec render(Report.t()) :: String.t()
  def render(%Report{} = report) do
    rows = Enum.map(report.mentions, &row(&1, report.client))

    [@headers | rows]
    |> Enum.map_join("\r\n", &line/1)
    |> Kernel.<>("\r\n")
  end

  @doc """
  One mention as a list of fields, in header order.

  Public so a test can assert on the values without parsing CSV back.
  """
  @spec row(Mention.t(), SmmMonitor.Client.t()) :: [String.t()]
  def row(%Mention{} = mention, client) do
    [
      client.id,
      client.name,
      to_string(mention.platform),
      mention.id,
      mention.author,
      mention.text || "",
      mention.url || "",
      DateTime.to_iso8601(mention.timestamp),
      to_string(mention.sentiment),
      float(mention.sentiment_value),
      to_string(mention.sentiment_score),
      to_string(mention.mock)
    ]
  end

  @doc """
  Escapes one field.

      iex> alias SmmMonitor.Reports.CSV
      iex> CSV.escape("plain")
      "plain"
      iex> CSV.escape(~s(has "quotes", commas))
      ~s("has ""quotes"", commas")
      iex> CSV.escape("two\\nlines")
      ~s("two\\nlines")
  """
  @spec escape(String.t() | nil) :: String.t()
  def escape(nil), do: ""

  def escape(value) do
    value = to_string(value)

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      ~s("#{String.replace(value, "\"", "\"\"")}")
    else
      value
    end
  end

  defp line(fields), do: Enum.map_join(fields, ",", &escape/1)

  defp float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp float(value), do: to_string(value)
end
