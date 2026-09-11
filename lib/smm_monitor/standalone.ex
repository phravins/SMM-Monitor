defmodule SmmMonitor.Standalone do
  @moduledoc """
  The bits that are only true when this is a downloaded binary.

  `mix smm.tui`, the systemd release and the test suite all start the
  same application in the same way. The single-file build — the one
  somebody downloads, double-clicks and expects a dashboard from — needs
  two things none of the others do.

  ## It should show the dashboard

  Every other way of starting is headless by default, because a terminal
  UI fighting `mix test` for stdout is nobody's idea of a good time. A
  binary called `smm-monitor` that boots and then sits there silently is
  worse. So `SMM_TUI` defaults to on here and off everywhere else — see
  `config/runtime.exs`.

  ## It should stay running

  Burrito starts the node through `elixir start_cli` *without* the
  `--no-halt` that a normal Mix release passes. With nothing to run,
  Elixir's CLI halts the node the instant boot finishes: the supervision
  tree comes up, termbox takes the screen, and the VM exits — you see a
  cleared terminal and nothing else. It is a very fast, very confusing
  failure.

  `hold_open/0` registers an exit hook that blocks instead, which is the
  last thing the CLI does before halting. Quitting the dashboard doesn't
  go through it: `q` calls `System.stop/0`, which shuts the node down
  through OTP and never reaches an Elixir exit hook.
  """

  @doc """
  Whether this process is running from a Burrito-built binary.

  The wrapper sets `__BURRITO` before it launches the node; nothing else
  does.
  """
  @spec running?() :: boolean()
  def running?, do: System.get_env("__BURRITO") == "1"

  @doc """
  The path of the binary that started this, or `nil`.

  Worth having for the "you're running an old copy" kind of message, and
  for telling somebody where their download actually went.
  """
  @spec binary_path() :: String.t() | nil
  def binary_path, do: System.get_env("__BURRITO_BIN_PATH")

  @doc """
  Arguments the binary was invoked with.

  Burrito passes them after `-extra`, which is where
  `:init.get_plain_arguments/0` reads from. Read directly rather than
  through `Burrito.Util.Args` so the runtime doesn't depend on a
  build-time-only package.
  """
  @spec argv() :: [String.t()]
  def argv do
    if running?() do
      Enum.map(:init.get_plain_arguments(), &to_string/1)
    else
      System.argv()
    end
  end

  @doc """
  Stops Elixir's CLI from halting the node the moment boot finishes.

  A no-op unless this is the packaged binary — every other way in either
  passes `--no-halt` already or wants the node to exit.
  """
  @spec hold_open() :: :ok
  def hold_open do
    if running?(), do: System.at_exit(fn _status -> Process.sleep(:infinity) end)

    :ok
  end
end
