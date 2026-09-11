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
  @type problem :: :termbox_unavailable

  @doc """
  `:ok`, or `{:error, :termbox_unavailable}` if termbox didn't load.

  A NIF that fails in `on_load` takes its module down with it, so the
  module being absent is the test. `function_exported?/3` covers the
  stranger case of the module loading without its NIF entry points.
  """
  @spec check() :: :ok | {:error, problem()}
  def check do
    if available?(), do: :ok, else: {:error, :termbox_unavailable}
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
  def explain(:termbox_unavailable, opts \\ []) do
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
