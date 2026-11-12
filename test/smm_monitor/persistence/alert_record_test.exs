defmodule SmmMonitor.Persistence.AlertRecordTest do
  @moduledoc """
  Reading alert rows back. The database is a file anyone with access to
  the machine can edit, so a row is untrusted input: it must never mint
  new atoms (they are never garbage collected) or crash a report.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Alerts.Alert
  alias SmmMonitor.Persistence.AlertRecord

  test "round-trips an alert this build raised" do
    alert = %Alert{
      kind: :volume_spike,
      client_id: "acme",
      severity: :critical,
      state: :firing,
      window_ms: 3_600_000,
      at: ~U[2026-09-12 12:00:00Z],
      details: %{observed: 42, baseline: 7.0, ratio: :infinity, average_sentiment: 0.1}
    }

    record = struct(AlertRecord, AlertRecord.from_alert(alert))
    back = AlertRecord.to_alert(record)

    assert back.kind == :volume_spike
    assert back.severity == :critical
    assert back.state == :firing
    assert back.details.observed == 42
    assert back.details.average_sentiment == 0.1
    assert back.details.ratio == nil
  end

  test "an unknown kind, state or detail key does not create an atom" do
    name = "kind_from_a_hand_edited_row_#{System.unique_integer([:positive])}"

    record = %AlertRecord{
      kind: name,
      state: name,
      severity: name,
      details: Jason.encode!(%{name => 1})
    }

    alert = AlertRecord.to_alert(record)

    assert alert.kind == :unknown
    assert alert.state == :unknown
    assert alert.severity == :unknown
    assert alert.details == %{name => 1}

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "a corrupt details column reads as no details" do
    assert AlertRecord.to_alert(%AlertRecord{kind: "watch_phrase", details: "{not json"}).details ==
             %{}
  end
end
