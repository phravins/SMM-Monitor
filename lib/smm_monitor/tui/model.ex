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

  alias SmmMonitor.Config
  alias SmmMonitor.Monitor

  @default_rows 12

  defstruct tab: :all,
            tabs: [:all],
            # Config screen state. `editing` names the field being typed
            # into, or nil when the screen is just being read.
            config: %{keywords: [], subreddits: []},
            config_source: :defaults,
            config_path: nil,
            selected_field: :keywords,
            editing: nil,
            buffer: "",
            flash: nil,
            # Set when the user asks to quit; the app acts on it.
            quit: false,
            # True for sessions that may view but not change config. Set
            # at construction rather than sniffed from the connection, so
            # a session cannot talk its way out of it later.
            read_only: false,
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

  # Tab shortcuts: a for all, t/i/r/y for the platforms, c for config.
  @tab_keys %{
    ?a => :all,
    ?t => :twitter,
    ?i => :instagram,
    ?r => :reddit,
    ?y => :youtube,
    ?c => :config
  }

  # The fields the config screen can edit, in display order.
  @config_fields [:keywords, :subreddits]

  @doc """
  Builds the initial model.

  `context` is the runtime's context map; `%{window: %{height: h}}` is used
  to size the mentions table, so the dashboard fills whatever terminal it
  was started in.
  """
  @spec new(map()) :: t()
  def new(context \\ %{}) do
    %__MODULE__{
      tabs: [:all | SmmMonitor.platforms()] ++ [:config],
      rows: rows_for(context),
      read_only: Map.get(context, :read_only, false),
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
    # The config tab has no mention list of its own; reading for :config
    # would filter on a platform that doesn't exist.
    reading_tab = if model.tab == :config, do: :all, else: model.tab
    mentions = Monitor.recent(reading_tab, 200)

    %{
      model
      | mentions: mentions,
        stats: Monitor.stats(reading_tab),
        breakdown: Monitor.breakdown(),
        statuses: statuses(),
        config: read_config(),
        config_source: config_source(),
        config_path: config_path(),
        updated_at: DateTime.utc_now()
    }
    |> clamp_offset()
  end

  @doc """
  Applies a key press. Unknown keys leave the model untouched.

  While a config field is being edited every key goes into the text
  buffer, so tab shortcuts and `q` are typed rather than acted on — a
  brand term containing a `q` would otherwise be unreachable. That is why
  `q` is handled here rather than as a Ratatouille quit event: the runtime
  checks quit events *before* the app sees the key, so it could never be
  captured by a text field.
  """
  @spec handle_key(t(), key()) :: t()
  def handle_key(%__MODULE__{editing: field} = model, key) when not is_nil(field) do
    handle_edit_key(model, key)
  end

  def handle_key(%__MODULE__{} = model, {:char, ?q}), do: %{model | quit: true}

  def handle_key(%__MODULE__{} = model, {:char, char}) when is_map_key(@tab_keys, char) do
    select_tab(model, @tab_keys[char])
  end

  # On the config screen the same keys move between fields rather than
  # scrolling a list that isn't there.
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?j}), do: move_field(model, 1)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?k}), do: move_field(model, -1)
  def handle_key(%__MODULE__{tab: :config} = model, {:key, :arrow_down}), do: move_field(model, 1)
  def handle_key(%__MODULE__{tab: :config} = model, {:key, :arrow_up}), do: move_field(model, -1)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?e}), do: start_editing(model)
  def handle_key(%__MODULE__{tab: :config} = model, {:key, :enter}), do: start_editing(model)

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
      # Leaving the config screen abandons any half-typed edit.
      refresh(%{model | tab: tab, offset: 0, editing: nil, buffer: "", flash: nil})
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
  # The config screen isn't a view over mentions, so a count would be
  # meaningless there.
  def tab_label(%__MODULE__{}, :config), do: "config"

  def tab_label(%__MODULE__{} = model, :all) do
    "all (#{Enum.sum(Map.values(model.breakdown))})"
  end

  def tab_label(%__MODULE__{} = model, platform) do
    "#{platform} (#{Map.get(model.breakdown, platform, 0)})"
  end

  @doc "Whether the mentions list scrolls past the bottom of the table."
  @spec scrollable?(t()) :: boolean()
  def scrollable?(%__MODULE__{} = model), do: length(model.mentions) > model.rows

  # --- config screen --------------------------------------------------------

  @doc "The fields the config screen can edit, in display order."
  @spec config_fields() :: [atom()]
  def config_fields, do: @config_fields

  @doc "Moves the selection between config fields, wrapping at the ends."
  @spec move_field(t(), integer()) :: t()
  def move_field(%__MODULE__{} = model, delta) do
    index = Enum.find_index(@config_fields, &(&1 == model.selected_field)) || 0

    next =
      Enum.at(@config_fields, rem(index + delta + length(@config_fields), length(@config_fields)))

    %{model | selected_field: next, flash: nil}
  end

  @doc """
  Starts editing the selected field, seeding the buffer with its current
  value so an edit is a correction rather than a retype.
  """
  @spec start_editing(t()) :: t()
  def start_editing(%__MODULE__{read_only: true} = model) do
    %{
      model
      | flash: {:error, "read-only session — config can only be changed from the host terminal"}
    }
  end

  def start_editing(%__MODULE__{} = model) do
    %{
      model
      | editing: model.selected_field,
        buffer: field_value(model, model.selected_field),
        flash: nil
    }
  end

  @doc "Abandons an in-progress edit, leaving the stored value alone."
  @spec cancel_editing(t()) :: t()
  def cancel_editing(%__MODULE__{} = model) do
    %{model | editing: nil, buffer: "", flash: {:info, "cancelled"}}
  end

  @doc """
  Commits the buffer to `SmmMonitor.Config`.

  A rejected value (an empty keyword list) leaves the editor open with the
  reason shown, rather than dropping what was typed.
  """
  @spec commit_editing(t()) :: t()
  def commit_editing(%__MODULE__{editing: nil} = model), do: model

  # Belt and braces: start_editing/1 already refuses, so reaching here on
  # a read-only session would mean a bug rather than a user action. Fail
  # closed regardless.
  def commit_editing(%__MODULE__{read_only: true} = model) do
    %{model | editing: nil, buffer: "", flash: {:error, "read-only session — nothing was saved"}}
  end

  def commit_editing(%__MODULE__{editing: field, buffer: buffer} = model) do
    case write_field(field, buffer) do
      {:ok, values} ->
        %{
          model
          | editing: nil,
            buffer: "",
            config: Map.put(model.config, field, values),
            flash: {:ok, "#{label(field)} saved — fetchers pick this up on their next poll"}
        }

      {:error, reason} ->
        %{model | flash: {:error, error_message(field, reason)}}
    end
  end

  @doc "The current value of a config field, as the comma-separated text shown."
  @spec field_value(t(), atom()) :: String.t()
  def field_value(%__MODULE__{config: config}, field) do
    config |> Map.get(field, []) |> Enum.join(", ")
  end

  @doc "Human label for a config field."
  @spec label(atom()) :: String.t()
  def label(:keywords), do: "brand terms"
  def label(:subreddits), do: "subreddits"
  def label(field), do: to_string(field)

  @doc "Whether the config screen is currently capturing typed input."
  @spec editing?(t()) :: boolean()
  def editing?(%__MODULE__{editing: editing}), do: not is_nil(editing)

  # Every key goes into the buffer while editing, so a term containing a
  # tab shortcut letter (or a `q`) can actually be typed.
  defp handle_edit_key(model, {:key, :enter}), do: commit_editing(model)
  defp handle_edit_key(model, {:key, :escape}), do: cancel_editing(model)

  defp handle_edit_key(model, {:key, :backspace}) do
    %{model | buffer: String.slice(model.buffer, 0..-2//1), flash: nil}
  end

  defp handle_edit_key(model, {:char, char}) when char >= 32 do
    %{model | buffer: model.buffer <> <<char::utf8>>, flash: nil}
  end

  defp handle_edit_key(model, _key), do: model

  defp write_field(:keywords, buffer), do: Config.put_keywords(buffer)
  defp write_field(:subreddits, buffer), do: Config.put_subreddits(buffer)

  defp error_message(:keywords, :no_keywords),
    do: "at least one brand term is needed — nothing would be monitored"

  defp error_message(field, reason), do: "could not save #{label(field)}: #{inspect(reason)}"

  # The config screen reads through the same public API as everything else.
  # A Config process that isn't running (a test rendering the model in
  # isolation) shows empty rather than crashing the dashboard.
  defp read_config do
    Config.all()
  catch
    :exit, _reason -> %{keywords: [], subreddits: []}
  end

  defp config_source do
    Config.source()
  catch
    :exit, _reason -> :unavailable
  end

  defp config_path do
    Config.path()
  catch
    :exit, _reason -> nil
  end

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
