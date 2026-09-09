defmodule SmmMonitor.Factory do
  @moduledoc """
  Test helpers for building mentions.

  Timestamps default to "now" and are usually overridden with `minutes_ago:`
  so tests can pin windows and ordering without sleeping.
  """

  alias SmmMonitor.Mention

  @doc """
  Builds mention attrs. Accepts `:minutes_ago` as a shorthand for a
  back-dated timestamp.
  """
  def attrs(overrides \\ []) do
    {minutes_ago, overrides} = Keyword.pop(overrides, :minutes_ago)

    defaults = [
      id: "m-#{System.unique_integer([:positive])}",
      platform: :reddit,
      author: "u/tester",
      text: "a neutral mention about the brand",
      url: "https://example.test/post",
      timestamp: timestamp(minutes_ago)
    ]

    defaults |> Keyword.merge(overrides) |> Map.new()
  end

  @doc "Builds a `Mention` struct directly, bypassing the processor."
  def mention(overrides \\ []), do: overrides |> attrs() |> Mention.new()

  defp timestamp(nil), do: DateTime.utc_now()
  defp timestamp(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
end
