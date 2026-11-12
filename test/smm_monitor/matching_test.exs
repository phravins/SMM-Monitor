defmodule SmmMonitor.MatchingTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.{Client, Matching}

  doctest SmmMonitor.Matching

  defp client(id, keywords, overrides \\ []) do
    struct!(%Client{id: id, name: id, keywords: keywords}, overrides)
  end

  defp matches(clients, text), do: clients |> Matching.build() |> Matching.clients_for(text)

  describe "word boundaries" do
    test "matches a whole word in any case, with punctuation around it" do
      clients = [client("ro", ["realoffice"])]

      for text <- ["realoffice", "RealOffice rocks", "#RealOffice", "@realoffice!", "RealOffice's"] do
        assert matches(clients, text) == ["ro"], "expected a match in #{inspect(text)}"
      end
    end

    test "does not match inside a longer word" do
      clients = [client("ro", ["realoffice"])]

      for text <- ["surrealofficer", "realoffices", "xrealoffice", "realoffice_bot"] do
        assert matches(clients, text) == [], "expected no match in #{inspect(text)}"
      end
    end

    test "letters from other scripts count as part of a word" do
      clients = [client("acme", ["acme"])]

      assert matches(clients, "acmeé") == []
      assert matches(clients, "éacme") == []
      assert matches(clients, "acme, café") == ["acme"]
    end
  end

  describe "phrases" do
    test "a space in a term matches any run of whitespace" do
      clients = [client("ro", ["real office"])]

      assert matches(clients, "the real office") == ["ro"]
      assert matches(clients, "the real\n\toffice") == ["ro"]
      assert matches(clients, "the realoffice") == []
      assert matches(clients, "the real offices") == []
    end
  end

  describe "accents and emoji" do
    test "accented terms match case-insensitively" do
      clients = [client("cafe", ["Café Été"])]

      assert matches(clients, "Lunch at CAFÉ ÉTÉ today") == ["cafe"]
      assert matches(clients, "Lunch at cafe ete today") == []
    end

    test "emoji next to a term do not stop it matching" do
      clients = [client("acme", ["acme"])]

      assert matches(clients, "🔥acme🔥") == ["acme"]
    end
  end

  describe "several clients" do
    test "a post that mentions two clients belongs to both, in client order" do
      clients = [client("a", ["alpha"]), client("b", ["bravo"])]

      assert matches(clients, "bravo and alpha") == ["a", "b"]
      assert matches(clients, "just bravo") == ["b"]
    end

    test "regex characters in a term are matched literally" do
      clients = [client("cpp", ["c++"]), client("dot", ["a.b"])]

      assert matches(clients, "I write c++ daily") == ["cpp"]
      assert matches(clients, "axb") == []
      assert matches(clients, "see a.b") == ["dot"]
    end
  end

  describe "what gets left out" do
    test "paused clients never match" do
      clients = [client("acme", ["acme"], active: false)]

      matcher = Matching.build(clients)
      assert Matching.empty?(matcher)
      assert Matching.clients_for(matcher, "acme") == []
    end

    test "blank and punctuation-only terms are dropped" do
      matcher = Matching.build([client("x", ["", "  ", "!!!", "#"])])

      assert Matching.empty?(matcher)
      assert Matching.clients_for(matcher, "!!! # anything") == []
    end

    test "nil text never matches" do
      assert matches([client("acme", ["acme"])], nil) == []
    end

    test "no clients means nothing matches" do
      assert Matching.empty?(Matching.build([]))
      assert matches([], "acme") == []
    end
  end
end
