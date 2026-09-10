defmodule SmmMonitor.SSH.KeyAuth do
  @moduledoc """
  Public-key authentication callback for the SSH daemon.

  Implements Erlang's `:ssh_server_key_api`. `:ssh` calls `is_auth_key/3`
  with the key a client offered; we answer from the authorized keys file.
  Host key lookup is delegated to `:ssh_file`, which reads the key
  `SmmMonitor.SSH.HostKey` generated.

  Password authentication is not enabled anywhere in the daemon options,
  so a public key is the only way in.
  """

  @behaviour :ssh_server_key_api

  require Logger

  alias SmmMonitor.SSH.AuthorizedKeys

  @impl true
  def host_key(algorithm, options), do: :ssh_file.host_key(algorithm, options)

  @impl true
  def is_auth_key(key, user, options) do
    # Read fresh every time, so revoking a key takes effect immediately.
    file = authorized_keys_path(options)

    if AuthorizedKeys.authorized?(key, file) do
      Logger.info("ssh: accepted key for user #{user}")
      true
    else
      Logger.warning("ssh: rejected connection for user #{user} — key not in #{file}")
      false
    end
  end

  # The daemon passes our own options through under :key_cb_private.
  defp authorized_keys_path(options) do
    options
    |> Keyword.get(:key_cb_private, [])
    |> Keyword.get(:authorized_keys)
    |> Kernel.||(AuthorizedKeys.path())
  end
end
