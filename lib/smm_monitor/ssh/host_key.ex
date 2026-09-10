defmodule SmmMonitor.SSH.HostKey do
  @moduledoc """
  The server's own identity, stable across restarts.

  An SSH host key must not change between boots: clients pin it in
  `known_hosts` the first time they connect, and a new one every restart
  would greet everybody with the "REMOTE HOST IDENTIFICATION HAS CHANGED"
  warning and refuse to connect. So it is generated once, on first boot,
  and kept.

  Generated with Erlang's own `:public_key` rather than by shelling out
  to `ssh-keygen`, so there is no dependency on OpenSSH being installed
  on the host.

  The private key is written `0600` and the directory `0700`, which
  Erlang's `:ssh` expects and which stops other users on the box reading
  the server's identity.
  """

  require Logger

  @key_file "ssh_host_rsa_key"
  @key_size 2048

  @doc "Directory holding the host key, as `:ssh.daemon`'s `system_dir`."
  @spec dir() :: Path.t()
  def dir do
    System.get_env("SMM_SSH_HOST_KEY_DIR") ||
      Application.get_env(:smm_monitor, :ssh_host_key_dir) ||
      default_dir()
  end

  @doc "Default host key directory."
  @spec default_dir() :: Path.t()
  def default_dir do
    base =
      System.get_env("XDG_DATA_HOME") ||
        case System.user_home() do
          nil -> ".smm_monitor"
          home -> Path.join([home, ".local", "share"])
        end

    Path.join([base, "smm_monitor", "ssh"])
  end

  @doc """
  Ensures a host key exists, generating one on first boot.

  Returns the directory to hand to `:ssh.daemon`.
  """
  @spec ensure!(Path.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def ensure!(directory \\ nil) do
    directory = directory || dir()
    file = Path.join(directory, @key_file)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- ensure_key(file) do
      {:ok, directory}
    end
  end

  @doc "Whether a host key is already present."
  @spec exists?(Path.t() | nil) :: boolean()
  def exists?(directory \\ nil) do
    (directory || dir()) |> Path.join(@key_file) |> File.exists?()
  end

  @doc "Path of the host key file within a directory."
  @spec key_path(Path.t()) :: Path.t()
  def key_path(directory), do: Path.join(directory, @key_file)

  # --- internals ------------------------------------------------------------

  defp ensure_key(file) do
    if File.exists?(file) do
      :ok
    else
      Logger.info("ssh: generating a host key at #{file} (first boot)")
      generate(file)
    end
  end

  defp generate(file) do
    pem =
      {:rsa, @key_size, 65_537}
      |> :public_key.generate_key()
      |> then(&:public_key.pem_entry_encode(:RSAPrivateKey, &1))
      |> List.wrap()
      |> :public_key.pem_encode()

    with :ok <- File.write(file, pem) do
      # :ssh refuses to use a host key other users can read.
      File.chmod(file, 0o600)
    end
  rescue
    error -> {:error, error}
  end
end
