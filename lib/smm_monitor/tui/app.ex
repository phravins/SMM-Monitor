defmodule SmmMonitor.TUI.App do
  @moduledoc """
  The Ratatouille application — the Elm Architecture triple.

  This module is intentionally thin. It is the adapter between Ratatouille's
  runtime and our own pure `SmmMonitor.TUI.Model`:

    * `init/1`   — builds the model from the runtime context
    * `update/2` — translates events into model keys and applies them
    * `render/1` — delegates to the configured renderer

  All the dashboard's behaviour lives in the model, and all its appearance
  lives in the renderer, so neither is coupled to Ratatouille's runtime.
  """

  @behaviour Ratatouille.App

  alias Ratatouille.Runtime.Subscription
  alias SmmMonitor.TUI.Model

  # The processing layer is read once a second. Fetchers poll every 30s, but
  # a faster UI tick keeps "time ago" columns honest and makes new mentions
  # appear promptly.
  @tick_ms 1_000

  @impl true
  def init(context), do: Model.new(context)

  @impl true
  def subscribe(_model), do: Subscription.interval(@tick_ms, :tick)

  @impl true
  def update(model, message) do
    case message do
      :tick ->
        Model.refresh(model)

      {:event, event} ->
        case renderer().translate_event(event) do
          :ignore -> model
          key -> model |> Model.handle_key(key) |> maybe_quit()
        end

      {:refresh, _event} ->
        # Terminal resize: recompute how many table rows fit.
        model |> Model.resize(%{}) |> Model.refresh()

      _other ->
        model
    end
  end

  @impl true
  def render(model), do: renderer().render(model)

  # `q` is handled by the model rather than as a Ratatouille quit event,
  # because the runtime checks quit events *before* the app sees the key —
  # so a text field could never capture a `q`, and brand terms containing
  # one would be untypeable. Shutting down here goes through the same
  # System.stop/0 the runtime's own `shutdown: :system` uses, which stops
  # the application, terminates Ratatouille.Window, and lets termbox
  # restore the terminal on the way out.
  defp maybe_quit(%Model{quit: true} = model) do
    System.stop()
    model
  end

  defp maybe_quit(model), do: model

  @doc "The renderer module, so the drawing layer stays swappable via config."
  @spec renderer() :: module()
  def renderer do
    SmmMonitor.config(:renderer, SmmMonitor.TUI.Renderers.RatatouilleRenderer)
  end
end
