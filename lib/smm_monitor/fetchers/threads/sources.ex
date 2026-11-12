defmodule SmmMonitor.Fetchers.Threads.Sources do
  @moduledoc """
  What the Threads fetcher reads, as data.

    * `:search` — public posts containing a brand term, from
      `/keyword_search`. The closest Threads gets to "who mentioned us
      anywhere". Spends from Meta's 2,200 queries a day, and **until Meta
      approves `threads_keyword_search` in App Review it only searches the
      connected account's own posts**.

    * `:mentions` — posts that @-mention the connected account, from
      `/{user-id}/mentions`. Free of the search quota. Needs
      `threads_manage_mentions`, and until that is approved only returns
      posts by the app's testers. The feed belongs to the account, not to a
      client, so each client keeps only the mentions that name one of its
      brand terms.

    * `:replies` — replies to the account's own recent posts. Opt-in, like
      Instagram's comments: one request for the posts plus one per post
      that has replies. Replies belong to the account too, and every client
      receives them, so turn this on when one client owns the account.
  """

  @all [:search, :mentions, :replies]
  @default [:search, :mentions]

  @type source :: :search | :mentions | :replies

  @doc "Every source this fetcher knows how to read."
  @spec all() :: [source()]
  def all, do: @all

  @doc "The sources enabled unless configured otherwise."
  @spec default() :: [source()]
  def default, do: @default

  @doc """
  Normalises a configured source list, dropping anything unrecognised.

      iex> alias SmmMonitor.Fetchers.Threads.Sources
      iex> Sources.normalize([:search, :nonsense, "replies"])
      [:search, :replies]
      iex> Sources.normalize(nil)
      [:search, :mentions]
  """
  @spec normalize(term()) :: [source()]
  def normalize(nil), do: @default

  def normalize(sources) do
    sources
    |> List.wrap()
    |> Enum.map(&to_source/1)
    |> Enum.filter(&(&1 in @all))
    |> Enum.uniq()
  end

  @doc "A one-line description of what a source can see, for logs."
  @spec describe(source()) :: String.t()
  def describe(:search), do: "public posts containing a brand term"
  def describe(:mentions), do: "posts that @-mention the account"
  def describe(:replies), do: "replies to the account's own posts"

  defp to_source(source) when source in @all, do: source

  defp to_source(source) when is_binary(source) do
    case String.trim(source) do
      "search" -> :search
      "mentions" -> :mentions
      "replies" -> :replies
      _other -> :unknown
    end
  end

  defp to_source(_source), do: :unknown
end
