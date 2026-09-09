defmodule SmmMonitor.Processing.SentimentTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Processing.Sentiment

  doctest Sentiment

  describe "analyze/1" do
    test "scores positive keywords above zero" do
      assert {:positive, 2} = Sentiment.analyze("great tool, would recommend")
    end

    test "scores negative keywords below zero" do
      assert {:negative, -2} = Sentiment.analyze("terrible support and a broken app")
    end

    test "text with no scoring keywords is neutral" do
      assert {:neutral, 0} = Sentiment.analyze("posted a walkthrough of our setup")
    end

    test "mixed text nets out" do
      # "love" (+1) and "slow" (-1) cancel.
      assert {:neutral, 0} = Sentiment.analyze("love the product but the app is slow")
    end

    test "handles nil and empty text" do
      assert {:neutral, 0} = Sentiment.analyze(nil)
      assert {:neutral, 0} = Sentiment.analyze("")
    end

    test "is case insensitive" do
      assert Sentiment.analyze("EXCELLENT") == Sentiment.analyze("excellent")
    end

    test "ignores punctuation attached to words" do
      assert {:positive, 1} = Sentiment.analyze("excellent!")
      assert {:negative, -1} = Sentiment.analyze("(terrible)")
    end
  end

  describe "negation" do
    test "flips the polarity of the following word" do
      assert {:negative, -1} = Sentiment.analyze("not great")
      assert {:positive, 1} = Sentiment.analyze("not terrible")
    end

    test "does not reach past a non-scoring word" do
      assert {:positive, 1} = Sentiment.analyze("not the product I expected, but excellent")
    end

    test "handles contracted forms" do
      assert {:negative, -1} = Sentiment.analyze("didn't love it")
    end
  end

  describe "intensifiers" do
    test "double the weight of the following word" do
      assert {:positive, 2} = Sentiment.analyze("very good")
      assert {:negative, -2} = Sentiment.analyze("really awful")
    end

    test "combine with negation" do
      assert {:negative, -2} = Sentiment.analyze("not very good")
    end
  end

  describe "label/1" do
    test "maps scores onto labels" do
      assert Sentiment.label(3) == :positive
      assert Sentiment.label(0) == :neutral
      assert Sentiment.label(-3) == :negative
    end
  end

  describe "tokenize/1" do
    test "lowercases and strips punctuation but keeps apostrophes" do
      assert Sentiment.tokenize("Great, isn't it?!") == ["great", "isn't", "it"]
    end
  end

  describe "word lists" do
    test "do not overlap" do
      overlap =
        MapSet.intersection(
          MapSet.new(Sentiment.positive_words()),
          MapSet.new(Sentiment.negative_words())
        )

      assert MapSet.size(overlap) == 0, "words in both lists: #{inspect(MapSet.to_list(overlap))}"
    end
  end
end
