defmodule SmmMonitor.TUI.Renderers.RatatouilleRenderer do
  @moduledoc """
  Draws the dashboard with Ratatouille, for the local terminal.

  The layout itself lives in `SmmMonitor.TUI.Renderers.Common`, shared
  with the SSH renderer. Only key translation is specific to this
  library.
  """

  @behaviour SmmMonitor.TUI.Renderer

  use SmmMonitor.TUI.Renderers.Common,
    view: Ratatouille.View,
    constants: Ratatouille.Constants

  import Ratatouille.Constants, only: [key: 1]

  # Termbox reports non-printable keys as integer constants; map only the
  # ones the dashboard actually navigates with.
  @navigation_keys %{
    key(:arrow_up) => {:key, :arrow_up},
    key(:arrow_down) => {:key, :arrow_down},
    key(:pgup) => {:key, :page_up},
    key(:pgdn) => {:key, :page_down},
    key(:home) => {:key, :home},
    # Needed by the config screen's text input.
    key(:enter) => {:key, :enter},
    key(:esc) => {:key, :escape},
    key(:backspace) => {:key, :backspace},
    key(:backspace2) => {:key, :backspace},
    key(:space) => {:char, ?\s}
  }

  @doc """
  Maps a Ratatouille event onto a `SmmMonitor.TUI.Model` key.

  Ratatouille reports printable characters in `:ch` and everything else as
  a `:key` constant, so both paths are handled here and the model never
  sees a raw event.
  """
  @impl true
  def translate_event(%{ch: ch}) when ch > 0, do: {:char, ch}

  def translate_event(%{key: key}) do
    Map.get(@navigation_keys, key, :ignore)
  end

  def translate_event(_event), do: :ignore
end
