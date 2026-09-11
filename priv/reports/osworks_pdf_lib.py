# -*- coding: utf-8 -*-
"""
OSWORKS / REALWEBSITES branded PDF component library (ReportLab).

Reproduces the style established in
REALWEBSITES_Instatic_Feasibility_Assessment_v1_0.pdf and
OSWORKS-Keycloak-Paperless-Group-Sync-Guide.pdf: a light, editorial,
black/cream/orange document style with a serif body font, Helvetica-Bold
headings, cream callout boxes, black-header data tables, and pastel
status tables.

See references/style_guide.md in this skill for the full color/font/layout
specification. This module just gives you ready-to-use building blocks so
you don't have to reconstruct the styling from scratch each time.

Typical usage
-------------
    from osworks_pdf_lib import *

    set_brand("OSWORKS.IN", "INTEGRATION GUIDE",
              "OSWORKS.IN  \u2022  Internal Deployment Reference  \u2022  Version 1.0")

    story = []
    story.append(Spacer(1, 8 * mm))
    story.append(Paragraph(BRAND, styles["BrandWordmark"]))
    story.append(Paragraph("Integration Guide", styles["CoverTitle"]))
    story.append(Paragraph("Some Subtitle", styles["CoverSubtitle"]))
    story.append(hr())
    story.append(Paragraph("For X clients", styles["CoverContext"]))
    story.append(callout("Working recommendation", "Body text..."))
    story.append(meta_table([
        ("Document", "..."), ("Version", "1.0"),
        ("Date", "..."), ("Purpose", "..."),
    ]))
    story.append(PageBreak())

    story.append(section_heading("1. Executive Summary"))
    story.append(Paragraph("...", styles["Body"]))
    story.append(numbered_step(1, "Do the first thing", "Optional detail line."))

    doc = SimpleDocTemplate("/mnt/user-data/outputs/My-Doc.pdf", pagesize=A4,
        leftMargin=MARGIN, rightMargin=MARGIN, topMargin=16*mm, bottomMargin=22*mm,
        title="My Doc", author="OSWORKS")
    doc.build(story, canvasmaker=BrandedCanvas)

Pagination reminder: don't sprinkle PageBreak() between every section. Only
the cover -> first page break is normally needed. Use KeepTogether([...]) for
small atomic units (a step + its table, a code block, a status table with its
heading) instead of forcing whole sub-sections onto fresh pages -- see
references/style_guide.md section 9.

Vendored into SMM Monitor from the OSWORKS PDF style skill so the app can
render branded client reports at runtime without the skill being present.
Kept byte-for-byte apart from this note: if the house style changes, the
fix is to re-copy this file, not to edit it here.
"""

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    HRFlowable, PageBreak, KeepTogether,
)
from reportlab.pdfgen import canvas as pdfcanvas

# ---------------------------------------------------------------------------
# Palette (see references/style_guide.md section 1 for the full table)
# ---------------------------------------------------------------------------
ORANGE = colors.HexColor("#C1571F")
CHARCOAL = colors.HexColor("#222222")
BLUE_RULE = colors.HexColor("#3B6FA8")
CREAM = colors.HexColor("#F2EEE5")
CREAM_ALT = colors.HexColor("#F7F4EE")
GRAY_TEXT = colors.HexColor("#3F3F3F")
GRAY_META = colors.HexColor("#8A8A8A")
BLACK = colors.HexColor("#141414")
LINE = colors.HexColor("#BFBFBF")
PALE_GREEN = colors.HexColor("#DCEEDD")
PALE_AMBER = colors.HexColor("#F2E0BF")
PALE_RED = colors.HexColor("#F3D6D6")
CODE_BG = colors.HexColor("#F4F4F2")

PAGE_W, PAGE_H = A4
MARGIN = 20 * mm

# ---------------------------------------------------------------------------
# Brand / footer text -- call set_brand() once at the top of your script if
# you want values other than these defaults.
# ---------------------------------------------------------------------------
BRAND = "OSWORKS.IN"
DOC_TYPE = "INTERNAL DOCUMENT"
FOOTER_LINE = "OSWORKS.IN  \u2022  Internal Deployment Reference  \u2022  Version 1.0"


def set_brand(brand, doc_type, footer_line):
    """Override the module-level brand/footer strings used by BrandedCanvas."""
    global BRAND, DOC_TYPE, FOOTER_LINE
    BRAND, DOC_TYPE, FOOTER_LINE = brand, doc_type, footer_line


# ---------------------------------------------------------------------------
# Paragraph styles
# ---------------------------------------------------------------------------
styles = getSampleStyleSheet()

styles.add(ParagraphStyle(
    name="BrandWordmark", fontName="Times-Bold", fontSize=15, leading=17,
    textColor=ORANGE,
))
styles.add(ParagraphStyle(
    name="CoverTitle", fontName="Helvetica", fontSize=25, leading=29,
    textColor=CHARCOAL,
))
styles.add(ParagraphStyle(
    name="CoverSubtitle", fontName="Helvetica", fontSize=16, leading=20,
    textColor=CHARCOAL,
))
styles.add(ParagraphStyle(
    name="CoverContext", fontName="Helvetica-Oblique", fontSize=10.5, leading=15,
    textColor=GRAY_META,
))
styles.add(ParagraphStyle(
    name="CalloutLabel", fontName="Helvetica-Bold", fontSize=10.5, leading=13,
    textColor=ORANGE, spaceAfter=5,
))
styles.add(ParagraphStyle(
    name="CalloutBody", fontName="Times-Roman", fontSize=10.3, leading=14.8,
    textColor=GRAY_TEXT,
))
styles.add(ParagraphStyle(
    name="MetaLabel", fontName="Helvetica-Bold", fontSize=9.5, leading=13,
    textColor=CHARCOAL,
))
styles.add(ParagraphStyle(
    name="MetaValue", fontName="Times-Roman", fontSize=9.8, leading=13.5,
    textColor=GRAY_TEXT,
))
styles.add(ParagraphStyle(
    name="SectionHeading", fontName="Helvetica-Bold", fontSize=14.5, leading=18,
    textColor=CHARCOAL, spaceBefore=16, spaceAfter=7,
))
styles.add(ParagraphStyle(
    name="SubHeading", fontName="Helvetica-Bold", fontSize=11.5, leading=15,
    textColor=CHARCOAL, spaceBefore=12, spaceAfter=5,
))
styles.add(ParagraphStyle(
    name="Body", fontName="Times-Roman", fontSize=10.2, leading=14.8,
    textColor=GRAY_TEXT, spaceAfter=6,
))
styles.add(ParagraphStyle(
    name="BulletBody", fontName="Times-Roman", fontSize=10.2, leading=14.8,
    textColor=GRAY_TEXT, spaceAfter=3, leftIndent=12, bulletIndent=0,
))
styles.add(ParagraphStyle(
    name="NumStepTitle", fontName="Times-Bold", fontSize=10.2, leading=14.5,
    textColor=CHARCOAL,
))
styles.add(ParagraphStyle(
    name="NumStepBody", fontName="Times-Roman", fontSize=9.9, leading=14,
    textColor=GRAY_TEXT,
))
styles.add(ParagraphStyle(
    name="NumIndex", fontName="Times-Bold", fontSize=10.2, leading=14.5,
    textColor=CHARCOAL,
))
styles.add(ParagraphStyle(
    name="TableHeadWhite", fontName="Helvetica-Bold", fontSize=9.3, leading=12,
    textColor=colors.white,
))
styles.add(ParagraphStyle(
    name="TableCell", fontName="Times-Roman", fontSize=9.6, leading=13.5,
    textColor=GRAY_TEXT,
))
styles.add(ParagraphStyle(
    name="TableCellBold", fontName="Times-Bold", fontSize=9.6, leading=13.5,
    textColor=CHARCOAL,
))
styles.add(ParagraphStyle(
    name="CodeText", fontName="Courier", fontSize=8.3, leading=11.8,
    textColor=CHARCOAL,
))
styles.add(ParagraphStyle(
    name="CodeLabel", fontName="Helvetica-Bold", fontSize=8, leading=10,
    textColor=GRAY_META,
))
styles.add(ParagraphStyle(
    name="StatusWord", fontName="Times-Bold", fontSize=9.8, leading=13.5,
    textColor=CHARCOAL,
))


# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------

def hr():
    """Thin blue rule, used under the cover title block and at doc close."""
    return HRFlowable(width="100%", thickness=1, color=BLUE_RULE,
                       spaceBefore=4, spaceAfter=12)


def callout(label, body_html):
    """Cream callout box with a bold orange label heading.

    Use for: Working recommendation, Assessment, Governance rule, Decision,
    Suggested service concept, Note, Warning (use a text prefix like
    'WARNING \u2014 ' in the label, never a unicode glyph -- base-14 fonts
    can't render \u26a0/\u2713 and will show a broken-glyph box instead).
    """
    inner = Table([[[
        Paragraph(label, styles["CalloutLabel"]),
        Paragraph(body_html, styles["CalloutBody"]),
    ]]], colWidths=[PAGE_W - 2 * MARGIN])
    inner.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), CREAM),
        ("LEFTPADDING", (0, 0), (-1, -1), 14),
        ("RIGHTPADDING", (0, 0), (-1, -1), 14),
        ("TOPPADDING", (0, 0), (-1, -1), 12),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 12),
    ]))
    return inner


def meta_table(rows):
    """Cover-page Document/Version/Date/Purpose table.

    rows: list of (label, value_html) tuples.
    Alternating cream/white left-column background, black grid.
    """
    data = []
    for label, value in rows:
        data.append([Paragraph(label, styles["MetaLabel"]),
                     Paragraph(value, styles["MetaValue"])])
    t = Table(data, colWidths=[42 * mm, PAGE_W - 2 * MARGIN - 42 * mm])
    cmds = [
        ("GRID", (0, 0), (-1, -1), 0.6, BLACK),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
    ]
    for i in range(len(rows)):
        bg = CREAM_ALT if i % 2 == 0 else colors.white
        cmds.append(("BACKGROUND", (0, i), (0, i), bg))
        cmds.append(("BACKGROUND", (1, i), (1, i), colors.white))
    t.setStyle(TableStyle(cmds))
    return t


def data_table(header, rows, col_widths):
    """Standard black-header / white-body data table.

    header: list of column header strings.
    rows: list of row-lists (strings, may contain inline HTML like <b>).
    col_widths: list of widths (e.g. [40*mm, None]) matching header length.
    """
    data = [[Paragraph(h, styles["TableHeadWhite"]) for h in header]]
    for row in rows:
        data.append([Paragraph(c, styles["TableCell"]) for c in row])
    t = Table(data, colWidths=col_widths)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), BLACK),
        ("GRID", (0, 0), (-1, -1), 0.5, LINE),
        ("BOX", (0, 0), (-1, -1), 0.8, BLACK),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    return t


def status_table(rows, col_widths):
    """PASS/AMBER/RED-style decision-gate table (no header row).

    rows: list of (status_word, bg_color, description_html) tuples, e.g.
        ("PASS", PALE_GREEN, "Description..."),
        ("PARTIAL", PALE_AMBER, "Description..."),
        ("FAIL", PALE_RED, "Description..."),
    col_widths: [status_col_width, description_col_width]
    """
    data = [[Paragraph(w, styles["StatusWord"]), Paragraph(d, styles["TableCell"])]
            for w, _, d in rows]
    t = Table(data, colWidths=col_widths)
    cmds = [
        ("GRID", (0, 0), (-1, -1), 0.6, BLACK),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
    ]
    for i, (_, bg, _) in enumerate(rows):
        cmds.append(("BACKGROUND", (0, i), (0, i), bg))
        cmds.append(("BACKGROUND", (1, i), (1, i), colors.white))
    t.setStyle(TableStyle(cmds))
    return t


def numbered_step(n, title, body=None):
    """One numbered procedural step: bold serif index + bold serif title,
    optional lighter serif detail line beneath.

    This is the step style used in integration/setup guides (replaces the
    older teal numbered-badge-box style -- don't use badges/boxes per step
    in the OSWORKS format).
    """
    title_p = Paragraph(f"<b>{title}</b>", styles["NumStepTitle"])
    flow = [title_p]
    if body:
        flow.append(Spacer(1, 2))
        flow.append(Paragraph(body, styles["NumStepBody"]))
    t = Table([[Paragraph(f"{n}.", styles["NumIndex"]), flow]], colWidths=[8 * mm, None])
    t.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 0),
        ("RIGHTPADDING", (0, 0), (-1, -1), 0),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return t


def bullet_item(text):
    """Plain black round-bullet list item (for non-procedural prose docs,
    e.g. the feasibility-assessment variant of this style)."""
    return Paragraph(f"\u2022&nbsp;&nbsp;{text}", styles["BulletBody"])


def wrap_code_lines(code, max_chars=92):
    """Manually wrap long code/config lines so they don't overflow the page."""
    out = []
    for raw in code.split("\n"):
        if len(raw) <= max_chars:
            out.append(raw if raw.strip() else " ")
        else:
            line = raw
            while len(line) > max_chars:
                cut = line.rfind(" ", 0, max_chars)
                if cut <= 0:
                    cut = max_chars
                out.append(line[:cut])
                line = "  " + line[cut:].lstrip()
            out.append(line)
    return out


def code_block(code, label="CONFIGURATION"):
    """Light-gray config/code block with a small gray uppercase label.

    Wrap the *result* of this call in KeepTogether([...]) at the call site
    so the block never splits across a page boundary.
    """
    lines = wrap_code_lines(code)

    def esc(s):
        return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                 .replace(" ", "&nbsp;"))

    joined = "<br/>".join(esc(l) for l in lines)
    t = Table([[Paragraph(label, styles["CodeLabel"])],
               [Paragraph(joined, styles["CodeText"])]],
              colWidths=[PAGE_W - 2 * MARGIN])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), CODE_BG),
        ("BOX", (0, 0), (-1, -1), 0.6, LINE),
        ("LEFTPADDING", (0, 0), (-1, -1), 12),
        ("RIGHTPADDING", (0, 0), (-1, -1), 12),
        ("TOPPADDING", (0, 0), (0, 0), 8),
        ("BOTTOMPADDING", (0, 0), (0, 0), 2),
        ("TOPPADDING", (0, 1), (0, 1), 2),
        ("BOTTOMPADDING", (0, 1), (0, 1), 10),
    ]))
    return t


def section_heading(text):
    """Top-level numbered heading, e.g. '1. Executive Summary'."""
    return Paragraph(text, styles["SectionHeading"])


def sub_heading(text):
    """Decimal-numbered sub-heading, e.g. '2.1 Group creation'."""
    return Paragraph(text, styles["SubHeading"])


# ---------------------------------------------------------------------------
# Branded canvas: running header (skips cover page) + footer on every page
# ---------------------------------------------------------------------------

class BrandedCanvas(pdfcanvas.Canvas):
    """Pass as canvasmaker=BrandedCanvas to SimpleDocTemplate.build().

    Draws, on every page:
      - footer rule + centered "BRAND \u2022 ... \u2022 Version X.X" text
    And on every page except the first (the cover):
      - top-right running header "BRAND | DOC TYPE"

    Reads the module-level BRAND / DOC_TYPE / FOOTER_LINE globals -- call
    set_brand(...) before building if you want non-default text.
    """

    def __init__(self, *args, **kwargs):
        pdfcanvas.Canvas.__init__(self, *args, **kwargs)
        self._saved_page_states = []

    def showPage(self):
        self._saved_page_states.append(dict(self.__dict__))
        self._startPage()

    def save(self):
        num_pages = len(self._saved_page_states)
        for i, state in enumerate(self._saved_page_states):
            self.__dict__.update(state)
            self.draw_chrome(i + 1, num_pages)
            pdfcanvas.Canvas.showPage(self)
        pdfcanvas.Canvas.save(self)

    def draw_chrome(self, page_num, total_pages):
        self.saveState()
        if page_num > 1:
            self.setFont("Times-Roman", 8.3)
            self.setFillColor(GRAY_META)
            self.drawRightString(PAGE_W - MARGIN, PAGE_H - 14 * mm,
                                  f"{BRAND}  |  {DOC_TYPE}")
        self.setStrokeColor(LINE)
        self.setLineWidth(0.4)
        self.line(MARGIN, 15 * mm, PAGE_W - MARGIN, 15 * mm)
        self.setFont("Times-Roman", 7.8)
        self.setFillColor(GRAY_META)
        self.drawCentredString(PAGE_W / 2, 11 * mm, FOOTER_LINE)
        self.restoreState()


# ---------------------------------------------------------------------------
# Minimal self-test / usage example
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import os

    set_brand("OSWORKS.IN", "SAMPLE DOCUMENT",
              "OSWORKS.IN  \u2022  Internal Deployment Reference  \u2022  Version 1.0")

    story = []
    story.append(Spacer(1, 8 * mm))
    story.append(Paragraph(BRAND, styles["BrandWordmark"]))
    story.append(Spacer(1, 6))
    story.append(Paragraph("Sample Document", styles["CoverTitle"]))
    story.append(Paragraph("A minimal style self-test", styles["CoverSubtitle"]))
    story.append(hr())
    story.append(Paragraph("For internal style verification", styles["CoverContext"]))
    story.append(Spacer(1, 14))
    story.append(callout("Working recommendation",
                          "This is a sample callout box to verify the palette "
                          "and fonts render correctly."))
    story.append(Spacer(1, 14))
    story.append(meta_table([
        ("Document", "OSWORKS PDF style self-test"),
        ("Version", "1.0"),
        ("Date", "10 August 2026"),
        ("Purpose", "Verify the component library renders correctly."),
    ]))
    story.append(PageBreak())

    story.append(section_heading("1. Executive Summary"))
    story.append(Paragraph("This is body text in the serif font used throughout "
                            "the OSWORKS document style.", styles["Body"]))
    story.append(sub_heading("1.1 A sub-heading"))
    story.append(numbered_step(1, "First step title", "Optional detail line."))
    story.append(numbered_step(2, "Second step title"))
    story.append(Spacer(1, 8))
    story.append(data_table(
        ["Field", "Value"],
        [["Name", "example"], ["Type", "Default"]],
        [40 * mm, PAGE_W - 2 * MARGIN - 40 * mm],
    ))
    story.append(Spacer(1, 8))
    story.append(status_table(
        [("PASS", PALE_GREEN, "Everything looks correct."),
         ("FAIL", PALE_RED, "Something needs attention.")],
        [26 * mm, PAGE_W - 2 * MARGIN - 26 * mm],
    ))

    out_dir = "/tmp"
    out_path = os.path.join(out_dir, "osworks_pdf_lib_selftest.pdf")
    doc = SimpleDocTemplate(
        out_path, pagesize=A4,
        leftMargin=MARGIN, rightMargin=MARGIN, topMargin=16 * mm, bottomMargin=22 * mm,
        title="OSWORKS PDF style self-test", author="OSWORKS",
    )
    doc.build(story, canvasmaker=BrandedCanvas)
    print(f"Wrote {out_path}")
