defmodule SmmMonitor.Fetchers.Instagram.SourcesTest do
  @moduledoc """
  The list of things Instagram will actually let us read, and the
  normalisation that keeps a typo in an env var from silently disabling
  monitoring.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Instagram.Sources

  doctest Sources

  test "the default is the two sources a plain account token can read" do
    assert Sources.default() == [:tags, :comments]
  end

  test "hashtag search is known but not on by default" do
    # It spends a budget of 30 unique hashtags per rolling 7 days.
    assert :hashtag in Sources.all()
    refute :hashtag in Sources.default()
  end

  describe "normalize/1" do
    test "accepts atoms and strings, since one comes from an env var" do
      assert Sources.normalize(["tags", "hashtag"]) == [:tags, :hashtag]
      assert Sources.normalize([:tags, :hashtag]) == [:tags, :hashtag]
    end

    test "tolerates whitespace from a comma-separated list" do
      assert Sources.normalize([" tags ", "comments"]) == [:tags, :comments]
    end

    test "drops anything it doesn't know how to fetch" do
      # There is no "search" source, however much anyone wants one.
      assert Sources.normalize([:tags, :search, :mentions]) == [:tags]
    end

    test "de-duplicates" do
      assert Sources.normalize([:tags, "tags"]) == [:tags]
    end

    test "unset means the default, not nothing" do
      assert Sources.normalize(nil) == Sources.default()
    end

    test "an explicitly empty list stays empty" do
      # Distinct from unset: the fetcher reports it rather than silently
      # falling back to the default.
      assert Sources.normalize([]) == []
    end

    test "a list of nothing but typos ends up empty, not defaulted" do
      # Better to report "no sources enabled" than to quietly monitor
      # something the operator didn't ask for.
      assert Sources.normalize(["tagz", "commentz"]) == []
    end
  end

  describe "describe/1" do
    test "says what each source can see" do
      assert Sources.describe(:tags) =~ "@-tag"
      assert Sources.describe(:comments) =~ "own posts"
      # The limitation belongs in the description, not just the README.
      assert Sources.describe(:hashtag) =~ "no author"
    end
  end
end
