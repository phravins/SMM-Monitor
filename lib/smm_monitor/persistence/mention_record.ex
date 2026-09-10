defmodule SmmMonitor.Persistence.MentionRecord do
  @moduledoc """
  The `mentions` table: one row per collected mention.

  Deliberately close to `SmmMonitor.Mention` rather than a normalised
  design. This is a log, not a model — nothing joins to it, and keeping
  the shapes aligned means the mapping in either direction is obvious.

  Sentiment is stored as scored, not recomputed on read: the processing
  layer already worked it out on the way in, and recomputing would mean a
  row's sentiment could silently change when the word lists are edited.
  """

  use Ecto.Schema

  alias SmmMonitor.Mention

  @type t :: %__MODULE__{}

  schema "mentions" do
    # The platform-scoped id from the source API. Unique per platform,
    # which is what stops a restart re-inserting what we already have.
    field(:mention_id, :string)
    field(:platform, :string)
    field(:author, :string)
    field(:text, :string)
    field(:url, :string)
    # When the mention was published, per the platform.
    field(:source_timestamp, :utc_datetime_usec)
    field(:sentiment, :string)
    # Normalised -1.0..1.0. Nullable: rows written before scoring became
    # numeric have only the raw integer.
    field(:sentiment_value, :float)
    field(:sentiment_score, :integer)
    field(:mock, :boolean, default: false)
    # When *we* stored it. Distinct from source_timestamp: a mention can
    # be published long before we see it.
    field(:inserted_at, :utc_datetime_usec)
  end

  @doc """
  Maps a `Mention` onto the plain map `insert_all/3` wants.

  `insert_all` is used rather than changesets because writes arrive a
  poll at a time and go in as one statement; there is nothing here a
  changeset would validate that the struct hasn't already guaranteed.
  """
  @spec from_mention(Mention.t(), DateTime.t()) :: map()
  def from_mention(%Mention{} = mention, now \\ DateTime.utc_now()) do
    %{
      mention_id: mention.id,
      platform: to_string(mention.platform),
      author: mention.author,
      text: mention.text,
      url: mention.url,
      source_timestamp: usec(mention.timestamp),
      sentiment: to_string(mention.sentiment),
      sentiment_value: mention.sentiment_value,
      sentiment_score: mention.sentiment_score,
      mock: mention.mock,
      inserted_at: usec(now)
    }
  end

  # :utc_datetime_usec insists on microsecond precision, and timestamps
  # parsed from an ISO8601 payload often carry milliseconds (or whole
  # seconds). Adding zero microseconds re-stamps the precision without
  # touching the value; truncate/2 only ever lowers it, so it can't help
  # here.
  defp usec(nil), do: nil
  defp usec(%DateTime{} = timestamp), do: DateTime.add(timestamp, 0, :microsecond)

  @doc "Maps a stored row back into a `Mention`, as the boot load needs."
  @spec to_mention(t()) :: Mention.t()
  def to_mention(%__MODULE__{} = record) do
    %Mention{
      id: record.mention_id,
      platform: String.to_existing_atom(record.platform),
      author: record.author,
      text: record.text,
      url: record.url,
      timestamp: record.source_timestamp,
      sentiment: sentiment_atom(record.sentiment),
      sentiment_value: sentiment_value(record),
      sentiment_score: record.sentiment_score || 0,
      mock: record.mock || false
    }
  end

  # Rows stored before scoring became numeric have no value. Rather than
  # rescoring them — which would silently rewrite history when the word
  # lists change — derive a rough one from the label they were given.
  defp sentiment_value(%__MODULE__{sentiment_value: value}) when is_float(value), do: value
  defp sentiment_value(%__MODULE__{sentiment: "positive"}), do: 0.5
  defp sentiment_value(%__MODULE__{sentiment: "negative"}), do: -0.5
  defp sentiment_value(%__MODULE__{}), do: 0.0

  # Only the three known labels are converted, so a corrupted or
  # hand-edited row can't crash the boot load with an unknown atom.
  defp sentiment_atom("positive"), do: :positive
  defp sentiment_atom("negative"), do: :negative
  defp sentiment_atom(_other), do: :neutral
end
