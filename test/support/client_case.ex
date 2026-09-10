defmodule SmmMonitor.ClientCase do
  @moduledoc """
  Test case for anything that reads or edits the client list.

  The application's `SmmMonitor.Clients` process is shared by the whole
  suite, so each test snapshots the list and puts it back afterwards.
  Restoring happens in memory, which stops a test leaving rows behind for
  the next one.

  The process is long-lived and sits outside any test's sandbox
  ownership, so it is explicitly allowed onto the test's connection.
  Without that its writes fail, the store falls back to memory, and the
  tests would pass while proving nothing about the database.
  """

  use ExUnit.CaseTemplate

  alias SmmMonitor.{Client, Clients}

  using do
    quote do
      import SmmMonitor.ClientCase

      alias SmmMonitor.{Client, Clients}
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SmmMonitor.Repo, shared: not tags[:async])
    Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), Process.whereis(Clients))

    original = Clients.list()

    on_exit(fn ->
      Clients.replace(original)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  @doc """
  Builds a client without going through the store.

  Takes a name and derives everything else, since most tests care about
  *which* client a thing belongs to rather than what it is called.
  """
  @spec build_client(String.t(), keyword()) :: Client.t()
  def build_client(name, overrides \\ []) do
    {:ok, client} =
      Client.new(
        Map.merge(
          %{name: name, keywords: [Client.slug(name)]},
          Map.new(overrides)
        )
      )

    client
  end

  @doc "Sets the client list to exactly these, by name."
  @spec set_clients([String.t() | Client.t()]) :: [Client.t()]
  def set_clients(clients) do
    clients =
      Enum.map(clients, fn
        %Client{} = client -> client
        name when is_binary(name) -> build_client(name)
      end)

    :ok = Clients.replace(clients)
    clients
  end
end
