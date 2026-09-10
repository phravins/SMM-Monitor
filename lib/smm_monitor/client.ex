defmodule SmmMonitor.Client do
  @moduledoc """
  A client whose brand is being monitored.

  RealOffice runs social media for several businesses at once, so the unit
  of monitoring is a *client*, not a keyword. Each carries its own brand
  terms and its own subreddit list, and every mention belongs to exactly
  one of them.

  ## Why keywords is a list

  The brief says "keyword", but a brand is rarely one string: "realoffice"
  and "real office" are the same client and both need searching. So this
  is a list, the same shape the single-brand config used, which also means
  the migration from that config is a rename rather than a conversion.

  ## Ids

  The id is a slug derived from the name — `"Acme Corp"` becomes
  `"acme-corp"` — because it ends up in the database on every mention row
  and in log lines, where a readable value is worth more than a UUID.
  Uniqueness is enforced by `SmmMonitor.Clients`, which suffixes a
  collision rather than rejecting the name: two clients called "Acme" is
  the operator's business, not ours.

  Ids never change. Renaming a client leaves its id — and therefore its
  history — alone, which is the whole point of not keying mentions on the
  name.
  """

  alias SmmMonitor.Client.AlertConfig

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    keywords: [],
    subreddits: [],
    # An inactive client keeps its history but is not polled for. Cheaper
    # and less destructive than deleting one whose contract is on hold.
    active: true,
    # When this client's monitoring should wake somebody up. Per client,
    # because the thresholds that matter differ by brand.
    alerts: nil,
    created_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          keywords: [String.t()],
          subreddits: [String.t()],
          active: boolean(),
          alerts: SmmMonitor.Client.AlertConfig.t(),
          created_at: DateTime.t() | nil
        }

  # Long enough for a real business name, short enough to render in a
  # terminal column without truncating everything around it.
  @max_name_length 60

  @doc """
  Builds a client from attrs, normalising the lists and deriving an id.

  Returns `{:error, reason}` rather than raising: these values come from
  someone typing into a terminal, so invalid input is expected and needs
  a message, not a crash.

      iex> {:ok, client} = SmmMonitor.Client.new(%{name: "Acme Corp", keywords: "acme, acme corp"})
      iex> {client.id, client.keywords}
      {"acme-corp", ["acme", "acme corp"]}

      iex> SmmMonitor.Client.new(%{name: "  "})
      {:error, :missing_name}

      iex> SmmMonitor.Client.new(%{name: "Acme", keywords: []})
      {:error, :no_keywords}
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) do
    attrs = Map.new(attrs)
    name = attrs |> Map.get(:name) |> to_string() |> String.trim()
    keywords = normalize(Map.get(attrs, :keywords))

    cond do
      name == "" ->
        {:error, :missing_name}

      String.length(name) > @max_name_length ->
        {:error, :name_too_long}

      # A client with no brand terms would be polled for nothing on every
      # platform — a silent no-op that looks like a working client.
      keywords == [] ->
        {:error, :no_keywords}

      true ->
        {:ok,
         %__MODULE__{
           id: Map.get(attrs, :id) || slug(name),
           name: name,
           keywords: keywords,
           subreddits: normalize(Map.get(attrs, :subreddits)),
           active: Map.get(attrs, :active, true),
           alerts: alert_config(Map.get(attrs, :alerts)),
           created_at: Map.get(attrs, :created_at) || DateTime.utc_now()
         }}
    end
  end

  @doc """
  Applies a partial update, re-validating the result.

  The id is never changed, so a rename keeps the client's mentions.
  """
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, atom()}
  def update(%__MODULE__{} = client, attrs) do
    attrs = Map.new(attrs)

    new(%{
      id: client.id,
      name: Map.get(attrs, :name, client.name),
      keywords: Map.get(attrs, :keywords, client.keywords),
      subreddits: Map.get(attrs, :subreddits, client.subreddits),
      active: Map.get(attrs, :active, client.active),
      alerts: Map.get(attrs, :alerts, client.alerts),
      created_at: client.created_at
    })
  end

  # A client always has an alert config, defaulted rather than nil, so
  # nothing downstream has to check before reading a threshold.
  defp alert_config(%AlertConfig{} = config), do: config
  defp alert_config(attrs), do: AlertConfig.new(attrs)

  @doc """
  Turns a name into a url-safe, readable id.

      iex> SmmMonitor.Client.slug("Acme Corp")
      "acme-corp"
      iex> SmmMonitor.Client.slug("Beta & Sons (UK)")
      "beta-sons-uk"
      iex> SmmMonitor.Client.slug("日本のブランド")
      "client"
  """
  @spec slug(String.t()) :: String.t()
  def slug(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      # A name with no ASCII alphanumerics at all still needs an id, and
      # `Clients` will suffix it into uniqueness.
      "" -> "client"
      slug -> String.slice(slug, 0, 40)
    end
  end

  @doc """
  Normalises user input into a clean list of terms.

  Accepts a list or a comma-separated string, trims, drops blanks and
  de-duplicates while preserving order — the same rules the single-brand
  config used, so what someone typed before still means the same thing.

      iex> SmmMonitor.Client.normalize("realoffice, real office")
      ["realoffice", "real office"]
      iex> SmmMonitor.Client.normalize(["  spaced  ", "", "spaced"])
      ["spaced"]
  """
  @spec normalize([String.t()] | String.t() | nil) :: [String.t()]
  def normalize(nil), do: []
  def normalize(value) when is_binary(value), do: value |> String.split(",") |> normalize()

  def normalize(values) when is_list(values) do
    values
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize(_value), do: []

  @doc "A short label for logs and the dashboard header."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{name: name, active: true}), do: name
  def label(%__MODULE__{name: name}), do: "#{name} (paused)"
end
