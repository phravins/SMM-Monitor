defmodule SmmMonitor.Application do
  @moduledoc """
  Top of the supervision tree.

  Layers are added as they land; the strategy is `:one_for_one` so that a
  crash in one layer never takes the others with it.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []

    opts = [strategy: :one_for_one, name: SmmMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
