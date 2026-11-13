defmodule SmmMonitor.Fetchers.News.FeedTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.News.Feed
  alias SmmMonitor.NewsStub

  doctest SmmMonitor.Fetchers.News.Feed

  defp parse!(name, base \\ "https://feeds.example/feed") do
    {:ok, feed} = Feed.parse(NewsStub.fixture(name), base)
    feed
  end

  defp rss(items, extra \\ "") do
    ~s(<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>T</title>) <>
      extra <> items <> "</channel></rss>"
  end

  defp item(fields), do: "<item>" <> fields <> "</item>"

  describe "RSS 2.0" do
    setup do: {:ok, feed: parse!("rss2")}

    test "reads the channel and every item", %{feed: feed} do
      assert feed.title == "The Ops Ledger"
      assert feed.link == "https://opsledger.example/"
      assert length(feed.items) == 4
    end

    test "takes the summary over the full content, as text", %{feed: feed} do
      [first | _rest] = feed.items

      assert first.title == "Acme raises prices for small teams"
      assert first.guid == "opsledger-4411"
      assert first.link == "https://opsledger.example/2026/11/acme-prices"
      assert first.published == ~U[2026-11-12 09:30:00Z]
      assert first.author == "Dana Lee"
      assert first.summary == "Acme’s new plans start at $12 a seat."
    end

    test "resolves a relative link and reads the name out of an e-mail author", %{feed: feed} do
      second = Enum.at(feed.items, 1)

      assert second.link == "https://feeds.example/2026/11/ten-tools"
      assert second.author == "Tom Okafor"
      assert second.summary =~ "Acme makes the list at number three & Globex"
    end

    test "the channel's image title is not the feed's title", %{feed: feed} do
      refute feed.title =~ "Image"
    end
  end

  describe "Atom" do
    setup do: {:ok, feed: parse!("atom")}

    test "reads the feed and its entries", %{feed: feed} do
      assert feed.title == "SaaS Briefing"
      assert feed.link == "https://saasbriefing.example/"
      assert length(feed.items) == 2
    end

    test "picks the alternate link, not replies", %{feed: feed} do
      assert hd(feed.items).link == "https://saasbriefing.example/acme-free-tier"
    end

    test "escaped HTML titles and inline XHTML summaries become text", %{feed: feed} do
      entry = hd(feed.items)

      assert entry.title == "Acme doubles its free tier"
      assert entry.summary == "More room for small teams."
    end

    test "the author is the name, never the e-mail", %{feed: feed} do
      assert hd(feed.items).author == "Priya Nair"
    end

    test "published wins over updated; updated stands in when alone", %{feed: feed} do
      [first, second] = feed.items

      assert first.published == ~U[2026-11-12 10:00:00Z]
      assert second.published == ~U[2026-11-12 14:00:00Z]
    end

    test "content stands in for a missing summary", %{feed: feed} do
      assert Enum.at(feed.items, 1).summary == "Not about Acme at all. Well, once."
    end
  end

  test "RSS 1.0 (RDF), with a dc:date" do
    feed = parse!("rdf")

    assert feed.title == "Northside Business Journal"
    assert [item] = feed.items
    assert item.title == "Acme opens a Northside office"
    assert item.link == "https://journal.example/acme-office"
    assert item.published == ~U[2026-11-12 06:15:00Z]
    assert item.author == "Staff"
  end

  test "Google News: the publisher comes from <source>" do
    feed = parse!("google_news", "https://news.google.com/rss/search?q=acme")

    assert [first, second] = feed.items
    assert first.source == "Martech Weekly"
    assert first.guid == "CBMiAAA1"
    assert second.source == "Growth Desk"
  end

  describe "untrusted XML" do
    test "entities declared in a DOCTYPE are never expanded" do
      xml = """
      <?xml version="1.0"?>
      <!DOCTYPE rss [
        <!ENTITY lol "lol">
        <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
      ]>
      <rss version="2.0"><channel><title>T</title>
      <item><title>Acme &lol3;</title><guid>1</guid></item></channel></rss>
      """

      assert {:ok, %{items: [item]}} = Feed.parse(xml, "https://feeds.example/")
      assert byte_size(item.title) < 50
      refute item.title =~ "lollol"
    end

    test "an external entity is not fetched or read" do
      xml = """
      <?xml version="1.0"?>
      <!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
      <rss version="2.0"><channel><title>T</title>
      <item><title>Acme &xxe;</title><guid>1</guid></item></channel></rss>
      """

      assert {:ok, %{items: [item]}} = Feed.parse(xml, "https://feeds.example/")
      refute item.title =~ "root:"
    end

    test "malformed XML is an error" do
      assert {:error, {:bad_xml, _reason}} =
               Feed.parse(rss(item("<title>Acme</title><guid>1")), "https://feeds.example/")
    end

    test "an HTML page is not a feed" do
      assert {:error, _reason} =
               Feed.parse("<!doctype html><html><body>Hi</body></html>", "https://feeds.example/")

      assert {:error, :not_a_feed} =
               Feed.parse("<html><body><p>Hi</p></body></html>", "https://feeds.example/")
    end

    test "other XML is not a feed" do
      assert {:error, :not_a_feed} = Feed.parse("<sitemap><url/></sitemap>", "https://x.example/")
    end

    test "the item count is capped" do
      items = Enum.map_join(1..30, &item("<title>Acme #{&1}</title><guid>#{&1}</guid>"))

      assert {:ok, %{items: items}} =
               Feed.parse(rss(items), "https://feeds.example/", max_items: 10)

      assert length(items) == 10
      assert hd(items).title == "Acme 1"
    end

    test "long fields are cut short" do
      long = String.duplicate("acme ", 2_000)

      assert {:ok, %{items: [item]}} =
               Feed.parse(
                 rss(item("<title>#{long}</title><description>#{long}</description>")),
                 "https://feeds.example/"
               )

      assert String.length(item.title) <= 300
      assert String.length(item.summary) <= 2_000
      assert String.ends_with?(item.title, "…")
    end

    test "only http(s) links without a password are kept" do
      for link <- [
            "javascript:alert(1)",
            "data:text/html,hi",
            "ftp://feeds.example/x",
            "https://user:pw@feeds.example/x"
          ] do
        assert {:ok, %{items: [item]}} =
                 Feed.parse(
                   rss(item("<title>Acme</title><guid>1</guid><link>#{link}</link>")),
                   "https://feeds.example/"
                 )

        assert item.link == nil, "expected #{link} to be dropped"
      end
    end

    test "control characters are taken out of the text" do
      assert {:ok, %{items: [item]}} =
               Feed.parse(rss(item("<title>Acme&#x1B;[31m red</title>")), "https://feeds.example/")

      refute item.title =~ "\e"
    end
  end

  describe "real-world faults it repairs" do
    test "a bare ampersand" do
      assert {:ok, %{items: [item]}} =
               Feed.parse(rss(item("<title>Acme & Globex</title>")), "https://feeds.example/")

      assert item.title == "Acme & Globex"
    end

    test "a byte order mark and whitespace before the declaration" do
      xml = "﻿\n  " <> rss(item("<title>Acme</title>"))
      assert {:ok, %{items: [_item]}} = Feed.parse(xml, "https://feeds.example/")
    end

    test "an ISO-8859-1 feed is converted" do
      xml =
        ~s(<?xml version="1.0" encoding="ISO-8859-1"?><rss version="2.0"><channel>) <>
          "<item><title>Caf\xE9 Acme</title></item></channel></rss>"

      assert {:ok, %{items: [item]}} = Feed.parse(xml, "https://feeds.example/")
      assert item.title == "Café Acme"
    end

    test "a feed that says Latin-1 but is really UTF-8 is left alone" do
      xml =
        ~s(<?xml version="1.0" encoding="iso-8859-1"?><rss version="2.0"><channel>) <>
          "<item><title>Café Acme</title></item></channel></rss>"

      assert {:ok, %{items: [item]}} = Feed.parse(xml, "https://feeds.example/")
      assert item.title == "Café Acme"
    end

    test "an encoding it cannot read is an error" do
      xml = ~s(<?xml version="1.0" encoding="Shift_JIS"?><rss version="2.0"><channel/></rss>)
      assert {:error, {:unsupported_encoding, _name}} = Feed.parse(xml, "https://feeds.example/")
    end

    test "CDATA titles and namespaced elements" do
      xml =
        rss(
          item(
            "<title><![CDATA[Acme <b>&</b> co]]></title><dc:creator>Ann</dc:creator>" <>
              "<guid>1</guid>"
          )
        )
        |> String.replace(
          ~s(<rss version="2.0">),
          ~s(<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">)
        )

      assert {:ok, %{items: [item]}} = Feed.parse(xml, "https://feeds.example/")
      assert item.title == "Acme & co"
      assert item.author == "Ann"
    end
  end

  describe "items it drops" do
    test "an item with no title or summary" do
      assert {:ok, %{items: []}} =
               Feed.parse(rss(item("<link>https://a.example/</link>")), "https://feeds.example/")
    end

    test "an item with only a summary uses it as the title" do
      assert {:ok, %{items: [item]}} =
               Feed.parse(
                 rss(item("<description>Acme news</description><guid>1</guid>")),
                 "https://feeds.example/"
               )

      assert item.title == "Acme news"
      assert item.summary == ""
    end
  end
end
