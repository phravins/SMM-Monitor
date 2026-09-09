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
          key -> Model.handle_key(model, key)
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

  @doc "The renderer module, so the drawing layer stays swappable via config."
  @spec renderer() :: module()
  def renderer do
    SmmMonitor.config(:renderer, SmmMonitor.TUI.Renderers.RatatouilleRenderer)
  end
end
