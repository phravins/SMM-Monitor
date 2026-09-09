defmodule SmmMonitor.TUI.Renderer do
  @moduledoc """
  The contract between the dashboard's state and whatever draws it.

  `SmmMonitor.TUI.Model` holds all the behaviour; a renderer only turns that
  model into its library's view representation. Swapping Ratatouille for
  another TUI library is therefore a matter of adding a module here and
  pointing `config :smm_monitor, :renderer` at it.
  """

  @doc "Turns the dashboard model into a view for the underlying TUI library."
  @callback render(SmmMonitor.TUI.Model.t()) :: term()

  @doc """
  Translates a library-specific input event into the normalised key the
  model understands, or `:ignore`.
  """
  @callback translate_event(term()) :: SmmMonitor.TUI.Model.key() | :ignore
end
