# Clients and shared API budgets

[← Back to the README](../README.md)

The unit of monitoring is a **client**, not a keyword — RealOffice runs
social media for several businesses, and each needs its own brand terms,
its own subreddits and its own view.

Every mention belongs to exactly one client. The dashboard always shows
one client at a time, and `]` / `[` cycle between them:

```
 SMM MONITOR · Acme Corp 2/4 [[/]] · acme, acme corp · LIVE · updated 14:22:07
```

The client's name comes first because with four on one dashboard,
"whose numbers am I looking at?" is the question that has to be answered
before any other. **The "all" tab means all of this client's platforms**
— never every client's mentions added together, which would be a number
nobody could act on.

### Adding a client

1. Press **`c`** for the clients screen.
2. Press **`+`**. Type the client's name — "Acme Corp" — and press
   **Enter**. The name doubles as its first brand term, so it starts
   searching immediately.
3. The new client is highlighted with its **brand terms** selected. Press
   **`e`**, type the terms you actually want (comma-separated:
   `acme, acme corp, acmecorp`) and press **Enter**.
4. Press **`l`** to move to **subreddits**, then **`e`** to edit them —
   comma-separated, or leave empty to search all of Reddit.
5. Press **`s`** to switch the dashboard to the new client.

That's it. **No restart**: every platform picks the new client up on its
next poll — 30s for Reddit, 5 minutes for X, 15 for Instagram and 18 for
YouTube.

```
┌─clients · changes are picked up on the next poll─────────────────────────────┐
│                                                                              │
│  CLIENTS   3 configured                                                      │
│                                                                              │
│    1. Real office  (unassigned)  ● viewing                                   │
│        name         Real office                                              │
│        brand terms  realoffice, real office                                  │
│        subreddits   smallbusiness, marketing                                 │
│  ▸ 2. Acme Corp  (acme-corp)                                                 │
│        name         Acme Corp                                                │
│      › brand terms  acme, acme corp                                          │
│        subreddits   saas, startups                                           │
│    3. Beta Labs  (beta-labs)  ‖ paused — not polled                          │
│        name         Beta Labs                                                │
│        brand terms  betalabs                                                 │
│        subreddits   (none — searching all of Reddit)                         │
│                                                                              │
│  j/k client · h/l field · e edit · + add · d remove · p pause · s view       │
└──────────────────────────────────────────────────────────────────────────────┘
```

| Field | What it does |
| --- | --- |
| **name** | What you see in the header. Renaming keeps the client's id, so its history is untouched. |
| **brand terms** | The search terms for this client, used by every platform. Comma-separated; multi-word terms are quoted as phrases automatically. At least one is required. |
| **subreddits** | Which subreddits Reddit watches **for this client**. Comma-separated. Empty means all of Reddit. |
| **alert phrases** | Words that raise an alert on sight — `lawsuit, refund, scam`. Empty by default. |
| **alert if sentiment** | The mean sentiment at or below which this client alerts. |
| **alert if volume** | The multiple of this client's normal hourly volume that alerts. |
| **slack webhook** | This client's own Slack channel, overriding the global one. |

The last four are covered in [Alerting](alerts.md). Only the client your
cursor is on shows its fields; the rest collapse to a line, since seven
rows times five clients is a screen nobody can read.

### Pausing vs. removing

**`p` pauses** a client: it stops being polled for, and keeps every
mention already collected. That's the one to use for a contract on hold.

**`d` removes** it — and takes its mentions with it. It asks first, and a
second `d` confirms. Deleting is deliberately total: a client row with no
mentions, or mentions with no client, are both states nothing else in the
app knows how to render.

### Clients on separate SSH sessions

**Which client you're viewing is per session.** Two people connected over
SSH can watch different clients at the same time without fighting over a
shared selection. What *is* shared is the client list itself: if someone
adds a client, everyone's next refresh sees it.

### Where clients are stored

In SQLite, in a `clients` table alongside the mentions — not in the old
JSON config file. Mentions reference a client, and keeping the two in
separate stores would let a client vanish while its mentions still
pointed at it.

The id is a slug of the name (`Acme Corp` → `acme-corp`) rather than a
number, because it is written onto every mention row and read in log
lines. **Ids never change on rename**, which is what makes a rename safe.
Two clients with the same name get `acme` and `acme-2` — two clients
called Acme is your business, not something for the tool to refuse.

### Upgrading from the single-keyword version

Nothing is lost, and there is nothing to do. On the first boot after this
update:

1. The **migration** adds `client_id` to every stored mention and assigns
   existing rows to a holding client id, `unassigned`. It prints how many
   it moved. It can't do better than one holding client: nothing in a
   mention row records which brand it was collected for, so guessing
   would be worse than admitting it.
2. **`SmmMonitor.Clients` then creates that client** from your previous
   settings — the `~/.config/smm_monitor/config.json` file first, falling
   back to `SMM_KEYWORDS` — and names it from the brand term. So
   `["realoffice", "real office"]` becomes a client called *Real office*,
   already searching for both and watching the same subreddits, and every
   mention collected before the upgrade belongs to it.

   The migration deliberately does *not* create the row itself. If it
   did, the seed would find the table already populated, decide there was
   nothing to do, and the upgrade would come up monitoring an empty
   keyword list.
3. The old config file is **left on disk untouched** and never written to
   again, so rolling back to the previous release is a downgrade rather
   than a restore from backup.

The upshot: an install that was watching one brand keeps watching it,
under a name, with its history intact. Add your second client whenever
you're ready.

### What needs a restart

| Setting | Changed how |
| --- | --- |
| Clients: add, remove, pause | **Clients screen, live** |
| Brand terms, subreddits, name | **Clients screen, live** |
| Alert thresholds, phrases, client webhook | **Clients screen, live** |
| Reddit and YouTube keys, via `c` then `S` | **Setup wizard, live** |
| X and Instagram keys (`TWITTER_*`, `INSTAGRAM_*`) | Env var + restart |
| Demo data (`SMM_DEMO`, `SMM_MOCK_*`) | Env var + restart |
| Poll intervals, quota budget, window/retention | Env var + restart |

Reddit and YouTube keys are the exception, because they are the two a
non-technical person is expected to add themselves: the wizard writes
them to `~/.config/smm_monitor/settings.json` (readable only by you) and
merges them into the running app, which polls that platform straight
away rather than waiting for its next scheduled poll. A corrected key
replaces the old one, and re-running the wizard and skipping a step
keeps the key you saved before. A key set in the environment always
wins over one typed into the wizard. Nothing else is editable from the screen — a
server's credentials belong in its environment, not in a table the
dashboard writes.

⚠️ **Credentials are per install, not per client.** Every client is
searched using the same Reddit app, YouTube key and X bearer token —
which is what the next section is about.

## How API limits are shared between clients

This is the part worth understanding before adding your fifth client.

**An API budget belongs to the credential, not to the client.** YouTube's
10,000 daily quota units and X's monthly post cap are spent by whoever
holds the key, and every client is searched with the same key. So the
budget is shared, and it does not grow when you add a client — **it
divides**.

| Platform | The binding limit | Effect of N clients |
| --- | --- | --- |
| **YouTube** | 8,000 units/day (100 per search) | 80 searches/day total, split across clients |
| **Twitter/X** | Monthly post cap (10,000 by default) | Shared; each client's results count against it |
| **Reddit** | 60 requests/minute | Rarely binding — one request per client per poll |
| **Instagram** | Meta's hourly allowance | Scoped per account, so effectively per client |

That's why all of a platform's clients are polled from **one worker**,
looping over them, rather than a worker each: one process has to own the
counting. A worker per client would give each its own private idea of the
quota, and four clients would quietly spend four times the budget and get
the key cut off.

### Can one client starve another?

**Yes, in principle — and that's mitigated rather than ignored.**

If the same client were polled first every cycle, it would spend the
shared quota and the others would get whatever was left, which on a tight
YouTube budget is nothing. So the client list is **rotated by poll
count**: whoever went first this cycle goes last next time.

When a fetcher reports a spent quota or a rate limit, the cycle **stops
there** rather than working through the remaining clients — the limit is
shared, so those calls would fail anyway — and the rotation puts the
skipped clients first next time. The worker records this as coverage:

```
youtube: stopping this cycle at beta-labs ({:quota_exhausted, 42600000}) - the
limit is shared across clients, so 2 client(s) are skipped and go first next cycle
```

The result is that a quota shortfall is spread evenly instead of falling
on the same client every day. **Everyone loses the same fraction of
coverage**, rather than one client losing all of it.

### Making the budget go further

If you are monitoring several clients on YouTube in particular, do the
arithmetic before you rely on it: **80 searches a day ÷ N clients** is how
many polls each client gets.

| Clients | Polls per client per day | Sensible interval |
| --- | --- | --- |
| 1 | 80 | 18 min |
| 3 | 26 | 55 min |
| 5 | 16 | 90 min |
| 10 | 8 | 3 hours |

```bash
# Five clients on YouTube: poll every 90 minutes, not every 5.
export SMM_YOUTUBE_POLL_INTERVAL_MS=5400000
```

The startup warning tells you when your interval can't be sustained, and
the platform stands down cleanly when the budget is spent rather than
failing every call. Twitter's monthly cap has the same shape — raise
`SMM_TWITTER_MONTHLY_POST_BUDGET` to what your plan actually allows, and
remember it is divided between clients.

**Paused clients cost nothing.** Pausing (`p`) is the cheapest way to get
a struggling budget back: a paused client isn't polled and isn't counted
in the rotation.

