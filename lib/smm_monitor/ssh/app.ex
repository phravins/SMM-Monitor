defmodule SmmMonitor.SSH.App do
  @moduledoc """
  The dashboard as served over SSH.

  Garnish spawns one channel process per SSH session, each holding its own
  model. That is what gives every viewer their own tab, scroll position
  and cursor while they all read the same shared ETS table — no state is
  held anywhere common to two sessions, so there is nothing to leak
  between them.

  ## What Garnish needed that Ratatouille didn't

  Garnish is a fork of Ratatouille for SSH, but its `Garnish.App`
  behaviour is *not* `Ratatouille.App`. Three differences mattered:

    * `handle_key/2` replaces `update/2` receiving `{:event, event}`, and
      `init/1` returns `{:ok, model}` rather than a bare model.
    * There is no `subscribe/1`, so the once-a-second refresh is our own
      `Process.send_after/3` loop through `handle_info/2`.
    * Special keys arrive as terminfo mnemonics rather than termbox
      constants (see `SmmMonitor.TUI.Renderers.GarnishRenderer`).

  None of that reached `SmmMonitor.TUI.Model`, which is the point of
  having kept the dashboard's behaviour free of any TUI library: the
  model, and therefore every state transition and every test over it, is
  shared with the local terminal app unchanged.

  ## Read-only

  Sessions built here are read-only. The config screen renders, so remote
  viewers can see what is being tracked, but editing is refused by the
  model itself. The flag is set at construction rather than derived from
  the connection, so it cannot be argued out of later.
  """

  @behaviour Garnish.App

  require Logger

  alias SmmMonitor.TUI.Model
  alias SmmMonitor.TUI.Renderers.GarnishRenderer

  @tick_ms 1_000

  # Ctrl-C and Ctrl-D close the session. `q` is deliberately *not* here:
  # the config screen's text input has to be able to receive it, exactly
  # as in the local app.
  @quit_keys [3, 4]

  @impl true
  def init(context) do
    log_connection(context)

    model = Model.new(%{window: window(context), read_only: true})
    schedule_tick()

    {:ok, model, quit_keys: @quit_keys}
  end

  @impl true
  def handle_key(event, model) do
    case GarnishRenderer.translate_event(event) do
      :ignore ->
        # Nothing changed, so tell Garnish not to redraw.
        {:ok, model, render: false}

      key ->
        model = Model.handle_key(model, key)

        if model.quit do
          {:stop, :normal, model}
        else
          {:ok, model}
        end
    end
  end

  @impl true
  def handle_info(:tick, model) do
    schedule_tick()
    {:ok, Model.refresh(model)}
  end

  def handle_info(_message, model), do: {:ok, model, render: false}

  @impl true
  def handle_resize(size, model) do
    {rows, cols} = usable_size(size)
    {:ok, Model.resize(model, %{window: %{height: rows, width: cols}})}
  end

  @impl true
  def render(model), do: GarnishRenderer.render(model)

  @impl true
  def terminate(_reason, _model), do: :ok

  # --- internals ------------------------------------------------------------

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  # A client that reports no usable size (a non-interactive ssh
  # invocation, say) would otherwise produce a 0x0 render box and a
  # garbled screen. Fall back to the conventional 80x24.
  @fallback_size {24, 80}

  defp window(%{size: size}),
    do: size |> usable_size() |> then(fn {rows, cols} -> %{height: rows, width: cols} end)

  defp window(_context), do: window(%{size: @fallback_size})

  defp usable_size({rows, cols})
       when is_integer(rows) and is_integer(cols) and rows > 0 and cols > 0,
       do: {rows, cols}

  defp usable_size(_size), do: @fallback_size

  # Worth a log line: this is someone connecting to the dashboard from
  # another machine.
  defp log_connection(%{connection: connection}) when not is_nil(connection) do
    peer =
      case :ssh.connection_info(connection, [:peer]) do
        [peer: {_name, {address, port}}] -> "#{:inet.ntoa(address)}:#{port}"
        _other -> "unknown"
      end

    Logger.info("ssh: dashboard session opened from #{peer}")
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp log_connection(_context), do: :ok
end
