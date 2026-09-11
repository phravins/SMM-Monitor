# -*- coding: utf-8 -*-
"""
Renders an SMM Monitor client report as a branded PDF.

Reads a JSON payload (written by SmmMonitor.Reports.PDF) and writes a PDF
in the OSWORKS house style -- see osworks_pdf_lib.py, vendored from the
OSWORKS PDF style skill.

    python3 render_report.py <payload.json> <output.pdf>

Kept deliberately dumb: every number in here was computed in Elixir and
is printed as given. Arithmetic in two languages is arithmetic that
eventually disagrees, and the client is the one who finds out.
"""

import json
import sys
import unicodedata

from osworks_pdf_lib import (
    BLACK, CHARCOAL, CREAM, GRAY_META, GRAY_TEXT, LINE, MARGIN, ORANGE,
    PAGE_W, PALE_AMBER, PALE_GREEN, PALE_RED,
    A4, BrandedCanvas, KeepTogether, PageBreak, Paragraph, Spacer,
    SimpleDocTemplate, Table, TableStyle, callout, colors, data_table, hr,
    meta_table, mm, section_heading, set_brand, styles, sub_heading,
)
from reportlab.graphics.shapes import Drawing, Line, PolyLine, Rect, String

# --- text safety -----------------------------------------------------------

# ReportLab's base-14 fonts are WinAnsi (CP1252) encoded, so anything
# outside that renders as a black box. Social copy is full of emoji and
# non-Latin scripts, so text is folded to what the fonts can actually
# draw before it reaches a Paragraph.
#
# CP1252 *does* include em dashes, en dashes, smart quotes, bullets and
# ellipses, so those are kept rather than downgraded -- "--" in the
# middle of a sentence looks like a typo in a document going to a client.
_REPLACEMENTS = {"\u00a0": " ", "\u2192": "->", "\u2190": "<-"}


def safe_text(value):
    """Fold text to something the base-14 fonts can render, then escape it."""
    if value is None:
        return ""

    text = str(value)
    for bad, good in _REPLACEMENTS.items():
        text = text.replace(bad, good)

    out = []
    for char in text:
        try:
            char.encode("cp1252")
        except UnicodeEncodeError:
            # Not renderable as-is. Decompose accents to their base
            # letters where that works, and drop whatever is left --
            # emoji, CJK, symbols. Dropping beats a page of black boxes,
            # and the CSV export keeps the original text intact.
            folded = unicodedata.normalize("NFKD", char)
            out.append("".join(c for c in folded if ord(c) < 128))
        else:
            out.append(char)

    text = "".join(out)
    # Paragraph() parses inline markup, so the three XML specials have to
    # be escaped or a mention containing "<3" ends the document early.
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return " ".join(text.split())


# --- sentiment chart -------------------------------------------------------

CHART_W = PAGE_W - 2 * MARGIN
CHART_H = 46 * mm


def sentiment_chart(daily):
    """A small line chart of daily average sentiment across the period.

    Drawn by hand rather than with reportlab.graphics.charts: the axis
    here is fixed at -1..1 with a zero line, which is the whole point of
    the picture, and the stock line chart fights that.
    """
    drawing = Drawing(CHART_W, CHART_H)
    plot_left, plot_right = 26, CHART_W - 6
    plot_top, plot_bottom = CHART_H - 10, 20
    plot_h = plot_top - plot_bottom

    drawing.add(Rect(plot_left, plot_bottom, plot_right - plot_left, plot_h,
                     fillColor=colors.white, strokeColor=LINE, strokeWidth=0.5))

    def y_for(value):
        # -1.0 at the bottom, +1.0 at the top, 0 in the middle.
        return plot_bottom + (value + 1.0) / 2.0 * plot_h

    # Gridlines and labels at +1, 0, -1.
    for value, label in ((1.0, "+1"), (0.0, "0"), (-1.0, "-1")):
        y = y_for(value)
        width = 0.8 if value == 0 else 0.4
        colour = GRAY_META if value == 0 else LINE
        drawing.add(Line(plot_left, y, plot_right, y,
                         strokeColor=colour, strokeWidth=width))
        drawing.add(String(4, y - 3, label, fontName="Times-Roman",
                           fontSize=7.5, fillColor=GRAY_META))

    points = []
    step = (plot_right - plot_left) / max(len(daily) - 1, 1)
    for index, day in enumerate(daily):
        x = plot_left + index * step if len(daily) > 1 else (plot_left + plot_right) / 2
        points.extend([x, y_for(day["average"])])

    if len(daily) > 1:
        drawing.add(PolyLine(points, strokeColor=ORANGE, strokeWidth=1.6))

    # A dot per day, so a seven-point series doesn't read as a smooth curve.
    for index in range(0, len(points), 2):
        drawing.add(Rect(points[index] - 1.4, points[index + 1] - 1.4, 2.8, 2.8,
                         fillColor=ORANGE, strokeColor=ORANGE))

    # Date labels: first, middle and last only — seven dates fit, thirty don't.
    if daily:
        marks = {0, len(daily) - 1} if len(daily) < 4 else {0, len(daily) // 2, len(daily) - 1}
        for index in sorted(marks):
            x = plot_left + index * step if len(daily) > 1 else (plot_left + plot_right) / 2
            drawing.add(String(x, plot_bottom - 12, safe_text(daily[index]["label"]),
                               fontName="Times-Roman", fontSize=7.5,
                               fillColor=GRAY_META, textAnchor="middle"))

    return drawing


# --- document sections -----------------------------------------------------

def cover(story, data):
    period = data["period"]

    story.append(Spacer(1, 8 * mm))
    story.append(Paragraph(safe_text(data["brand"]), styles["BrandWordmark"]))
    story.append(Paragraph("Social Media Report", styles["CoverTitle"]))
    story.append(Paragraph(safe_text(data["client"]["name"]), styles["CoverSubtitle"]))
    story.append(hr())
    story.append(Paragraph(safe_text(period["human_range"]), styles["CoverContext"]))
    story.append(Paragraph(
        "Prepared by %s" % safe_text(data["brand"]), styles["CoverContext"]))
    story.append(Spacer(1, 14))
    story.append(callout("Summary", safe_text(data["headline"])))
    story.append(Spacer(1, 14))
    story.append(meta_table([
        ("Client", safe_text(data["client"]["name"])),
        ("Period", "%s (%s)" % (safe_text(period["human_range"]), safe_text(period["label"]))),
        ("Generated", safe_text(data["generated_at"])),
        ("Brand terms", safe_text(", ".join(data["client"]["keywords"]))),
    ]))
    story.append(PageBreak())


def summary_section(story, data):
    summary = data["summary"]

    story.append(section_heading("1. Summary"))
    story.append(Paragraph(safe_text(data["summary_prose"]), styles["Body"]))
    story.append(Spacer(1, 6))
    story.append(data_table(
        ["Measure", "This period", "Change"],
        [
            ["Total mentions", str(summary["total"]), safe_text(summary["volume_change"])],
            ["Average sentiment", safe_text(summary["average"]),
             safe_text(summary["sentiment_change"])],
            ["Positive", str(summary["positive"]), safe_text(summary["positive_share"])],
            ["Neutral", str(summary["neutral"]), safe_text(summary["neutral_share"])],
            ["Negative", str(summary["negative"]), safe_text(summary["negative_share"])],
        ],
        [58 * mm, 42 * mm, None],
    ))


def platform_section(story, data):
    story.append(section_heading("2. Mentions by platform"))

    rows = [[safe_text(row["platform"]), str(row["count"]), safe_text(row["share"])]
            for row in data["platforms"]]

    story.append(KeepTogether([
        data_table(["Platform", "Mentions", "Share"], rows, [58 * mm, 42 * mm, None]),
    ]))


def trend_section(story, data):
    story.append(section_heading("3. Sentiment trend"))
    story.append(Paragraph(safe_text(data["trend_prose"]), styles["Body"]))
    story.append(Spacer(1, 8))
    story.append(sentiment_chart(data["daily"]))
    story.append(Spacer(1, 10))

    rows = [[safe_text(day["label"]), str(day["count"]), safe_text(day["average_text"])]
            for day in data["daily"]]
    story.append(KeepTogether([
        sub_heading("3.1 Daily breakdown"),
        data_table(["Day", "Mentions", "Average sentiment"], rows, [58 * mm, 42 * mm, None]),
    ]))


def mentions_section(story, heading, intro, mentions, empty_note):
    story.append(section_heading(heading))

    if not mentions:
        story.append(Paragraph(safe_text(empty_note), styles["Body"]))
        return

    story.append(Paragraph(safe_text(intro), styles["Body"]))
    story.append(Spacer(1, 6))

    for mention in mentions:
        meta = "%s &nbsp;|&nbsp; %s &nbsp;|&nbsp; %s &nbsp;|&nbsp; sentiment %s" % (
            safe_text(mention["platform"]),
            safe_text(mention["author"]),
            safe_text(mention["when"]),
            safe_text(mention["sentiment"]),
        )
        block = Table(
            [[[Paragraph(meta, styles["CodeLabel"]),
               Spacer(1, 3),
               Paragraph(safe_text(mention["text"]), styles["Body"])]]],
            colWidths=[PAGE_W - 2 * MARGIN],
        )
        block.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), colors.white),
            ("BOX", (0, 0), (-1, -1), 0.5, LINE),
            ("LEFTPADDING", (0, 0), (-1, -1), 9),
            ("RIGHTPADDING", (0, 0), (-1, -1), 9),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ]))
        # Each mention is one atomic block: a quote split across a page
        # break reads as two different posts.
        story.append(KeepTogether([block, Spacer(1, 5)]))


def alerts_section(story, data):
    story.append(section_heading("6. Alerts raised"))
    alerts = data["alerts"]

    if not alerts["available"]:
        story.append(Paragraph(safe_text(alerts["note"]), styles["Body"]))
        return

    if not alerts["rows"]:
        story.append(Paragraph(safe_text(alerts["note"]), styles["Body"]))
        return

    rows = [[safe_text(row["when"]), safe_text(row["kind"]), safe_text(row["detail"])]
            for row in alerts["rows"]]
    story.append(KeepTogether([
        data_table(["When", "Alert", "Detail"], rows, [38 * mm, 34 * mm, None]),
    ]))


def build(data, output_path):
    set_brand(
        data["brand"],
        "CLIENT REPORT",
        "%s  •  Client Report  •  %s" % (data["brand"], data["period"]["human_range"]),
    )

    story = []
    cover(story, data)
    summary_section(story, data)
    platform_section(story, data)
    trend_section(story, data)
    mentions_section(
        story, "4. Most positive mentions",
        "The %d most positive mentions in the period, highest sentiment first."
        % len(data["top_positive"]),
        data["top_positive"],
        "No positive mentions were collected in this period.",
    )
    mentions_section(
        story, "5. Most negative mentions",
        "The %d most negative mentions in the period, lowest sentiment first. "
        "These are the ones worth replying to." % len(data["top_negative"]),
        data["top_negative"],
        "No negative mentions were collected in this period.",
    )
    alerts_section(story, data)

    doc = SimpleDocTemplate(
        output_path, pagesize=A4,
        leftMargin=MARGIN, rightMargin=MARGIN, topMargin=16 * mm, bottomMargin=22 * mm,
        title="%s - Social Media Report" % data["client"]["name"],
        author=data["brand"],
    )
    doc.build(story, canvasmaker=BrandedCanvas)


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: render_report.py <payload.json> <output.pdf>\n")
        return 2

    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)

    build(data, sys.argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
