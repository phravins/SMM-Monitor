defmodule SmmMonitor.Alerts.Conditions do
  @moduledoc """
  The things worth waking someone for, and how each decides.

  Every condition is a pure function from an observation to a verdict.
  No clock, no database, no process — which is what lets every threshold
  decision be tested without waiting for a real spike, and what lets the
  `SmmMonitor.Alerts` process stay a loop with no judgement in it.

  ## The three

    * `SentimentThreshold` — absolute: are people unhappy?
    * `VolumeSpike` — relative: is this louder than this client's normal?
    * `WatchPhrase` — literal: did anyone say the word?

  They answer different questions on purpose. A brand can have terrible
  sentiment at a perfectly normal volume (a slow-burning complaint), a
  huge volume spike at neutral sentiment (a viral mention that isn't
  bad), or one quiet mention containing "lawsuit" that matters more than
  either.

  ## A verdict, not a boolean

  Each returns `{:alert, details}` or `{:ok, reason}`. The reason is kept
  rather than collapsed to `false` so the dashboard and the logs can say
  *"not enough mentions to average yet"* instead of going quiet, which
  is the difference between a system that is working and one that looks
  like it.
  """

  alias SmmMonitor.Alerts.Conditions.{SentimentThreshold, VolumeSpike, WatchPhrase}

  @typedoc "Why no alert was raised."
  @type reason :: :disabled | :below_threshold | :too_few_mentions | :warming_up | :no_phrases

  @typedoc "What a condition found, ready to be turned into an `Alert`."
  @type details :: map()

  @type verdict :: {:alert, details()} | {:ok, reason()}

  @doc "The condition modules, in the order they are evaluated."
  @spec all() :: [module()]
  def all, do: [SentimentThreshold, VolumeSpike, WatchPhrase]

  @doc """
  The kinds a condition can raise, for rendering and for keying
  incidents.
  """
  @spec kinds() :: [atom()]
  def kinds, do: [:sentiment_drop, :volume_spike, :watch_phrase]
end
