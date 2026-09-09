defmodule SmmMonitor.Processing.Sentiment do
  @moduledoc """
  Keyword-based sentiment scoring.

  Deliberately dumb for v1: tokenise, count hits against a positive and a
  negative word list, subtract. No ML, no external service, no network call
  in the hot path. Good enough to make the dashboard's sentiment bar useful,
  and cheap enough to run on every mention as it arrives.

  Two small refinements that pay for themselves on social copy:

    * **Negations** ("not great", "never worked") flip the polarity of the
      next scoring word.
    * **Intensifiers** ("very", "really") double the next scoring word.

  Swapping this for a real model later means keeping `analyze/1`'s contract:
  text in, `{sentiment, score}` out.
  """

  @positive ~w(
    amazing awesome brilliant excellent fantastic great good love loved loves
    nice perfect recommend recommended solid superb thanks thank helpful
    impressed impressive smooth reliable fast responsive delightful best
    win winning happy pleased quality worth wonderful outstanding
  )

  @negative ~w(
    awful bad broken bug buggy crash crashed crashes crashing disappointed disappointing
    downtime error fail failed failing garbage hate horrible issue issues
    lousy outage overpriced poor problem refund rubbish scam slow terrible
    trash unusable useless worst worse angry frustrating frustrated complaint
  )

  @negations ~w(not no never none cannot cant can't didn't didnt won't wont isn't isnt)
  @intensifiers ~w(very really extremely incredibly super so totally absolutely)

  # Scores inside this band are treated as neutral rather than a weak signal.
  @neutral_band 0

  @doc """
  Scores `text` and returns `{sentiment, score}`.

  `score` is the signed keyword total; `sentiment` is its label.

      iex> SmmMonitor.Processing.Sentiment.analyze("absolutely love this")
      {:positive, 2}

      iex> SmmMonitor.Processing.Sentiment.analyze("not great, kept crashing")
      {:negative, -2}

      iex> SmmMonitor.Processing.Sentiment.analyze("posted an update today")
      {:neutral, 0}
  """
  @spec analyze(String.t() | nil) :: {SmmMonitor.Mention.sentiment(), integer()}
  def analyze(nil), do: {:neutral, 0}

  def analyze(text) when is_binary(text) do
    score =
      text
      |> tokenize()
      |> score_tokens(1, 0)

    {label(score), score}
  end

  @doc "Label for a raw score. Exposed so aggregates can reuse the thresholds."
  @spec label(integer()) :: SmmMonitor.Mention.sentiment()
  def label(score) when score > @neutral_band, do: :positive
  def label(score) when score < -@neutral_band, do: :negative
  def label(_score), do: :neutral

  @doc "The positive word list, for tests and for tuning."
  @spec positive_words() :: [String.t()]
  def positive_words, do: @positive

  @doc "The negative word list, for tests and for tuning."
  @spec negative_words() :: [String.t()]
  def negative_words, do: @negative

  @doc """
  Splits text into lowercase word tokens, dropping punctuation but keeping
  the apostrophes that matter for negations ("didn't").
  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}'\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  # Walks the tokens carrying a multiplier from the previous token, so
  # "not" negates and "very" amplifies whatever scoring word comes next.
  defp score_tokens([], _multiplier, acc), do: acc

  defp score_tokens([token | rest], multiplier, acc) do
    cond do
      token in @negations -> score_tokens(rest, -1 * abs(multiplier), acc)
      token in @intensifiers -> score_tokens(rest, multiplier * 2, acc)
      token in @positive -> score_tokens(rest, 1, acc + multiplier)
      token in @negative -> score_tokens(rest, 1, acc - multiplier)
      # A non-scoring word ends the reach of a negation/intensifier.
      true -> score_tokens(rest, 1, acc)
    end
  end
end
