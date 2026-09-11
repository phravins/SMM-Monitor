defmodule SmmMonitor.Persistence.AlertRecord do
  @moduledoc """
  The `alerts` table: one row per alert raised or resolved.

  Written so that an alert history outlives the process that raised it.
  Reports are the reason — an alert history that only exists in one
  GenServer's memory can't be put in a document — but it also means a
  restart no longer forgets what fired this morning.

  The rendered message is stored alongside the numbers. Re-deriving the
  wording later from stored numbers would make old alerts silently
  change their text when the phrasing is improved, and a report is a
  record of what was said at the time.
  """

  use Ecto.Schema

  alias SmmMonitor.Alerts.Alert

  @type t :: %__MODULE__{}

  schema "alerts" do
    field(:client_id, :string)
    field(:kind, :string)
    field(:subject, :string)
    field(:state, :string)
    field(:severity, :string)
    field(:message, :string)
    field(:window_ms, :integer)
    field(:raised_at, :utc_datetime_usec)
    field(:opened_at, :utc_datetime_usec)
    field(:details, :string)
    field(:inserted_at, :utc_datetime_usec)
  end

  @doc "Maps an `Alert` onto the map `insert_all/3` wants."
  @spec from_alert(Alert.t(), DateTime.t()) :: map()
  def from_alert(%Alert{} = alert, now \\ DateTime.utc_now()) do
    %{
      client_id: alert.client_id,
      kind: to_string(alert.kind),
      subject: alert.subject,
      state: to_string(alert.state),
      severity: to_string(alert.severity || :warning),
      message: Alert.message(alert),
      window_ms: alert.window_ms,
      raised_at: usec(alert.at),
      opened_at: alert.opened_at && usec(alert.opened_at),
      details: encode(alert.details),
      inserted_at: usec(now)
    }
  end

  @doc "Maps a stored row back onto an `Alert`."
  @spec to_alert(t()) :: Alert.t()
  def to_alert(%__MODULE__{} = record) do
    %Alert{
      kind: safe_atom(record.kind),
      client_id: record.client_id,
      client_name: nil,
      subject: record.subject,
      severity: safe_atom(record.severity),
      window_ms: record.window_ms,
      at: record.raised_at,
      opened_at: record.opened_at,
      details: decode(record.details),
      state: safe_atom(record.state)
    }
  end

  @doc """
  The alert kind, as an atom.

  Safe against a row whose kind names a condition this build doesn't
  know — and, more usually, against the conditions module simply not
  being loaded: a report generated from the CLI runs with alerting off,
  so `:sentiment_drop` may never have been created in that VM.
  """
  @spec kind(t()) :: atom()
  def kind(%__MODULE__{kind: kind}), do: safe_atom(kind)

  @doc "The alert state (`:firing` or `:resolved`), as an atom."
  @spec state(t()) :: atom()
  def state(%__MODULE__{state: state}), do: safe_atom(state)

  @doc """
  The stored message, which is what a report shows.

  Kept separate from `to_alert/1` because the wording is a record of
  what was sent at the time, not something to re-render.
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message || ""

  # A hand-edited or future-version row must not crash a report with an
  # unknown atom — and neither must a perfectly ordinary one whose atom
  # this VM has not happened to create yet.
  defp safe_atom(nil), do: nil

  defp safe_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> String.to_atom(value)
  end

  # The mention inside a phrase alert's details is a whole struct; only
  # its id is worth keeping, and :infinity has no JSON representation.
  defp encode(details) do
    details
    |> Map.new(fn
      {:mention, mention} -> {:mention_id, mention && mention.id}
      {:ratio, :infinity} -> {:ratio, nil}
      pair -> pair
    end)
    |> Jason.encode!()
  end

  defp decode(nil), do: %{}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> atomize(decoded)
      _invalid -> %{}
    end
  end

  defp atomize(map) do
    Map.new(map, fn {key, value} -> {safe_atom(key) || key, value} end)
  end

  defp usec(%DateTime{} = at), do: DateTime.add(at, 0, :microsecond)
  defp usec(_at), do: DateTime.utc_now()
end
