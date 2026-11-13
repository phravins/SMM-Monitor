defmodule SmmMonitor.Text do
  @moduledoc """
  Makes text from strangers safe to put on a terminal.

  Every mention this app collects was written by somebody we have never
  met, and it is drawn straight onto a terminal. A terminal is not a
  passive display: bytes below 0x20 are commands to it. Ratatouille
  turns a string into one cell per grapheme and termbox writes each
  cell's codepoint out verbatim, so an ESC in a Reddit comment is an ESC
  on the analyst's screen.

  That is not theoretical. A post reading

      great tool! \\e]0;PWNED BY A REDDIT POST\\a\\e[2J

  retitled the terminal window and blanked the dashboard — proved
  end to end against this app before this module existed.

  What an attacker gets without this: the window title (OSC 0), a
  cleared or scrolled screen, cursor moves that overwrite neighbouring
  rows — so a negative mention can be painted over a positive one, or
  the LIVE indicator forged — and, on terminals that allow it, the
  clipboard (OSC 52), which is how a dashboard becomes a way to put a
  command on somebody's clipboard.

  So nothing but printable text reaches the screen.

  ## What is removed

    * C0 controls (0x00-0x1F) and DEL — ESC, BEL and friends. Tab,
      newline and carriage return are legitimate in a post, so they
      become spaces rather than vanishing: the table is one line a row.
    * C1 controls (0x80-0x9F), which some terminals accept as an
      alternative encoding of the same commands.
    * Bidirectional overrides (U+202A-U+202E, U+2066-U+2069) and the
      direction marks. These reorder displayed text without changing it
      — the "Trojan Source" trick — so "refund" can be made to read
      "dnufer" or a URL made to appear to point somewhere else. The
      Arabic letter mark (U+061C) is removed for the same reason.
    * Invisible characters that hide text or split words to dodge a
      match: zero width space (U+200B), word joiner (U+2060), the byte
      order mark (U+FEFF) and the interlinear annotation marks
      (U+FFF9-U+FFFB). Zero width joiner and non-joiner are kept: emoji
      sequences and several scripts need them.
    * Line and paragraph separators (U+2028, U+2029) become spaces, like
      a newline.
    * Runs of more than four combining marks on one character ("Zalgo"
      text), which some terminals draw over the rows above and below.

  Everything else is kept, emoji and every script included: this is a
  social media tool and the content is the point.
  """

  # Tab, newline and carriage return carry meaning in a post; the rest of
  # C0 does not survive.
  @as_space [?\t, ?\n, ?\r, ?\v, ?\f]

  @doc """
  Strips terminal control sequences and bidi overrides, and tidies the
  whitespace that is left.

      iex> SmmMonitor.Text.safe("hello")
      "hello"

      iex> SmmMonitor.Text.safe("great tool! \\e]0;PWNED\\a")
      "great tool! ]0;PWNED"

      iex> SmmMonitor.Text.safe("line one\\nline two")
      "line one line two"

      iex> SmmMonitor.Text.safe(nil)
      nil
  """
  @spec safe(String.t()) :: String.t()
  @spec safe(nil) :: nil
  def safe(nil), do: nil

  def safe(text) when is_binary(text) do
    text
    # Invalid UTF-8 from an API would crash String.graphemes/1 further
    # down; a replacement character is a better answer than a stack trace.
    |> sanitize_encoding()
    |> String.to_charlist()
    |> Enum.map(&replace/1)
    |> Enum.reject(&is_nil/1)
    |> cap_combining()
    |> List.to_string()
    |> collapse_whitespace()
  end

  def safe(other), do: other |> to_string() |> safe()

  @doc """
  HTML as plain text, for the platforms that send it: Mastodon posts and
  news feed summaries.

  Line breaks and the ends of blocks (paragraphs, list items, headings,
  cells) become spaces, scripts and styles go with their contents, every
  other tag goes, and entities are decoded. It is not a sanitiser: the
  result still goes through `safe/1` like any other text.

      iex> SmmMonitor.Text.html_to_text("<p>Hi &amp; bye</p><p>Next<br>line</p>")
      "Hi & bye Next line"

      iex> SmmMonitor.Text.html_to_text("<ul><li>one</li><li>two</li></ul><script>x()</script>")
      "one two"

      iex> SmmMonitor.Text.html_to_text("It&rsquo;s here &hellip;")
      "It’s here …"
  """
  @spec html_to_text(term()) :: String.t()
  def html_to_text(html) when is_binary(html) do
    html
    |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1\s*>}is, " ")
    |> String.replace(~r{<br\s*/?>|</(?:p|div|li|h[1-6]|td|th|tr|blockquote)\s*>}i, " ")
    |> String.replace(~r/<[^>]*>/, "")
    |> decode_entities()
    |> String.split()
    |> Enum.join(" ")
  end

  def html_to_text(_other), do: ""

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "hellip" => "…",
    "mdash" => "—",
    "ndash" => "–",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "laquo" => "«",
    "raquo" => "»",
    "copy" => "©",
    "reg" => "®",
    "trade" => "™"
  }

  defp decode_entities(text) do
    Regex.replace(~r/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});/, text, fn all, name ->
      case name do
        "#x" <> hex -> codepoint(Integer.parse(hex, 16), all)
        "#X" <> hex -> codepoint(Integer.parse(hex, 16), all)
        "#" <> decimal -> codepoint(Integer.parse(decimal), all)
        name -> Map.get(@entities, name, all)
      end
    end)
  end

  # Only real characters: not NUL, not a surrogate, not past Unicode.
  defp codepoint({code, ""}, _all)
       when code in 1..0xD7FF or code in 0xE000..0x10FFFF,
       do: <<code::utf8>>

  defp codepoint(_parsed, _all), do: ""

  @doc """
  Whether `text` carries anything this module would strip.

  For tests and for anyone who wants to count how often it happens
  rather than silently clean it up.
  """
  @spec safe?(String.t()) :: boolean()
  def safe?(text) when is_binary(text), do: safe(text) == collapse_whitespace(text)

  defp replace(char) when char in @as_space, do: ?\s
  # C0 and DEL.
  defp replace(char) when char < 0x20 or char == 0x7F, do: nil
  # C1: a second spelling of the same control codes.
  defp replace(char) when char >= 0x80 and char <= 0x9F, do: nil
  # Bidi overrides and isolates, and the direction marks.
  defp replace(char) when char in 0x202A..0x202E, do: nil
  defp replace(char) when char in 0x2066..0x2069, do: nil
  defp replace(char) when char in [0x200E, 0x200F, 0x061C], do: nil
  # Invisible: zero width space, word joiner, BOM, annotation marks.
  defp replace(char) when char in [0x200B, 0x2060, 0xFEFF], do: nil
  defp replace(char) when char in 0xFFF9..0xFFFB, do: nil
  # Line and paragraph separators break a row like a newline would.
  defp replace(char) when char in [0x2028, 0x2029], do: ?\s
  defp replace(char), do: char

  @max_combining 4

  # Keep at most @max_combining combining marks after any one character.
  defp cap_combining(chars) do
    {kept, _run} =
      Enum.reduce(chars, {[], 0}, fn char, {acc, run} ->
        cond do
          not combining?(char) -> {[char | acc], 0}
          run < @max_combining -> {[char | acc], run + 1}
          true -> {acc, run}
        end
      end)

    Enum.reverse(kept)
  end

  defp combining?(char) do
    char in 0x0300..0x036F or char in 0x1AB0..0x1AFF or char in 0x1DC0..0x1DFF or
      char in 0x20D0..0x20FF or char in 0xFE20..0xFE2F
  end

  defp sanitize_encoding(text) do
    if String.valid?(text) do
      text
    else
      text
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        binary when is_binary(binary) -> binary
        _invalid -> replace_invalid(text)
      end
    end
  end

  defp replace_invalid(text) do
    for <<byte <- text>>, into: "" do
      if byte < 0x80, do: <<byte>>, else: "?"
    end
  end

  defp collapse_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+/u, " ")
    |> String.trim()
  end
end
