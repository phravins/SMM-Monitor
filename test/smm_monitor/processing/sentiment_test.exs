defmodule SmmMonitor.Processing.SentimentTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Processing.Sentiment

  doctest Sentiment

  # The scorer's job is direction first, magnitude second: a client
  # reading the dashboard needs "is this a complaint?" answered
  # correctly far more than they need two mentions ranked between
  # themselves. The tests are written the same way — label assertions
  # are exact, magnitude assertions are comparative, so tuning a weight
  # doesn't rewrite the suite.
  describe "score/1 plain text" do
    test "positive words score positive" do
      result = Sentiment.score("great tool, would recommend")

      assert result.label == :positive
      assert result.score > 0
    end

    test "negative words score negative" do
      result = Sentiment.score("terrible support and a broken app")

      assert result.label == :negative
      assert result.score < 0
    end

    test "text with no scoring words is neutral" do
      result = Sentiment.score("posted a walkthrough of our setup")

      assert result.label == :neutral
      assert result.score == 0.0
    end

    test "strong words outweigh mild ones" do
      assert Sentiment.score("excellent").score > Sentiment.score("good").score
      assert Sentiment.score("terrible").score < Sentiment.score("slow").score
    end

    test "scores stay inside -1.0..1.0 however emphatic the text" do
      shouting =
        "absolutely terrible, worst support ever, awful broken useless garbage " <>
          "and a horrible refund process"

      assert Sentiment.score(shouting).score >= -1.0
      assert Sentiment.score(shouting).label == :negative
    end

    test "handles nil, empty and non-text input" do
      assert Sentiment.score(nil).label == :neutral
      assert Sentiment.score("").label == :neutral
      assert Sentiment.score(:not_text).label == :neutral
    end

    test "is case insensitive and ignores attached punctuation" do
      assert Sentiment.score("EXCELLENT!").score == Sentiment.score("excellent").score
      assert Sentiment.score("(terrible)").label == :negative
    end
  end

  describe "score/1 negation" do
    test "flips a positive word" do
      assert Sentiment.score("not good").label == :negative
    end

    test "flips a negative word" do
      assert Sentiment.score("not bad at all").label == :positive
    end

    test "handles contracted forms" do
      assert Sentiment.score("didn't love it").label == :negative
    end

    test "reaches over a few words, as ordinary English does" do
      assert Sentiment.score("not at all helpful").label == :negative
    end

    test "stops reaching after its window" do
      # Far enough from "not" that it is a new thought, and the sentence
      # would otherwise be scored backwards.
      result = Sentiment.score("not the release we planned for, though the support was excellent")

      assert result.label == :positive
    end

    test "combines with an intensifier" do
      # "not very reliable" is a complaint, and a firmer one than "not
      # reliable" — the intensifier survives the flip.
      negated = Sentiment.score("the app is not very reliable")

      assert negated.label == :negative
      assert negated.score < Sentiment.score("the app is not reliable").score
    end
  end

  describe "score/1 intensifiers and downtoners" do
    test "an intensifier raises the magnitude" do
      assert Sentiment.score("very good").score > Sentiment.score("good").score
      assert Sentiment.score("really awful").score < Sentiment.score("awful").score
    end

    test "a downtoner lowers it" do
      assert Sentiment.score("slightly slow").score > Sentiment.score("slow").score
      assert Sentiment.score("slightly slow").score < 0.0
    end

    test "a downtoned grumble reads as neutral rather than a complaint" do
      assert Sentiment.score("slightly slow").label == :neutral
      assert Sentiment.score("slow").label == :negative
    end

    test "the modifier only reaches the words near it" do
      # "very" applies to "quick", not to "broken" three clauses later.
      assert Sentiment.score("very quick").score > Sentiment.score("quick").score
    end
  end

  describe "score/1 mixed clauses" do
    test "praise and complaint in one sentence do not silently cancel" do
      result = Sentiment.score("love the product but support is slow")

      assert length(result.clauses) == 2
      assert Enum.map(result.clauses, & &1.text) == ["love the product", "support is slow"]
    end

    test "the clause after a contrastive conjunction carries the point" do
      # A brand monitor that files this under "positive" hides the bug
      # report inside it.
      result = Sentiment.score("great tool, would recommend, but the mobile app keeps crashing")

      refute result.label == :positive
    end

    test "sentence ends split clauses too" do
      result = Sentiment.score("Excellent onboarding. Billing is broken.")

      assert length(result.clauses) == 2
    end

    test "a clause carrying more sentiment words has more say" do
      result = Sentiment.score("slow. excellent, brilliant, fantastic support")

      assert result.label == :positive
    end

    test "does not split mid-word" do
      # "buttons" contains "but"; splitting there would invent a clause.
      assert Sentiment.split_clauses("the buttons are great") == ["the buttons are great"]
    end

    test "clauses are reported with their own working" do
      result = Sentiment.score("excellent onboarding but terrible billing")

      assert Enum.all?(result.clauses, &(&1.signals == 1))
      assert [%{score: positive}, %{score: negative}] = result.clauses
      assert positive > 0 and negative < 0
    end
  end

  describe "label/1" do
    test "maps scores onto labels through the neutral band" do
      assert Sentiment.label(0.6) == :positive
      assert Sentiment.label(-0.6) == :negative
      assert Sentiment.label(0.0) == :neutral
    end

    test "a score inside the neutral band is neutral, not a faint opinion" do
      band = Keyword.fetch!(Sentiment.settings(), :neutral_band)

      assert Sentiment.label(band / 2) == :neutral
      assert Sentiment.label(-band / 2) == :neutral
    end
  end

  describe "analyze/1" do
    test "still answers with a label and an integer, for older callers" do
      assert {:positive, score} = Sentiment.analyze("great tool, would recommend")
      assert is_integer(score) and score > 0

      assert {:negative, negative} = Sentiment.analyze("not good")
      assert is_integer(negative) and negative < 0

      assert {:neutral, 0} = Sentiment.analyze("posted a walkthrough of our setup")
    end
  end

  describe "tokenize/1" do
    test "lowercases and strips punctuation but keeps apostrophes" do
      assert Sentiment.tokenize("Great, isn't it?!") == ["great", "isn't", "it"]
    end
  end

  describe "the shipped word lists" do
    alias SmmMonitor.Processing.Sentiment.Lexicon

    test "do not put a word in both directions" do
      positive =
        MapSet.union(Lexicon.words(:strong_positive), Lexicon.words(:mild_positive))

      negative =
        MapSet.union(Lexicon.words(:strong_negative), Lexicon.words(:mild_negative))

      overlap = MapSet.intersection(positive, negative)

      assert MapSet.size(overlap) == 0,
             "words in both directions: #{inspect(MapSet.to_list(overlap))}"
    end

    test "do not put a word in both strengths" do
      for {strong, mild} <- [
            {:strong_positive, :mild_positive},
            {:strong_negative, :mild_negative}
          ] do
        overlap = MapSet.intersection(Lexicon.words(strong), Lexicon.words(mild))

        assert MapSet.size(overlap) == 0,
               "#{strong}/#{mild} overlap: #{inspect(MapSet.to_list(overlap))}"
      end
    end

    test "recognise an outage, which is the mention that matters most" do
      assert Sentiment.score("realoffice was down again this morning").label == :negative
    end
  end
end
