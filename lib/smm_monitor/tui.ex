defmodule SmmMonitor.TUI do
  @moduledoc """
  Entry point for the dashboard.

  The TUI takes over the terminal, so it is never started by the OTP
  application by default — `mix test` and headless runs would fight it for
  stdout. Start it explicitly with `mix smm.tui`, the escript, or by setting
  `SMM_TUI=1`.
  """

  import Ratatouille.Constants, only: [key: 1]

  # `q` to quit, per the spec, plus ctrl-c as the usual escape hatch. These
  # are handled by the runtime rather than the model so that termbox always
  # gets a chance to restore the terminal on the way out.
  @quit_events [{:ch, ?q}, {:ch, ?Q}, {:key, key(:ctrl_c)}]

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
