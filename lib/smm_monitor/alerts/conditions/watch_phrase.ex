defmodule SmmMonitor.Alerts.Conditions.WatchPhrase do
  @moduledoc """
  Alerts when a mention contains one of a client's watch phrases.

  No thresholds and no baseline: one mention saying "lawsuit" is the
  whole signal, and averaging it with anything would bury it. This is
  the condition that catches what the other two are structurally unable
  to — a single quiet post that matters more than a hundred loud ones.

  Matching is case-insensitive substring, which is what "refund" needs
  in order to catch "Refunded" and "no refund yet". That does mean
  "scam" matches "scamper"; a word-boundary match would fix it and break
  "refund"/"refunds", so v1 takes the false positive over the false
  negative. Phrases are stored lowercased so matching is one `downcase`
  per mention rather than one per phrase.

  ## One incident per phrase, not per mention

  Ten mentions saying "refund" in an hour is one problem. The incident
  is therefore keyed on the phrase, and the alert carries the first
  matching mention as evidence plus a count of how many matched.
  """

  alias SmmMonitor.Alerts.Conditions
  alias SmmMonitor.Client.AlertConfig
  alias SmmMonitor.Mention

  @typedoc "The mentions in the current window."
  @type observation :: %{required(:mentions) => [Mention.t()]}

  @doc "The kind this condition raises."
  @spec kind() :: atom()
  def kind, do: :watch_phrase

  @doc """
  Finds every watch phrase present in the window's mentions.

  Returns one verdict per phrase that matched, because two different
  phrases are two different problems and each needs its own incident.
  """
  @spec evaluate(observation(), AlertConfig.t()) :: [Conditions.verdict()]
  def evaluate(_observation, %AlertConfig{watch_phrases: []}), do: [{:ok, :no_phrases}]

  def evaluate(observation, %AlertConfig{} = config) do
    matches =
      observation
      |> Map.get(:mentions, [])
      |> Enum.flat_map(fn mention ->
        # Every phrase in the mention, not just the first: one post can
        # carry two problems and the second must not be hidden by
        # whichever happened to be listed first.
        config
        |> AlertConfig.matching_phrases(mention.text)
        |> Enum.map(&{&1, mention})
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    case matches do
      empty when empty == %{} ->
        [{:ok, :below_threshold}]

      matches ->
        Enum.map(matches, fn {phrase, mentions} -> alert_for(phrase, mentions) end)
    end
  end

  @doc """
  Whether a phrase has stopped appearing in the window.

  There is no hysteresis here, unlike the threshold conditions: a phrase
  is either in the window or it is not, and the window rolling past the
  mention is a real recovery rather than a number jittering over a line.
  """
  @spec cleared?(observation(), AlertConfig.t(), String.t()) :: boolean()
  def cleared?(observation, %AlertConfig{} = _config, phrase) do
    observation
    |> Map.get(:mentions, [])
    |> Enum.all?(fn mention ->
      not String.contains?(String.downcase(mention.text || ""), phrase)
    end)
  end

  defp alert_for(phrase, mentions) do
    # Newest first, so the evidence quoted in the alert is the most
    # recent one rather than whichever the window happened to start with.
    [latest | _rest] = Enum.sort_by(mentions, & &1.timestamp, {:desc, DateTime})

    {:alert,
     %{
       kind: kind(),
       phrase: phrase,
       observed: length(mentions),
       mention: latest,
       excerpt: excerpt(latest.text),
       # A watch phrase is opted into one word at a time: if somebody
       # went to the trouble of adding "lawsuit", it is not a warning.
       severity: :critical
     }}
  end

  # Long enough to see the sentence around the phrase, short enough for
  # a Slack line.
  defp excerpt(nil), do: ""

  defp excerpt(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) > 160, do: String.slice(text, 0, 159) <> "…", else: text
  end
end
