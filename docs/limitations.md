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
* **Reddit sees comments only in a client's own subreddits.** Searching
  all of Reddit, for a client with no subreddits, returns posts, not
  comments, and Reddit's search index can take a few minutes to include
  a new post. `time_filter` bounds how far back a search looks.
* Reddit's subreddit listings show the **newest 100 posts and 100
  comments**, and a poll reads at most three pages of each. A very busy
  set of subreddits, or a long pause (a spent quota, the app being
  stopped), can pass more than that between polls, and the rest is not
  seen. Nothing older than a day is reported, and nothing is fetched
  from before the app started.
* Reddit **edits and deletions are not followed**; a post or comment is
  stored as it was first read.
* A **private, banned or misspelt subreddit** is skipped for an hour at a
  time, with a log line naming it. A client whose subreddits are all
  refused shows an error.
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
* **Discord only sees servers the bot has been invited to**, and only
  channels it is allowed to view. There is no public search: other
  communities are invisible. Direct messages, bots, webhooks and system
  messages are skipped.
* Discord **edits and deletions are not followed**. A mention stays as it
  was first sent, even if the author edits or deletes it.
* Discord's catch-up after a restart covers **only channels that had a
  message before the restart**, and at most **1,000 messages** (10 pages
  of 100) per channel. A busier channel, or a channel created while the
  app was down, loses the rest. Short drops are replayed by Discord
  itself and lose nothing.
* There is **no sharding**. Discord requires it at 2,500 servers; the
  bot stops with a log line saying so. Using Message Content Intent in
  **100 or more servers** also needs Discord's review of the bot.
* With `SMM_DISCORD_CHANNELS` set, a thread is allowed through its
  parent channel, so a thread whose parent the bot has not seen yet
  (for example, one in a server still loading) is skipped until it has.
* Discord matching is whole words only, the same as Bluesky.
* **Threads search only covers your own account's posts until Meta
  approves the app in App Review** for `threads_keyword_search`, and
  mentions only come from the app's testers until
  `threads_manage_mentions` is approved. Before then the Threads tab is
  mostly empty, and correctly so.
* Threads' 2,200 searches a day are **shared with every other app** the
  account has authorised. The budget here is our own count: it can't see
  other apps' searches, it counts searches that found nothing (Meta
  doesn't), and it starts from zero when the app restarts.
* A Threads **mention is stored only if it names one of the client's
  brand terms**; one that only @-mentions the account is dropped.
  **Replies** to the account's own posts (opt-in) go to every client.
* Threads never returns **private profiles**, returns nothing for some
  sensitive keywords, and **edits and deletions are not followed**.
* The Threads token renews itself, but only while the app runs: if it is
  not started for **60 days**, the token expires and a new one has to be
  made by hand.
* **Mastodon sees only what your server knows about.** The fediverse has
  no central search: a server hears from its own users and from the
  accounts they follow, so a small server misses most of the network
  and even `mastodon.social` misses some. Posts from before the moment
  it connects are never fetched.
* Mastodon's federated stream on a large server carries **every public
  post it hears about**, matched or not. The bandwidth has not been
  measured for this release; `SMM_MASTODON_TIMELINE=local` is far lighter.
* Mastodon's catch-up after a drop or restart is **capped at 400 posts
  (10 pages of 40) and one hour**. A busy federated timeline passes 400
  posts in minutes, so anything longer than a short drop loses posts.
* A Mastodon server's admin can **switch live feeds off** or limit them
  to some users (Mastodon 4.5 and later). The stream then stops with the
  same message as a refused token.
* Mastodon **boosts, edits and deletions are not followed**, and
  unlisted, followers-only and direct posts are never seen. A post whose
  id or account name does not look like Mastodon's is dropped.
* Mastodon matching is whole words only, the same as Bluesky.
* **News sees only what a feed carries**, usually the headline and a
  summary. A brand named only deep in an article is missed when the
  feed carries just a summary, and paywalled or log-in feeds cannot be
  read at all.
* News is **polled every 10 minutes**, and only articles from the
  **last 24 hours** are kept; there is no back-fill of older articles.
* News reads **at most 100 feeds, 100 articles per feed and 5 MB per
  fetch**. A bigger feed counts as failing.
* **Google News search is off by default** because Google publishes its
  search feeds for personal, non-commercial use. It is at most 5 brand
  terms a client, and it pauses whenever Google refuses requests.
* News matching is whole words only, the same as Bluesky and Mastodon.
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
