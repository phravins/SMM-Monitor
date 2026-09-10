defmodule SmmMonitor.Processing.Sentiment do
  @moduledoc """
  Scores how positive or negative a mention reads.

  Deliberately not machine learning: this runs on every mention as it
  arrives, so it stays a fast, local, deterministic function with no
  model to load and no API to call. It is a lexicon scorer with three
  refinements that matter far more on social copy than a longer word
  list would.

  ## What it does

  1. **Splits into clauses.** Sentence ends and contrastive conjunctions
     ("but", "however", "although") start a new clause, so
     *"love the product but support is slow"* is scored as two opinions
     rather than one confused average of words.
  2. **Handles negation.** A negator flips the polarity of sentiment
     words within the next few tokens, so *"not good"* is negative.
     A window rather than only the next word, because *"not really
     great"* and *"not at all helpful"* are ordinary English.
  3. **Handles intensifiers and downtoners.** *"very good"* scores higher
     than *"good"*; *"slightly slow"* scores lower than *"slow"*.

  Each clause is normalised to `-1.0..1.0`, then combined into an overall
  score weighted by how much signal each clause carried — a clause with
  three sentiment words has more say than one with a single word.

  ## What it returns

  `score/1` returns a `Result` carrying the numeric score, the derived
  label, and the per-clause breakdown. The breakdown is the point: when
  someone asks why a mention was scored the way it was, the answer is
  data rather than a shrug.

  A clause that follows a contrastive conjunction counts for more, since
  in English that is where the speaker's real point usually lands:
  *"great tool, but it keeps crashing"* is a complaint, not praise.

  ## Known limits

  Sarcasm and idiom defeat it, as they defeat every lexicon. A word not
  in the lists contributes nothing — see `priv/sentiment/README.md` for
  how to add one.
  """

  alias SmmMonitor.Processing.Sentiment.Lexicon

  defmodule Result do
    @moduledoc """
    A scored piece of text: the number, the label, and the working.
    """

    @derive {Inspect, only: [:score, :label, :raw]}
    defstruct score: 0.0, label: :neutral, raw: 0.0, clauses: []

    @type clause :: %{text: String.t(), score: float(), raw: float(), signals: non_neg_integer()}

    @type t :: %__MODULE__{
            score: float(),
            label: SmmMonitor.Mention.sentiment(),
            raw: float(),
            clauses: [clause()]
          }
  end

  # Weights per category. Tunable via config, but the defaults are the
  # shape the word lists were written against.
  @defaults [
    strong: 2.0,
    mild: 1.0,
    intensifier: 1.5,
    downtoner: 0.5,
    # A negated word flips sign. Kept at exactly -1 for explainability:
    # "not good" is the mirror of "good".
    negation: -1.0,
    # How many tokens a negator or intensifier reaches forward.
    negation_window: 3,
    modifier_window: 2,
    # Raw clause score at which the normalised score hits ±1.0. Two
    # strong words, or one strong word intensified and then some.
    saturation: 4.0,
    # Scores inside ±this are reported as neutral.
    neutral_band: 0.15,
    # How much more a clause after "but" counts. In English the part
    # after a contrastive conjunction usually carries the speaker's real
    # point: "great tool, but it keeps crashing" is a complaint.
    contrast_weight: 2.0
  ]

  @clause_separators ~w(but however although though whereas yet)

  @doc "Scoring settings in force: the defaults, overridden by config."
  @spec settings() :: keyword()
  def settings, do: Keyword.merge(@defaults, SmmMonitor.config(:sentiment, []))

  @doc """
  Scores `text`, returning a `Result`.

      iex> alias SmmMonitor.Processing.Sentiment
      iex> Sentiment.score("absolutely excellent").label
      :positive
      iex> Sentiment.score("not good").label
      :negative
      iex> Sentiment.score("posted an update today").label
      :neutral
  """
  @spec score(String.t() | nil, keyword()) :: Result.t()
  def score(text, opts \\ [])
  def score(nil, _opts), do: %Result{}

  def score(text, opts) when is_binary(text) do
    settings = Keyword.merge(settings(), opts)

    clauses =
      text
      |> split_clauses(:with_contrast)
      |> Enum.map(fn {clause, contrast?} -> score_clause(clause, contrast?, settings) end)
      |> Enum.reject(&(&1.text == ""))

    combine(clauses, settings)
  end

  def score(_text, _opts), do: %Result{}

  @doc """
  Backwards-compatible entry point: `{label, integer_score}`.

  The integer is the raw clause total rounded, which is what earlier
  versions produced and what stored rows still hold.

      iex> SmmMonitor.Processing.Sentiment.analyze("not good")
      {:negative, -1}
  """
  @spec analyze(String.t() | nil) :: {SmmMonitor.Mention.sentiment(), integer()}
  def analyze(text) do
    result = score(text)
    {result.label, round(result.raw)}
  end

  @doc """
  The label for a normalised score.

      iex> alias SmmMonitor.Processing.Sentiment
      iex> Sentiment.label(0.6)
      :positive
      iex> Sentiment.label(-0.6)
      :negative
      iex> Sentiment.label(0.0)
      :neutral
  """
  @spec label(float(), keyword()) :: SmmMonitor.Mention.sentiment()
  def label(score, opts \\ []) do
    band = Keyword.get(Keyword.merge(settings(), opts), :neutral_band)

    cond do
      score > band -> :positive
      score < -band -> :negative
      true -> :neutral
    end
  end

  @doc """
  Splits text into clauses on sentence ends and contrastive conjunctions.

      iex> alias SmmMonitor.Processing.Sentiment
      iex> Sentiment.split_clauses("love it but support is slow")
      ["love it", "support is slow"]
  """
  @spec split_clauses(String.t()) :: [String.t()]
  def split_clauses(text) do
    text |> split_clauses(:with_contrast) |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Splits into `{clause, follows_contrast?}` pairs, so the combiner knows
  which clauses sit after a "but".

      iex> alias SmmMonitor.Processing.Sentiment
      iex> Sentiment.split_clauses("love it but support is slow", :with_contrast)
      [{"love it", false}, {"support is slow", true}]
  """
  @spec split_clauses(String.t(), :with_contrast) :: [{String.t(), boolean()}]
  def split_clauses(text, :with_contrast) do
    text
    |> String.split(~r/[.!?;\n]+/u)
    |> Enum.flat_map(&split_on_conjunctions/1)
    |> Enum.map(fn {clause, contrast?} -> {String.trim(clause), contrast?} end)
    |> Enum.reject(fn {clause, _contrast?} -> clause == "" end)
  end

  @doc """
  Splits text into lowercase word tokens, keeping the apostrophes that
  distinguish "didn't" from "did".

      iex> SmmMonitor.Processing.Sentiment.tokenize("Great, isn't it?!")
      ["great", "isn't", "it"]
  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}'\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  # --- clause scoring -------------------------------------------------------

  defp score_clause(clause, contrast?, settings) do
    {raw, signals} =
      clause
      |> tokenize()
      |> walk(settings, %{negation: 0, modifier: 1.0, modifier_left: 0}, {0.0, 0})

    %{
      text: clause,
      raw: raw,
      signals: signals,
      contrast: contrast?,
      score: normalise(raw, settings[:saturation])
    }
  end

  # Walks the clause carrying two decaying windows: how many more tokens
  # a negator still reaches over, and the multiplier an intensifier or
  # downtoner has set (with its own reach).
  defp walk([], _settings, _state, acc), do: acc

  defp walk([token | rest], settings, state, {raw, signals}) do
    cond do
      Lexicon.member?(:negators, token) ->
        walk(rest, settings, %{state | negation: settings[:negation_window]}, {raw, signals})

      Lexicon.member?(:intensifiers, token) ->
        walk(rest, settings, set_modifier(state, settings[:intensifier], settings), {raw, signals})

      Lexicon.member?(:downtoners, token) ->
        walk(rest, settings, set_modifier(state, settings[:downtoner], settings), {raw, signals})

      weight = weight_of(token, settings) ->
        contribution = weight * state.modifier * negation_factor(state, settings)
        # A sentiment word consumes both windows: "not very good" is one
        # negated, intensified opinion, not a negation hanging over the
        # rest of the clause.
        walk(rest, settings, reset(state), {raw + contribution, signals + 1})

      true ->
        walk(rest, settings, decay(state), {raw, signals})
    end
  end

  defp weight_of(token, settings) do
    cond do
      Lexicon.member?(:strong_positive, token) -> settings[:strong]
      Lexicon.member?(:mild_positive, token) -> settings[:mild]
      Lexicon.member?(:strong_negative, token) -> -settings[:strong]
      Lexicon.member?(:mild_negative, token) -> -settings[:mild]
      true -> nil
    end
  end

  defp negation_factor(%{negation: n}, settings) when n > 0, do: settings[:negation]
  defp negation_factor(_state, _settings), do: 1.0

  defp set_modifier(state, multiplier, settings) do
    %{state | modifier: multiplier, modifier_left: settings[:modifier_window]}
  end

  defp reset(state), do: %{state | negation: 0, modifier: 1.0, modifier_left: 0}

  # Both windows decay by one token, and a lapsed modifier returns to 1.
  defp decay(state) do
    modifier_left = max(state.modifier_left - 1, 0)

    %{
      state
      | negation: max(state.negation - 1, 0),
        modifier_left: modifier_left,
        modifier: if(modifier_left == 0, do: 1.0, else: state.modifier)
    }
  end

  # --- combining ------------------------------------------------------------

  defp combine([], _settings), do: %Result{}

  defp combine(clauses, settings) do
    scored = Enum.filter(clauses, &(&1.signals > 0))

    if scored == [] do
      %Result{clauses: clauses}
    else
      # Weighted by signal count — a clause carrying three sentiment words
      # says more than one carrying a single word — and again by whether
      # the clause follows a contrastive conjunction.
      weights = Enum.map(scored, &clause_weight(&1, settings))
      total_weight = Enum.sum(weights)

      weighted =
        scored
        |> Enum.zip(weights)
        |> Enum.map(fn {clause, weight} -> clause.score * weight end)
        |> Enum.sum()

      score = clamp(weighted / total_weight, -1.0, 1.0)

      %Result{
        score: round_to(score, 3),
        label: label(score, settings),
        raw: scored |> Enum.map(& &1.raw) |> Enum.sum() |> round_to(3),
        clauses: clauses
      }
    end
  end

  defp clause_weight(%{contrast: true} = clause, settings),
    do: clause.signals * settings[:contrast_weight]

  defp clause_weight(clause, _settings), do: clause.signals * 1.0

  defp normalise(_raw, saturation) when saturation <= 0, do: 0.0

  defp normalise(raw, saturation), do: raw |> Kernel./(saturation) |> clamp(-1.0, 1.0)

  # Only at a word boundary, so "buttons" doesn't split on "but". Every
  # piece after the first followed a conjunction, which is what earns it
  # the contrast weighting.
  defp split_on_conjunctions(segment) do
    case String.split(segment, ~r/\b(?:#{Enum.join(@clause_separators, "|")})\b/iu) do
      [only] -> [{only, false}]
      [first | rest] -> [{first, false} | Enum.map(rest, &{&1, true})]
    end
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  defp round_to(value, places), do: Float.round(value * 1.0, places)
end
