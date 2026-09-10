defmodule SmmMonitor.Mention do
  @moduledoc """
  A single brand mention, normalised across every platform.

  Fetchers are responsible for mapping their platform's payload onto this
  struct; everything downstream (processing, TUI) only ever sees this shape.
  That normalisation boundary is what keeps adding a platform cheap.
  """

  @enforce_keys [:id, :platform, :author, :text, :timestamp]
  defstruct [
    # Stable, platform-scoped id. Used to de-duplicate across polls.
    :id,
    # :reddit | :youtube | :twitter | :instagram | ...
    :platform,
    :author,
    :text,
    # Permalink back to the post, when the platform gives us one.
    :url,
    # DateTime the mention was published (UTC).
    :timestamp,
    # :positive | :neutral | :negative — filled in by the processing
    # layer, derived from sentiment_value.
    sentiment: :neutral,
    # Normalised sentiment, -1.0 (most negative) to 1.0 (most positive).
    # This is the number to compare and average across mentions.
    sentiment_value: 0.0,
    # The raw lexicon total behind that value. Kept because it is what
    # earlier versions produced and what already-stored rows hold, and
    # because "how many sentiment words fired" is useful evidence.
    sentiment_score: 0,
    # True when the mention came from fixtures rather than a live API.
    mock: false
  ]

  @type sentiment :: :positive | :neutral | :negative

  @type t :: %__MODULE__{
          id: String.t(),
          platform: atom(),
          author: String.t(),
          text: String.t(),
          url: String.t() | nil,
          timestamp: DateTime.t(),
          sentiment: sentiment(),
          sentiment_value: float(),
          sentiment_score: integer(),
          mock: boolean()
        }

  @doc """
  Builds a mention from a plain map, filling in sensible defaults.

  Accepts string or atom keys so fetchers can hand over lightly-massaged
  API payloads without ceremony.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = normalize_keys(attrs)

    %__MODULE__{
      id: to_string(Map.get(attrs, :id) || generate_id()),
      platform: attrs |> Map.fetch!(:platform) |> to_atom(),
      author: to_string(Map.get(attrs, :author, "unknown")),
      text: to_string(Map.get(attrs, :text, "")),
      url: attrs[:url],
      timestamp: parse_timestamp(Map.get(attrs, :timestamp)),
      sentiment: Map.get(attrs, :sentiment, :neutral),
      sentiment_value: Map.get(attrs, :sentiment_value, 0.0),
      sentiment_score: Map.get(attrs, :sentiment_score, 0),
      mock: Map.get(attrs, :mock, false)
    }
  end

  @doc """
  Millisecond epoch for the mention, which is what the ETS store keys on.
  """
  @spec epoch_ms(t()) :: integer()
  def epoch_ms(%__MODULE__{timestamp: timestamp}), do: DateTime.to_unix(timestamp, :millisecond)

  @doc """
  Human-friendly relative age, e.g. `"4m ago"`. Used by the TUI table.
  """
  @spec time_ago(t(), DateTime.t()) :: String.t()
  def time_ago(%__MODULE__{timestamp: timestamp}, now \\ DateTime.utc_now()) do
    seconds = DateTime.diff(now, timestamp, :second)

    cond do
      seconds < 0 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp normalize_keys(attrs) when is_list(attrs), do: normalize_keys(Map.new(attrs))

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp parse_timestamp(%DateTime{} = timestamp), do: timestamp
  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(unix) when is_integer(unix) do
    # Platforms hand back seconds (Reddit) — anything larger is already ms.
    if unix > 100_000_000_000 do
      DateTime.from_unix!(unix, :millisecond)
    else
      DateTime.from_unix!(unix, :second)
    end
  end

  defp parse_timestamp(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, timestamp, _offset} -> timestamp
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
