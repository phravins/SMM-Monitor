defmodule SmmMonitor.Matching do
  @moduledoc """
  Decides which clients a post is about.

  The polled platforms ask each API to search for a client's brand terms,
  so every result already belongs to the client it was fetched for. A
  stream is different: Bluesky's Jetstream sends every new post on the
  network, and the app has to pick out the ones that mention a brand
  itself. This module does that picking.

  A term matches as a whole word or phrase, case-insensitively and with
  Unicode-aware boundaries, so "realoffice" matches "#RealOffice" and
  "RealOffice's" but not "surrealofficer". Spaces in a term match any
  run of whitespace, so "real office" also matches "real\\noffice".

  Every client gets one compiled regex. Before any regex runs, a single
  `:binary.match/2` over the lowercased text checks whether *any* term of
  *any* client appears at all. On a firehose almost nothing does, so the
  regexes run only on the few posts that might match.
  """

  @enforce_keys [:prefilter, :clients]
  defstruct [:prefilter, clients: []]

  @type t :: %__MODULE__{
          prefilter: :binary.cp() | nil,
          clients: [{String.t(), Regex.t()}]
        }

  @doc """
  Builds a matcher for these clients. Inactive clients and clients with
  no usable terms are left out.

      iex> client = %SmmMonitor.Client{id: "acme", name: "Acme", keywords: ["acme", "acme corp"]}
      iex> matcher = SmmMonitor.Matching.build([client])
      iex> SmmMonitor.Matching.clients_for(matcher, "I love ACME products")
      ["acme"]
      iex> SmmMonitor.Matching.clients_for(matcher, "acmezone is something else")
      []
  """
  @spec build([SmmMonitor.Client.t()]) :: t()
  def build(clients) do
    compiled =
      for %{active: true, id: id, keywords: keywords} <- clients,
          terms = clean_terms(keywords),
          terms != [],
          do: {id, terms_regex(terms), terms}

    case compiled do
      [] ->
        %__MODULE__{prefilter: nil, clients: []}

      _some ->
        prefilter =
          compiled
          |> Enum.flat_map(fn {_id, _regex, terms} -> Enum.map(terms, &first_word/1) end)
          |> Enum.uniq()
          |> :binary.compile_pattern()

        %__MODULE__{
          prefilter: prefilter,
          clients: Enum.map(compiled, fn {id, regex, _terms} -> {id, regex} end)
        }
    end
  end

  @doc "True when no client has anything to match."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{clients: clients}), do: clients == []

  @doc """
  Returns the ids of the clients `text` mentions, in client order.

      iex> clients = [
      ...>   %SmmMonitor.Client{id: "ro", name: "RealOffice", keywords: ["realoffice", "real office"]},
      ...>   %SmmMonitor.Client{id: "cafe", name: "Café Été", keywords: ["café été"]}
      ...> ]
      iex> matcher = SmmMonitor.Matching.build(clients)
      iex> SmmMonitor.Matching.clients_for(matcher, "Trying #RealOffice today")
      ["ro"]
      iex> SmmMonitor.Matching.clients_for(matcher, "a surrealofficer appears")
      []
      iex> SmmMonitor.Matching.clients_for(matcher, "Real\\n  Office at CAFÉ ÉTÉ")
      ["ro", "cafe"]
  """
  @spec clients_for(t(), String.t() | nil) :: [String.t()]
  def clients_for(%__MODULE__{prefilter: nil}, _text), do: []
  def clients_for(_matcher, nil), do: []

  def clients_for(%__MODULE__{prefilter: prefilter, clients: clients}, text) when is_binary(text) do
    lowered = String.downcase(text)

    case :binary.match(lowered, prefilter) do
      :nomatch -> []
      _found -> for {id, regex} <- clients, Regex.match?(regex, text), do: id
    end
  end

  # Terms are trimmed, lowercased and de-duplicated; empty ones and ones
  # with nothing but punctuation would match too much and are dropped.
  defp clean_terms(keywords) do
    keywords
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.filter(&String.match?(&1, ~r/[\p{L}\p{N}]/u))
    |> Enum.uniq()
  end

  # The prefilter only needs some piece of the term that must appear in
  # any text that matches; the first word is enough and survives the
  # whitespace flexibility the regex allows.
  defp first_word(term), do: term |> String.split(~r/\s+/u, parts: 2) |> hd()

  defp terms_regex(terms) do
    alternatives =
      terms
      # Longest first, so "acme corp" wins over "acme" where both fit.
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.map_join("|", fn term ->
        term
        |> String.split(~r/\s+/u, trim: true)
        |> Enum.map_join("\\s+", &Regex.escape/1)
      end)

    Regex.compile!("(?<![\\p{L}\\p{N}_])(?:#{alternatives})(?![\\p{L}\\p{N}_])", "iu")
  end
end
