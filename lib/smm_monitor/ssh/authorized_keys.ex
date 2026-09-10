defmodule SmmMonitor.SSH.AuthorizedKeys do
  @moduledoc """
  Decides which public keys may open a dashboard session.

  An OpenSSH `authorized_keys` file: one key per line, blank lines and
  `#` comments ignored, trailing comment on each line ignored. Exactly
  the file people already know how to edit, so adding a colleague is
  "paste the line they sent you".

  The file is re-read on **every authentication attempt**, so adding or
  removing a key takes effect immediately with no restart. That is
  affordable because authentications are rare and the file is small;
  caching it would buy nothing and cost the property that makes revoking
  a key useful.

  ## Failing closed

  A missing, unreadable or empty file authorises **nobody**. That is the
  deliberate choice: the alternative — treating "no keys configured" as
  "allow everyone" — turns a misconfiguration into an open dashboard.
  """

  require Logger

  @doc "Where the authorized keys file lives."
  @spec path() :: Path.t()
  def path do
    System.get_env("SMM_SSH_AUTHORIZED_KEYS") ||
      Application.get_env(:smm_monitor, :ssh_authorized_keys) ||
      default_path()
  end

  @doc """
  Default location: `/etc/smm-monitor/authorized_keys` under systemd,
  `~/.config/smm_monitor/authorized_keys` otherwise.
  """
  @spec default_path() :: Path.t()
  def default_path, do: SmmMonitor.Paths.config("authorized_keys")

  @doc """
  Whether `key` is authorised, reading the file fresh.

  Returns false for anything it cannot positively authorise.
  """
  @spec authorized?(term(), Path.t() | nil) :: boolean()
  def authorized?(key, file \\ nil) do
    file = file || path()

    case load(file) do
      {:ok, []} ->
        Logger.warning("ssh: #{file} authorises no keys; refusing connection")
        false

      {:ok, keys} ->
        Enum.any?(keys, &match_key?(&1, key))

      {:error, :enoent} ->
        Logger.warning("ssh: no authorized keys file at #{file}; refusing connection")
        false

      {:error, reason} ->
        Logger.warning("ssh: could not read #{file} (#{inspect(reason)}); refusing connection")
        false
    end
  end

  @doc """
  Loads and parses the file into a list of public keys.

  Unparseable lines are skipped with a warning rather than failing the
  whole file: one bad paste shouldn't lock out the rest of the team.
  """
  @spec load(Path.t()) :: {:ok, [term()]} | {:error, term()}
  def load(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, parse(contents)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses `authorized_keys` content into public keys.

      iex> alias SmmMonitor.SSH.AuthorizedKeys
      iex> AuthorizedKeys.parse("# a comment\\n\\n")
      []
  """
  @spec parse(String.t()) :: [term()]
  def parse(contents) do
    contents
    |> String.split(["\n", "\r\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&skip_line?/1)
    |> Enum.flat_map(&parse_line/1)
  end

  @doc "How many keys the file currently authorises. Used by the README's checks."
  @spec count(Path.t() | nil) :: non_neg_integer()
  def count(file \\ nil) do
    case load(file || path()) do
      {:ok, keys} -> length(keys)
      {:error, _reason} -> 0
    end
  end

  # --- internals ------------------------------------------------------------

  defp skip_line?(""), do: true
  defp skip_line?("#" <> _rest), do: true
  defp skip_line?(_line), do: false

  defp parse_line(line) do
    # :ssh_file.decode/2 wants a trailing newline and returns
    # [{key, attributes}] for each entry it understands.
    case :ssh_file.decode(line <> "\n", :openssh_key) do
      entries when is_list(entries) ->
        Enum.flat_map(entries, fn
          {key, _attributes} -> [key]
          _other -> []
        end)

      {:error, reason} ->
        Logger.warning("ssh: skipping unparseable authorized_keys line (#{inspect(reason)})")
        []
    end
  rescue
    _error ->
      Logger.warning("ssh: skipping unparseable authorized_keys line")
      []
  end

  # Compares the decoded key structures directly rather than any string
  # form, so formatting differences in the file can't produce a false
  # negative or a false positive.
  defp match_key?(authorized, offered), do: authorized == offered
end
