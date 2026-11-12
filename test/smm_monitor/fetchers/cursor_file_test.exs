defmodule SmmMonitor.Fetchers.CursorFileTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.CursorFile

  @moduletag :tmp_dir

  test "writes a private file and reads it back", %{tmp_dir: dir} do
    path = Path.join(dir, "x.cursor")

    assert CursorFile.write(path, "123") == :ok
    assert CursorFile.read(path) == "123"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    refute File.exists?(path <> ".tmp")

    assert CursorFile.write(path, ["4", "56"]) == :ok
    assert CursorFile.read(path) == "456"
  end

  test "creates a missing directory private", %{tmp_dir: dir} do
    path = Path.join([dir, "state", "x.cursor"])

    assert CursorFile.write(path, "1") == :ok
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
  end

  test "replaces a stale temporary file rather than writing through it", %{tmp_dir: dir} do
    path = Path.join(dir, "x.cursor")
    elsewhere = Path.join(dir, "elsewhere")
    File.write!(elsewhere, "keep me")
    File.ln_s!(elsewhere, path <> ".tmp")

    assert CursorFile.write(path, "1") == :ok
    assert File.read!(elsewhere) == "keep me"
    assert CursorFile.read(path) == "1"
  end

  test "a nil path reads nothing and writes nowhere" do
    assert CursorFile.read(nil) == nil
    assert CursorFile.write(nil, "1") == :ok
  end

  test "a missing file reads as nil", %{tmp_dir: dir} do
    assert CursorFile.read(Path.join(dir, "missing")) == nil
  end
end
