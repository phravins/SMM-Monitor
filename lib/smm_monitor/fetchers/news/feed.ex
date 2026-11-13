defmodule SmmMonitor.Fetchers.News.Feed do
  @moduledoc """
  Reads RSS 2.0, RSS 1.0 (RDF) and Atom feeds into plain maps.

  A feed is XML written by somebody else's server, so it is parsed as
  untrusted input:

    * Saxy, a streaming parser, reads it. It creates no atoms and never
      expands an entity declared in a DOCTYPE, so the "billion laughs"
      trick and its relatives come out as the literal text `&lol9;`.
    * At most `:max_items` items are read (200 by default); the parse
      stops there. Each field keeps at most 64 KB of text while it is
      being read, and less once it is cleaned up.
    * HTML in titles and summaries (escaped, in CDATA, or Atom's inline
      XHTML) is reduced to text by `SmmMonitor.Text.html_to_text/1`.
    * Links are kept only when they are `http` or `https` with no user
      name or password in them, resolved against the feed's own address.

  Real feeds are not always well-formed. Two common faults are repaired
  before parsing: a byte order mark or whitespace before the XML
  declaration, and a bare `&` that is not the start of an entity. A feed
  declared as ISO-8859-1 or Windows-1252 is converted to UTF-8, which is
  all Saxy reads. Anything still broken is an error for that feed alone.
  """

  alias SmmMonitor.Fetchers.News.Date, as: FeedDate
  alias SmmMonitor.Text

  @default_max_items 200

  @max_title 300
  @max_summary 2_000
  @max_author 120
  @max_guid 1_000
  @max_link 2_000

  @typedoc "One item, cleaned up. Every field may be `nil` except `:title`."
  @type item :: %{
          guid: String.t() | nil,
          title: String.t(),
          link: String.t() | nil,
          published: DateTime.t() | nil,
          summary: String.t(),
          author: String.t() | nil,
          source: String.t() | nil
        }

  @type t :: %{title: String.t() | nil, link: String.t() | nil, items: [item()]}

  @doc """
  Parses a feed's body. `base_url` is the address it was fetched from,
  for resolving relative links.

      iex> xml = ~s(<rss version="2.0"><channel><title>Acme News</title>
      ...>   <item><title>Acme &amp; friends</title><link>/a/1</link>
      ...>   <pubDate>Wed, 12 Nov 2026 10:00:00 GMT</pubDate></item></channel></rss>)
      iex> {:ok, feed} = SmmMonitor.Fetchers.News.Feed.parse(xml, "https://news.example/feed")
      iex> feed.title
      "Acme News"
      iex> [item] = feed.items
      iex> {item.title, item.link, item.published}
      {"Acme & friends", "https://news.example/a/1", ~U[2026-11-12 10:00:00Z]}
  """
  @spec parse(binary(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(body, base_url, opts \\ []) when is_binary(body) do
    max_items = Keyword.get(opts, :max_items, @default_max_items)

    with {:ok, xml} <- prepare(body),
         {:ok, raw} <- run(xml, max_items) do
      {:ok, finish(raw, base_url)}
    end
  end

  # --- before parsing --------------------------------------------------------

  @doc false
  # Public for tests.
  def prepare(body) do
    body =
      body
      |> strip_bom()
      |> String.trim_leading()

    with {:ok, body} <- to_utf8(body) do
      {:ok, escape_bare_ampersands(body)}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(body), do: body

  @declaration ~r/\A<\?xml[^>]*?encoding\s*=\s*["']([A-Za-z0-9._-]{1,40})["'][^>]*\?>/

  defp to_utf8(body) do
    case Regex.run(@declaration, body, capture: :all_but_first) do
      nil ->
        {:ok, body}

      [encoding] ->
        case String.downcase(encoding) do
          utf8 when utf8 in ["utf-8", "utf8", "us-ascii", "ascii"] ->
            {:ok, declare_utf8(body)}

          latin when latin in ["iso-8859-1", "latin1", "latin-1", "windows-1252", "cp1252"] ->
            converted =
              if String.valid?(body),
                # Says Latin-1 but is already UTF-8: a common mislabel.
                do: body,
                else: :unicode.characters_to_binary(body, :latin1, :utf8)

            {:ok, declare_utf8(converted)}

          other ->
            {:error, {:unsupported_encoding, other}}
        end
    end
  end

  # Saxy refuses any declared encoding but UTF-8, even after conversion.
  defp declare_utf8(body) do
    Regex.replace(~r/\A(<\?xml[^>]*?encoding\s*=\s*)["'][^"']*["']/, body, "\\1\"UTF-8\"",
      global: false
    )
  end

  # `AT&T` in a title makes a feed malformed, and a lot of feeds do it.
  defp escape_bare_ampersands(body) do
    String.replace(
      body,
      ~r/&(?!(?:[A-Za-z][A-Za-z0-9]{0,31}|#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6});)/,
      "&amp;"
    )
  end

  defp run(xml, max_items) do
    state = %{
      depth: 0,
      stack: [],
      root: nil,
      feed: %{},
      item: nil,
      item_depth: nil,
      items: [],
      count: 0,
      max_items: max_items,
      capture: nil
    }

    case Saxy.parse_string(xml, __MODULE__.Handler, state, expand_entity: :keep) do
      {:ok, %{root: root} = state} when root in ["rss", "feed", "RDF"] -> {:ok, state}
      {:ok, _state} -> {:error, :not_a_feed}
      {:error, %Saxy.ParseError{reason: reason}} -> {:error, {:bad_xml, short(reason)}}
      {:error, _other} -> {:error, {:bad_xml, :unknown}}
    end
  end

  # A parse error's reason can quote the document; keep only its shape.
  defp short({tag, _detail}) when is_atom(tag), do: tag
  defp short(tag) when is_atom(tag), do: tag
  defp short(_other), do: :unknown

  # --- after parsing ---------------------------------------------------------

  defp finish(state, base_url) do
    feed_link = link(state.feed[:link], base_url)

    items =
      state.items
      |> Enum.reverse()
      |> Enum.map(&item(&1, base_url))
      |> Enum.reject(&is_nil/1)

    %{title: clean(state.feed[:title], @max_title), link: feed_link, items: items}
  end

  defp item(raw, base_url) do
    title = clean(raw[:title], @max_title)
    summary = clean(raw[:summary] || raw[:content], @max_summary) || ""
    link = link(raw[:link], base_url)
    guid = raw[:guid] |> plain(@max_guid)

    # Something has to identify it and something has to be readable.
    if (title || summary != "") && (guid || link || title) do
      %{
        guid: guid,
        title: title || truncate(summary, @max_title),
        link: link,
        published: FeedDate.parse(raw[:published] || raw[:updated]),
        summary: if(title, do: summary, else: ""),
        author: raw[:author] |> author() |> clean(@max_author),
        source: clean(raw[:source], @max_author)
      }
    end
  end

  defp clean(nil, _max), do: nil

  defp clean(text, max) do
    case text |> Text.html_to_text() |> Text.safe() do
      "" -> nil
      text -> truncate(text, max)
    end
  end

  defp plain(nil, _max), do: nil

  defp plain(text, max) do
    case String.trim(text) do
      "" -> nil
      text -> String.slice(text, 0, max)
    end
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  # RSS 2.0's <author> is an email address, often with the name after it
  # in brackets: "jane@example.com (Jane Doe)". Only the name is kept.
  defp author(nil), do: nil

  defp author(text) do
    text = String.trim(text)

    cond do
      match = Regex.run(~r/\A\S+@\S+\s*\((.+)\)\z/, text, capture: :all_but_first) -> hd(match)
      Regex.match?(~r/\A\S+@\S+\z/, text) -> nil
      true -> text
    end
  end

  @doc false
  # Public for tests: a link from a feed, resolved against `base_url`,
  # or nil if it is not a plain web address.
  def link(nil, _base_url), do: nil

  def link(href, base_url) do
    href = String.trim(href)

    with true <- href != "" and byte_size(href) <= @max_link,
         {:ok, base} <- URI.new(base_url),
         {:ok, ref} <- URI.new(href),
         %URI{scheme: scheme, host: host, userinfo: nil} = uri
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.merge(base, ref) do
      URI.to_string(uri)
    else
      _not_a_link -> nil
    end
  rescue
    # URI.merge raises on a base it cannot merge into.
    ArgumentError -> nil
  end

  defmodule Handler do
    @moduledoc false
    # Saxy callbacks. The state is the map built in `Feed.run/2`.
    #
    # Elements are matched by local name, so `<dc:creator>`, `<atom:link>`
    # and a default-namespace `<entry>` all work whatever prefix a feed
    # chose. While a field is being read (`capture`), child elements do
    # not interrupt it: Atom's `type="xhtml"` content is a tree of tags
    # whose text all belongs to the one field.

    @behaviour Saxy.Handler

    # While reading. A summary longer than this is not a summary.
    @max_field_bytes 65_536

    @impl true
    def handle_event(:start_document, _prolog, state), do: {:ok, state}
    def handle_event(:end_document, _data, state), do: {:ok, state}

    def handle_event(:start_element, {name, attributes}, state) do
      local = local_name(name)
      parent = List.first(state.stack)
      depth = state.depth + 1
      state = %{state | depth: depth, stack: [local | state.stack]}
      state = if depth == 1, do: %{state | root: local}, else: state

      {:ok, start(state, local, parent, attributes, depth)}
    end

    def handle_event(:end_element, _name, state) do
      state = finish_capture(state)
      state = %{state | depth: state.depth - 1, stack: tl(state.stack)}

      if state.item && state.depth < state.item_depth do
        state = %{
          state
          | items: [state.item | state.items],
            count: state.count + 1,
            item: nil,
            item_depth: nil
        }

        if state.count >= state.max_items, do: {:stop, state}, else: {:ok, state}
      else
        {:ok, state}
      end
    end

    def handle_event(:characters, chars, %{capture: {key, depth, buffer, size, mode}} = state) do
      wanted? =
        case mode do
          :all -> true
          # An Atom <author> holds <name> and <email>, and an Atom <source>
          # a whole feed header; only the name, or an RSS element's own
          # text, is wanted.
          :direct -> state.depth == depth or hd(state.stack) == "name"
        end

      if wanted? and size < @max_field_bytes do
        {:ok, %{state | capture: {key, depth, [buffer, chars], size + byte_size(chars), mode}}}
      else
        {:ok, state}
      end
    end

    def handle_event(:characters, _chars, state), do: {:ok, state}

    # Inside a field being read: nothing starts.
    defp start(%{capture: capture} = state, _local, _parent, _attributes, _depth)
         when capture != nil,
         do: state

    defp start(%{item: nil} = state, local, _parent, _attributes, depth)
         when local in ["item", "entry"],
         do: %{state | item: %{}, item_depth: depth}

    defp start(%{item: item} = state, local, _parent, attributes, depth) when item != nil do
      if depth == state.item_depth + 1 do
        item_field(state, local, attributes, depth)
      else
        state
      end
    end

    # Channel or feed level: its title and its own link.
    defp start(state, local, parent, attributes, depth) when parent in ["channel", "feed"] do
      cond do
        local == "title" and state.feed[:title] == nil ->
          capture(state, :feed_title, depth)

        local == "link" and alternate?(attributes) and state.feed[:link] == nil ->
          case attribute(attributes, "href") do
            nil when parent == "channel" -> capture(state, :feed_link, depth)
            nil -> state
            href -> put_in(state.feed[:link], href)
          end

        true ->
          state
      end
    end

    defp start(state, _local, _parent, _attributes, _depth), do: state

    defp item_field(state, "link", attributes, depth) do
      case attribute(attributes, "href") do
        # RSS: the link is the element's text.
        nil ->
          capture(state, :link, depth)

        # Atom: in an attribute, and only the alternate (the page itself),
        # not an enclosure or a comments feed.
        href ->
          if alternate?(attributes) and state.item[:link] == nil,
            do: put_in(state.item[:link], href),
            else: state
      end
    end

    defp item_field(state, local, _attributes, depth) do
      case field(local) do
        nil -> state
        key when key in [:author, :source] -> capture(state, key, depth, :direct)
        key -> capture(state, key, depth)
      end
    end

    defp field("title"), do: :title
    defp field("guid"), do: :guid
    defp field("id"), do: :guid
    defp field("pubDate"), do: :published
    defp field("published"), do: :published
    defp field("issued"), do: :published
    # dc:date
    defp field("date"), do: :published
    defp field("updated"), do: :updated
    defp field("modified"), do: :updated
    defp field("description"), do: :summary
    defp field("summary"), do: :summary
    # content:encoded, and Atom's <content>
    defp field("encoded"), do: :content
    defp field("content"), do: :content
    # dc:creator
    defp field("creator"), do: :author
    defp field("author"), do: :author
    defp field("source"), do: :source
    defp field(_other), do: nil

    defp capture(state, key, depth, mode \\ :all),
      do: %{state | capture: {key, depth, [], 0, mode}}

    defp finish_capture(%{capture: {key, depth, buffer, _size, _mode}} = state)
         when depth == state.depth do
      text = IO.iodata_to_binary(buffer)
      state = %{state | capture: nil}

      case key do
        :feed_title -> put_new(state, :feed, :title, text)
        :feed_link -> put_new(state, :feed, :link, text)
        key -> if state.item, do: put_new(state, :item, key, text), else: state
      end
    end

    defp finish_capture(state), do: state

    # The first value wins: a feed that repeats a field meant the first.
    defp put_new(state, where, key, text) do
      if String.trim(text) == "" do
        state
      else
        Map.update!(state, where, &Map.put_new(&1, key, text))
      end
    end

    defp alternate?(attributes), do: attribute(attributes, "rel") in [nil, "alternate"]

    defp attribute(attributes, name) do
      Enum.find_value(attributes, fn {key, value} -> if local_name(key) == name, do: value end)
    end

    defp local_name(name) do
      case :binary.split(name, ":") do
        [_prefix, local] -> local
        [local] -> local
      end
    end
  end
end
