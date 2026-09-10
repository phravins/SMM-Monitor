defmodule SmmMonitor.Alerts.Incident do
  @moduledoc """
  One ongoing problem, from the moment it starts to the moment it stops.

  Without this, a condition that stays true would notify on every
  evaluation — sixty Slack messages an hour for one bad afternoon, which
  trains everybody to ignore the channel. An incident is opened the first
  time a condition trips, stays open while it keeps tripping, and is
  closed once the condition clears; exactly two notifications reach the
  channel, one at each end.

  ## Why not just a cooldown

  A cooldown ("don't repeat for an hour") is simpler and wrong in both
  directions: it goes quiet while a problem is still running, and it says
  nothing at all when the problem ends. What someone actually needs to
  know is *it started* and *it's over* — and how long it lasted, which
  only something that remembers the start can say.
  """

  alias SmmMonitor.Alerts.Alert

  @enforce_keys [:key, :alert, :opened_at]
  defstruct [
    :key,
    # The alert that opened it, kept so the resolution can describe what
    # it was that ended.
    :alert,
    :opened_at,
    :last_seen_at,
    # How many evaluations have found it still true. Useful evidence in
    # the resolved message and when tuning thresholds.
    occurrences: 1
  ]

  @type t :: %__MODULE__{
          key: {String.t() | nil, atom(), String.t() | nil},
          alert: Alert.t(),
          opened_at: DateTime.t(),
          last_seen_at: DateTime.t(),
          occurrences: pos_integer()
        }

  @doc "Opens an incident around the alert that started it."
  @spec open(Alert.t()) :: t()
  def open(%Alert{} = alert) do
    %__MODULE__{
      key: Alert.key(alert),
      alert: alert,
      opened_at: alert.at,
      last_seen_at: alert.at
    }
  end

  @doc """
  Records that the condition is still true.

  The alert is refreshed rather than kept, so the dashboard shows the
  current numbers of a running incident instead of the ones it opened
  with — a spike that is getting worse should read as worse.
  """
  @spec touch(t(), Alert.t()) :: t()
  def touch(%__MODULE__{} = incident, %Alert{} = alert) do
    %{
      incident
      | alert: %{alert | opened_at: incident.opened_at},
        last_seen_at: alert.at,
        occurrences: incident.occurrences + 1
    }
  end

  @doc """
  Closes an incident, returning the alert to send as the all-clear.

  `recovery` carries whatever the condition measured when it cleared, so
  the message can say what it recovered *to* rather than only that it
  did.
  """
  @spec close(t(), map(), DateTime.t()) :: Alert.t()
  def close(%__MODULE__{} = incident, recovery, at) do
    Alert.resolved(%{incident.alert | opened_at: incident.opened_at}, recovery, at)
  end
end
