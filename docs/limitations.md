# Known limitations

[← Back to the README](../README.md)

* Mentions older than the retention window are gone for good. Reports
  and CSV exports can only cover what is still on disk, so a 90-day
  report on a 30-day retention shows 30 days and says nothing about the
  missing 60. Raise `SMM_RETENTION_DAYS` before you need the history,
  not after.
* Retention deletes rows but SQLite doesn't shrink the file — see
  [disk space](architecture.md#disk-space).
* The clients screen edits clients, brand terms, subreddits and alert
  settings. Reddit and YouTube keys can be added from the setup wizard;
  X and Instagram credentials, poll intervals and demo mode are
  environment variables and need a restart.
* Sentiment is a word list; sarcasm, negation beyond one word, and
  domain-specific language will all fool it.
* **Credentials are per install, not per client.** Every client is
  searched with the same Reddit app, YouTube key and X token, so the API
  budgets are shared and divide as clients are added — see
  [how API limits are shared](clients.md#how-api-limits-are-shared-between-clients).
  Monitoring clients under separate
  API accounts would need credentials on the client record.
* **Instagram is the exception, awkwardly.** Its endpoints are scoped to
  one connected Business account, so a second client's Instagram would
  need its own token and account id. Today every client is polled against
  the one connected account, which is right for a single-brand install
  and wrong for an agency — the honest fix is per-client Instagram
  credentials, and it isn't built.
* Removing a client deletes its mentions. There is no undo and no export
  first.
* Reddit search returns *posts*, not comments. A brand discussed only in
  the comments of someone else's thread won't show up.
* Reddit's search index lags a little behind new posts, so a mention can
  take a few minutes to appear. `time_filter` bounds how far back a poll
  looks; mentions older than that are never seen at all.
* YouTube search finds *videos*, not comments — so a brand discussed in
  the comments under someone else's video won't show up. The hybrid that
  would fix this is described in
  [platforms.md](platforms.md#youtube).
* YouTube polls every 18 minutes by default, which is what the free
  daily quota allows around the clock. Polling faster, or adding
  clients, runs the budget out before the day ends — see
  [the quota section](platforms.md#youtube-quota).
* YouTube quota accounting is our own estimate — Google doesn't report
  remaining quota — so it can't see another process sharing the key.
* **Instagram cannot do brand-wide search.** It sees posts that tag your
  account, comments on your own posts, and (opt-in) public posts
  carrying a tracked hashtag — nothing else. @-mentions in other
  people's captions are webhook-only and out of reach for a polling
  tool. See [what Instagram can and cannot see](platforms.md#what-instagram-monitoring-can-and-cannot-see); this is a platform limit, not
  a to-do.
* Instagram hashtag results carry **no author** — Meta strips usernames
  — so they show as `#brandname` rather than a person.
* Instagram hashtag search allows **30 unique hashtags per rolling 7
  days** and only returns the last 24 hours of media.
* Instagram long-lived tokens expire after **60 days** and there is no
  automatic refresh; the fetcher names the failure but cannot fix it.
* X recent search needs a **paid tier** and only reaches back 7 days.
* The X monthly post cap isn't reported in any response header, so the
  count here is our own estimate against a conservative budget — it
  can't see other apps sharing the Project. Check `GET /2/usage/tweets`
  for the real figure.
* **Bluesky only sees posts made while it is connected**, plus up to an
  hour of catch-up after a restart or outage (Jetstream's replay, from
  the saved cursor). A gap longer than that is lost; there is no search
  to backfill it. Switching Bluesky on does not fetch anything older
  than the moment it connects.
* Bluesky receives **every post on the network** and throws away the
  ones that don't match. The bandwidth this uses has not been measured
  for this release; expect a steady stream rather than occasional
  requests, and check it before turning Bluesky on over a metered
  connection.
* Bluesky matching is **whole words only**: "acme" matches "Acme's new
  app" but not "acmecorp" or "#acmecorp". Add those as brand terms if
  they matter. Case is ignored; accents are not, so "cafe" does not
  match "café".
* A Bluesky author shows as their DID (`did:plc:...`) when the public
  profile lookup fails or times out; the handle is not filled in later
  for mentions already stored.
* SSH access has no rate limiting or audit trail beyond one log line per
  connection — run it behind a VPN or firewall rather than exposed.
* Remote sessions are read-only; there's no per-user permission model,
  only "host terminal" versus "everyone else".
* **Email alerting is not built** — Slack (or any webhook) only. The
  notifier behaviour is the seam if you want to add it.
* Alerts are written to the database as they fire, so reports can show
  what happened, but the *live incident state* is still in memory: a
  restart forgets what was firing. A condition still true at the next
  evaluation opens a new incident and alerts once more; one that
  recovered while the app was down never sends its all-clear.
* Watch phrases are plain substrings, so "scam" matches "scamper". A
  word-boundary match would fix that and break "refund"/"refunds"; v1
  takes the false positive over the false negative.
* Sentiment alerts inherit the lexicon scorer's blind spots — sarcasm
  especially.
* PDF reports need `python3` and `reportlab` on the host. Without them
  you get the CSV and a message saying what to install — the data is
  never the thing that goes missing.
* Reports are written to a directory and nothing else happens to them.
  There is no emailing, no upload, and no record of which ones were
  sent to a client.
* A report's numbers come from the durable log, so a client added last
  week cannot be reported on for the month before it existed.
* The trends screen shows UTC days. A mention posted at 01:00 in
  Melbourne lands on the previous day's column.
* The trends screen reads the database only. With persistence switched
  off it has nothing to show, and says so in its footer rather than
  drawing an empty chart.
* **Windows runs it through WSL**, not natively — termbox has no
  Windows build, and that is the honest workaround rather than an
  oversight. Use Windows Terminal; conhost renders the dashboard's block
  characters as boxes.
* The macOS binaries are unsigned and unnotarised. A browser download
  needs the quarantine attribute removed; the installer's doesn't.
* Upgrading means running the install command again. The binary unpacks
  itself under `~/.local/share/.burrito` keyed by version, so a new
  version unpacks fresh and the old one is cleaned up.
