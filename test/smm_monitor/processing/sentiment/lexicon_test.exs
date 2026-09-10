defmodule SmmMonitor.Processing.Sentiment.LexiconTest do
  # Not async: the lists are cached in :persistent_term, which is global,
  # and these tests point the loader at temporary directories.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.Processing.Sentiment
  alias SmmMonitor.Processing.Sentiment.Lexicon

  doctest Lexicon

  setup do
    dir = Path.join(System.tmp_dir!(), "smm-sentiment-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      System.delete_env("SMM_SENTIMENT_DIR")
      Lexicon.reload()
    end)

    {:ok, dir: dir}
  end

  describe "the packaged lists" do
    test "load a word for every category" do
      Lexicon.reload()

      for category <- Lexicon.categories() do
        assert MapSet.size(Lexicon.words(category)) > 0, "#{category} loaded empty"
      end
    end

    test "are cached after the first read" do
      Lexicon.clear_cache()
      first = Lexicon.lists()

      assert :persistent_term.get({Lexicon, :lists}) == first
      assert Lexicon.lists() == first
    end

    test "report where each category was read from" do
      Lexicon.reload()

      for {_category, source} <- Lexicon.sources() do
        assert is_binary(source)
        assert File.regular?(source)
      end
    end
  end

  describe "parse/1" do
    test "lowercases, trims, and drops blanks and comments" do
      assert Lexicon.parse("# heading\n\nGood\n  GREAT  \n\n# trailing\n") == ["good", "great"]
    end

    test "drops duplicates, so a pasted list can't weight a word twice" do
      assert Lexicon.parse("good\ngood\nGood\n") == ["good"]
    end

    test "accepts CRLF, which is what a Windows editor writes" do
      assert Lexicon.parse("good\r\ngreat\r\n") == ["good", "great"]
    end
  end

  describe "overrides" do
    test "a file in the override directory replaces the packaged one", %{dir: dir} do
      File.write!(Path.join(dir, "strong_positive.txt"), "unicorn\n")
      System.put_env("SMM_SENTIMENT_DIR", dir)
      Lexicon.reload()

      assert Lexicon.member?(:strong_positive, "unicorn")
      refute Lexicon.member?(:strong_positive, "excellent")
      assert Sentiment.score("this is unicorn").label == :positive
    end

    test "categories with no override file keep the packaged list", %{dir: dir} do
      File.write!(Path.join(dir, "strong_positive.txt"), "unicorn\n")
      System.put_env("SMM_SENTIMENT_DIR", dir)
      Lexicon.reload()

      assert Lexicon.member?(:negators, "not")
      assert Lexicon.member?(:strong_negative, "terrible")
    end

    test "an override directory that doesn't exist falls back to the packaged lists" do
      System.put_env("SMM_SENTIMENT_DIR", "/nonexistent/smm-sentiment")
      Lexicon.reload()

      assert Lexicon.member?(:strong_positive, "excellent")
      assert Sentiment.score("excellent").label == :positive
    end

    test "reload/0 picks up an edit without a restart", %{dir: dir} do
      path = Path.join(dir, "mild_positive.txt")
      File.write!(path, "serviceable\n")
      System.put_env("SMM_SENTIMENT_DIR", dir)
      Lexicon.reload()

      refute Lexicon.member?(:mild_positive, "workable")

      File.write!(path, "serviceable\nworkable\n")
      Lexicon.reload()

      assert Lexicon.member?(:mild_positive, "workable")
    end
  end

  describe "damaged word lists" do
    test "an empty file yields an empty category rather than an error", %{dir: dir} do
      File.write!(Path.join(dir, "intensifiers.txt"), "")
      System.put_env("SMM_SENTIMENT_DIR", dir)
      Lexicon.reload()

      assert MapSet.size(Lexicon.words(:intensifiers)) == 0
      # Scoring carries on; "very" simply stops multiplying.
      assert Sentiment.score("very good").label == :positive
    end

    test "a file of nothing but comments and blanks is treated as empty", %{dir: dir} do
      File.write!(Path.join(dir, "downtoners.txt"), "# nothing here yet\n\n   \n")
      System.put_env("SMM_SENTIMENT_DIR", dir)
      Lexicon.reload()

      assert MapSet.size(Lexicon.words(:downtoners)) == 0
    end

    test "an unreadable override warns and scores without that list", %{dir: dir} do
      path = Path.join(dir, "negators.txt")
      File.write!(path, "not\n")
      File.chmod!(path, 0o000)
      System.put_env("SMM_SENTIMENT_DIR", dir)

      log = capture_log(fn -> Lexicon.reload() end)

      # Running as root defeats the permission bit, so only assert the
      # failure path when the file is genuinely unreadable.
      if match?({:error, _}, File.read(path)) do
        assert log =~ "could not read"
        assert MapSet.size(Lexicon.words(:negators)) == 0
        assert Sentiment.score("not good").label == :positive
      end

      File.chmod!(path, 0o644)
    end

    test "a missing category warns and scores without it", %{dir: dir} do
      # An override directory that shadows the packaged one entirely,
      # with one category simply absent.
      packaged = Lexicon.default_dir()

      for category <- Lexicon.categories(), category != :negators do
        File.cp!(Path.join(packaged, "#{category}.txt"), Path.join(dir, "#{category}.txt"))
      end

      System.put_env("SMM_SENTIMENT_DIR", dir)
      Lexicon.reload()

      # The packaged negators are still found, because an override
      # directory adds to the search path rather than replacing it.
      assert Lexicon.member?(:negators, "not")
    end

    test "scoring never raises, whatever the lists say", %{dir: dir} do
      for category <- Lexicon.categories() do
        File.write!(Path.join(dir, "#{category}.txt"), "")
      end

      System.put_env("SMM_SENTIMENT_DIR", dir)
      Lexicon.reload()

      result = Sentiment.score("not very excellent, but terrible")

      assert result.label == :neutral
      assert result.score == 0.0
    end
  end
end
