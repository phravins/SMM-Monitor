defmodule SmmMonitor.Persistence.ClientRecord do
  @moduledoc """
  The `clients` table: one row per monitored client.

  Unlike `mentions`, this is a small mutable set rather than an append-only
  log — a handful of rows, edited by hand from the config screen. It lives
  in SQLite next to the mentions rather than in the old JSON config file
  because mentions now reference it: keeping the two in separate stores
  would let a client vanish while its mentions still pointed at it.

  The id is the slug, used as the primary key, so a mention row carries a
  readable `client_id` rather than an opaque integer.

  ## A note on `active`

  SQLite has no boolean type, and Ecto's `:boolean` loader raises on
  anything but 1/0. Writes that go through this schema are cast for us;
  anything writing to the table *without* it — a migration using a raw
  table name, say — must write 1 or 0, or every later read of the whole
  table fails and the app falls back to running from memory.
  """

  use Ecto.Schema

  alias SmmMonitor.Client
  alias SmmMonitor.Client.AlertConfig

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "clients" do
    field(:name, :string)
    # Comma-separated rather than a join table: these are a handful of
    # short strings edited as one field in the UI, never queried across.
    field(:keywords, :string)
    field(:subreddits, :string)
    field(:active, :boolean, default: true)
    # The client's alert thresholds and watch phrases, as JSON.
    field(:alert_config, :string)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc "Maps a `Client` onto the map `insert_all/3` and `update_all/3` want."
  @spec from_client(Client.t(), DateTime.t()) :: map()
  def from_client(%Client{} = client, now \\ DateTime.utc_now()) do
    %{
      id: client.id,
      name: client.name,
      keywords: join(client.keywords),
      subreddits: join(client.subreddits),
      active: client.active,
      alert_config: encode_alerts(client.alerts),
      created_at: usec(client.created_at || now),
      updated_at: usec(now)
    }
  end

  @doc "Maps a stored row back onto a `Client`."
  @spec to_client(t()) :: Client.t()
  def to_client(%__MODULE__{} = record) do
    %Client{
      id: record.id,
      name: record.name,
      keywords: Client.normalize(record.keywords),
      subreddits: Client.normalize(record.subreddits),
      active: record.active,
      alerts: decode_alerts(record.alert_config),
      created_at: record.created_at
    }
  end

  defp encode_alerts(nil), do: nil

  defp encode_alerts(%AlertConfig{} = config) do
    config |> AlertConfig.to_map() |> Jason.encode!()
  end

  # A row written before alerting was configurable, or one hand-edited
  # into invalid JSON, falls back to the defaults rather than failing the
  # whole client list load.
  defp decode_alerts(nil), do: AlertConfig.new()

  defp decode_alerts(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, attrs} when is_map(attrs) -> AlertConfig.new(attrs)
      _invalid -> AlertConfig.new()
    end
  end

  defp join(values), do: values |> List.wrap() |> Enum.join(",")

  # :utc_datetime_usec rejects anything coarser than microseconds, and
  # adding zero re-stamps the precision (truncate/2 only ever lowers it).
  defp usec(%DateTime{} = at), do: DateTime.add(at, 0, :microsecond)
  defp usec(_at), do: DateTime.utc_now()
end
