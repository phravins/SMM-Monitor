defmodule SmmMonitor.TUI.Model do
  @moduledoc """
  The dashboard's state and every transition over it — with no reference to
  Ratatouille anywhere in this module.

  Input arrives as normalised keys (`{:char, ?r}`, `{:key, :arrow_down}`)
  rather than a terminal library's event structs, and output is plain data
  that a renderer turns into widgets. That is the seam: swapping Ratatouille
  for another TUI library means writing a new renderer and a new event
  translation, and leaving this module — where the actual behaviour lives —
  untouched.

  It is also why the dashboard's logic is testable without a terminal.
  """

  alias SmmMonitor.Monitor

  @default_rows 12

  defstruct tab: :all,
            tabs: [:all],
            stats: %{count: 0, positive: 0, neutral: 0, negative: 0, score: 0},
            breakdown: %{},
            mentions: [],
            statuses: [],
            # Index of the first visible row in `mentions`.
            offset: 0,
            rows: @default_rows,
            keywords: [],
            mock_mode: true,
            window_ms: nil,
            updated_at: nil

  @type key :: {:char, char()} | {:key, atom()}

  @type t :: %__MODULE__{}

  # Tab shortcuts, per the spec: a for all, t/i/r/y for the platforms.
  @tab_keys %{?a => :all, ?t => :twitter, ?i => :instagram, ?r => :reddit, ?y => :youtube}

  @doc """
  Builds the initial model.

  `context` is the runtime's context map; `%{window: %{height: h}}` is used
  to size the mentions table, so the dashboard fills whatever terminal it
  was started in.
  """
  @spec new(map()) :: t()
  def new(context \\ %{}) do
    %__MODULE__{
      tabs: [:all | SmmMonitor.platforms()],
      rows: rows_for(context),
      keywords: SmmMonitor.config(:keywords, []),
      mock_mode: SmmMonitor.config(:mock_mode, true),
      window_ms: SmmMonitor.config(:window_ms, :timer.hours(24))
    }
    |> refresh()
  end

  @doc """
  Pulls the latest data from the processing layer.

  Called on every tick. Reads hit ETS directly (see `SmmMonitor.Monitor`),
  so this stays cheap enough to run once a second.
  """
  @spec refresh(t()) :: t()
  def refresh(%__MODULE__{} = model) do
    mentions = Monitor.recent(model.tab, 200)

    %{
      model
      | mentions: mentions,
        stats: Monitor.stats(model.tab),
        breakdown: Monitor.breakdown(),
        statuses: statuses(),
        updated_at: DateTime.utc_now()
    }
    |> clamp_offset()
  end

  @doc """
  Applies a key press. Unknown keys leave the model untouched.

  Quitting is handled by the runtime's quit events, not here, so that the
  terminal is always restored properly on the way out.
  """
  @spec handle_key(t(), key()) :: t()
  def handle_key(%__MODULE__{} = model, {:char, char}) when is_map_key(@tab_keys, char) do
    select_tab(model, @tab_keys[char])
  end

  def handle_key(model, {:char, ?j}), do: scroll(model, 1)
  def handle_key(model, {:char, ?k}), do: scroll(model, -1)
  def handle_key(model, {:char, ?g}), do: %{model | offset: 0}
  def handle_key(model, {:key, :arrow_down}), do: scroll(model, 1)
  def handle_key(model, {:key, :arrow_up}), do: scroll(model, -1)
  def handle_key(model, {:key, :page_down}), do: scroll(model, model.rows)
  def handle_key(model, {:key, :page_up}), do: scroll(model, -model.rows)
  def handle_key(model, {:key, :home}), do: %{model | offset: 0}
  def handle_key(model, _key), do: model

  @doc "Switches the active tab and re-reads for it, resetting the scroll."
  @spec select_tab(t(), atom()) :: t()
  def select_tab(%__MODULE__{} = model, tab) do
    if tab in model.tabs do
      refresh(%{model | tab: tab, offset: 0})
    else
      # An unconfigured platform (e.g. `i` with Instagram disabled) is a
      # no-op rather than an empty screen.
      model
    end
  end

  @doc "Moves the table's viewport by `delta` rows, staying in bounds."
  @spec scroll(t(), integer()) :: t()
  def scroll(%__MODULE__{} = model, delta) do
    clamp_offset(%{model | offset: model.offset + delta})
  end

  @doc "Handles a terminal resize by recomputing how many rows fit."
  @spec resize(t(), map()) :: t()
  def resize(%__MODULE__{} = model, context) do
    clamp_offset(%{model | rows: rows_for(context)})
  end

  @doc "The slice of mentions currently on screen."
  @spec visible_mentions(t()) :: [SmmMonitor.Mention.t()]
  def visible_mentions(%__MODULE__{} = model) do
    Enum.slice(model.mentions, model.offset, model.rows)
  end

  @doc """
  Sentiment split as whole percentages that always sum to 100.

  The largest bucket absorbs the rounding remainder, so the bar never has a
  gap or an overflow column.
  """
  @spec sentiment_percentages(t()) :: %{
          positive: integer(),
          neutral: integer(),
          negative: integer()
        }
  def sentiment_percentages(%__MODULE__{stats: stats}) do
    total = stats.count

    if total == 0 do
      %{positive: 0, neutral: 0, negative: 0}
    else
      raw =
        Map.new([:positive, :neutral, :negative], &{&1, div(Map.fetch!(stats, &1) * 100, total)})

      remainder = 100 - (raw.positive + raw.neutral + raw.negative)
      largest = Enum.max_by([:positive, :neutral, :negative], &Map.fetch!(stats, &1))
      Map.update!(raw, largest, &(&1 + remainder))
    end
  end

  @doc """
  Splits `width` columns between the sentiment buckets, proportionally.

  Returns `{positive, neutral, negative}` column counts summing to `width`
  (or all zeros when there is nothing to show).
  """
  @spec sentiment_bar(t(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def sentiment_bar(%__MODULE__{stats: stats}, width) do
    total = stats.count

    if total == 0 do
      {0, 0, 0}
    else
      positive = div(stats.positive * width, total)
      neutral = div(stats.neutral * width, total)
      {positive, neutral, width - positive - neutral}
    end
  end

  @doc "Label for a tab, with its count, e.g. `\"reddit (12)\"`."
  @spec tab_label(t(), atom()) :: String.t()
  def tab_label(%__MODULE__{} = model, :all) do
    "all (#{Enum.sum(Map.values(model.breakdown))})"
  end

  def tab_label(%__MODULE__{} = model, platform) do
    "#{platform} (#{Map.get(model.breakdown, platform, 0)})"
  end

  @doc "Whether the mentions list scrolls past the bottom of the table."
  @spec scrollable?(t()) :: boolean()
  def scrollable?(%__MODULE__{} = model), do: length(model.mentions) > model.rows

  # Offsets are clamped rather than rejected so that a shrinking list (after
  # a prune, or a tab switch) can never leave the table showing nothing.
  defp clamp_offset(%__MODULE__{} = model) do
    max_offset = max(length(model.mentions) - model.rows, 0)
    %{model | offset: model.offset |> max(0) |> min(max_offset)}
  end

  # Chrome above and below the table: bars, tab row, stats panel, borders.
  @chrome_rows 13

  defp rows_for(%{window: %{height: height}}) when is_integer(height) do
    max(height - @chrome_rows, 3)
  end

  defp rows_for(_context), do: @default_rows

  # A worker that is mid-restart reports `:unavailable`; the dashboard shows
  # that rather than crashing along with it.
  defp statuses do
    Enum.map(SmmMonitor.platforms(), fn platform ->
      case SmmMonitor.Fetchers.Worker.status(platform) do
        :unavailable -> %{platform: platform, mode: :down, last_error: :not_running}
        status -> status
      end
    end)
  end
end
