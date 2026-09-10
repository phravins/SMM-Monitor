defmodule SmmMonitor.TUI do
  @moduledoc """
  Entry point for the dashboard.

  The TUI takes over the terminal, so it is never started by the OTP
  application by default — `mix test` and headless runs would fight it for
  stdout. Start it explicitly with `mix smm.tui`, the escript, or by setting
  `SMM_TUI=1`.
  """

  import Ratatouille.Constants, only: [key: 1]

  # Only ctrl-c. `q` used to be here, but the runtime checks quit events
  # *before* handing the key to the app, so the config screen's text input
  # could never have captured one — a brand term containing a `q` would be
  # untypeable. `q` is handled in the model instead (see
  # `SmmMonitor.TUI.App`); ctrl-c stays here as an always-available escape
  # hatch that no text field needs.
  @quit_events [{:key, key(:ctrl_c)}]

  @doc """
  Child spec for the Ratatouille runtime supervisor.

  `shutdown: :system` stops the whole VM when the user quits, which is what
  you want from a foreground CLI.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    runtime =
      Keyword.merge(
        [
          app: SmmMonitor.TUI.App,
          shutdown: Keyword.get(opts, :shutdown, :system),
          quit_events: @quit_events
        ],
        Keyword.get(opts, :runtime, [])
      )

    %{
      id: __MODULE__,
      start: {Ratatouille.Runtime.Supervisor, :start_link, [[runtime: runtime]]},
      type: :supervisor
    }
  end

  @doc """
  Starts the dashboard in the foreground and blocks until the user quits.

  Used by the escript and the `smm.tui` mix task.
  """
  @spec run(keyword()) :: no_return()
  def run(opts \\ []) do
    {:ok, _pid} = Application.ensure_all_started(:smm_monitor)
    {:ok, _pid} = Supervisor.start_link([child_spec(opts)], strategy: :one_for_one)

    # The runtime halts the VM on quit; until then, just stay out of its way.
    Process.sleep(:infinity)
  end
end
