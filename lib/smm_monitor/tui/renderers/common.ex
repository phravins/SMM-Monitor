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
      alias SmmMonitor.TUI.Model

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

      defp top_bar(model) do
        mode = if model.mock_mode, do: "MOCK DATA", else: "LIVE"
        brands = Enum.join(model.keywords, ", ")

        bar do
          label do
            text(content: " SMM MONITOR ", color: @accent, attributes: @bold)
            text(content: "· watching: #{brands} ")
            text(content: "· #{mode} ", color: mode_color(model.mock_mode))
            text(content: "· updated #{clock(model.updated_at)}", color: @muted)
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
            text(content: " select field · ")
            text(content: "e", color: @accent, attributes: @bold)
            text(content: "dit · ")
            text(content: "a", color: @accent, attributes: @bold)
            text(content: " back to mentions · ")
            text(content: "q", color: @accent, attributes: @bold)
            text(content: " quit · ")
            text(content: worker_summary(model), color: @muted)
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
            text(content: "onfig · ")
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
            Enum.map(model.tabs, fn tab ->
              selected? = tab == model.tab
              content = Model.tab_label(model, tab)

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

      # --- config screen --------------------------------------------------------

      defp config_panel(model) do
        panel(
          title: config_title(model),
          height: :fill,
          padding: 0
        ) do
          label(content: "")

          Enum.map(Model.config_fields(), &config_field(model, &1))

          label(content: "")

          label do
            text(content: "  PLATFORM MODE", color: @muted, attributes: @bold)
          end

          Enum.map(model.statuses, &platform_status_row/1)

          label(content: "")

          label do
            text(
              content: "  mock/live is set by environment variables and needs a restart",
              color: @muted
            )
          end

          # Remote viewers get told why editing does nothing, rather than
          # being left to discover it by pressing keys.
          label do
            if model.read_only do
              text(
                content: "  read-only session — config is editable from the host terminal only",
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

      # The selected row is marked with a caret and bold text, so the selection
      # is visible on a terminal without colour too.
      defp config_field(model, field) do
        selected? = model.selected_field == field
        editing? = model.editing == field

        label do
          text(
            content:
              "  #{if selected?, do: "›", else: " "} #{String.pad_trailing(Model.label(field), 14)}",
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
            text(content: field_display(model, field))
          end
        end
      end

      defp config_title(%Model{read_only: true}), do: "config · read-only from this session"

      defp config_title(_model), do: "config · edit and fetchers pick it up next poll"

      defp field_display(model, field) do
        case Model.field_value(model, field) do
          "" -> "(none — searching everywhere)"
          value -> value
        end
      end

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

            nil ->
              text(
                content: "  saved to #{model.config_path || "(unknown)"} #{source_note(model)}",
                color: @muted
              )
          end
        end
      end

      defp source_note(%Model{config_source: {:corrupt, _reason}}),
        do: "· previous file was unreadable and has been kept as .corrupt"

      defp source_note(%Model{config_source: :defaults}), do: "· not written yet, showing defaults"
      defp source_note(_model), do: ""

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
