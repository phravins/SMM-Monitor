defmodule SmmMonitor.Clients.Store do
  @moduledoc """
  Reads and writes the `clients` table.

  Split from `SmmMonitor.Clients` so the GenServer holds the cache and the
  policy while this holds the SQL — and so the failure handling lives in
  one place. Every function here returns a tagged result rather than
  raising, because a database that has gone away must degrade the client
  list to memory, not take the app down.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  require Logger

  alias SmmMonitor.Client
  alias SmmMonitor.Persistence.{ClientRecord, MentionRecord}
  alias SmmMonitor.Repo

  @doc "Every stored client, oldest first."
  @spec load(module() | nil) :: {:ok, [Client.t()]} | {:error, term()}
  def load(repo \\ nil) do
    repo = repo || Repo

    clients =
      ClientRecord
      |> from(order_by: [asc: :created_at, asc: :id])
      |> repo.all()
      |> Enum.map(&ClientRecord.to_client/1)

    {:ok, clients}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Inserts a client, ignoring one that is already there."
  @spec insert(Client.t(), module() | nil) :: :ok | {:error, term()}
  def insert(%Client{} = client, repo \\ nil) do
    repo = repo || Repo
    repo.insert_all(ClientRecord, [ClientRecord.from_client(client)], on_conflict: :nothing)
    :ok
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Inserts or replaces a client."
  @spec upsert(Client.t(), module() | nil) :: :ok | {:error, term()}
  def upsert(%Client{} = client, repo \\ nil) do
    repo = repo || Repo
    row = ClientRecord.from_client(client)

    repo.insert_all(ClientRecord, [row],
      on_conflict: {:replace, [:name, :keywords, :subreddits, :active, :updated_at]},
      conflict_target: [:id]
    )

    :ok
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Deletes a client and every mention collected for it.

  Returns how many mentions went. Both go together on purpose: a client
  row with no mentions, or mentions with no client, are states nothing
  else in the app knows how to render.
  """
  @spec delete(String.t(), module() | nil) :: non_neg_integer()
  def delete(id, repo \\ nil) do
    repo = repo || Repo

    {mentions, _returning} =
      MentionRecord
      |> where([m], m.client_id == ^id)
      |> repo.delete_all()

    ClientRecord
    |> where([c], c.id == ^id)
    |> repo.delete_all()

    mentions
  rescue
    error ->
      Logger.warning("clients: could not delete #{id} (#{inspect(error)})")
      0
  catch
    :exit, reason ->
      Logger.warning("clients: could not delete #{id} (#{inspect(reason)})")
      0
  end
end
