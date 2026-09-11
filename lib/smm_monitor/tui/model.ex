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

  alias SmmMonitor.Alerts
  alias SmmMonitor.{Client, Clients, Reports}
  alias SmmMonitor.Client.AlertConfig
  alias SmmMonitor.Monitor
  alias SmmMonitor.Processing.Sentiment

  @default_rows 12

  defstruct tab: :all,
            tabs: [:all],
            # Every client, and the one this session is looking at. The
            # selection is per session on purpose: two people on separate
            # SSH sessions watch different clients without fighting over
            # a shared one.
            clients: [],
            client_id: nil,
            # Config screen state. The screen is a grid — one row per
            # client, one column per editable field — so the selection is
            # a cell. `editing` names the field being typed into, or nil
            # when the screen is just being read.
            selected_client: 0,
            selected_field: :name,
            editing: nil,
            buffer: "",
            # Set to a client id while a delete is waiting for
            # confirmation. Removing a client takes its mentions with it,
            # which is not something to do on a single keystroke.
            confirm_remove: nil,
            flash: nil,
            # Alerts raised recently, newest first. Shown as a banner.
            alerts: [],
            # Set when the user asks to quit; the app acts on it.
            quit: false,
            # True for sessions that may view but not change config. Set
            # at construction rather than sniffed from the connection, so
            # a session cannot talk its way out of it later.
            read_only: false,
            stats: %{
              count: 0,
              positive: 0,
              neutral: 0,
              negative: 0,
              score: 0,
              value: 0.0,
              average: 0.0
            },
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

  # The fields of a client the config screen can edit, in display order.
  # The alerting settings sit after the monitoring ones because that is
  # the order they are set up in: decide what to watch, then decide what
  # is worth being woken for.
  @config_fields [
    :name,
    :keywords,
    :subreddits,
    :watch_phrases,
    :sentiment_threshold,
    :volume_multiple,
    :webhook_url
  ]

  # The subset that lives on the client's alert config rather than on the
  # client itself, and so is written through a different door.
  @alert_fields [:watch_phrases, :sentiment_threshold, :volume_multiple, :webhook_url]

  @doc """
  Builds the initial model.

  `context` is the runtime's context map; `%{window: %{height: h}}` is used
  to size the mentions table, so the dashboard fills whatever terminal it
  was started in.
  """
  @spec new(map()) :: t()
  def new(context \\ %{}) do
    clients = read_clients()

    %__MODULE__{
      tabs: [:all | SmmMonitor.platforms()] ++ [:config],
      rows: rows_for(context),
      read_only: Map.get(context, :read_only, false),
      clients: clients,
      client_id: Map.get(context, :client_id) || default_client_id(clients),
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
    clients = read_clients()
    model = %{model | clients: clients, client_id: resolve_selection(model, clients)}
    scope = model.client_id || :all

    %{
      model
      | mentions: Monitor.recent(reading_tab, 200, scope),
        stats: Monitor.stats(reading_tab, nil, scope),
        breakdown: Monitor.breakdown(nil, scope),
        statuses: statuses(),
        alerts: read_alerts(scope),
        keywords: keywords_of(model),
        updated_at: DateTime.utc_now()
    }
    |> clamp_selection()
    |> clamp_offset()
  end

  # A client removed by someone else — or the very first refresh — leaves
  # the selection pointing at nothing. Falling back keeps the dashboard
  # showing *a* client rather than an empty scope that looks like silence.
  defp resolve_selection(%__MODULE__{client_id: nil}, clients), do: default_client_id(clients)

  defp resolve_selection(%__MODULE__{client_id: id}, clients) do
    if Enum.any?(clients, &(&1.id == id)), do: id, else: default_client_id(clients)
  end

  defp default_client_id([]), do: nil

  defp default_client_id(clients) do
    active = Enum.filter(clients, & &1.active)
    List.first((active in [[], nil] && clients) || active).id
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

  # Cycling clients works from every tab: switching client is the thing
  # an account manager does most, and it should never need a detour
  # through the config screen.
  def handle_key(%__MODULE__{} = model, {:char, ?]}), do: cycle_client(model, 1)
  def handle_key(%__MODULE__{} = model, {:char, ?[}), do: cycle_client(model, -1)

  # The numbered list: 1-9 jump straight to a client.
  def handle_key(%__MODULE__{} = model, {:char, char}) when char in ?1..?9 do
    select_client_at(model, char - ?0)
  end

  # On the config screen these keys manage clients rather than scrolling
  # a mention list that isn't there.
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?j}), do: move_client(model, 1)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?k}), do: move_client(model, -1)
  def handle_key(%__MODULE__{tab: :config} = model, {:key, :arrow_down}), do: move_client(model, 1)
  def handle_key(%__MODULE__{tab: :config} = model, {:key, :arrow_up}), do: move_client(model, -1)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?l}), do: move_field(model, 1)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?h}), do: move_field(model, -1)

  def handle_key(%__MODULE__{tab: :config} = model, {:key, :arrow_right}),
    do: move_field(model, 1)

  def handle_key(%__MODULE__{tab: :config} = model, {:key, :arrow_left}), do: move_field(model, -1)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?e}), do: start_editing(model)
  def handle_key(%__MODULE__{tab: :config} = model, {:key, :enter}), do: start_editing(model)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?+}), do: start_adding(model)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?p}), do: toggle_active(model)
  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?s}), do: view_highlighted(model)

  # `R` from anywhere: a report is about the client you are looking at,
  # and having to find the config screen first would be a detour through
  # a settings page to do the most client-facing thing in the app.
  def handle_key(%__MODULE__{} = model, {:char, ?R}), do: generate_report(model)

  # `d` asks the first time and confirms the second, so a client and its
  # mentions can't be lost to one keystroke.
  def handle_key(%__MODULE__{tab: :config, confirm_remove: nil} = model, {:char, ?d}),
    do: request_remove(model)

  def handle_key(%__MODULE__{tab: :config} = model, {:char, ?d}), do: confirm_remove(model)

  # Any other key while a removal is pending cancels it.
  def handle_key(%__MODULE__{tab: :config, confirm_remove: id} = model, key) when not is_nil(id) do
    handle_key(cancel_remove(model), key)
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
      # Leaving the config screen abandons any half-typed edit.
      refresh(%{
        model
        | tab: tab,
          offset: 0,
          editing: nil,
          buffer: "",
          flash: nil,
          confirm_remove: nil
      })
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

  @doc """
  The window's mean sentiment, from `-1.0` to `1.0`.

  Falls back to `0.0` for stats maps written before scoring became
  numeric, so an old snapshot renders as neutral rather than crashing.
  """
  @spec average_sentiment(t()) :: float()
  def average_sentiment(%__MODULE__{stats: stats}), do: Map.get(stats, :average) || 0.0

  @doc """
  The label the mean score falls under, using the scorer's own band.

  Reading it from `Sentiment` rather than hardcoding `> 0` keeps the
  dashboard's idea of "neutral" identical to each mention's.
  """
  @spec average_label(t()) :: :positive | :neutral | :negative
  def average_label(%__MODULE__{} = model) do
    model |> average_sentiment() |> Sentiment.label()
  end

  @doc """
  Lays out a diverging meter for the mean score across `width` columns.

  Returns `{left_pad, negative, positive, right_pad}` column counts: the
  bar grows left from a fixed centre when the mean is negative and right
  when it is positive, so the eye reads direction from which side is lit
  rather than from a number. The centre marker is drawn by the renderer
  and is not counted here, so the four values plus one fill `width`.

  A non-zero score always lights at least one column: rounding a genuine
  -0.02 down to an empty bar would show "no feeling" where there is
  faint feeling.
  """
  @spec sentiment_gauge(t(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def sentiment_gauge(%__MODULE__{} = model, width) do
    half = div(width - 1, 2)
    average = average_sentiment(model)
    magnitude = gauge_magnitude(average, half)

    if average < 0 do
      {half - magnitude, magnitude, 0, half}
    else
      {half, 0, magnitude, half - magnitude}
    end
  end

  defp gauge_magnitude(average, half) do
    scaled = average |> abs() |> Kernel.*(half) |> round() |> min(half)

    if scaled == 0 and average != 0.0, do: min(1, half), else: scaled
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

  # --- client selection -----------------------------------------------------

  @doc """
  Writes a report for the selected client over the last seven days.

  Runs in the calling process rather than a task: the render takes a
  second or two, and a dashboard that silently carried on while a file
  may or may not have appeared would be worse than one that pauses and
  then says where it went.

  Read-only sessions are refused. A remote viewer writing files onto the
  host's disk is not a thing a read-only session should be able to do.
  """
  @spec generate_report(t()) :: t()
  def generate_report(%__MODULE__{read_only: true} = model) do
    %{
      model
      | flash: {:error, "read-only session — reports are generated from the host terminal"}
    }
  end

  def generate_report(%__MODULE__{} = model) do
    case current_client(model) do
      nil ->
        %{model | flash: {:error, "no client selected"}}

      client ->
        write_report(model, client)
    end
  end

  defp write_report(model, client) do
    period = Reports.Period.last_days(7)

    with {:ok, report} <- Reports.build(client, period),
         {:ok, paths} <- Reports.Writer.write(report, formats(), []) do
      %{model | flash: {:ok, "wrote #{Enum.map_join(paths, " and ", &Path.basename/1)}"}}
    else
      {:error, reason} -> %{model | flash: {:error, report_error(reason)}}
    end
  end

  # PDF when the toolchain is there, CSV always — a missing Python
  # install should cost you the formatted report, not the data.
  defp formats do
    case Reports.PDF.available() do
      :ok -> [:pdf, :csv]
      {:error, _reason} -> [:csv]
    end
  end

  defp report_error(reason), do: Reports.PDF.explain(reason)

  @doc "The client this session is looking at, or `nil` if there are none."
  @spec current_client(t()) :: Client.t() | nil
  def current_client(%__MODULE__{clients: clients, client_id: id}) do
    Enum.find(clients, &(&1.id == id))
  end

  @doc """
  Moves the selection `delta` clients along, wrapping at both ends.

  Bound to `]` and `[` so cycling never needs a modifier: switching
  client is the thing an account manager does most.
  """
  @spec cycle_client(t(), integer()) :: t()
  def cycle_client(%__MODULE__{clients: []} = model, _delta), do: model

  def cycle_client(%__MODULE__{clients: clients} = model, delta) do
    index = Enum.find_index(clients, &(&1.id == model.client_id)) || 0
    next = Enum.at(clients, rem(index + delta + length(clients), length(clients)))
    select_client(model, next.id)
  end

  @doc """
  Jumps straight to the nth client, 1-based, as the number keys do.

  Out of range is a no-op rather than an error: pressing 7 with three
  clients means nothing, and should do nothing.
  """
  @spec select_client_at(t(), pos_integer()) :: t()
  def select_client_at(%__MODULE__{clients: clients} = model, position) do
    case Enum.at(clients, position - 1) do
      nil -> model
      client -> select_client(model, client.id)
    end
  end

  @doc "Switches to a client by id and re-reads everything for it."
  @spec select_client(t(), String.t()) :: t()
  def select_client(%__MODULE__{} = model, id) do
    # Scroll position belongs to the client whose list you were reading,
    # so it resets rather than carrying over to a different list.
    refresh(%{model | client_id: id, offset: 0, flash: nil})
  end

  @doc "Where the selected client sits in the list, 1-based, for the header."
  @spec client_position(t()) :: {non_neg_integer(), non_neg_integer()}
  def client_position(%__MODULE__{clients: clients} = model) do
    case Enum.find_index(clients, &(&1.id == model.client_id)) do
      nil -> {0, length(clients)}
      index -> {index + 1, length(clients)}
    end
  end

  # --- config screen: managing clients --------------------------------------

  @doc "The fields of a client the config screen can edit, in display order."
  @spec config_fields() :: [atom()]
  def config_fields, do: @config_fields

  @doc "The client highlighted on the config screen, or `nil` when empty."
  @spec highlighted_client(t()) :: Client.t() | nil
  def highlighted_client(%__MODULE__{clients: clients, selected_client: index}) do
    Enum.at(clients, index)
  end

  @doc "Moves the highlight between clients, wrapping at the ends."
  @spec move_client(t(), integer()) :: t()
  def move_client(%__MODULE__{clients: []} = model, _delta), do: model

  def move_client(%__MODULE__{clients: clients} = model, delta) do
    index = rem(model.selected_client + delta + length(clients), length(clients))
    %{model | selected_client: index, flash: nil, confirm_remove: nil}
  end

  @doc "Moves the highlight between a client's fields, wrapping at the ends."
  @spec move_field(t(), integer()) :: t()
  def move_field(%__MODULE__{} = model, delta) do
    index = Enum.find_index(@config_fields, &(&1 == model.selected_field)) || 0

    next =
      Enum.at(@config_fields, rem(index + delta + length(@config_fields), length(@config_fields)))

    %{model | selected_field: next, flash: nil, confirm_remove: nil}
  end

  @doc """
  Starts editing the highlighted field, seeding the buffer with its
  current value so an edit is a correction rather than a retype.
  """
  @spec start_editing(t()) :: t()
  def start_editing(%__MODULE__{read_only: true} = model), do: refuse(model)

  def start_editing(%__MODULE__{} = model) do
    case highlighted_client(model) do
      nil ->
        %{model | flash: {:error, "no clients yet — press + to add one"}}

      client ->
        %{
          model
          | editing: model.selected_field,
            buffer: field_value(client, model.selected_field),
            confirm_remove: nil,
            flash: nil
        }
    end
  end

  @doc """
  Starts adding a client: types a name, and everything else is edited
  afterwards from the same screen.
  """
  @spec start_adding(t()) :: t()
  def start_adding(%__MODULE__{read_only: true} = model), do: refuse(model)

  def start_adding(%__MODULE__{} = model) do
    %{model | editing: :new_client, buffer: "", confirm_remove: nil, flash: nil}
  end

  @doc "Abandons an in-progress edit, leaving the stored value alone."
  @spec cancel_editing(t()) :: t()
  def cancel_editing(%__MODULE__{} = model) do
    %{model | editing: nil, buffer: "", flash: {:info, "cancelled"}}
  end

  @doc """
  Commits the buffer, either creating a client or updating a field.

  A rejected value leaves the editor open with the reason shown, rather
  than dropping what was typed.
  """
  @spec commit_editing(t()) :: t()
  def commit_editing(%__MODULE__{editing: nil} = model), do: model

  # Belt and braces: start_editing/1 already refuses, so reaching here on
  # a read-only session would mean a bug rather than a user action. Fail
  # closed regardless.
  def commit_editing(%__MODULE__{read_only: true} = model) do
    %{model | editing: nil, buffer: "", flash: {:error, "read-only session — nothing was saved"}}
  end

  def commit_editing(%__MODULE__{editing: :new_client, buffer: buffer} = model) do
    # The name doubles as the first brand term, so a new client starts
    # searching for something rather than nothing. Almost always right,
    # and obvious to correct on the row below when it isn't.
    case Clients.add(%{name: buffer, keywords: buffer}) do
      {:ok, client} ->
        model = refresh(%{model | editing: nil, buffer: ""})
        index = Enum.find_index(model.clients, &(&1.id == client.id)) || 0

        %{
          model
          | selected_client: index,
            selected_field: :keywords,
            flash: {:ok, "added #{client.name} — check its brand terms, then press s to view it"}
        }

      {:error, reason} ->
        %{model | flash: {:error, add_error_message(reason)}}
    end
  end

  def commit_editing(%__MODULE__{editing: field, buffer: buffer} = model) do
    case highlighted_client(model) do
      nil ->
        %{model | editing: nil, buffer: "", flash: {:error, "that client is no longer there"}}

      client ->
        case write_field(client, field, buffer) do
          {:ok, updated} ->
            %{refresh(%{model | editing: nil, buffer: ""}) | flash: saved_flash(field, updated)}

          {:error, reason} ->
            %{model | flash: {:error, error_message(field, reason)}}
        end
    end
  end

  # Alert settings validate against their own rules — a sentiment
  # threshold outside -1.0..1.0 is always-on or never-on — so they go
  # through the door that reports why rather than the one that coerces.
  defp write_field(client, field, buffer) when field in @alert_fields do
    Clients.put_alert_setting(client.id, field, buffer)
  end

  defp write_field(client, field, buffer) do
    Clients.update(client.id, %{field => buffer})
  end

  @doc """
  Asks to remove the highlighted client, or carries it out if the same
  key is pressed twice.

  Removing takes the client's mentions with it, so it needs two presses
  rather than one.
  """
  @spec request_remove(t()) :: t()
  def request_remove(%__MODULE__{read_only: true} = model), do: refuse(model)

  def request_remove(%__MODULE__{} = model) do
    case highlighted_client(model) do
      nil ->
        model

      client ->
        %{
          model
          | confirm_remove: client.id,
            flash:
              {:warning,
               "remove #{client.name} and everything collected for it? press d again to confirm"}
        }
    end
  end

  @doc "Carries out a removal that has been confirmed."
  @spec confirm_remove(t()) :: t()
  def confirm_remove(%__MODULE__{read_only: true} = model), do: refuse(model)

  def confirm_remove(%__MODULE__{confirm_remove: nil} = model), do: model

  def confirm_remove(%__MODULE__{confirm_remove: id} = model) do
    name = with %Client{name: name} <- Enum.find(model.clients, &(&1.id == id)), do: name

    case Clients.remove(id) do
      {:ok, deleted} ->
        model = refresh(%{model | confirm_remove: nil, selected_client: 0})
        %{model | flash: {:ok, "removed #{name} and #{deleted} mention(s)"}}

      {:error, _reason} ->
        %{model | confirm_remove: nil, flash: {:error, "could not remove that client"}}
    end
  end

  @doc "Abandons a pending removal."
  @spec cancel_remove(t()) :: t()
  def cancel_remove(%__MODULE__{} = model) do
    %{model | confirm_remove: nil, flash: {:info, "not removed"}}
  end

  @doc "Pauses or resumes the highlighted client. Paused clients aren't polled."
  @spec toggle_active(t()) :: t()
  def toggle_active(%__MODULE__{read_only: true} = model), do: refuse(model)

  def toggle_active(%__MODULE__{} = model) do
    case highlighted_client(model) do
      nil ->
        model

      client ->
        case Clients.set_active(client.id, not client.active) do
          {:ok, updated} ->
            verb = if updated.active, do: "resumed", else: "paused"
            %{refresh(model) | flash: {:ok, "#{updated.name} #{verb}"}}

          {:error, _reason} ->
            %{model | flash: {:error, "could not change that client"}}
        end
    end
  end

  @doc "Switches the dashboard to the highlighted client."
  @spec view_highlighted(t()) :: t()
  def view_highlighted(%__MODULE__{} = model) do
    case highlighted_client(model) do
      nil -> model
      client -> %{select_client(model, client.id) | flash: {:ok, "viewing #{client.name}"}}
    end
  end

  @doc "The current value of a client's field, as the text shown."
  @spec field_value(Client.t() | nil, atom()) :: String.t()
  def field_value(nil, _field), do: ""
  def field_value(%Client{name: name}, :name), do: name
  def field_value(%Client{keywords: keywords}, :keywords), do: Enum.join(keywords, ", ")
  def field_value(%Client{subreddits: subreddits}, :subreddits), do: Enum.join(subreddits, ", ")

  def field_value(%Client{} = client, field) when field in @alert_fields do
    alert_value(client.alerts || AlertConfig.new(), field)
  end

  def field_value(%Client{}, _field), do: ""

  defp alert_value(%AlertConfig{} = config, :watch_phrases) do
    Enum.join(config.watch_phrases, ", ")
  end

  defp alert_value(%AlertConfig{} = config, :sentiment_threshold) do
    :erlang.float_to_binary(config.sentiment_threshold, decimals: 2)
  end

  defp alert_value(%AlertConfig{} = config, :volume_multiple) do
    :erlang.float_to_binary(config.volume_multiple, decimals: 1)
  end

  defp alert_value(%AlertConfig{} = config, :webhook_url), do: config.webhook_url || ""

  @doc "Human label for a client field."
  @spec label(atom()) :: String.t()
  def label(:watch_phrases), do: "alert phrases"
  def label(:sentiment_threshold), do: "alert if sentiment"
  def label(:volume_multiple), do: "alert if volume"
  def label(:webhook_url), do: "slack webhook"
  def label(:name), do: "name"
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

  defp error_message(:keywords, :no_keywords),
    do: "at least one brand term is needed — nothing would be monitored"

  defp error_message(:sentiment_threshold, :out_of_range),
    do: "sentiment runs from -1.00 to 1.00, so a threshold outside that never changes anything"

  defp error_message(:volume_multiple, :out_of_range),
    do: "a multiple of 1x or less would alert on every ordinary hour"

  defp error_message(field, :not_a_number), do: "#{label(field)} needs a number"

  defp error_message(:webhook_url, :invalid_webhook_url),
    do: "a Slack webhook URL starts with https:// — leave it empty to use the global one"

  defp error_message(:name, :missing_name), do: "a client needs a name"
  defp error_message(:name, :name_too_long), do: "that name is too long to fit the dashboard"
  defp error_message(field, reason), do: "could not save #{label(field)}: #{inspect(reason)}"

  @doc """
  The alert to show in the banner, or `nil` when all is quiet.

  Only alerts still inside their window are shown: a spike from this
  morning shouldn't sit at the top of the screen all afternoon.
  """
  @spec active_alert(t()) :: SmmMonitor.Alerts.Alert.t() | nil
  def active_alert(%__MODULE__{alerts: []}), do: nil

  def active_alert(%__MODULE__{alerts: [latest | _rest], updated_at: now}) do
    if fresh?(latest, now || DateTime.utc_now()), do: latest, else: nil
  end

  defp fresh?(alert, now), do: DateTime.diff(now, alert.at, :millisecond) < alert.window_ms

  # Alerting may be switched off, in which case there is simply nothing
  # to show rather than an error to handle.
  defp read_alerts(client) do
    Alerts.recent(SmmMonitor.Alerts, 10, client)
  catch
    :exit, _reason -> []
  end

  # The dashboard reads through the same public API as everything else. A
  # Clients process that isn't running (a test rendering the model in
  # isolation) shows an empty list rather than crashing the dashboard.
  defp read_clients do
    Clients.list()
  catch
    :exit, _reason -> []
  end

  defp keywords_of(model) do
    case current_client(model) do
      nil -> []
      client -> client.keywords
    end
  end

  # The highlight has to stay on a row that exists after a client is
  # removed — by this session or another one.
  defp clamp_selection(%__MODULE__{clients: []} = model), do: %{model | selected_client: 0}

  defp clamp_selection(%__MODULE__{clients: clients} = model) do
    %{model | selected_client: model.selected_client |> max(0) |> min(length(clients) - 1)}
  end

  defp refuse(model) do
    %{
      model
      | flash: {:error, "read-only session — clients can only be changed from the host terminal"}
    }
  end

  defp saved_flash(:name, client) do
    {:ok, "renamed to #{client.name} — its history and id are unchanged"}
  end

  defp saved_flash(field, _client) when field in @alert_fields do
    {:ok, "#{label(field)} saved — alerting picks this up within a minute"}
  end

  defp saved_flash(field, _client) do
    {:ok, "#{label(field)} saved — fetchers pick this up on their next poll"}
  end

  defp add_error_message(:missing_name), do: "a client needs a name"
  defp add_error_message(:name_too_long), do: "that name is too long to fit the dashboard"
  defp add_error_message(:no_keywords), do: "a client needs at least one brand term"
  defp add_error_message(reason), do: "could not add that client (#{inspect(reason)})"

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
