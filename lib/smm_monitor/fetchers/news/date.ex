defmodule SmmMonitor.Fetchers.News.Date do
  @moduledoc """
  Reads the dates news feeds carry.

  RSS 2.0 uses RFC 822 (`Wed, 12 Nov 2026 10:00:00 GMT`), Atom uses RFC
  3339 (`2026-11-12T10:00:00Z`), and RSS 1.0's `dc:date` is W3C-DTF, a
  subset of ISO 8601 that allows a bare date or a time without seconds.
  Feeds bend all three, so this is lenient about what it accepts: no
  weekday, a two-digit year, no seconds, a US zone name. Anything it
  cannot read is `nil`, never a guess.
  """

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  # RFC 822's named zones, in hours from UTC. Military single letters
  # other than Z are ambiguous in practice (RFC 1123 says so) and read as
  # UTC, as does any name not listed.
  @zones %{
    "gmt" => 0,
    "ut" => 0,
    "utc" => 0,
    "z" => 0,
    "est" => -5,
    "edt" => -4,
    "cst" => -6,
    "cdt" => -5,
    "mst" => -7,
    "mdt" => -6,
    "pst" => -8,
    "pdt" => -7
  }

  @rfc822 ~r/\A(?:[A-Za-z]{2,9}\.?,?\s+)?(\d{1,2})\s+([A-Za-z]{3,9})\.?,?\s+(\d{2}|\d{4}),?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*([+-]\d{2}:?\d{2}|[A-Za-z]{1,5})?\s*\z/

  @doc """
  Parses a feed date into a UTC `DateTime`, or `nil`.

      iex> SmmMonitor.Fetchers.News.Date.parse("Wed, 12 Nov 2026 10:00:00 GMT")
      ~U[2026-11-12 10:00:00Z]

      iex> SmmMonitor.Fetchers.News.Date.parse("12 Nov 26 10:00 +0530")
      ~U[2026-11-12 04:30:00Z]

      iex> SmmMonitor.Fetchers.News.Date.parse("2026-11-12T10:00:00-05:00")
      ~U[2026-11-12 15:00:00Z]

      iex> SmmMonitor.Fetchers.News.Date.parse("2026-11-12")
      ~U[2026-11-12 00:00:00Z]

      iex> SmmMonitor.Fetchers.News.Date.parse("last Tuesday")
      nil
  """
  @spec parse(term()) :: DateTime.t() | nil
  def parse(text) when is_binary(text) do
    text = String.trim(text)

    if byte_size(text) > 64, do: nil, else: iso8601(text) || rfc822(text)
  end

  def parse(_other), do: nil

  # --- ISO 8601 / RFC 3339 / W3C-DTF ----------------------------------------

  defp iso8601(text) do
    # Accept a lower-case t and z, and a time without seconds.
    text =
      text
      |> String.upcase()
      |> String.replace(~r/\A(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?=Z|[+-]|\z)/, "\\1T\\2:00")
      |> String.replace(~r/\A(\d{4}-\d{2}-\d{2}) (?=\d)/, "\\1T")

    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} ->
        DateTime.truncate(datetime, :second)

      {:error, :missing_offset} ->
        # No zone at all: UTC is the only defensible reading.
        case NaiveDateTime.from_iso8601(text) do
          {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)
          {:error, _reason} -> nil
        end

      {:error, _reason} ->
        case Date.from_iso8601(text) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          {:error, _reason} -> nil
        end
    end
  end

  # --- RFC 822 / RFC 1123 ----------------------------------------------------

  defp rfc822(text) do
    with [_all, day, month, year, hour, minute | rest] <- Regex.run(@rfc822, text),
         {:ok, month} <- month(month),
         {:ok, offset_s} <- offset(Enum.at(rest, 1)),
         {:ok, naive} <-
           NaiveDateTime.new(
             year(year),
             month,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             seconds(Enum.at(rest, 0))
           ) do
      naive
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.add(-offset_s, :second)
    else
      _unreadable -> nil
    end
  end

  defp month(name) do
    case Enum.find_index(@months, &(&1 == name |> String.slice(0, 3) |> String.downcase())) do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  # RFC 822 allowed two-digit years; RFC 1123 moved to four. A two-digit
  # one is read as the nearest century that makes sense for a news item.
  defp year(<<_two::binary-size(2)>> = year) do
    case String.to_integer(year) do
      year when year < 70 -> 2000 + year
      year -> 1900 + year
    end
  end

  defp year(year), do: String.to_integer(year)

  defp seconds(nil), do: 0
  defp seconds(""), do: 0
  defp seconds(seconds), do: String.to_integer(seconds)

  defp offset(nil), do: {:ok, 0}
  defp offset(""), do: {:ok, 0}

  defp offset(<<sign, rest::binary>>) when sign in [?+, ?-] do
    <<hours::binary-size(2), minutes::binary-size(2)>> = String.replace(rest, ":", "")
    {hours, minutes} = {String.to_integer(hours), String.to_integer(minutes)}

    if hours <= 14 and minutes < 60 do
      seconds = hours * 3_600 + minutes * 60
      {:ok, if(sign == ?-, do: -seconds, else: seconds)}
    else
      :error
    end
  end

  defp offset(zone), do: {:ok, Map.get(@zones, String.downcase(zone), 0) * 3_600}
end
