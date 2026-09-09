defmodule SmmMonitor.Application do
  @moduledoc """
  Top of the supervision tree.

      SmmMonitor.Supervisor              (one_for_one)
      └── SmmMonitor.Processing.Processor — ETS owner + aggregation

  The strategy is `:one_for_one` so that a crash in one layer never takes
  the others with it. The processor starts first because it owns the ETS
  table every other layer reads from.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [SmmMonitor.Processing.Processor]

    opts = [strategy: :one_for_one, name: SmmMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
