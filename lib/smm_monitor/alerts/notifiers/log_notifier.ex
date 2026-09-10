defmodule SmmMonitor.Alerts.Notifiers.LogNotifier do
  @moduledoc """
  Writes alerts to the log. Always on, and the one channel that cannot be
  misconfigured — if every other notifier is unset or down, the alert is
  still recorded somewhere.
  """

  @behaviour SmmMonitor.Alerts.Notifier

  require Logger

  alias SmmMonitor.Alerts.Alert

  @impl true
  def configured?, do: true

  @impl true
  # A resolution is good news and logs as such: an all-clear at :error
  # would trip whatever is watching the log for errors.
  def notify(%Alert{state: :resolved} = alert) do
    Logger.info("RESOLVED #{Alert.message(alert)}")
    :ok
  end

  def notify(%Alert{severity: :critical} = alert) do
    Logger.error("ALERT #{Alert.message(alert)}")
    :ok
  end

  def notify(%Alert{} = alert) do
    Logger.warning("ALERT #{Alert.message(alert)}")
    :ok
  end
end
