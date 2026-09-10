defmodule SmmMonitor.TUI.Renderers.GarnishRenderer do
  @moduledoc """
  Draws the dashboard with Garnish, for sessions arriving over SSH.

  The layout itself lives in `SmmMonitor.TUI.Renderers.Common`, shared
  with the local Ratatouille renderer — Garnish is a fork of Ratatouille
  and exposes the same view DSL, so the drawing code is identical.

  What differs is key translation. Termbox hands Ratatouille integer
  constants for special keys; Garnish decodes them against the client's
  terminfo and reports *mnemonics* (`:kcuu1` for cursor-up, `:kpp` for
  page-up), because over SSH the client's terminal type is whatever they
  happen to be running. Printable keys arrive as their byte value in
  both.
  """

  @behaviour SmmMonitor.TUI.Renderer

  use SmmMonitor.TUI.Renderers.Common,
    view: Garnish.View,
    constants: Garnish.Constants

  # Terminfo mnemonics, not termbox constants. Named after their terminfo
  # capabilities: kcuu1/kcud1 are cursor up/down, kpp/knp are previous and
  # next page, khome is home, kbs is backspace.
  @mnemonics %{
    kcuu1: {:key, :arrow_up},
    kcud1: {:key, :arrow_down},
    kpp: {:key, :page_up},
    knp: {:key, :page_down},
    khome: {:key, :home},
    kbs: {:key, :backspace},
    kdch1: {:key, :backspace}
  }

  # Control bytes the client sends directly.
  @enter 13
  @newline 10
  @escape 27
  @backspace 8
  @delete 127

  @doc """
  Maps a Garnish key event onto a `SmmMonitor.TUI.Model` key.

  Alt-modified keys are ignored rather than treated as their base
  character, so alt-q can't quit and alt-j can't scroll by accident.
  """
  @impl true
  def translate_event(%{alt: true}), do: :ignore

  def translate_event(%{key: key}) when is_atom(key) and not is_nil(key) do
    Map.get(@mnemonics, key, :ignore)
  end

  def translate_event(%{key: key}) when is_integer(key) do
    case key do
      @enter -> {:key, :enter}
      @newline -> {:key, :enter}
      @escape -> {:key, :escape}
      @backspace -> {:key, :backspace}
      @delete -> {:key, :backspace}
      char when char >= 32 and char < 127 -> {:char, char}
      _other -> :ignore
    end
  end

  def translate_event(_event), do: :ignore
end
