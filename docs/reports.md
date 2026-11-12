# Trends and client reports

[← Back to the README](../README.md)

## Seeing the trend

Every other screen answers "what is being said right now". Press **`h`**
(for history) and you get the other question: is this getting better or
worse?

![The trends screen: a bar chart of mentions per day over fourteen days
with one tall spike, and below it a chart of average sentiment per day
with a single negative day in red](images/trends.png)

*Two charts over the same window: how much was said each day, and how it
felt. The spike on the right is the kind of thing the alert banner at the
top fires on.*


Two charts, one column per day, for whichever client is selected:

* **Mentions per day**, scaled to the busiest day in the window. The
  axis carries the number; the shape is what you read. A day nobody
  said anything is a blank column, not a missing one.
* **Average sentiment per day**, on a fixed −1 to +1 scale, growing up
  from a zero line in green and down from it in red. Fixed rather than
  scaled to the week's own range, so a calm week looks calm instead of
  being magnified into a crisis.

### Changing the window

`w` cycles **7 → 14 → 30 days** and `W` goes back the other way. The
default is **14** — two weekends and the week between them, which is
enough to see a weekly rhythm without flattening this week into it.

The window only means anything on this screen, so `w` does nothing on
the others: changing a window you can't see is a setting, not a
keystroke.

### What it reads

The SQLite log, grouped by day in SQL — not the live window, which only
holds hours. Two consequences worth knowing:

* **Days are UTC**, and they are the day a mention was *published*, not
  the day we collected it. That matches what the PDF reports say about
  the same period.
* **Retention bounds it.** With the default 30-day retention a 30-day
  window is the whole of your history, and the oldest columns start
  disappearing as the window catches up with the cutoff. Raise
  `SMM_RETENTION_DAYS` before you need the history rather than after.

The footer says `from stored history`, or tells you when persistence or
writing is switched off — on this screen an empty chart would otherwise
be ambiguous between "nobody said anything" and "nothing is being
written down".

### Terminal size

The columns widen on a roomy terminal and narrow to single characters
for a 30-day window. A 30-day window needs about 60 columns; below that
the screen drops the *oldest* days and says how many, rather than
letting the right-hand end — this week — get clipped off the edge.

### Speed

The query is grouped in SQLite and indexed on `(client_id,
source_timestamp)`, so its cost follows the window being drawn rather
than the history behind it. On a synthetic database, a 30-day window
took 1.1 ms at 100,000 mentions and 1.2 ms at 2,000,000. The series is
re-read at most every five seconds while the screen is open, and not at
all while you are on another tab.

## Client reports

Everything above is for the person watching the dashboard. A report is
for the person paying for it: one document, per client, covering a week
or any range you ask for, that can go to them as it comes out.

```sh
# Last 7 days for one client — PDF and CSV
mix smm.report --client acme-corp

# An explicit range
mix smm.report --client acme-corp --from 2026-09-01 --to 2026-09-07

# Last 30 days, data only
mix smm.report --client acme-corp --days 30 --format csv

# Every active client at once
mix smm.report --all --days 7

# If you can't remember the id
mix smm.report --list
```

On a release there is no `mix`, so the same thing is an `rpc` into the
running node (see **[DEPLOY.md](../DEPLOY.md)**):

```sh
sudo -u smm-monitor /opt/smm-monitor/bin/smm_monitor rpc \
  'SmmMonitor.Reports.generate("acme-corp", days: 7)'
```

Or press **`R`** on the dashboard: it writes a report for whichever
client is on screen and tells you the filenames in the footer. That's
the whole interaction — it's the same seven days the mix task defaults
to. Read-only SSH sessions can't do this; a remote viewer shouldn't be
able to write files onto the host's disk by pressing a key.

### Where the files go

`$SMM_REPORTS_DIR` if you set it, otherwise a `reports` directory
alongside the database (`/var/lib/smm-monitor/reports` under systemd,
`./data/reports` in development). Deliberately *not* inside the release
directory, which a deploy replaces — last quarter's reports should
survive an upgrade.

Files are named for the client and the period they cover:

```
reports/
├── acme-corp_2026-09-05_2026-09-11.pdf
├── acme-corp_2026-09-05_2026-09-11.csv
├── globex_2026-09-05_2026-09-11.pdf
└── globex_2026-09-05_2026-09-11.csv
```

That name still identifies the document after someone has forwarded it,
and the directory sorts sensibly on its own.

### What's in the PDF

Four or five pages, in the OSWORKS house style — cream, charcoal and
rust, serif body text, black-header tables:

1. **Cover** — client name, the date range in words, when it was
   generated, the brand terms it was built from, and a summary callout
   in a sentence or two of plain English ("Sentiment is improving, on
   higher volume than the week before").
2. **Summary** — total mentions against the previous period of the same
   length, average sentiment against the same, and the positive /
   neutral / negative split with shares.
3. **Mentions by platform** — every configured platform, busiest first,
   including the ones with nothing on them. A platform reading zero is
   information; a missing row just looks like an oversight.
4. **Sentiment trend** — a line chart on a fixed −1 to +1 axis, one
   point per day, plus the daily table underneath it.
5. **Most positive and most negative mentions** — up to five each, as
   quotes, with platform, author, time and score. This is the part
   clients actually read.
6. **Alerts raised** — what fired during the period and when. If
   alerting wasn't running, the section says so rather than showing an
   empty table: "no alerts" and "nothing was watching" are different
   facts and only one of them is reassuring.

### What's in the CSV

Every mention in the period, one row each, twelve columns:
`client_id`, `client_name`, `platform`, `mention_id`, `author`, `text`,
`url`, `published_at`, `sentiment`, `sentiment_value`, `sentiment_score`
and `mock`. RFC 4180 quoting, CRLF line endings, header row always
present — it opens in Excel or Sheets without an import wizard, and a
multi-line forum post stays one row.

The `mock` column matters when you're still running sample data: it's
the difference between coverage and a demo.

### PDF needs Python; CSV needs nothing

The PDF is rendered by a small ReportLab script shipped in
`priv/reports/`, so the PDF half of this needs:

```sh
sudo apt install python3
pip3 install reportlab        # or: apt install python3-reportlab
```

Nothing else in the app depends on it. If it's missing, the mix task
says exactly what to install instead of failing obscurely, and
`--format csv` keeps working. The weekly schedule and the `R` key both
degrade the same way: you lose the formatted document, not the data.

### Weekly reports, unprompted

Off by default — a process that writes files on its own should be
something you switched on:

```sh
SMM_WEEKLY_REPORTS=true      # default false
SMM_WEEKLY_REPORT_DAY=1      # 1 = Monday … 7 = Sunday
SMM_WEEKLY_REPORT_HOUR=7     # UTC
SMM_REPORTS_DIR=/var/lib/smm-monitor/reports
```

With it on, every active client's last seven days are written to the
reports directory at the configured hour — Monday 07:00 UTC by default,
so a week that ended last night is on someone's desk before the Monday
meeting. Paused clients are skipped.

It checks the calendar hourly rather than setting a seven-day timer, so
a restart, a deploy or a machine that was asleep doesn't cost you a
week's report. One client's report failing doesn't stop the others.

Nothing is emailed anywhere: the files land in a directory, and what
happens to them next is a human decision.
