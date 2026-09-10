defmodule SmmMonitor.DatabaseCase do
  @moduledoc """
  Test case for anything touching the durable log.

  Each test runs inside a sandboxed transaction that is rolled back
  afterwards, so tests never see each other's rows and the throwaway
  database doesn't accumulate.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import SmmMonitor.DatabaseCase

      alias SmmMonitor.Persistence
      alias SmmMonitor.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SmmMonitor.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Builds a mention, defaulting everything the durable log cares about.

  `:minutes_ago` and `:days_ago` back-date the publication time, which is
  what retention keys on.
  """
  def mention(overrides \\ []) do
    {days_ago, overrides} = Keyword.pop(overrides, :days_ago)
    {minutes_ago, overrides} = Keyword.pop(overrides, :minutes_ago)

    defaults = [
      id: "m-#{System.unique_integer([:positive])}",
      platform: :reddit,
      author: "u/tester",
      text: "a mention of the brand",
      url: "https://example.test/p",
      timestamp: timestamp(days_ago, minutes_ago),
      sentiment: :neutral,
      sentiment_value: 0.0,
      sentiment_score: 0
    ]

    struct!(SmmMonitor.Mention, Keyword.merge(defaults, overrides))
  end

  defp timestamp(nil, nil), do: DateTime.utc_now()
  defp timestamp(days, nil), do: DateTime.add(DateTime.utc_now(), -days * 24 * 3_600, :second)
  defp timestamp(_days, minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
end
