defmodule Mix.Tasks.Smm.Tui do
  @moduledoc """
  Runs the SMM Monitor dashboard.

      mix smm.tui

  Starts the supervision tree (fetchers + processing) and takes over the
  terminal. Mock mode is the default, so this works with no API keys; set
  `SMM_MOCK_MODE=false` plus the relevant credentials for live data.

  Press `q` to quit.
  """

  @shortdoc "Runs the SMM Monitor terminal dashboard"

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    # Mix's own shell writes would land on top of the rendered view.
    Mix.shell(Mix.Shell.Quiet)
    SmmMonitor.TUI.run()
  end
end
