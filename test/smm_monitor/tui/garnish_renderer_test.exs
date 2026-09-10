defmodule SmmMonitor.TUI.Renderers.GarnishRendererTest do
  @moduledoc """
  Key translation for SSH sessions.

  Garnish decodes special keys against the *client's* terminfo and reports
  mnemonics, where termbox gives Ratatouille integer constants. This is
  the one part of the drawing layer the two renderers can't share.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.TUI.Renderers.GarnishRenderer, as: Renderer

  describe "printable keys" do
    test "arrive as their byte value" do
      assert {:char, ?c} = Renderer.translate_event(%{key: ?c, alt: false, data: "c"})
      assert {:char, ?q} = Renderer.translate_event(%{key: ?q, alt: false, data: "q"})
      assert {:char, ?\s} = Renderer.translate_event(%{key: ?\s, alt: false, data: " "})
    end

    test "include the whole printable range" do
      assert {:char, ?~} = Renderer.translate_event(%{key: ?~, alt: false, data: "~"})
      assert {:char, ?0} = Renderer.translate_event(%{key: ?0, alt: false, data: "0"})
    end
  end

  describe "control keys" do
    test "enter, escape and backspace map for the config editor" do
      assert {:key, :enter} = Renderer.translate_event(%{key: 13, alt: false, data: "\r"})
      assert {:key, :enter} = Renderer.translate_event(%{key: 10, alt: false, data: "\n"})
      assert {:key, :escape} = Renderer.translate_event(%{key: 27, alt: false, data: "\e"})
      assert {:key, :backspace} = Renderer.translate_event(%{key: 8, alt: false, data: "\b"})
      # Most terminals send DEL for backspace.
      assert {:key, :backspace} = Renderer.translate_event(%{key: 127, alt: false, data: "\d"})
    end

    test "other control bytes are ignored" do
      assert :ignore = Renderer.translate_event(%{key: 1, alt: false, data: <<1>>})
    end
  end

  describe "terminfo mnemonics" do
    test "map the navigation keys the dashboard uses" do
      assert {:key, :arrow_up} = Renderer.translate_event(%{key: :kcuu1, alt: false, data: "\e[A"})

      assert {:key, :arrow_down} =
               Renderer.translate_event(%{key: :kcud1, alt: false, data: "\e[B"})

      assert {:key, :page_up} = Renderer.translate_event(%{key: :kpp, alt: false, data: "\e[5~"})
      assert {:key, :page_down} = Renderer.translate_event(%{key: :knp, alt: false, data: "\e[6~"})
      assert {:key, :home} = Renderer.translate_event(%{key: :khome, alt: false, data: "\e[H"})
      assert {:key, :backspace} = Renderer.translate_event(%{key: :kbs, alt: false, data: "\d"})
    end

    test "unknown mnemonics are ignored rather than guessed at" do
      assert :ignore = Renderer.translate_event(%{key: :kf13, alt: false, data: "\e[25~"})
      assert :ignore = Renderer.translate_event(%{key: :kcub1, alt: false, data: "\e[D"})
    end
  end

  describe "alt-modified keys" do
    test "are ignored rather than treated as the base character" do
      # Otherwise alt-q would quit and alt-j would scroll.
      assert :ignore = Renderer.translate_event(%{key: ?q, alt: true, data: "\eq"})
      assert :ignore = Renderer.translate_event(%{key: :kcuu1, alt: true, data: "\e\e[A"})
    end
  end

  describe "unrecognised events" do
    test "are ignored" do
      assert :ignore = Renderer.translate_event(%{key: nil, alt: false, data: "\e[?1;2c"})
      assert :ignore = Renderer.translate_event(%{})
    end
  end
end
