defmodule SmmMonitor.TextTest do
  @moduledoc """
  The dashboard draws text written by strangers. These tests are the
  reason it is safe to.
  """
  use ExUnit.Case, async: true
  doctest SmmMonitor.Text

  alias SmmMonitor.{Mention, Text}

  # The payload that actually worked against this app: it set the
  # terminal's title and cleared the screen.
  @attack "great tool! \e]0;PWNED BY A REDDIT POST\a\e[31m\e[2J\e[HTERMINAL OWNED"

  describe "safe/1 against the real payload" do
    test "removes every byte the terminal would act on" do
      cleaned = Text.safe(@attack)

      refute String.contains?(cleaned, <<27>>), "an ESC survived"
      refute String.contains?(cleaned, <<7>>), "a BEL survived"
      assert cleaned == "great tool! ]0;PWNED BY A REDDIT POST[31m[2J[HTERMINAL OWNED"
    end

    test "leaves the words, so the analyst can see what was attempted" do
      assert Text.safe(@attack) =~ "great tool!"
      assert Text.safe(@attack) =~ "PWNED BY A REDDIT POST"
    end
  end

  describe "safe/1" do
    test "keeps ordinary text exactly as written" do
      assert Text.safe("Totally normal feedback about OSWORKS.") ==
               "Totally normal feedback about OSWORKS."
    end

    test "keeps emoji and non-Latin scripts — this is a social media tool" do
      assert Text.safe("excellent 🎉 サービス — спасибо") == "excellent 🎉 サービス — спасибо"
    end

    test "turns the line breaks of a multi-line post into one table row" do
      assert Text.safe("first line\nsecond line") == "first line second line"
      assert Text.safe("tab\tseparated") == "tab separated"
    end

    test "removes C1 controls, the other spelling of the same commands" do
      assert Text.safe("before" <> <<0xC2, 0x9B>> <> "after") == "beforeafter"
    end

    test "removes bidi overrides, which reorder text without changing it" do
      # The Trojan Source trick. Built from codepoints rather than typed
      # literally: Elixir's own compiler refuses these characters in
      # source, for exactly the reason this strips them from posts.
      override = <<0x202E::utf8>>
      isolate_start = <<0x2066::utf8>>
      isolate_end = <<0x2069::utf8>>

      assert Text.safe("refund" <> override <> "deuss") == "refunddeuss"
      assert Text.safe("a" <> isolate_start <> "b" <> isolate_end <> "c") == "abc"
    end

    test "survives invalid UTF-8 from an API rather than crashing" do
      assert is_binary(Text.safe("ok" <> <<0xFF, 0xFE>>))
    end

    test "passes nil through" do
      assert Text.safe(nil) == nil
    end
  end

  describe "the sanitiser is wired into the paths that matter" do
    test "a mention built from an API response is clean" do
      mention =
        Mention.new(%{
          platform: :reddit,
          author: "u/attacker\e]0;title\a",
          text: @attack,
          url: "https://example.invalid/\e[2J",
          timestamp: DateTime.utc_now()
        })

      for field <- [mention.text, mention.author, mention.url] do
        refute String.contains?(field, <<27>>)
      end
    end

    # A database written before the sanitiser existed still holds raw
    # escapes, and that database is the one most people have.
    test "a row read back from the database is clean even if it was stored dirty" do
      record = %SmmMonitor.Persistence.MentionRecord{
        mention_id: "x",
        platform: "reddit",
        client_id: "acme",
        author: "u/attacker\e[2J",
        text: @attack,
        url: nil,
        source_timestamp: DateTime.utc_now(),
        sentiment: "neutral",
        sentiment_value: 0.0,
        sentiment_score: 0,
        mock: false
      }

      mention = SmmMonitor.Persistence.MentionRecord.to_mention(record)

      refute String.contains?(mention.text, <<27>>)
      refute String.contains?(mention.author, <<27>>)
    end
  end
end
