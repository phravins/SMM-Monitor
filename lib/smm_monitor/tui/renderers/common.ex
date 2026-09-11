defmodule SmmMonitor.TUI.Renderers.Common do
  @moduledoc """
  The dashboard's drawing code, shared by the local and SSH renderers.

  Ratatouille and Garnish expose the same view DSL — the same element
  macros (`view`, `panel`, `label`, `text`, `table`, …) with the same
  attributes, and the same `color/1` and `attribute/1` constants. Garnish
  is a fork of Ratatouille adapted for SSH, which is why the two line up
  so exactly.

  So the layout is written once here and injected into both renderers,
  each of which imports its own library's modules. Duplicating ~300 lines
  of drawing code would have meant every future change to the dashboard
  being made twice, and the two copies drifting the first time someone
  forgot.

  What is *not* shared is `translate_event/1`: the two libraries report
  keys differently (termbox integer constants versus terminfo mnemonics),
  so each renderer maps its own.

  ## Usage

      use SmmMonitor.TUI.Renderers.Common,
        view: Garnish.View,
        constants: Garnish.Constants

  Everything here is presentation; the numbers, slicing and scroll bounds
  all come from `SmmMonitor.TUI.Model`.

  Layout:

      ┌ top bar ───────────────────────────────────────────┐
      │ SMM MONITOR · brand terms · MOCK/LIVE · updated at │
      ├ tabs ──────────────────────────────────────────────┤
      │ [ all (72) ] twitter (18) instagram (18) ...       │
      ├ summary ───────────────────────────────────────────┤
      │ mentions: 72   sentiment: ███████░░░░▓▓▓  +17      │
      ├ recent mentions ───────────────────────────────────┤
      │ PLATFORM  AUTHOR      MENTION           SENT   AGE │
      ├ bottom bar ────────────────────────────────────────┤
      │ a/t/i/r/y tabs · j/k scroll · q quit · reddit ok…  │
      └────────────────────────────────────────────────────┘
  """

  defmacro __using__(opts) do
    view_module = Keyword.fetch!(opts, :view)
    constants_module = Keyword.fetch!(opts, :constants)

    quote do
      import unquote(view_module)
      import unquote(constants_module), only: [color: 1, attribute: 1]

      alias SmmMonitor.Mention
      alias SmmMonitor.Processing.Sentiment
      alias SmmMonitor.Trends
      alias SmmMonitor.TUI.{Chart, Model, Setup}

      # Wide enough for the longest field label ("alert if sentiment"),
      # so no value starts flush against its own name.
      @label_width 20

      @bar_width 30
      # Odd, so the gauge has a true centre column for the zero marker.
      @gauge_width 25
      @text_width 68

      @positive color(:green)
      @negative color(:red)
      @neutral color(:white)
      @muted color(:cyan)
      @accent color(:yellow)
      # Style attributes are passed as a list, even when there is only one.
      @bold [attribute(:bold)]

      @impl true
      def render(%Model{setup: %Setup{} = setup} = model) do
        view(top_bar: setup_top_bar(), bottom_bar: setup_bottom_bar(setup)) do
          row do
            column(size: 12) do
              setup_panel(model, setup)
            end
          end
        end
      end

      def render(%Model{tab: :config} = model) do
        view(top_bar: top_bar(model), bottom_bar: bottom_bar(model)) do
          row do
            column(size: 12) do
              alert_banner(model)
              tab_bar(model)
              config_panel(model)
            end
          end
        end
      end

      def render(%Model{tab: :trends} = model) do
        view(top_bar: top_bar(model), bottom_bar: bottom_bar(model)) do
          row do
            column(size: 12) do
              alert_banner(model)
              tab_bar(model)
              trends_panel(model)
            end
          end
        end
      end

      def render(%Model{} = model) do
        view(top_bar: top_bar(model), bottom_bar: bottom_bar(model)) do
          row do
            column(size: 12) do
              alert_banner(model)
              tab_bar(model)
              summary(model)
              mentions_table(model)
            end
          end
        end
      end

      # Only drawn when something is actually wrong: a permanent "all
      # clear" strip would train people to ignore the space it occupies.
      defp alert_banner(model) do
        case Model.active_alert(model) do
          nil ->
            label(content: "")

          alert ->
            panel(height: 3, padding: 0, color: alert_colour(alert)) do
              label do
                text(content: "  ", color: alert_colour(alert))
                text(content: alert_label(alert), color: alert_colour(alert), attributes: @bold)
                text(content: "  " <> SmmMonitor.Alerts.Alert.message(alert), color: @neutral)
              end
            end
        end
      end

      defp alert_label(%{severity: :critical}), do: "!! NEGATIVE SPIKE"
      defp alert_label(_alert), do: "!  NEGATIVE SPIKE"

      defp alert_colour(%{severity: :critical}), do: @negative
      defp alert_colour(_alert), do: @accent

      # --- chrome ---------------------------------------------------------------

      # The client comes first and in the accent colour: with several
      # clients on one dashboard, "whose numbers am I looking at?" is the
      # question the header has to answer before any other.
      defp top_bar(model) do
        mode = if model.mock_mode, do: "MOCK DATA", else: "LIVE"
        {position, total} = Model.client_position(model)

        bar do
          label do
            text(content: " SMM MONITOR ", color: @accent, attributes: @bold)
            text(content: "· ", color: @muted)
            text(content: client_name(model), color: @accent, attributes: @bold)
            text(content: " #{position}/#{total} ", color: @muted)
            text(content: "[", color: @muted)
            text(content: "[/]", color: @accent, attributes: @bold)
            text(content: "] ", color: @muted)
            text(content: "· #{brands(model)} ", color: @muted)
            text(content: "· #{mode} ", color: mode_color(model.mock_mode))
            text(content: "· updated #{clock(model.updated_at)}", color: @muted)
          end
        end
      end

      defp client_name(model) do
        case Model.current_client(model) do
          nil -> "no client"
          client -> SmmMonitor.Client.label(client)
        end
      end

      defp brands(model) do
        case Enum.join(model.keywords, ", ") do
          "" -> "no brand terms"
          brands -> truncate(brands, 40)
        end
      end

      defp bottom_bar(%Model{editing: :new_client}) do
        bar do
          label do
            text(content: " new client — ", color: @accent, attributes: @bold)
            text(content: "Enter", color: @accent, attributes: @bold)
            text(content: " add · ")
            text(content: "Esc", color: @accent, attributes: @bold)
            text(content: " cancel · the name doubles as the first brand term")
          end
        end
      end

      defp bottom_bar(%Model{editing: field}) when not is_nil(field) do
        bar do
          label do
            text(content: " editing #{Model.label(field)} — ", color: @accent, attributes: @bold)
            text(content: "Enter", color: @accent, attributes: @bold)
            text(content: " save · ")
            text(content: "Esc", color: @accent, attributes: @bold)
            text(content: " cancel · separate multiple values with commas")
          end
        end
      end

      defp bottom_bar(%Model{tab: :config} = model) do
        bar do
          label do
            text(content: " j/k", color: @accent, attributes: @bold)
            text(content: " client · ")
            text(content: "h/l", color: @accent, attributes: @bold)
            text(content: " field · ")
            text(content: "e", color: @accent, attributes: @bold)
            text(content: "dit · ")
            text(content: "+", color: @accent, attributes: @bold)
            text(content: " add · ")
            text(content: "d", color: @accent, attributes: @bold)
            text(content: " remove · ")
            text(content: "p", color: @accent, attributes: @bold)
            text(content: " pause · ")
            text(content: "s", color: @accent, attributes: @bold)
            text(content: " view · ")
            text(content: "a", color: @accent, attributes: @bold)
            text(content: " back · ")
            text(content: "q", color: @accent, attributes: @bold)
            text(content: " quit")
          end
        end
      end

      defp bottom_bar(%Model{tab: :trends} = model) do
        bar do
          label do
            text(content: " w", color: @accent, attributes: @bold)
            text(content: " window (#{Enum.join(Trends.windows(), "/")}d) · ")
            text(content: "[/]", color: @accent, attributes: @bold)
            text(content: " client · ")
            text(content: "R", color: @accent, attributes: @bold)
            text(content: "eport · ")
            text(content: "a", color: @accent, attributes: @bold)
            text(content: " back · ")
            text(content: "q", color: @accent, attributes: @bold)
            text(content: " quit · ")
            text(content: "from #{Model.trend_source(model)}", color: @muted)
          end
        end
      end

      defp bottom_bar(model) do
        bar do
          label do
            text(content: " a", color: @accent, attributes: @bold)
            text(content: "ll ")
            text(content: "t", color: @accent, attributes: @bold)
            text(content: "witter ")
            text(content: "i", color: @accent, attributes: @bold)
            text(content: "nstagram ")
            text(content: "r", color: @accent, attributes: @bold)
            text(content: "eddit ")
            text(content: "y", color: @accent, attributes: @bold)
            text(content: "outube · ")
            text(content: "c", color: @accent, attributes: @bold)
            text(content: "lients · ")
            text(content: "h", color: @accent, attributes: @bold)
            text(content: "istory · ")
            text(content: "[/]", color: @accent, attributes: @bold)
            text(content: " client · ")
            text(content: "R", color: @accent, attributes: @bold)
            text(content: "eport · ")
            text(content: "j/k", color: @accent, attributes: @bold)
            text(content: " scroll · ")
            text(content: "q", color: @accent, attributes: @bold)
            text(content: " quit · ")
            text(content: worker_summary(model), color: @muted)
          end
        end
      end

      # The active tab is bracketed and bold — the same cue works on terminals
      # without colour.
      defp tab_bar(model) do
        panel(height: 3, padding: 0) do
          label do
            Enum.map(Model.tab_labels(model), fn {tab, content} ->
              selected? = tab == model.tab

              if selected? do
                text(content: " [#{content}] ", color: @accent, attributes: @bold)
              else
                text(content: "  #{content}  ", color: @muted)
              end
            end)
          end
        end
      end

      defp summary(model) do
        stats = model.stats
        percentages = Model.sentiment_percentages(model)
        {positive_cols, neutral_cols, negative_cols} = Model.sentiment_bar(model, @bar_width)
        average = Model.average_sentiment(model)

        {gauge_left_pad, gauge_negative, gauge_positive, gauge_right_pad} =
          Model.sentiment_gauge(model, @gauge_width)

        panel(
          title: "last #{window_label(model.window_ms)} · #{model.tab}",
          height: 6,
          padding: 0
        ) do
          label do
            text(content: "mentions: ", color: @muted)
            text(content: "#{stats.count}", attributes: @bold)
            text(content: "   avg sentiment: ", color: @muted)

            text(
              content: signed(average),
              color: sentiment_color(Model.average_label(model)),
              attributes: @bold
            )

            text(content: " #{Model.average_label(model)}", color: @muted)
          end

          # The mean score as a meter that grows out from a fixed centre,
          # so which side is lit answers "how are people feeling?" before
          # the number is read at all.
          label do
            text(content: "-1 ", color: @muted)
            text(content: String.duplicate("·", gauge_left_pad), color: @muted)
            text(content: String.duplicate("█", gauge_negative), color: @negative)
            text(content: "│", color: @muted)
            text(content: String.duplicate("█", gauge_positive), color: @positive)
            text(content: String.duplicate("·", gauge_right_pad), color: @muted)
            text(content: " +1", color: @muted)
          end

          label do
            text(content: String.duplicate("█", positive_cols), color: @positive)
            text(content: String.duplicate("▒", neutral_cols), color: @neutral)
            text(content: String.duplicate("█", negative_cols), color: @negative)
            text(content: empty_bar(positive_cols + neutral_cols + negative_cols), color: @muted)
          end

          label do
            text(
              content: "  positive #{percentages.positive}% (#{stats.positive})",
              color: @positive
            )

            text(content: "   neutral #{percentages.neutral}% (#{stats.neutral})", color: @neutral)

            text(
              content: "   negative #{percentages.negative}% (#{stats.negative})",
              color: @negative
            )
          end
        end
      end

      # --- the first-run wizard ---------------------------------------------------

      defp setup_top_bar do
        bar do
          label do
            text(content: " SMM MONITOR ", color: @accent, attributes: @bold)
            text(content: "· first-run setup", color: @muted)
          end
        end
      end

      defp setup_bottom_bar(setup) do
        bar do
          label do
            text(content: " #{Setup.hint(setup)}", color: @muted)
          end
        end
      end

      defp setup_panel(model, setup) do
        {step, total} = Setup.position(setup)

        panel(title: "setup · step #{step} of #{total}", height: :fill, padding: 1) do
          [
            label(content: ""),
            label do
              text(content: Setup.title(setup), color: @accent, attributes: @bold)
            end,
            label(content: ""),
            Enum.map(Setup.description(setup), &label(content: "  " <> &1)),
            setup_body(model, setup),
            setup_error(setup)
          ]
        end
      end

      defp setup_body(model, %Setup{step: :review} = setup) do
        [
          label(content: ""),
          Enum.map(Setup.summary(setup), &summary_line/1),
          label(content: ""),
          label do
            text(content: "  Your answers are saved to ", color: @muted)
            text(content: Model.settings_path(model), color: @muted, attributes: @bold)
          end
        ]
      end

      defp setup_body(_model, setup) do
        [
          label(content: ""),
          label do
            text(content: "  #{Setup.label(setup)}", color: @muted)
          end,
          label do
            text(content: "  > ", color: @accent, attributes: @bold)
            text(content: Setup.value(setup), attributes: @bold)
            # A block for a cursor: termbox gives us no real one inside a
            # panel, and an empty field should still look like a field.
            text(content: "█", color: @accent)
          end
        ]
      end

      # The demo-data warning is the one line on this screen that must
      # not be skimmed past, so it gets the colour everything else on the
      # screen doesn't.
      defp summary_line("No API keys, so every mention you see will be DEMO DATA —" = line) do
        label do
          text(content: "  " <> line, color: @accent, attributes: @bold)
        end
      end

      defp summary_line(line), do: label(content: "  " <> line)

      defp setup_error(%Setup{error: nil}), do: label(content: "")

      defp setup_error(%Setup{error: message}) do
        [
          label(content: ""),
          label do
            text(content: "  ! ", color: @negative, attributes: @bold)
            text(content: message, color: @negative)
          end
        ]
      end

      # --- trends screen: the last N days ---------------------------------------

      defp trends_panel(model) do
        trends = model.trends
        {volume_height, sentiment_height} = Model.trend_chart_heights(model)
        width = Model.trend_column_width(model)
        days = Model.trend_days(model)

        panel(
          title: "#{Model.trend_window_label(model)} · #{client_name(model)}",
          height: :fill,
          padding: 0
        ) do
          [
            trends_headline(trends),
            label(content: ""),
            chart_heading("mentions per day", volume_note(model, trends)),
            Enum.map(Chart.volume(days, height: volume_height, width: width), &chart_line/1),
            label(content: ""),
            chart_heading("average sentiment per day", sentiment_note(trends)),
            Enum.map(
              Chart.sentiment(days, height: sentiment_height, width: width),
              &chart_line/1
            )
          ]
        end
      end

      # The one line that has to be right even if nobody reads the charts.
      defp trends_headline(%Trends{client_id: nil}) do
        label(content: "  no client selected — add one on the clients screen (c)")
      end

      defp trends_headline(%Trends{total: 0} = trends) do
        label do
          text(content: "  nothing collected for this client ", color: @muted)
          text(content: "in the last #{trends.window_days} days", color: @muted)
        end
      end

      defp trends_headline(trends) do
        label do
          text(content: "  #{trends.total}", attributes: @bold)
          text(content: " mentions · ", color: @muted)
          text(content: "#{Trends.per_day(trends)}", attributes: @bold)
          text(content: " a day · ", color: @muted)
          text(content: "#{Trends.active_days(trends)}/#{trends.window_days}", attributes: @bold)
          text(content: " days with mentions · ", color: @muted)
          text(content: "avg ", color: @muted)

          text(
            content: signed(trends.average),
            color: sentiment_color(Sentiment.label(trends.average)),
            attributes: @bold
          )
        end
      end

      defp chart_heading(title, note) do
        label do
          text(content: "  #{title}", color: @muted, attributes: @bold)
          text(content: "   #{note}", color: @muted)
        end
      end

      # The narrower note goes first: on the terminal that needs it, the
      # end of the line is the part that gets clipped away.
      defp volume_note(model, trends) do
        [narrow_note(model), busiest_note(trends)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" · ")
      end

      defp busiest_note(%Trends{busiest: nil}), do: ""

      defp busiest_note(%Trends{busiest: day}) do
        "busiest #{day_label(day.date)} · #{day.count} mention(s)"
      end

      # Better to say the oldest days were left off than to let the
      # renderer clip the right-hand end, which is where this week is.
      defp narrow_note(model) do
        case Model.trend_days_dropped(model) do
          0 -> ""
          dropped -> "#{dropped} older day(s) need a wider terminal"
        end
      end

      defp sentiment_note(%Trends{best: nil}), do: ""

      # A week where every day scored the same would otherwise read
      # "best Wed · worst Wed", which is true and useless.
      defp sentiment_note(%Trends{best: %{average: same}, worst: %{average: same}}) do
        "flat at #{signed(same)} every day"
      end

      defp sentiment_note(%Trends{best: best, worst: worst}) do
        "best #{day_label(best.date)} #{signed(best.average)} · " <>
          "worst #{day_label(worst.date)} #{signed(worst.average)}"
      end

      defp chart_line(row) do
        label do
          text(content: row.label, color: @muted)
          text(content: row.bars, color: chart_color(row.style))
        end
      end

      # Volume is one measure in one colour; sentiment is two, because
      # which side of the zero line a day sits on is the whole point.
      defp chart_color(:volume), do: @accent
      defp chart_color(:positive), do: @positive
      defp chart_color(:negative), do: @negative
      defp chart_color(_axis), do: @muted

      defp day_label(date), do: Calendar.strftime(date, "%a %-d %b")

      # --- config screen: the client list ---------------------------------------

      defp config_panel(model) do
        panel(title: config_title(model), height: :fill, padding: 0) do
          label(content: "")

          label do
            text(content: "  CLIENTS", color: @muted, attributes: @bold)

            text(
              content: "   #{length(model.clients)} configured",
              color: @muted
            )
          end

          label(content: "")

          if model.clients == [] do
            [
              label do
                text(content: "  no clients yet — press ", color: @muted)
                text(content: "+", color: @accent, attributes: @bold)
                text(content: " to add one", color: @muted)
              end
            ]
          else
            Enum.with_index(model.clients, &client_block(model, &1, &2))
          end

          label(content: "")
          adding_row(model)

          label do
            text(content: "  PLATFORM MODE", color: @muted, attributes: @bold)
          end

          Enum.map(model.statuses, &platform_status_row/1)

          label(content: "")

          # This used to say mock/live was an environment variable needing
          # a restart. That stopped being true for half the platforms
          # when the wizard learned to store keys: those go live on the
          # next poll. Saying otherwise sends somebody off to edit a
          # shell profile for no reason, on the one screen where they
          # came to fix exactly this.
          label do
            text(content: "  reddit, youtube: press ", color: @muted)
            text(content: "S", color: @accent, attributes: @bold)
            text(content: " to add keys — live on the next poll", color: @muted)
          end

          label do
            text(
              content: "  twitter, instagram: set their env vars, then restart",
              color: @muted
            )
          end

          # Remote viewers get told why editing does nothing, rather than
          # being left to discover it by pressing keys.
          label do
            if model.read_only do
              text(
                content: "  read-only session — clients are editable from the host terminal only",
                color: @accent
              )
            else
              text(content: "", color: @muted)
            end
          end

          label(content: "")
          config_footer(model)
        end
      end

      # One block per client: a header row carrying its number and state,
      # then a row per editable field — but only for the client being
      # edited. Seven fields times five clients is a screen nobody can
      # read, so the rest collapse to a one-line summary and expand when
      # you move onto them.
      defp client_block(model, client, index) do
        highlighted? = model.selected_client == index and model.editing != :new_client
        viewing? = model.client_id == client.id

        header =
          label do
            [
              text(
                content: "  #{if highlighted?, do: "▸", else: " "} #{index + 1}. ",
                color: if(highlighted?, do: @accent, else: @muted),
                attributes: if(highlighted?, do: @bold, else: [])
              ),
              text(
                content: client.name,
                color: client_color(client),
                attributes: @bold
              ),
              text(content: "  (#{client.id})", color: @muted)
            ] ++ client_badges(client, viewing?, model)
          end

        if highlighted? do
          [header] ++ Enum.map(Model.config_fields(), &client_field(model, client, index, &1))
        else
          [header, collapsed_summary(client)]
        end
      end

      # What a collapsed client is worth saying in one line: what it
      # watches, and whether anything would wake you about it.
      defp collapsed_summary(client) do
        label do
          [
            text(content: "        ", color: @muted),
            text(content: truncate(Enum.join(client.keywords, ", "), 44), color: @muted),
            text(content: "   ", color: @muted)
          ] ++ alert_summary(client)
        end
      end

      defp alert_summary(%{alerts: nil}), do: [text(content: "")]

      defp alert_summary(%{alerts: alerts}) do
        cond do
          not alerts.enabled ->
            [text(content: "alerts off", color: @neutral)]

          alerts.watch_phrases != [] ->
            [
              text(content: "alerts on", color: @positive),
              text(
                content: " · #{length(alerts.watch_phrases)} phrase(s)",
                color: @muted
              )
            ]

          true ->
            [text(content: "alerts on", color: @positive)]
        end
      end

      defp client_badges(client, viewing?, model) do
        [
          if(viewing?, do: text(content: "  ● viewing", color: @accent), else: text(content: "")),
          if(client.active,
            do: text(content: ""),
            else: text(content: "  ‖ paused — not polled", color: @neutral)
          ),
          if(model.confirm_remove == client.id,
            do: text(content: "  press d again to remove", color: @negative, attributes: @bold),
            else: text(content: "")
          )
        ]
      end

      defp client_field(model, client, index, field) do
        selected? =
          model.selected_client == index and model.selected_field == field and
            model.editing != :new_client

        editing? = selected? and model.editing == field

        label do
          text(
            content:
              "      #{if selected?, do: "›", else: " "} " <>
                String.pad_trailing(Model.label(field), @label_width),
            color: if(selected?, do: @accent, else: @muted),
            attributes: if(selected?, do: @bold, else: [])
          )

          if editing? do
            # A list, not two statements: an `if` block returns only its last
            # expression, which would render the cursor and drop the text.
            # The block cursor is drawn by hand — termbox's own cursor isn't
            # positioned for us here.
            [
              text(content: model.buffer, attributes: @bold),
              text(content: "█", color: @accent)
            ]
          else
            text(content: field_display(client, field), color: field_color(field))
          end
        end
      end

      # The new-client editor is a row of its own rather than a modal:
      # the list stays visible, so it is obvious what is being added to.
      defp adding_row(%Model{editing: :new_client} = model) do
        [
          label do
            [
              text(content: "  + name  ", color: @accent, attributes: @bold),
              text(content: model.buffer, attributes: @bold),
              text(content: "█", color: @accent),
              text(content: "   (enter to add, esc to cancel)", color: @muted)
            ]
          end,
          label(content: "")
        ]
      end

      defp adding_row(_model), do: [label(content: "")]

      defp client_color(%{active: true}), do: @positive
      defp client_color(_client), do: @neutral

      defp config_title(%Model{read_only: true}), do: "clients · read-only from this session"

      defp config_title(_model), do: "clients · changes are picked up on the next poll"

      # A bare "-0.30" says nothing about which direction trips it.
      defp field_display(client, :sentiment_threshold = field) do
        "at or below #{Model.field_value(client, field)}"
      end

      defp field_display(client, :volume_multiple = field) do
        "at or above #{Model.field_value(client, field)}x the usual for this hour"
      end

      defp field_display(client, field) do
        case Model.field_value(client, field) do
          "" -> field_placeholder(field)
          value -> value
        end
      end

      # The thresholds read as explanation rather than as data, so they
      # sit back a shade from the values you actually type.
      defp field_color(field) when field in [:sentiment_threshold, :volume_multiple], do: @muted
      defp field_color(_field), do: @neutral

      defp field_placeholder(:subreddits), do: "(none — searching all of Reddit)"
      defp field_placeholder(:keywords), do: "(none — nothing will be found)"
      defp field_placeholder(:watch_phrases), do: "(none — no phrase alerts)"
      defp field_placeholder(:webhook_url), do: "(using the global webhook)"
      defp field_placeholder(_field), do: "(none)"

      defp platform_status_row(status) do
        label do
          text(content: "    #{String.pad_trailing(to_string(status.platform), 14)}", color: @muted)
          text(content: worker_state(status), color: mode_colour(status))
        end
      end

      defp mode_colour(%{mode: :live}), do: @positive
      defp mode_colour(%{mode: :down}), do: @negative
      defp mode_colour(_status), do: @accent

      defp config_footer(model) do
        label do
          case model.flash do
            {:ok, message} ->
              text(content: "  ✓ #{message}", color: @positive)

            {:error, message} ->
              text(content: "  ✗ #{message}", color: @negative)

            {:info, message} ->
              text(content: "  #{message}", color: @muted)

            {:warning, message} ->
              text(content: "  ! #{message}", color: @negative, attributes: @bold)

            nil ->
              text(content: "  #{config_help()}", color: @muted)
          end
        end
      end

      # The screen has more verbs than the rest of the dashboard, so they
      # are listed rather than left to be discovered — `S` included. It
      # was bound and unlisted, which is the same as not existing for
      # anybody who hasn't read the README.
      defp config_help do
        "j/k client · h/l field · e edit · + add · d remove · p pause · s view · S keys"
      end

      defp mentions_table(model) do
        panel(title: mentions_title(model), height: :fill, padding: 0) do
          table do
            table_row(attributes: @bold) do
              table_cell(content: "PLATFORM")
              table_cell(content: "AUTHOR")
              table_cell(content: "MENTION")
              table_cell(content: "SENTIMENT")
              table_cell(content: "AGE")
            end

            Enum.map(Model.visible_mentions(model), &mention_row(&1, model.updated_at))
          end
        end
      end

      defp mention_row(%Mention{} = mention, now) do
        table_row(color: sentiment_color(mention.sentiment)) do
          table_cell(content: to_string(mention.platform))
          table_cell(content: truncate(mention.author, 18))
          table_cell(content: truncate(one_line(mention.text), @text_width))

          table_cell(content: sentiment_label(mention))

          table_cell(content: Mention.time_ago(mention, now || DateTime.utc_now()))
        end
      end

      # --- helpers --------------------------------------------------------------

      defp mentions_title(model) do
        total = length(model.mentions)

        position =
          if Model.scrollable?(model) do
            first = min(model.offset + 1, total)
            " #{first}-#{min(model.offset + model.rows, total)} of #{total}"
          else
            " #{total}"
          end

        "recent mentions ·#{position}"
      end

      defp worker_summary(model) do
        model.statuses
        |> Enum.map_join(" ", fn status ->
          "#{status.platform}:#{worker_state(status)}"
        end)
      end

      defp worker_state(%{mode: :down}), do: "restarting"
      defp worker_state(%{last_error: error}) when not is_nil(error), do: "error"
      defp worker_state(%{mode: mode}), do: to_string(mode)

      defp mode_color(true), do: @accent
      defp mode_color(false), do: @positive

      defp sentiment_color(:positive), do: @positive
      defp sentiment_color(:negative), do: @negative
      defp sentiment_color(:neutral), do: @neutral

      # Direction plus magnitude, rather than a sign glyph next to a signed
      # number ("- -0.5" is a lot harder to scan than "▼ 0.50"). The
      # magnitude is the normalised score, so a mention's strength can be
      # compared against the column average directly above it.
      defp sentiment_label(%Mention{sentiment: :neutral}), do: "•  0.00"

      defp sentiment_label(%Mention{sentiment: :positive, sentiment_value: value}),
        do: "▲ #{magnitude(value)}"

      defp sentiment_label(%Mention{sentiment: :negative, sentiment_value: value}),
        do: "▼ #{magnitude(value)}"

      defp magnitude(value), do: value |> abs() |> two_places()

      defp signed(score) when score > 0, do: "+" <> two_places(score)
      defp signed(score), do: two_places(score)

      defp two_places(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 2)
      # Integers reach here from mention rows written before scoring
      # became numeric.
      defp two_places(score), do: two_places(score / 1)

      defp empty_bar(filled) when filled >= @bar_width, do: ""
      defp empty_bar(filled), do: String.duplicate("·", @bar_width - filled)

      # Newlines in a table cell would break the row layout.
      defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

      defp truncate(text, max) when byte_size(text) <= max, do: text
      defp truncate(text, max), do: String.slice(text, 0, max - 1) <> "…"

      defp clock(nil), do: "—"
      defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M:%S")

      defp window_label(nil), do: "24h"

      defp window_label(ms) do
        cond do
          ms >= :timer.hours(24) -> "#{div(ms, :timer.hours(24))}d"
          ms >= :timer.hours(1) -> "#{div(ms, :timer.hours(1))}h"
          true -> "#{div(ms, :timer.minutes(1))}m"
        end
      end
    end
  end
end
