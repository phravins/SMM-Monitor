defmodule SmmMonitor.Fetchers.CursorFile do
  @moduledoc """
  A small private file for a stream's resume position.

  Bluesky keeps the time of the last event it saw, Discord the last
  message id in each channel and Mastodon the last post id on its server,
  so a restart can pick up where the last run stopped. None is a secret,
  but they say which servers and channels are being watched, so the file is treated like the rest of the state
  directory: created `0600`, in a directory only this user can enter.

  Writes go to a temporary file that is then renamed over the old one, so
  a crash mid-write leaves the previous position rather than half a file.
  """

  @doc """
  The default path for `name`: next to the database, or nil when there is
  no database configured (and so nowhere sensible to keep it).
  """
  @spec default_path(String.t()) :: Path.t() | nil
  def default_path(name) do
    database = Application.get_env(:smm_monitor, SmmMonitor.Repo, [])[:database]
    if database, do: Path.join(Path.dirname(database), name)
  end

  @doc "The file's contents, or nil when there is no path or no readable file."
  @spec read(Path.t() | nil) :: binary() | nil
  def read(nil), do: nil

  def read(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> nil
    end
  end

  @doc "Replaces the file's contents. A nil path is a no-op."
  @spec write(Path.t() | nil, iodata()) :: :ok | {:error, term()}
  def write(nil, _contents), do: :ok

  def write(path, contents) do
    temporary = path <> ".tmp"

    with :ok <- SmmMonitor.Paths.ensure_private_dir(Path.dirname(path), only_if_created: true),
         :ok <- write_private(temporary, contents) do
      File.rename(temporary, path)
    end
  end

  # Created empty and made 0600 before anything is written, so the
  # contents are never readable by anyone else, even for a moment.
  # `:exclusive` refuses a file (or symlink) someone planted at the path.
  defp write_private(path, contents) do
    _ = File.rm(path)

    with {:ok, device} <- :file.open(String.to_charlist(path), [:write, :exclusive, :binary, :raw]) do
      try do
        with :ok <- File.chmod(path, 0o600), do: :file.write(device, contents)
      after
        :file.close(device)
      end
    end
  end
end
