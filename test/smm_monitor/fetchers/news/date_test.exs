defmodule SmmMonitor.Fetchers.News.DateTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.News.Date, as: FeedDate

  doctest SmmMonitor.Fetchers.News.Date

  describe "RFC 822, as RSS 2.0 uses it" do
    test "the textbook form" do
      assert FeedDate.parse("Thu, 12 Nov 2026 09:30:00 +0000") == ~U[2026-11-12 09:30:00Z]
    end

    test "no weekday, no seconds" do
      assert FeedDate.parse("12 Nov 2026 09:30 GMT") == ~U[2026-11-12 09:30:00Z]
    end

    test "a US zone name" do
      assert FeedDate.parse("Thu, 12 Nov 2026 09:30:00 EST") == ~U[2026-11-12 14:30:00Z]
      assert FeedDate.parse("Thu, 12 Nov 2026 09:30:00 PDT") == ~U[2026-11-12 16:30:00Z]
    end

    test "an offset with a colon, and a negative one" do
      assert FeedDate.parse("Thu, 12 Nov 2026 09:30:00 +05:30") == ~U[2026-11-12 04:00:00Z]
      assert FeedDate.parse("Thu, 12 Nov 2026 09:30:00 -0800") == ~U[2026-11-12 17:30:00Z]
    end

    test "a full month name and a one-digit day" do
      assert FeedDate.parse("Mon, 2 November 2026 09:30:00 GMT") == ~U[2026-11-02 09:30:00Z]
    end

    test "an unknown zone reads as UTC" do
      assert FeedDate.parse("Thu, 12 Nov 2026 09:30:00 XYZ") == ~U[2026-11-12 09:30:00Z]
    end

    test "two-digit years" do
      assert FeedDate.parse("12 Nov 26 09:30 GMT") == ~U[2026-11-12 09:30:00Z]
      assert FeedDate.parse("12 Nov 99 09:30 GMT") == ~U[1999-11-12 09:30:00Z]
    end
  end

  describe "ISO 8601, as Atom and dc:date use it" do
    test "with Z, an offset, and fractions of a second" do
      assert FeedDate.parse("2026-11-12T10:00:00Z") == ~U[2026-11-12 10:00:00Z]
      assert FeedDate.parse("2026-11-12T10:00:00+01:00") == ~U[2026-11-12 09:00:00Z]
      assert FeedDate.parse("2026-11-12T10:00:00.123Z") == ~U[2026-11-12 10:00:00Z]
    end

    test "no seconds, lower case, a space for the T" do
      assert FeedDate.parse("2026-11-12T06:15Z") == ~U[2026-11-12 06:15:00Z]
      assert FeedDate.parse("2026-11-12t06:15:00z") == ~U[2026-11-12 06:15:00Z]
      assert FeedDate.parse("2026-11-12 06:15:00Z") == ~U[2026-11-12 06:15:00Z]
    end

    test "no zone reads as UTC" do
      assert FeedDate.parse("2026-11-12T06:15:00") == ~U[2026-11-12 06:15:00Z]
    end
  end

  describe "what it refuses" do
    test "nonsense, impossible dates and silly offsets are nil" do
      for text <- [
            "",
            "soon",
            "Thu, 31 Feb 2026 09:30:00 GMT",
            "Thu, 12 Nov 2026 25:30:00 GMT",
            "Thu, 12 Nov 2026 09:30:00 +2500",
            "Thu, 12 Foo 2026 09:30:00 GMT",
            "2026-13-01T00:00:00Z"
          ] do
        assert FeedDate.parse(text) == nil, "expected nil for #{inspect(text)}"
      end
    end

    test "anything long is nil without being read" do
      assert FeedDate.parse("Thu, 12 Nov 2026 09:30:00 GMT" <> String.duplicate(" ", 100) <> "x") ==
               nil
    end

    test "a non-string is nil" do
      assert FeedDate.parse(nil) == nil
      assert FeedDate.parse(1_700_000_000) == nil
    end
  end
end
