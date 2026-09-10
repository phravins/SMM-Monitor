defmodule SmmMonitor.Client.AlertConfig do
  @moduledoc """
  When a client's monitoring should wake somebody up.

  Per client rather than global, because the thresholds that matter are
  not the same for a law firm and a games studio: a single mention of
  "lawsuit" is an emergency for one and Tuesday for the other, and a
  client with five mentions a day and one with five thousand cannot
  share a volume floor.

  ## The three conditions

    * **Sentiment** — the mean sentiment over the window drops to or
      below `sentiment_threshold`. An absolute measure: it answers "are
      people unhappy?" rather than "are they unhappier than usual?".
    * **Volume** — mentions in the window reach `volume_multiple` times
      the client's own baseline for this hour. A relative measure: a
      quiet brand getting twenty mentions is a story, a loud one getting
      twenty is a Tuesday.
    * **Phrases** — a mention's text contains one of `watch_phrases`.
      No thresholds and no baseline: one mention saying "lawsuit" is the
      whole signal.

  Each has a floor or a minimum alongside it, because every one of these
  is embarrassing on small numbers. Three mentions averaging -0.4 is two
  annoyed customers, not a crisis.

  ## Defaults

  Chosen so a client added from the config screen alerts sensibly with
  nothing typed: sentiment and volume on, phrases empty. Watch phrases
  start empty deliberately — there is no list of words that is right for
  every brand, and guessing would either cry wolf or say nothing.
  """

  alias SmmMonitor.Client

  @defaults %{
    enabled: true,
    window_ms: :timer.hours(1),
    sentiment_threshold: -0.3,
    sentiment_min_mentions: 5,
    volume_multiple: 3.0,
    volume_floor: 10,
    watch_phrases: [],
    webhook_url: nil
  }

  defstruct enabled: true,
            # The rolling window every condition is measured over.
            window_ms: :timer.hours(1),
            # Alert when the mean sentiment is at or below this.
            sentiment_threshold: -0.3,
            # ...but only once there are this many mentions to average.
            sentiment_min_mentions: 5,
            # Alert when volume reaches this multiple of the baseline.
            volume_multiple: 3.0,
            # ...and is at least this many in absolute terms.
            volume_floor: 10,
            # Case-insensitive substrings. Any match alerts immediately.
            watch_phrases: [],
            # Overrides the global Slack webhook for this client only.
            webhook_url: nil

  @type t :: %__MODULE__{
          enabled: boolean(),
          window_ms: pos_integer(),
          sentiment_threshold: float(),
          sentiment_min_mentions: non_neg_integer(),
          volume_multiple: float(),
          volume_floor: non_neg_integer(),
          watch_phrases: [String.t()],
          webhook_url: String.t() | nil
        }

  @doc "The defaults, as a map. Documented in the README."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "A config with everything at its default."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Builds a config from attrs, keeping defaults for anything absent.

  Values arrive from JSON (string keys, from the database) or from
  someone typing into the config screen (strings that need parsing), so
  both are accepted and anything unusable falls back to the default
  rather than failing — an unreadable threshold should not stop a client
  being monitored.

      iex> alias SmmMonitor.Client.AlertConfig
      iex> AlertConfig.new(%{"sentiment_threshold" => -0.5}).sentiment_threshold
      -0.5
      iex> AlertConfig.new(%{sentiment_threshold: "nonsense"}).sentiment_threshold
      -0.3
  """
  @spec new(map() | keyword() | nil) :: t()
  def new(nil), do: %__MODULE__{}

  def new(attrs) do
    attrs = normalize_keys(attrs)

    %__MODULE__{
      enabled: boolean(attrs, :enabled),
      window_ms: positive_integer(attrs, :window_ms),
      sentiment_threshold: sentiment_threshold(attrs),
      sentiment_min_mentions: non_negative_integer(attrs, :sentiment_min_mentions),
      volume_multiple: multiple(attrs),
      volume_floor: non_negative_integer(attrs, :volume_floor),
      watch_phrases: phrases(Map.get(attrs, :watch_phrases)),
      webhook_url: webhook_url(Map.get(attrs, :webhook_url))
    }
  end

  @doc """
  Applies a partial update, validating the changed value.

  Unlike `new/1` this *reports* a bad value instead of silently falling
  back, because it is called from the config screen where someone is
  watching and a silent no-op reads as a bug.
  """
  @spec put(t(), atom(), term()) :: {:ok, t()} | {:error, atom()}
  def put(%__MODULE__{} = config, :watch_phrases, value) do
    {:ok, %{config | watch_phrases: phrases(value)}}
  end

  def put(%__MODULE__{} = config, :webhook_url, value) do
    case webhook_url(value) do
      :invalid -> {:error, :invalid_webhook_url}
      url -> {:ok, %{config | webhook_url: url}}
    end
  end

  def put(%__MODULE__{} = config, :sentiment_threshold, value) do
    case parse_float(value) do
      {:ok, number} when number >= -1.0 and number <= 1.0 ->
        {:ok, %{config | sentiment_threshold: number}}

      {:ok, _number} ->
        # Sentiment is normalised to -1.0..1.0, so a threshold outside it
        # can only ever be always-on or never-on.
        {:error, :out_of_range}

      :error ->
        {:error, :not_a_number}
    end
  end

  def put(%__MODULE__{} = config, :volume_multiple, value) do
    case parse_float(value) do
      {:ok, number} when number > 1.0 -> {:ok, %{config | volume_multiple: number}}
      # At or below 1x, "spike" means "any normal hour".
      {:ok, _number} -> {:error, :out_of_range}
      :error -> {:error, :not_a_number}
    end
  end

  def put(%__MODULE__{} = config, field, value)
      when field in [:sentiment_min_mentions, :volume_floor] do
    case parse_integer(value) do
      {:ok, number} when number >= 0 -> {:ok, Map.put(config, field, number)}
      {:ok, _number} -> {:error, :out_of_range}
      :error -> {:error, :not_a_number}
    end
  end

  def put(%__MODULE__{} = config, :window_ms, value) do
    case parse_integer(value) do
      {:ok, number} when number > 0 -> {:ok, %{config | window_ms: number}}
      {:ok, _number} -> {:error, :out_of_range}
      :error -> {:error, :not_a_number}
    end
  end

  def put(%__MODULE__{} = config, :enabled, value) do
    {:ok, %{config | enabled: truthy?(value)}}
  end

  def put(%__MODULE__{}, _field, _value), do: {:error, :unknown_field}

  @doc "As a plain map with string keys, for storing as JSON."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      "enabled" => config.enabled,
      "window_ms" => config.window_ms,
      "sentiment_threshold" => config.sentiment_threshold,
      "sentiment_min_mentions" => config.sentiment_min_mentions,
      "volume_multiple" => config.volume_multiple,
      "volume_floor" => config.volume_floor,
      "watch_phrases" => config.watch_phrases,
      "webhook_url" => config.webhook_url
    }
  end

  @doc """
  Whether any condition is worth evaluating.

  A client with alerting off, or with every condition neutralised, is
  skipped entirely rather than evaluated into silence.
  """
  @spec any_conditions?(t()) :: boolean()
  def any_conditions?(%__MODULE__{enabled: false}), do: false
  def any_conditions?(%__MODULE__{}), do: true

  @doc """
  Whether a mention's text trips any of the watch phrases.

  Case-insensitive substring matching, which is what "refund" needs to
  catch "Refunded" and "no refund yet". Returns the phrase that matched,
  since the alert has to say which word it was.

      iex> alias SmmMonitor.Client.AlertConfig
      iex> config = AlertConfig.new(%{watch_phrases: ["lawsuit", "refund"]})
      iex> AlertConfig.matching_phrase(config, "still waiting on my REFUND")
      "refund"
      iex> AlertConfig.matching_phrase(config, "great product")
      nil
  """
  @spec matching_phrase(t(), String.t() | nil) :: String.t() | nil
  def matching_phrase(%__MODULE__{watch_phrases: []}, _text), do: nil
  def matching_phrase(%__MODULE__{}, nil), do: nil

  def matching_phrase(%__MODULE__{watch_phrases: phrases}, text) do
    downcased = String.downcase(text)
    Enum.find(phrases, &String.contains?(downcased, &1))
  end

  # --- internals ------------------------------------------------------------

  defp normalize_keys(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn {key, value} -> {to_atom(key), value} end)
  end

  defp to_atom(key) when is_atom(key), do: key

  defp to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    # An unknown key in stored JSON is ignored rather than crashing the
    # boot; :unknown is not a field, so it falls out of the struct build.
    ArgumentError -> :unknown
  end

  defp boolean(attrs, key) do
    case Map.get(attrs, key) do
      nil -> Map.fetch!(@defaults, key)
      value -> truthy?(value)
    end
  end

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?(value) when is_binary(value), do: String.downcase(value) in ~w(1 true yes on)
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp sentiment_threshold(attrs) do
    with {:ok, number} <- parse_float(Map.get(attrs, :sentiment_threshold)),
         true <- number >= -1.0 and number <= 1.0 do
      number
    else
      _invalid -> @defaults.sentiment_threshold
    end
  end

  defp multiple(attrs) do
    with {:ok, number} <- parse_float(Map.get(attrs, :volume_multiple)),
         true <- number > 1.0 do
      number
    else
      _invalid -> @defaults.volume_multiple
    end
  end

  defp positive_integer(attrs, key) do
    with {:ok, number} <- parse_integer(Map.get(attrs, key)),
         true <- number > 0 do
      number
    else
      _invalid -> Map.fetch!(@defaults, key)
    end
  end

  defp non_negative_integer(attrs, key) do
    with {:ok, number} <- parse_integer(Map.get(attrs, key)),
         true <- number >= 0 do
      number
    else
      _invalid -> Map.fetch!(@defaults, key)
    end
  end

  # Phrases are stored and matched lowercased, so the match is a plain
  # `contains?` rather than a downcase per phrase per mention.
  defp phrases(value) do
    value
    |> Client.normalize()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp webhook_url(nil), do: nil

  defp webhook_url(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      url -> if String.starts_with?(url, "https://"), do: url, else: :invalid
    end
  end

  defp webhook_url(_value), do: :invalid

  defp parse_float(nil), do: :error
  defp parse_float(value) when is_float(value), do: {:ok, value}
  defp parse_float(value) when is_integer(value), do: {:ok, value / 1}

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp parse_float(_value), do: :error

  defp parse_integer(nil), do: :error
  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp parse_integer(_value), do: :error
end
