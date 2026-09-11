defmodule SmmMonitor.TUI.Preflight do
  @moduledoc """
  Checks the dashboard can actually be drawn, before anything tries to.

  The terminal UI is drawn by termbox, a C library loaded as an Erlang
  NIF. If that library won't load, the failure surfaces four frames deep
  — `Ratatouille.Window` calling `ExTermbox.Bindings.init/0` on a module
  that isn't there — and OTP reports it the way it reports any failed
  child: a `Kernel pid terminated` line, a nested `shutdown` tuple, and a
  crash dump written to whatever directory you happened to be in.

  Somebody who downloaded a binary and typed `smm-monitor` cannot read
  that, and the one thing it never says is the thing they need to do.

  ## Why the library fails to load

  Almost always: a stale unpacked copy. The binary carries its own Erlang
  runtime and libraries compressed inside it, and unpacks them on first
  run into a directory named after the app and runtime versions —

      ~/.local/share/.burrito/standalone_erts-13.2.2.5_0.1.0

  Burrito decides whether to unpack by looking for `_metadata.json` in
  that directory and nothing else (`wrapper.zig`: *"If the metadata file
  exists, don't install again"*). So once a directory exists under that
  name it is used forever, whatever is in it. A copy left by an older or
  differently-built binary of the same version is never replaced, and
  downloading the binary again cannot help: the new payload is never
  unpacked.

  The symptom is specific, because the runtime inside these binaries is
  linked against musl while a library built on an ordinary Linux machine
  is linked against glibc:

      Failed to load NIF library: ... __snprintf_chk: symbol not found

  `__snprintf_chk` is glibc's fortified `snprintf`. musl has no such
  symbol, so a glibc-built library loaded by a musl runtime fails on the
  first one it needs.

  Deleting the directory fixes it: the next run unpacks the payload the
  binary is actually carrying. It holds only the unpacked program —
  mentions, clients and settings live elsewhere — so it is safe to
  delete, which is what makes it a reasonable thing to tell somebody to
  do.
  """

  @bindings ExTermbox.Bindings

  @typedoc "Why the dashboard can't start."
  @type problem :: :termbox_unavailable | :unsupported_terminal

  # termbox drives the screen through a terminfo entry. `dumb` has none
  # worth the name, and an empty TERM names nothing at all, so
  # `tb_init()` returns TB_EUNSUPPORTED_TERMINAL. Ratatouille asserts
  # `:ok = bindings.init()`, so that arrives as a MatchError inside a
  # supervisor's child, and the practical effect is that the app exits 1
  # having printed nothing whatsoever. Catching the two terminals that
  # cannot possibly work turns the commonest version of that into a
  # sentence.
  @unusable_terminals ["", "dumb"]

  @doc """
  `:ok`, or `{:error, :termbox_unavailable}` if termbox didn't load.

  A NIF that fails in `on_load` takes its module down with it, so the
  module being absent is the test. `function_exported?/3` covers the
  stranger case of the module loading without its NIF entry points.
  """
  @spec check() :: :ok | {:error, problem()}
  def check do
    cond do
      not available?() -> {:error, :termbox_unavailable}
      not drawable_terminal?() -> {:error, :unsupported_terminal}
      true -> :ok
    end
  end

  @doc """
  Whether `TERM` names a terminal termbox could draw on.

  Only rules out the two that certainly can't be drawn on. A terminal
  named but not described on this machine still fails inside termbox,
  where this can't see it.
  """
  @spec drawable_terminal?(String.t() | nil) :: boolean()
  def drawable_terminal?(term \\ System.get_env("TERM")) do
    String.trim(term || "") not in @unusable_terminals
  end

  @doc "Whether termbox's bindings loaded."
  @spec available?() :: boolean()
  def available? do
    match?({:module, _}, Code.ensure_loaded(@bindings)) and
      function_exported?(@bindings, :init, 0)
  end

  @doc """
  What to print when the dashboard can't start.

  Takes the install directory and OS rather than reading them, so the
  wording for a machine can be tested from any other machine.

  `root` is the unpacked copy — Burrito exports it as `RELEASE_ROOT`, and
  it is exactly the directory to delete. `nil` means this isn't a
  downloaded binary at all but a checkout, where the fix is to rebuild
  the dependency instead.
  """
  @spec explain(problem(), keyword()) :: String.t()
  def explain(problem, opts \\ [])

  def explain(:termbox_unavailable, opts) do
    root = Keyword.get_lazy(opts, :root, &install_root/0)
    os = Keyword.get_lazy(opts, :os, &host_os/0)

    if root do
      """
      SMM Monitor could not start the dashboard.

      The part that draws the screen wouldn't load. This happens when the
      unpacked copy of the app is stale — left behind by an earlier build
      of the same version — and it is not replaced by downloading the app
      again, because a copy that already exists is always reused.

      To fix it, delete the unpacked copy and start SMM Monitor again:

      #{indent(remedy(os, root))}

      That folder holds the unpacked program only. Your clients, your
      mentions and your settings are stored elsewhere and are untouched.
      """
    else
      """
      SMM Monitor could not start the dashboard.

      The termbox library, which draws the screen, would not load. In a
      checkout that usually means it was built for a different machine or
      a different Erlang. Rebuild it:

      #{indent("mix deps.compile ex_termbox --force")}
      """
    end
  end

  def explain(:unsupported_terminal, opts) do
    term = Keyword.get_lazy(opts, :term, fn -> System.get_env("TERM") end)

    """
    SMM Monitor could not start the dashboard.

    It draws a full-screen dashboard, and that needs a terminal that can
    draw one. This one says it is #{inspect(term || "")}, which can't.

    If you are running it through a script, a scheduled job, or an
    editor's built-in output pane, run it in a terminal window instead.
    On Windows, use Windows Terminal rather than the old console window.

    To run it without the dashboard — logging to the screen, for a server
    or a cron job — set SMM_TUI=0.
    """
  end

  # Windows has no `rm`, and telling somebody to run one is how you get a
  # support thread instead of a working dashboard.
  defp remedy({:win32, _}, root) do
    """
    Remove-Item -Recurse -Force "#{root}"
    smm-monitor
    """
  end

  defp remedy(_unix, root) do
    """
    rm -rf "#{root}"
    smm-monitor
    """
  end

  @doc """
  The unpacked copy's directory, or `nil` outside a downloaded binary.

  Burrito's launcher sets `RELEASE_ROOT` to the directory it unpacked
  into; a Mix release sets it too, which is why this is guarded by
  `Standalone.running?/0`.
  """
  @spec install_root() :: String.t() | nil
  def install_root do
    if SmmMonitor.Standalone.running?(), do: System.get_env("RELEASE_ROOT")
  end

  defp host_os, do: :os.type()

  defp indent(text) do
    text
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
