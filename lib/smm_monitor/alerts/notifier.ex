defmodule SmmMonitor.Alerts.Notifier do
  @moduledoc """
  Where a raised alert goes.

  Each channel is a module implementing `notify/1`. They are called in
  turn and independently: a webhook that is down must not stop the alert
  reaching the log, so a notifier that fails is logged and the rest still
  run.
  """

  alias SmmMonitor.Alerts.Alert

  @callback notify(Alert.t()) :: :ok | {:error, term()}

  @doc "Whether this notifier is configured well enough to be worth calling."
  @callback configured?() :: boolean()

  @optional_callbacks configured?: 0
end
