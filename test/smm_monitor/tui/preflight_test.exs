defmodule SmmMonitor.TUI.PreflightTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.TUI.Preflight

  @root "/home/someone/.local/share/.burrito/standalone_erts-13.2.2.5_0.1.0"

  describe "check/0" do
    test "passes when termbox loaded, which on a working machine it has" do
      assert Preflight.check() == :ok
      assert Preflight.available?()
    end
  end

  describe "drawable_terminal?/1" do
    test "rejects the terminals termbox cannot draw on" do
      refute Preflight.drawable_terminal?("dumb")
      refute Preflight.drawable_terminal?("")
      refute Preflight.drawable_terminal?(nil)
      refute Preflight.drawable_terminal?("  ")
    end

    test "accepts an ordinary terminal" do
      assert Preflight.drawable_terminal?("xterm-256color")
      assert Preflight.drawable_terminal?("screen")
    end
  end

  describe "explain/2 for a terminal that cannot draw" do
    setup do
      %{text: Preflight.explain(:unsupported_terminal, term: "dumb")}
    end

    test "says which terminal it found", %{text: text} do
      assert text =~ ~s("dumb")
    end

    # Without this the message is a dead end for anybody running it from
    # cron or a script, which is exactly who hits it.
    test "offers the headless way out", %{text: text} do
      assert text =~ "SMM_TUI=0"
    end

    test "does not blame a stale unpacked copy", %{text: text} do
      refute text =~ "rm -rf"
    end
  end

  describe "explain/2 for a downloaded binary" do
    setup do
      %{text: Preflight.explain(:termbox_unavailable, root: @root, os: {:unix, :linux})}
    end

    test "names the directory to delete", %{text: text} do
      assert text =~ ~s(rm -rf "#{@root}")
    end

    test "says what to run afterwards", %{text: text} do
      assert text =~ "smm-monitor"
    end

    # The whole point of naming the directory is that somebody will paste
    # `rm -rf` at it. They deserve to know it isn't their data.
    test "promises their data is somewhere else", %{text: text} do
      assert text =~ "untouched"
    end

    # The failure people will actually hit is a reinstall that changed
    # nothing, so the message has to head that off.
    test "explains why downloading it again won't help", %{text: text} do
      assert unwrapped(text) =~ "not replaced by downloading the app again"
    end

    test "says nothing about NIFs, symbols or supervision trees", %{text: text} do
      refute text =~ ~r/NIF|symbol|supervis|shutdown/i
    end
  end

  describe "explain/2 elsewhere" do
    test "uses PowerShell's spelling on Windows" do
      text = Preflight.explain(:termbox_unavailable, root: @root, os: {:win32, :nt})

      assert text =~ ~s(Remove-Item -Recurse -Force "#{@root}")
      refute text =~ "rm -rf"
    end

    test "in a checkout, points at the dependency rather than an unpacked copy" do
      text = Preflight.explain(:termbox_unavailable, root: nil)

      assert text =~ "mix deps.compile ex_termbox --force"
      refute text =~ "rm -rf"
    end
  end

  # The message is wrapped for a terminal, so an assertion about its
  # wording shouldn't depend on where the lines happen to break.
  defp unwrapped(text), do: String.replace(text, ~r/\s+/, " ")

  describe "install_root/0" do
    test "is nil unless this is a downloaded binary" do
      refute SmmMonitor.Standalone.running?()
      assert Preflight.install_root() == nil
    end

    test "is the directory the binary unpacked into" do
      System.put_env("__BURRITO", "1")
      System.put_env("RELEASE_ROOT", @root)
      on_exit(fn -> System.delete_env("__BURRITO") end)

      assert Preflight.install_root() == @root
    end
  end
end
