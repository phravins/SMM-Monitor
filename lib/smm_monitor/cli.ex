defmodule SmmMonitor.CLI do
  @moduledoc """
  Escript entry point: `mix escript.build && ./smm_monitor`.

  A release (`mix release`) is the better choice for a long-running deploy;
  the escript exists because a single copyable binary is the easiest way to
  hand the dashboard to someone on the team.
  """

  @doc "Starts the dashboard. Any arguments are ignored for now."
  @spec main([String.t()]) :: no_return()
  def main(_argv \\ []) do
    SmmMonitor.TUI.run()
  end
end
