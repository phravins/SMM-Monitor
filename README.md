# SMM Monitor

A terminal dashboard for tracking client brand mentions across social
platforms. Built for RealOffice's social media management work — no web
frontend, just a TUI you can leave running in a pane, a SQLite file
behind it, Slack alerts when something needs attention, and a PDF a
client can actually be handed.

```
 SMM MONITOR · watching: realoffice, real office · MOCK DATA · updated 13:15:13
┌──────────────────────────────────────────────────────────────────────────────┐
│ [all (72)]   reddit (18)    youtube (18)    twitter (18)    instagram (18)   │
└──────────────────────────────────────────────────────────────────────────────┘
┌─last 1d · all────────────────────────────────────────────────────────────────┐
│mentions: 72   net sentiment: +21                                             │
│████████████▒▒▒▒▒▒▒▒▒█████████                                                │
│  positive 41% (29)   neutral 30% (22)   negative 29% (21)                     │
└──────────────────────────────────────────────────────────────────────────────┘
┌─recent mentions · 1-27 of 72─────────────────────────────────────────────────┐
│PLATFORM    AUTHOR             MENTION                        SENTIMENT   AGE │
│youtube     @toolteardown      realoffice pricing page upda…   ▲ 1      1m ago │
│twitter     @devrel_dan        realoffice dashboards are br…   ▲ 2     27m ago │
│instagram   @maya.makes        not great — realoffice kept …   ▼ 2     33m ago │
│reddit      u/anna_ops         shout out to the realoffice …   ▲ 2     46m ago │
└──────────────────────────────────────────────────────────────────────────────┘
 all twitter instagram reddit youtube · j/k scroll · q quit · reddit:mock …
```

## Quick start

Mock mode is the default, so this works with no API keys at all:

```sh
mix deps.get
mix smm.tui
```

You'll get a populated, moving dashboard built from fixtures. Press `q` to
quit.

### Requirements

* Elixir ~> 1.15 with OTP 25+
* A C toolchain (`build-essential`) and `erlang-dev` — Ratatouille compiles
  a termbox NIF on install

<details>
<summary>If <code>mix deps.compile</code> fails on ex_termbox</summary>

The bundled termbox builds with waf 2.0.14, which uses a file mode (`rU`)
that Python 3.11 removed. If you see `ValueError: invalid mode: 'rUb'`,
either build with an older Python or patch the vendored copy:

```sh
sed -i "s/def readf(fname,m='r',encoding='latin-1'):/&\n\tm=m.replace('U','')/" \
  deps/ex_termbox/c_src/termbox/.waf3-*/waflib/Utils.py
mix deps.compile ex_termbox
```

This is an upstream packaging issue, not a problem with this project.
</details>

## Running it

| Command | What it does |
| --- | --- |
| `mix smm.tui` | Starts the supervision tree and the dashboard. The usual way. |
| `SMM_TUI=1 mix run --no-halt` | Same thing via the app's own config flag. |
| `mix run --no-halt` | Runs the fetchers and processing layer headless, no UI. |
| `./scripts/build_release.sh` | Builds a self-contained release and packages it (see [DEPLOY.md](DEPLOY.md)). |
| `mix test` | The test suite (no fetchers, no TUI — see `config/test.exs`). |

To run it as a background service on a server — systemd unit, dedicated
user, env file for secrets — see **[DEPLOY.md](DEPLOY.md)**. The release
bundles the Erlang runtime, so the target needs neither Elixir nor
Erlang installed.

To just run a release locally with the dashboard attached:

```sh
./scripts/build_release.sh --no-tar
SMM_TUI=1 _build/prod/rel/smm_monitor/bin/smm_monitor start
```

There's deliberately no escript: Ratatouille's termbox NIF can't be loaded
out of an escript archive, so the binary would start and immediately fail
on `ExTermbox.Bindings.init/0`. A release keeps the NIF in a real `priv`
directory and works.

### Keyboard shortcuts

| Key | Action |
| --- | --- |
| `]` / `[` | **Next / previous client** |
| `1`–`9` | Jump straight to that client |
| `a` | All platforms (for the selected client) |
| `t` `i` `r` `y` | Twitter · Instagram · Reddit · YouTube |
| `c` | Clients screen (see below) |
| `j` / `k`, `↑` / `↓` | Scroll the mentions table |
| `PgUp` / `PgDn` | Scroll a screen at a time |
| `g` / `Home` | Jump to the newest mention |
| `R` | **Write a report** for the selected client (see below) |
| `q` | Quit (or `Ctrl-C`) |

On the clients screen, `j`/`k` move between clients, `h`/`l` between a
client's fields, `e` or `Enter` starts editing, `+` adds a client, `d`
removes one (twice — it asks first), `p` pauses one, and `s` switches the
dashboard to it. **While you're editing every key is typed**, including
`q` and the tab letters — so a brand term like "quality" or "clarity"
goes in fine. `Ctrl-C` always quits.

## Monitoring several clients

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
next poll — 30s for Reddit, 5 minutes for YouTube and Twitter, 15 for
Instagram.

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

The last four are covered in [Alerting](#alerting). Only the client your
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
| Mock/live per platform (`SMM_MOCK_*`) | Env var + restart |
| API credentials (`REDDIT_*`, `YOUTUBE_API_KEY`, …) | Env var + restart |
| Poll intervals, quota budget, window/retention | Env var + restart |

Credentials are deliberately not editable from the screen: they belong in
the environment, not in a table the dashboard writes.

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

## How sentiment is scored

Every mention gets a number between `-1.0` and `1.0` as it arrives, and
the positive/neutral/negative label you see is derived from it. The
number is what the dashboard averages and what alerting compares; the
label is for reading at a glance.

This is a lexicon scorer, not a model. It runs on every mention in the
pipeline, so it stays local, deterministic and fast — no model to load,
no API to call, no per-mention cost. What makes it more than a keyword
count is three things it does before adding anything up.

**It splits the text into clauses.** Sentence ends and contrastive
conjunctions ("but", "however", "although", "though", "whereas", "yet")
each start a new clause, and a clause after one of those conjunctions
counts double. In English that is where the speaker's real point
usually lands:

> "great tool, would recommend, **but the mobile app keeps crashing**"

is a bug report with a compliment attached, not praise. A flat word
count files it under positive and the complaint disappears.

**It handles negation.** A negator flips the polarity of sentiment words
within the next few tokens, so "not good", "didn't love it" and "not at
all helpful" are all negative — and "not bad at all" is positive. The
window is a few tokens rather than only the next word because that is
how people actually write. It stops at the window's edge, so "not the
rollout we hoped for, though support was excellent" stays positive
about support.

**It handles intensifiers and downtoners.** "very good" outscores
"good"; "slightly slow" is a grumble rather than a complaint, and lands
in the neutral band where it belongs. Modifiers survive negation, so
"not very reliable" is a firmer complaint than "not reliable".

Words carry strong (2.0) or mild (1.0) weight rather than a flat 1.
Each clause is normalised against a saturation point, then the clauses
are combined weighted by how much sentiment each carried — a clause
with three sentiment words has more say than one with a single word.

### What changed, in practice

| Mention | Before | Now |
| --- | --- | --- |
| "great tool, would recommend, but the mobile app keeps crashing" | positive | **neutral** |
| "realoffice was down again this morning" | neutral | **negative** |
| "hardly useful for our workflow" | neutral | **negative** |
| "realoffice is slightly slow but it does the job" | negative | **neutral** |

The first two are the ones that matter for a brand monitor: a complaint
filed as praise is a complaint nobody sees, and an outage that doesn't
register as negative is the mention you most needed to catch.

### Tuning the word lists

The lists are plain text under `priv/sentiment`, one word per line, `#`
for comments:

```
priv/sentiment/
├── strong_positive.txt   weight +2.0   excellent, brilliant, flawless
├── mild_positive.txt     weight +1.0   good, useful, helpful
├── strong_negative.txt   weight -2.0   terrible, broken, outage, down
├── mild_negative.txt     weight -1.0   slow, confusing, clunky
├── negators.txt          flips the next few words
├── intensifiers.txt      x1.5          very, really, absolutely
└── downtoners.txt        x0.5          slightly, somewhat, fairly
```

Editing them needs no recompile. Adding your own vocabulary is the
single highest-value change you can make here: the words your clients'
customers use — a product name used as a verb, an in-house term for a
recurring bug — are worth more than any amount of tuning the weights.

On a deployed box the release directory is replaced on each deploy, so
tuned lists belong outside it. Point `SMM_SENTIMENT_DIR` at a directory
and any file present there wins, category by category:

```bash
mkdir -p /etc/smm-monitor/sentiment
cp priv/sentiment/mild_negative.txt /etc/smm-monitor/sentiment/
# edit it, then add to /etc/smm-monitor/env:
SMM_SENTIMENT_DIR=/etc/smm-monitor/sentiment
```

Override one list and the rest are still read from the packaged copies.
There is no file watcher, deliberately — scoring that shifted mid-run
with no record of why would make the history unreadable. Reload from a
remote console instead:

```elixir
SmmMonitor.Processing.Sentiment.Lexicon.reload()
SmmMonitor.Processing.Sentiment.Lexicon.sources()  # which file won, per category
```

Only mentions scored after the reload use the new lists. Stored rows
keep the score they were given, so tuning a list never rewrites what
past mentions meant.

The weights themselves are configurable if you need them, though the
word lists are almost always the better lever:

```elixir
config :smm_monitor, :sentiment,
  strong: 2.0,
  mild: 1.0,
  intensifier: 1.5,
  downtoner: 0.5,
  # Raw clause score at which the normalised score hits +/-1.0.
  saturation: 4.0,
  # Scores inside this band are reported as neutral.
  neutral_band: 0.15,
  # How much more a clause after "but" counts.
  contrast_weight: 2.0
```

### What it still gets wrong

Sarcasm and idiom defeat it, as they defeat every lexicon: "great, another
outage" scores positive. A mention that is genuinely half praise and half
complaint with no "but" between them averages toward neutral, which is
honest but tells you less than reading it would. And a word that isn't in
the lists contributes nothing at all — which is why adding your own
vocabulary beats tuning weights.

If you want to see the working for a particular mention, `score/1`
returns it:

```elixir
iex> SmmMonitor.Processing.Sentiment.score("love the product but support is slow").clauses
[
  %{text: "love the product", raw: 2.0, signals: 1, contrast: false, score: 0.5},
  %{text: "support is slow", raw: -1.0, signals: 1, contrast: true, score: -0.25}
]

The second clause follows "but", so it carries twice the weight of the
first despite the smaller number — which is what pulls the mention down
to neutral rather than leaving it as praise.
```

## Alerting

Collecting mentions only helps if someone notices when they turn. Every
minute each active client is measured over its own rolling window and put
to three conditions. Any that trips raises an alert; when it stops
tripping, an all-clear follows.

```
:rotating_light: Acme Corp: sentiment fell to -0.62 over 34 mentions in the last 1h (threshold -0.30)
:rotating_light: Acme Corp: "refund" mentioned 4 times in the last 1h — "third ticket about a refund, still nothing"
:white_check_mark: Acme Corp: sentiment recovered to 0.12 (lasted 47 min)
```

### The three conditions

They answer different questions on purpose. A brand can have terrible
sentiment at a perfectly ordinary volume, a huge volume spike at neutral
sentiment, or one quiet post containing "lawsuit" that matters more than
either.

| Condition | Asks | Trips when |
| --- | --- | --- |
| **Sentiment** | *Are people unhappy?* — absolute | The mean sentiment over the window is at or below the threshold |
| **Volume** | *Is this louder than normal for this client?* — relative | Mentions reach a multiple of that client's own usual level **for this hour** |
| **Watch phrases** | *Did anyone say the word?* — literal | A mention contains one of the client's phrases, case-insensitively |

Each has a guard against firing on small numbers, because all three are
embarrassing without one: sentiment needs a minimum number of mentions
to average, volume needs an absolute floor, and volume also needs at
least two days of history before it claims to know what normal is.

### Default thresholds

A client added from the clients screen alerts sensibly with nothing
typed:

| Setting | Default | Meaning |
| --- | --- | --- |
| Window | **1 hour** | Every condition is measured over this rolling window |
| Sentiment threshold | **-0.30** | Alert when the mean sentiment is at or below this |
| Minimum mentions | **5** | ...but not until there are this many to average |
| Volume multiple | **3.0x** | Alert at three times the usual for this hour |
| Volume floor | **10** | ...but not on fewer than ten mentions |
| Watch phrases | **empty** | No phrase alerts until you add some |
| Webhook | **the global one** | Unless this client has its own |

**Watch phrases start empty deliberately.** There is no list of words
that is right for every brand — "refund" is routine for a retailer and
alarming for a SaaS — so guessing would either cry wolf or say nothing.
Good starting points: `lawsuit`, `refund`, `scam`, `fraud`, `data
breach`, `outage`, `cancel my`.

### Setting up Slack

1. Go to <https://api.slack.com/apps> and **Create New App** → *From
   scratch*. Name it (e.g. "SMM Monitor") and pick your workspace.
2. In the app's sidebar choose **Incoming Webhooks** and turn the toggle
   **On**.
3. Click **Add New Webhook to Workspace**, choose the channel the alerts
   should land in, and **Allow**.
4. Copy the webhook URL. It looks like
   `https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXX`.
   **Treat it as a secret** — anyone holding it can post to that
   channel.
5. Put it in the environment and restart:

   ```bash
   export SMM_ALERT_WEBHOOK_URL='https://hooks.slack.com/services/T00.../B00.../XXX'
   ```

   On a deployed box that goes in `/etc/smm-monitor/env` alongside the
   API credentials.

Test it without waiting for a real incident:

```bash
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"SMM Monitor webhook test"}' \
  "$SMM_ALERT_WEBHOOK_URL"
```

If that posts to the channel, alerting will too.

### One channel, or one per client?

**Both, and the per-client one wins.** The global `SMM_ALERT_WEBHOOK_URL`
covers everything by default; any client can override it from the
clients screen with a webhook of their own.

That is deliberate, because neither alone works:

* **Global only** puts every client's alerts in one channel — right for
  a small agency, and unusable the moment a channel is *shared with* a
  client, since they would see everyone else's incidents.
* **Per client only** means setting a URL on every client before any
  alerting works at all, which is a poor first five minutes.

A client with an override sends **only** there, never to both: an alert
in two channels gets acknowledged in neither.

### Configuring a client's alerts

Press **`c`** for the clients screen and move to the client with `j`/`k`.
The alert settings are the last four fields — `h`/`l` moves between
them, `e` edits:

```
  ▸ 2. Acme Corp  (acme-corp)
        name                Acme Corp
        brand terms         acme, acme corp
        subreddits          saas, startups
      › alert phrases       lawsuit, refund, scam
        alert if sentiment  at or below -0.45
        alert if volume     at or above 3.0x the usual for this hour
        slack webhook       https://hooks.slack.com/services/T00/B00/acme
```

Changes are picked up on the next evaluation, within a minute — no
restart. Leaving the webhook empty falls back to the global one.

Rejections explain themselves: sentiment runs from -1.00 to 1.00 so a
threshold outside that never changes anything, a volume multiple of 1x
or less would alert on every ordinary hour, and a webhook URL that isn't
`https://` is a typo rather than a preference.

### One alert per incident, not one per minute

A condition that stays true is **one problem, not sixty**. Each is
tracked as an incident: opened the first time it trips, kept quiet while
it keeps tripping, and closed with an all-clear when it recovers.
Exactly two messages reach the channel — *started*, and *over, lasted 47
min*.

That is the difference between a channel people read and one they mute,
and it is why this isn't a cooldown. A cooldown ("don't repeat for an
hour") is wrong in both directions: it goes quiet while a problem is
still running, and says nothing at all when the problem ends.

Clearing uses a **margin** rather than the trigger threshold, so a number
sitting on the line doesn't alert and resolve alternately for an hour.
Sentiment has to recover past the threshold by 0.05; volume has to fall
to 80% of the trigger multiple.

A genuinely new incident after a recovery alerts again immediately —
recovering is not the same as being silenced.

### Why a baseline, not a fixed number, for volume

"Alert at 20 mentions an hour" is wrong for every client at once. One
with five mentions a day would never trip it; one with five thousand
would trip it permanently. So volume is always compared against **that
client's own recent normal**.

And normal is **the same hour on previous days**, not a flat weekly
average. Brands have a daily rhythm: a flat average says a Tuesday
lunchtime and a Sunday night should look alike, so it alerts every
weekday morning and misses a genuine weekend storm.

The average only counts days that actually had mentions in that hour. A
client added yesterday has one day of history, not seven, and dividing
by seven would count days that never happened and turn an ordinary hour
into a spike.

### A volume spike is not bad news

It says *something is happening*, not *something is wrong* — a product
launch and a data breach look identical to it. The sentiment condition
is what separates them, and the volume alert carries the window's
sentiment so you can tell at a glance which one you're looking at.

### Sentiment alerts inherit the scorer's limits

> ⚠️ Sentiment is a **lexicon scorer**, not a model. It is fooled by
> sarcasm and by phrasings that aren't in the word lists — see [How
> sentiment is scored](#how-sentiment-is-scored) and the tuning section
> there. Treat a sentiment alert as "go and look", not as a measurement.

### Email is not built

Slack only, for now. Email would mean adding Swoosh, an SMTP or API
provider, a sender identity that survives SPF and DKIM, and a bounce
story — none of it hard, all of it more surface than a webhook POST, and
none of it useful if the team already lives in Slack.

If you want it, the seam is `SmmMonitor.Alerts.Notifier`: a module with
`notify/1` and `configured?/0`, added to `:alert_notifiers`. The Slack
notifier is 200 lines and an email one would be shorter.

### Turning it off

```bash
SMM_ALERTS_ENABLED=false      # the whole engine
```

Or per client, from the clients screen — a paused client isn't
evaluated at all, and a client can have alerting switched off while
still being monitored.

### Failure policy

Alerting is the last thing that should be allowed to break collection.
A failing notifier is logged and the others still run; a database that
can't answer means no baseline, which reads as "still warming up" rather
than as a reason to alert. The log notifier is always on, so an alert is
recorded somewhere even when every webhook is down.

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
running node (see **[DEPLOY.md](DEPLOY.md)**):

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

## Remote access over SSH

Anyone on the team can view the live dashboard from their own terminal,
without access to the machine it runs on:

```sh
ssh -p 2222 viewer@your-host
```

The dashboard renders in their terminal exactly as it does locally. Each
connection gets its own tab and scroll position while reading the same
underlying data, so two people can look at different platforms at the
same time.

**Remote sessions are read-only.** The config tab renders — what's being
tracked is useful context — but editing is refused with a message saying
where it can be changed. Only the host terminal can change config.

### Turning it on

Off by default; a dashboard that starts listening on a port because
someone upgraded is not a pleasant surprise.

```sh
SMM_SSH_ENABLED=true          # opens the port
SMM_SSH_PORT=2222             # default; unprivileged, so no root needed
```

On first boot it generates a host key and logs the port:

```
[info] ssh: generating a host key at ~/.local/share/smm_monitor/ssh/ssh_host_rsa_key (first boot)
[info] ssh: dashboard available on port 2222 (3 authorised key(s))
```

### Adding a team member

1. **They** generate a keypair and send you the `.pub` file:

   ```sh
   ssh-keygen -t ed25519 -C "alice@realoffice"
   cat ~/.ssh/id_ed25519.pub
   ```

2. **You** append that line to the authorized keys file:

   ```sh
   cat alice.pub >> ~/.config/smm_monitor/authorized_keys
   ```

3. They connect. **No restart needed** — the file is re-read on every
   authentication attempt, so a key works within seconds of being added.

Removing someone is the same in reverse: delete their line and their next
attempt is refused. Revocation is immediate for the same reason.

The file is an ordinary OpenSSH `authorized_keys` — one key per line,
`#` comments and blank lines ignored. Override its location with
`SMM_SSH_AUTHORIZED_KEYS`.

> **It fails closed.** A missing, unreadable or empty authorized keys file
> authorises *nobody*. "No keys configured" never means "allow everyone".

### The host key

Generated once on first boot and kept at
`~/.local/share/smm_monitor/ssh/` (override with `SMM_SSH_HOST_KEY_DIR`).

It must stay stable: clients pin it in `known_hosts` on first connection,
and a key that rotated every restart would greet everyone with `REMOTE
HOST IDENTIFICATION HAS CHANGED` and refuse to connect. It's generated
with Erlang's own crypto, so `ssh-keygen` doesn't need to be installed on
the server, and written `0600` in a `0700` directory.

### Security

**Traffic is encrypted.** This is a real SSH server (Erlang's `:ssh`), so
the transport gets the same encryption, integrity and host-key
verification as any other SSH connection.

**Only the dashboard is exposed.** Shell, exec and SFTP are all disabled
in the daemon options — a connecting client can draw the dashboard and
nothing else. There is no way to get a command prompt through this port.
Password authentication is never offered; a public key is the only way
in.

**What a viewer can see:** every client, every mention collected, the brand terms and
subreddits being tracked, and each platform's mock/live mode. **What they
cannot see:** any API credential — those live in the environment and are
never rendered.

#### Is it safe to expose publicly?

**Put it behind a VPN or a firewall.** Not because of a known weakness,
but because the honest risk assessment is:

* The authentication itself is sound — Erlang's `:ssh` with public-key
  auth, no passwords, no shell.
* But this is a hobby-scale service exposed to the internet. It has had
  nowhere near the scrutiny OpenSSH has, it has no fail2ban-style
  throttling, no connection rate limiting, and no audit logging beyond a
  line per connection.
* An unauthenticated attacker reaching the port can attempt key auth
  indefinitely.

For a team dashboard, the sensible shape is: bind it on a private
network, and reach it over your existing VPN or an SSH tunnel through a
host you already trust:

```sh
ssh -L 2222:localhost:2222 you@bastion   # then: ssh -p 2222 viewer@localhost
```

If you do open it, the firewall rule is **inbound TCP on
`SMM_SSH_PORT`** (2222 by default) — and restrict the source range to
your office or VPN rather than `0.0.0.0/0`.

## Stored history

Mentions are written to a SQLite database as they arrive, so history
survives a restart. **ETS is still the only read path** — the database is
a durable log alongside it, never in front of it.

The dashboard reads from ETS exactly as it always did; a mention's journey
to disk is a `cast` that nothing waits on. Measured under a sustained
write load of 4,000 mentions, `Monitor.recent(:all, 200)` had a median
latency of **138µs with persistence on and 138µs with it off** — the read
path genuinely doesn't know the database exists.

On boot the most recent 200 mentions per platform are loaded back into
ETS, so the dashboard has history immediately rather than looking like a
fresh install until the first poll lands.

### Where the database lives

`~/.local/share/smm_monitor/mentions.db` (honouring `XDG_DATA_HOME`), or
wherever `SMM_DB_PATH` points. **No manual setup or migration step** — the
file is created and migrated on first boot:

```
[info] database: applied 1 migration(s)
```

Not under `priv/`, for the same reason the config file isn't:
`:code.priv_dir/1` resolves to the *build* copy, so `mix clean` would
silently delete months of collected history. History that survives a
restart but not a rebuild isn't really durable.

### Retention

Mentions published more than **30 days** ago are deleted once every 24
hours. Change the window with `SMM_RETENTION_DAYS`.

The first pass runs 30 seconds after boot rather than a day later, so an
instance that has been off for a while tidies up when it comes back
instead of carrying stale rows until its first anniversary. Retention is
keyed on when a mention was *published*, not when it was stored, so
backfilling old history doesn't earn it another 30 days.

### Disk space

About **230 bytes per mention** once settled (measured, not estimated).
At a 30-day window that reaches a steady state of roughly:

| Volume | 30-day steady state |
| --- | --- |
| 500 mentions/day | ~3 MB |
| 2,000/day | ~13 MB |
| 10,000/day | ~66 MB |
| 50,000/day | ~330 MB |

Two things worth knowing:

* **WAL files.** Journalling is set to WAL, so you'll see `mentions.db-wal`
  and `mentions.db-shm` alongside the database. The `-wal` file can be
  larger than the database itself between checkpoints; it's checkpointed
  automatically and on a clean shutdown, and it is not lost data.
* **Deleting rows doesn't shrink the file.** SQLite reuses freed pages, so
  the file settles at its high-water mark rather than shrinking after a
  prune. That's fine at steady state — space is reused, not leaked — but
  if you cut `SMM_RETENTION_DAYS` sharply and want the space back, run
  `VACUUM` against the file once.

### Why Ecto rather than raw exqlite

`ecto_sqlite3` uses `exqlite` as its driver, so this isn't a choice
against exqlite — exqlite still does the work. Ecto earns its four extra
dependencies here for two reasons: `Ecto.Migrator` gives versioned,
idempotent migrations, which is exactly what "no manual migration step"
requires, and `DBConnection` pooling makes it safe for the writer, the
boot loader and the retention job to touch the database from three
different processes. Raw exqlite would be the better call for a single
throwaway query; for a durable log with a schema that will change, this
is the standard path.

### What happens if the database is unavailable

Every query degrades rather than raises. A missing, locked or corrupt
database costs you history, not your dashboard — the app falls back to
exactly what it was before persistence existed: an in-memory view.
Migration failures, write failures and read failures are each logged and
carried on from.

## Live data

Everything runs on fixtures until you say otherwise. **Reddit and YouTube
have live implementations**; Twitter and Instagram are fixture-backed.
Each platform is switched on independently, so turning one live leaves the
others exactly as they were.

### Getting Reddit API credentials

Reddit's "script" app type is free and needs no approval wait.

1. Sign in to Reddit and go to <https://www.reddit.com/prefs/apps>.
2. Scroll to the bottom and click **"are you a developer? create an app…"**
   (or **"create another app…"**).
3. Fill in the form:
   - **name** — anything, e.g. `smm-monitor`
   - **type** — choose **script**. This is the important one: `script` is
     what enables the `client_credentials` grant with no user, no redirect
     and no review.
   - **description** / **about url** — optional, leave blank
   - **redirect uri** — required by the form but unused by this grant.
     `http://localhost:8080` is fine.
4. Click **create app**. You'll land on the app's detail box.
5. Read the two values off that box:
   - **client id** — the short string directly under the app's name, just
     below the words *"personal use script"*. It is *not* labelled.
   - **client secret** — the field explicitly labelled **secret**.

Both belong to your Reddit account, so treat the secret like a password.
Rate limits are counted per client id: 60 requests/minute.

### Setting the environment variables

```sh
cp .env.example .env
```

Then edit `.env` and set these four:

```sh
SMM_MOCK_REDDIT=false                       # the switch that turns Reddit live
REDDIT_CLIENT_ID=your_client_id
REDDIT_CLIENT_SECRET=your_client_secret
REDDIT_USER_AGENT=smm_monitor/0.1 (by /u/yourusername)
```

Load them into your shell and start the dashboard:

```sh
set -a; source .env; set +a
mix smm.tui
```

For YouTube, add:

```sh
SMM_MOCK_YOUTUBE=false                      # the switch that turns YouTube live
YOUTUBE_API_KEY=your_api_key
SMM_YOUTUBE_POLL_INTERVAL_MS=1080000        # 18 min — see the quota section
```

The status line at the bottom of the dashboard shows each worker's actual
mode — with both live you should see `reddit:live youtube:live
twitter:mock instagram:mock`.

`.env` is gitignored. Credentials are read in `config/runtime.exs`, which
runs on every boot (including from a release), so nothing is hardcoded and
nothing is committed.

> **On the user agent:** Reddit rejects requests with a generic or empty
> user agent, and asks that you identify yourself. Including your Reddit
> username is the convention.

### Switching between mock and live

There are two switches. The per-platform one wins:

| Setting | Effect |
| --- | --- |
| *(nothing set)* | Everything mocked. This is the default. |
| `SMM_MOCK_REDDIT=false` | Reddit live, everything else mocked. |
| `SMM_MOCK_TWITTER=false` | Twitter/X live, everything else mocked. |
| Several of the above | Exactly those platforms live, the rest mocked. |
| `SMM_MOCK_REDDIT=true` | Reddit mocked, even with credentials set. |
| `SMM_MOCK_MODE=false` | Global default flips to live. Any platform whose credentials are missing still serves fixtures. |

A per-platform flag unset means *"inherit `SMM_MOCK_MODE`"*, not *"go
live"* — so you can't accidentally start hitting an API by never setting
it. All four platforms are independent: turning YouTube on has no effect
on Reddit, Twitter or Instagram.

**A platform without credentials keeps serving mock data** rather than
failing. Set `SMM_MOCK_REDDIT=false` but forget the client secret — or
`SMM_MOCK_TWITTER=false` with no bearer token — and you'll get fixtures
plus one clear warning in the log:

```
[warning] reddit is configured for live data but its credentials are
missing or incomplete - falling back to mock data. See the README for the
environment variables this platform needs.
```

That's deliberate: a missing key should degrade one tab, not empty the
dashboard or crash the app.

### What Reddit gets asked

Each poll is **one** HTTP request. The configured subreddits are combined
into a single multireddit search (`/r/marketing+smallbusiness/search`)
rather than one request per subreddit, so watching twenty subreddits costs
the same quota as watching one.

Search terms come from `SMM_KEYWORDS`; multi-word terms are quoted as
phrases, and terms are OR-ed together. `SMM_KEYWORDS=realoffice,real office`
becomes `realoffice OR "real office"`.

At the default 30-second poll interval that's 2 requests/minute against a
60/minute budget. The fetcher tracks the quota Reddit reports on every
response and stops five requests short of the limit, so a burst from
something else sharing the credentials can't push you into a hard 429.

### Getting a YouTube API key

YouTube Data API v3 uses a plain API key — no OAuth, because the data is
public.

1. Go to the [Google Cloud Console](https://console.cloud.google.com/) and
   create a project (or pick an existing one).
2. **Enable the API**: *APIs & Services → Library*, search for
   **"YouTube Data API v3"**, open it, click **Enable**. This step is easy
   to skip and the key won't work without it — you'll get a 403 with
   reason `accessNotConfigured`.
3. **Create the key**: *APIs & Services → Credentials → Create Credentials
   → API key*. Copy the key it shows you.
4. **Restrict it** (optional but worth doing): click the new key → under
   *API restrictions* choose **Restrict key** and select *YouTube Data API
   v3*. An unrestricted key that leaks can be used against any Google API
   enabled on the project.

There is no approval wait and no billing account needed for the free tier.

If the key is wrong or the API isn't enabled, you'll see it in the log
rather than having to guess:

```
[warning] youtube fetch failed: {:invalid_api_key, "API key not valid.
Please pass a valid API key."}
```

### Quota: the thing that actually constrains YouTube

This is the part worth reading before you set a poll interval.

The free tier is **10,000 quota units per day**, and a `search.list` call
costs **100 units**. So the real allowance is **100 searches per day** —
and that is the binding constraint on everything else.

SMM Monitor budgets **8,000 units** (80 searches) by default, leaving 20%
in reserve for anything else using the same key. Once the budget is spent
it stops polling until the quota resets and logs why:

```
[warning] youtube: daily quota budget spent (8000/8000 units used today
(0 searches left)). Pausing polling for 312 minutes, until the quota
resets at midnight Pacific.
```

Work out an interval from the budget:

| Interval | Calls/day | Units/day | Result |
| --- | --- | --- | --- |
| 5 min *(default)* | 288 | 28,800 | Budget gone after **~6.7 hours**, dark until the reset |
| 10 min | 144 | 14,400 | Dark after ~13 hours |
| 15 min | 96 | 9,600 | Dark after ~20 hours |
| **18 min** | **80** | **8,000** | **Covers a full day** |
| 30 min | 48 | 4,800 | Comfortable, half the budget unused |

The 5-minute default gives you a responsive dashboard for a working
morning and then nothing. **If you want all-day coverage, set 18 minutes
or slower:**

```sh
SMM_YOUTUBE_POLL_INTERVAL_MS=1080000   # 18 minutes
```

The app tells you this at startup if your interval can't sustain a day:

```
[warning] youtube: polling every 5 min needs 28800 quota units/day but the
budget is 8000. Coverage will stop after about 6.7h each day. Set
SMM_YOUTUBE_POLL_INTERVAL_MS to 1080000 (18 min) for full-day coverage.
```

Two details worth knowing. The quota resets at **midnight Pacific**, not
UTC or your local midnight — that's Google's boundary, not ours. And
Google doesn't report remaining quota in response headers, so our count is
an estimate; it can't see usage from anything else sharing the key. That's
what the 2,000-unit reserve is for. If Google says the quota is gone
before our own count does, we believe Google and stand down.

### Why `search.list` and not `commentThreads.list`

`search.list` is the only endpoint that can **discover** a mention.

`commentThreads.list` is far cheaper (1 unit against search's 100) and
comments are honestly where brand chatter lives. But it can only read
comments on a video or channel *you already name* — its `searchTerms`
parameter filters within those. It cannot answer "who mentioned us
anywhere on YouTube today", which is the question this tool exists to
answer. Using it alone would mean maintaining a hand-curated list of
videos to watch, and you'd miss every new one.

So: `search.list` for discovery, bounded to recently published videos via
`publishedAfter` so each poll only sees what's new.

**The natural next step is a hybrid** — keep `search.list` for discovery,
then spend 1 unit per discovered video on `commentThreads.list` to pull
the discussion underneath it. Twenty videos of comments would cost 20
units against search's 100, so it's cheap. It's a real feature rather than
a tweak, so it isn't built yet.

### What YouTube gets asked

One `search.list` call per poll, for videos matching the shared
`SMM_KEYWORDS` terms (joined with YouTube's `|` OR syntax, phrases
quoted), ordered by date, published within the last 24 hours. The channel
title becomes the mention's author, the video title and description become
its text.

### Getting an X (Twitter) API bearer token

Recent search needs a **paid tier**. The free tier can post but cannot
read search results, so there is no free path to this data — budget for
it before wiring it up.

1. Go to <https://developer.x.com/en/portal/dashboard> and sign in with
   the account that will own the integration.
2. Create a **Project** (not just an App). Recent search is a v2
   endpoint, and v2 endpoints only work with keys attached to a Project —
   a standalone App returns 403 no matter how valid its token is.
3. Inside the Project, create an **App**.
4. Subscribe the Project to a paid tier. Basic is the cheapest that
   includes `/2/tweets/search/recent`.
5. Open the App's **Keys and tokens** tab and generate a **Bearer
   Token**. Copy it immediately — the portal shows it once, and
   regenerating invalidates the old one.

That token is the whole credential: app-only auth, no user context, no
refresh flow, nothing to cache. Treat it like a password.

```bash
export TWITTER_BEARER_TOKEN='AAAAAAAAAAAAAAAAAAAAA...'
export SMM_MOCK_TWITTER=false
```

### X's two limits, and why they're tracked differently

X bounds recent search twice, and confusing the two is how an
integration goes dark for three weeks:

| Limit | Reported? | How it's handled |
| --- | --- | --- |
| **Requests per 15 minutes** | Yes — `x-rate-limit-*` headers | Read from every response; backs off before the window empties, waiting exactly until the reset |
| **Posts per month** (the Project's post cap) | **No header at all** | Counted locally against a conservative budget, like YouTube's quota |

The monthly cap is the one that ends a month early. Nothing in a
response says how close it is, so `SMM_TWITTER_MONTHLY_POST_BUDGET`
holds a self-imposed ceiling — **10,000 by default, deliberately low**.
Set it to what your plan actually allows:

```bash
export SMM_TWITTER_MONTHLY_POST_BUDGET=50000
# If your billing cycle doesn't start on the 1st:
export SMM_TWITTER_BILLING_CYCLE_DAY=12
```

Standing down early costs coverage that this one variable fixes.
Overrunning the cap costs the rest of the month, so the default errs the
recoverable way. The real figure is at `GET /2/usage/tweets` in the
developer portal — worth checking after the first week and setting the
budget from what you see.

Two things keep the spend down without any tuning: the query excludes
retweets (500 retweets of one complaint would read as 500 complaints
*and* cost 500 posts), and the counter charges for posts actually
returned rather than the page size requested.

### What X gets asked

One `GET /2/tweets/search/recent` per poll, for the shared
`SMM_KEYWORDS` terms OR-ed together with phrases quoted, minus retweets,
over the last 7 days. Author handles come back through the `author_id`
expansion. A tweet whose author is missing from that expansion — a
deleted or protected account — still becomes a mention under `@unknown`,
because the text is the point.

Polling defaults to 5 minutes rather than 30 seconds, since the monthly
cap rather than the 15-minute window is what this platform runs out of.
`SMM_TWITTER_POLL_INTERVAL_MS` overrides it.

### Getting Instagram Graph API access

More setup than the others, because Meta scopes everything to an account
you control:

1. The Instagram account must be a **Business or Creator** account, not
   personal. (Instagram app → Settings → Account type.)
2. It must be **linked to a Facebook Page** you administer. (Page →
   Settings → Linked accounts → Instagram.)
3. Create an app at <https://developers.facebook.com/apps> — type
   **Business** — and add the **Instagram Graph API** product to it.
4. In **Graph API Explorer**, select your app, then generate a User
   Access Token with these permissions: `instagram_basic`,
   `instagram_manage_comments`, `pages_show_list` and
   `pages_read_engagement`.
5. **Exchange it for a long-lived token.** The token the Explorer gives
   you expires in about an hour:

   ```bash
   curl -s "https://graph.facebook.com/v21.0/oauth/access_token\
   ?grant_type=fb_exchange_token\
   &client_id=<APP_ID>\
   &client_secret=<APP_SECRET>\
   &fb_exchange_token=<SHORT_LIVED_TOKEN>"
   ```

6. **Find the Instagram Business Account ID** — not the username, and
   not the Facebook Page id:

   ```bash
   # The Page linked to the Instagram account:
   curl -s "https://graph.facebook.com/v21.0/me/accounts?access_token=<TOKEN>"

   # Then, with that Page's id:
   curl -s "https://graph.facebook.com/v21.0/<PAGE_ID>\
   ?fields=instagram_business_account&access_token=<TOKEN>"
   ```

   The `instagram_business_account.id` in that response — a 17-digit
   number beginning `1784…` — is what goes in the env var.

7. Going beyond your own test accounts needs **App Review** for those
   permissions. In development mode the app works for accounts with a
   role on it, which is enough to monitor your own brand.

```bash
export INSTAGRAM_ACCESS_TOKEN='EAAG...'
export INSTAGRAM_BUSINESS_ACCOUNT_ID='17841400000000000'
export SMM_MOCK_INSTAGRAM=false
```

⚠️ **Long-lived tokens expire after 60 days.** Refresh before then, or
Instagram silently stops returning data. The fetcher detects this
specific failure and logs `expired_access_token` rather than a generic
400, because a 60-day clock that fails quietly is worth naming.

### What Instagram monitoring can and cannot see

**Read this before trusting the Instagram tab.**

Reddit, YouTube and X all answer the question this tool exists to ask:
*who mentioned this brand anywhere on the platform?* **Instagram does
not.** There is no endpoint in the Graph API — at any tier, for any
amount of money — that takes a keyword and returns public posts
containing it. Instagram removed that capability years ago and has not
replaced it.

So Instagram monitoring here is **not** brand-wide search. It is three
narrow, account-scoped views, and you choose which ones to poll:

| Source | What it sees | Limits |
| --- | --- | --- |
| `tags` *(default)* | Posts by other people that **@-tag your account** in the media | Only posts where they actually tagged you |
| `comments` *(default)* | Comments on **your own** posts | Your posts only; bounded by `:media_limit` |
| `hashtag` *(opt-in)* | Public posts carrying a **tracked hashtag** | 30 unique hashtags per rolling 7 days; last 24 hours only; **no author** |

What **none** of them sees:

- **Someone writing "realoffice is broken" in a caption without tagging
  you.** Meta delivers @-mentions in other people's captions and
  comments *only by webhook* — a push to a public HTTPS endpoint. There
  is no pull equivalent, so a polling tool on a private box cannot
  retrieve them. Not implemented here, and not implementable without a
  public callback URL.
- **Stories, Reels-only mentions, or private accounts.** Out of scope
  for these edges.
- **Who posted a hashtag result.** Meta strips usernames from hashtag
  search — no personally identifying information is returned — so those
  mentions are attributed to `#realoffice` rather than to a person. That
  is honest; `@unknown` would imply we looked and failed.

Practically: **Instagram will under-report** compared to the other three
platforms, and a quiet Instagram tab means "nobody tagged us", not
"nobody mentioned us". If Instagram coverage is commercially important,
the honest options are Meta's webhooks (a public endpoint plus App
Review) or a third-party listening vendor with its own crawl — not a
setting in this app.

Turn the hashtag source on if you want the widest coverage the API
allows:

```bash
export SMM_INSTAGRAM_SOURCES=tags,comments,hashtag
export SMM_INSTAGRAM_HASHTAGS=realoffice,realofficeapp
```

Keep that hashtag list **short and stable**: Meta counts 30 *unique*
hashtags per rolling 7 days per account, and editing the list churns
through that budget. Hashtag ids are cached in the worker between polls,
since they never change.

### What Instagram gets asked

Per poll, one request per enabled source: `/{account-id}/tags`,
`/{account-id}/media` with the comments nested via field expansion (one
request, not one per post), and for hashtags an `ig_hashtag_search`
lookup — cached after the first — plus one `recent_media` call per tag.

Meta reports rate limiting as a **percentage of an opaque hourly
allowance** in `x-business-use-case-usage`, not as a count of requests
left. The fetcher backs off at 90%, because the percentage arrives on
the response *after* the call that caused it.

Each source runs independently. Meta's permissions are granular, and a
token that reads tags often cannot read comments — so one source failing
is logged and the others still return mentions. Only a poll where every
source failed counts as an error.

### Environment variables

| Variable | Used by |
| --- | --- |
| `SMM_MOCK_MODE` | Global switch; `true` (default) forces fixtures everywhere |
| `SMM_MOCK_REDDIT` | Per-platform override for Reddit. Unset inherits the global. |
| `SMM_MOCK_YOUTUBE` | Per-platform override for YouTube. Unset inherits the global. |
| `SMM_MOCK_TWITTER` | Per-platform override for Twitter/X. Unset inherits the global. |
| `SMM_MOCK_INSTAGRAM` | Per-platform override for Instagram. Unset inherits the global. |
| `SMM_KEYWORDS` | Comma-separated brand terms — used only to seed the first client on a fresh install |
| `SMM_CONFIG_FILE` | The legacy single-brand config file, read once on upgrade to seed the first client |
| `SMM_SSH_ENABLED` | Serve the dashboard over SSH (default false) |
| `SMM_SSH_PORT` | Port to listen on (default 2222) |
| `SMM_SSH_AUTHORIZED_KEYS` | Public keys allowed to connect |
| `SMM_SSH_HOST_KEY_DIR` | Where the server's host key is kept |
| `SMM_DB_PATH` | Where collected mentions are stored |
| `SMM_RETENTION_DAYS` | How long mentions are kept on disk (default 30) |
| `SMM_HISTORY_LIMIT` | Mentions per platform restored on boot (default 200) |
| `SMM_SENTIMENT_DIR` | Directory of word lists that override the packaged ones |
| `SMM_ALERT_WEBHOOK_URL` | Global Slack incoming webhook for alerts |
| `SMM_ALERTS_ENABLED` | Set `false` to switch the alert engine off entirely |
| `SMM_ALERT_BASELINE_DAYS` | Days of same-hour history behind the volume baseline (default 7) |
| `SMM_REPORTS_DIR` | Where generated reports are written (default: `reports` beside the database) |
| `SMM_WEEKLY_REPORTS` | Set `true` to write a weekly report per active client (default false) |
| `SMM_WEEKLY_REPORT_DAY` | Day of the week to write them, 1 = Monday (default 1) |
| `SMM_WEEKLY_REPORT_HOUR` | Hour of that day, UTC (default 7) |
| `SMM_POLL_INTERVAL_MS` | Poll interval per platform (default 30000) |
| `SMM_REDDIT_SUBREDDITS` | Comma-separated subreddits to watch. Empty searches all of Reddit. |
| `REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET` / `REDDIT_USER_AGENT` | Reddit **(live)** |
| `SMM_YOUTUBE_POLL_INTERVAL_MS` | YouTube's own poll interval (default 300000 = 5 min) |
| `SMM_YOUTUBE_DAILY_QUOTA_BUDGET` | Units to spend per day before standing down (default 8000) |
| `YOUTUBE_API_KEY` | YouTube **(live)** |
| `TWITTER_BEARER_TOKEN` | Twitter/X **(live)** |
| `SMM_TWITTER_MONTHLY_POST_BUDGET` | Posts to spend per cycle before standing down (default 10000) |
| `SMM_TWITTER_BILLING_CYCLE_DAY` | Day of month the post cap resets (default 1) |
| `SMM_TWITTER_POLL_INTERVAL_MS` | Twitter's own poll interval (default 300000 = 5 min) |
| `INSTAGRAM_ACCESS_TOKEN` | Instagram **(live)** |
| `INSTAGRAM_BUSINESS_ACCOUNT_ID` | The 17-digit IG Business account id (`INSTAGRAM_USER_ID` also accepted) |
| `SMM_INSTAGRAM_SOURCES` | Which sources to poll: `tags,comments,hashtag` (default `tags,comments`) |
| `SMM_INSTAGRAM_HASHTAGS` | Hashtags to search if `hashtag` is enabled (default: the brand keywords) |
| `SMM_INSTAGRAM_POLL_INTERVAL_MS` | Instagram's own poll interval (default 900000 = 15 min) |

## What each platform actually gives you

All four platforms run on live APIs, with mock data as a fallback rather
than a default state. What differs is **how much of the platform each
one can see**, which matters more than whether the code is written:

| Platform | Coverage | How it works |
| --- | --- | --- |
| **Reddit** | **Platform-wide search.** Any post matching the brand terms. | OAuth2 script app, `client_credentials` grant, multireddit `/search` sorted by new. Token cached and refreshed before expiry; rate limit read from Reddit's headers. Free tier. |
| **YouTube** | **Platform-wide search** of video titles and descriptions. Comments are not searched — see below. | Data API v3 `search.list` with an API key. Daily quota tracked against a budget; stands down when spent. Free tier. |
| **Twitter/X** | **Platform-wide search**, last 7 days, retweets excluded. | v2 `/2/tweets/search/recent` with an app-only bearer token. Two limits tracked separately: the 15-minute window from headers, the monthly post cap locally. **Paid tier required.** |
| **Instagram** | **Not brand-wide.** Only posts that tag your account, comments on your own posts, and (opt-in) public posts carrying a tracked hashtag. | Graph API, scoped to one Business account. The Graph API has no keyword search at any tier — see [What Instagram monitoring can and cannot see](#what-instagram-monitoring-can-and-cannot-see). |

Every platform independently falls back to fixtures when its credentials
are missing, and says so in the log. So a half-configured install shows
real Reddit data next to fixture Instagram data rather than an empty
dashboard or a crash — and `SMM_MOCK_MODE=true` (the default) serves
fixtures everywhere, which is what makes the app runnable with no
credentials at all.

**Coverage is uneven, on purpose.** Reddit, YouTube and X answer "who
mentioned us anywhere?"; Instagram answers "who tagged us, and what did
people say on our own posts?". A quiet Instagram tab does not mean
nobody is talking about the brand there.

## Architecture

Three layers, each supervised independently:

```
SmmMonitor.Supervisor                    (one_for_one)
├── SmmMonitor.Repo                      SQLite: clients and the mention log
├── SmmMonitor.Persistence.Migrator      migrates on boot, then :ignore
├── SmmMonitor.Persistence.Writer        off-critical-path writes
├── SmmMonitor.Persistence.Retention     daily prune
├── SmmMonitor.Clients                   the clients being monitored
├── SmmMonitor.Processing.Processor      ETS owner, scoring, aggregation
├── SmmMonitor.Alerts                    sentiment, volume and phrase alerting
├── SmmMonitor.SSH.Server                remote dashboard, when enabled
├── SmmMonitor.Fetchers.Supervisor       (one_for_one)
│   ├── PlatformSupervisor(:reddit)    → Worker(:reddit)
│   ├── PlatformSupervisor(:youtube)   → Worker(:youtube)
│   ├── PlatformSupervisor(:twitter)   → Worker(:twitter)
│   └── PlatformSupervisor(:instagram) → Worker(:instagram)
└── Ratatouille.Runtime.Supervisor       only when the TUI is enabled
```

**Fetching.** One GenServer per platform, each under its *own* supervisor.
That's the whole point of the layer: if the YouTube worker crashes in a
loop, the restarts are counted against its supervisor alone. Reddit keeps
polling and the dashboard keeps rendering. Workers schedule the next poll
*after* finishing the current one (`Process.send_after/3`), so a slow API
can never stack polls on top of each other. An expected `{:error, reason}`
is logged and retried; an unexpected exception is left to crash the worker
so its supervisor can restart it clean.

Each worker also carries its platform's own state between polls — for
Reddit, the cached OAuth token and the rate-limit quota. That state lives
in the worker's GenServer state, so a crashing platform restarts with a
clean token and can't corrupt anyone else's. A fetcher that fails with
`{:rate_limited, ms}` pushes its next poll out by at least that long:
backing off is the fetcher's decision to make and the worker's to enforce.

**Clients.** One GenServer holding the clients being monitored, each with
its own brand terms and subreddits. Application env is the right home for
settings fixed at boot — credentials, intervals, quota budgets — but it
isn't meant to be written to at runtime, so these live in SQLite with a
cached copy here. It's the single source of truth: fetchers read the
client list on every poll, which is what makes an edit land on the next
poll rather than the next restart. Started after the repo it reads from
and before the fetchers that read from it.

Which client a viewer is *looking at* is deliberately not here — that is
per-session state in the TUI model, so two SSH sessions can watch
different clients without fighting over a shared selection.

**Persistence.** SQLite via Ecto, kept strictly off the read path. The
processor hands newly-inserted mentions to `Persistence.Writer` with a
cast and carries on; a whole poll arrives as one message and goes in as
one `insert_all`, so batching comes for free without a flush timer. The
`Migrator` is a supervision-tree child that does its work in
`start_link/1` and returns `:ignore` — the point is timing, since a
supervisor waits for each child's `start_link` to return, guaranteeing
the table exists before the processor queries it. A `Task` would return
as soon as it was spawned.

**Alerts.** `Alerts.Detector` holds the judgement and is pure — numbers
in, verdict out — so every threshold decision is testable without waiting
for a real spike. The `Alerts` GenServer holds the clock, the cooldowns
and the notifier fan-out. The current window is read from ETS (cheap, and
an hour is well inside its retention); the baseline comes from SQLite,
because that is the only place that knows what a week looks like.

**SSH.** `Garnish` serves the same dashboard to remote terminals, one
channel process per session. Garnish is a fork of Ratatouille adapted for
SSH, and its `Garnish.App` behaviour is *not* `Ratatouille.App` — it has
`handle_key/2` instead of `update/2`, no `subscribe/1` (so the refresh
tick is ours), and terminfo mnemonics instead of termbox constants. None
of that reached `TUI.Model`: keeping the dashboard's behaviour free of
any TUI library is what made SSH support a new renderer and a thin
adapter rather than a rewrite. The layout itself is shared with the local
renderer via `TUI.Renderers.Common`.

**Processing.** One GenServer with a narrow job: score sentiment,
de-duplicate, store, prune. It doesn't fetch and it doesn't render. Writes
go through it (serialised, so de-duplication stays consistent); reads go
straight to ETS from the caller's process, so the TUI's 1s refresh never
queues behind it. `SmmMonitor.Monitor` is the public API — nothing outside
it needs to know mentions live in ETS.

**TUI.** Elm Architecture, split three ways so only the smallest piece is
tied to Ratatouille:

* `TUI.Model` — every state transition, with no reference to any TUI
  library. Takes normalised keys (`{:char, ?r}`) rather than event structs
  and exposes plain data. This is where the behaviour lives, and it's
  testable with no terminal.
* `TUI.Renderer` — the behaviour a drawing layer implements.
* `TUI.Renderers.RatatouilleRenderer` — the only Ratatouille-aware module.
* `TUI.App` — a thin adapter between the runtime and the two above.

Swapping Ratatouille (for TermUI, say) means writing one new renderer and
pointing `config :smm_monitor, :renderer` at it. The model doesn't change.

The TUI is **not** in the supervision tree by default — it takes over the
terminal, and `mix test` shouldn't have to fight it for stdout.

## Adding a platform

Two steps. First, the module:

```elixir
defmodule SmmMonitor.Fetchers.Mastodon do
  use SmmMonitor.Fetchers.Fetcher, platform: :mastodon, display_name: "Mastodon"

  @impl true
  def ready?(context), do: is_binary(context.credentials[:access_token])

  # Optional: anything to carry between polls (a token, a cursor).
  @impl true
  def init_state(_context), do: nil

  @impl true
  def fetch(context, state) do
    # Call the API, then map onto SmmMonitor.Mention.new/1 attrs:
    #   %{id:, platform:, author:, text:, url:, timestamp:}
    # Keep the mapping in a public parse/1 so it's testable without HTTP.
    {:ok, mentions, state}
  end
end
```

Then the config in `config/config.exs`:

```elixir
config :smm_monitor, :platforms,
  # ...
  mastodon: [module: SmmMonitor.Fetchers.Mastodon, enabled: true, opts: []]
```

That's it. `use`-ing the behaviour gives you a fixture-backed
`mock_fetch/1`, so the platform shows up in the dashboard *before* the API
work is done. The supervisors build their children from config, so no
supervisor needs editing. Add credentials to `config/runtime.exs` and
`.env.example` if the platform needs them.

The one place that isn't automatic: `TUI.Model`'s tab shortcuts are a fixed
map (`a`/`t`/`i`/`r`/`y`) — pick a free letter and add it there.

## Testing

```sh
mix test
```

The suite covers the processing and aggregation logic, mention parsing for
all four platforms, the TUI model's state transitions, and the supervision
isolation property (kill a worker, check its sibling is untouched and the
stored mentions survive). Rendering itself isn't tested — that needs a
terminal.

**Nothing in the suite touches the network**, including the Reddit tests:

* Parsing runs against `test/fixtures/reddit_search.json`, a payload
  mirroring Reddit's documented `Listing` / `t3` shape. To replace it with
  a response captured from your own account, grab a token and save a real
  search:

  ```sh
  TOKEN=$(curl -s -X POST \
    -u "$REDDIT_CLIENT_ID:$REDDIT_CLIENT_SECRET" \
    -d grant_type=client_credentials \
    -A "$REDDIT_USER_AGENT" \
    https://www.reddit.com/api/v1/access_token | jq -r .access_token)

  curl -s -H "Authorization: Bearer $TOKEN" -A "$REDDIT_USER_AGENT" \
    "https://oauth.reddit.com/r/marketing/search?q=yourbrand&sort=new&limit=5&raw_json=1" \
    > test/fixtures/reddit_search.json
  ```

  The parse tests assert on specific post ids, so they'll need updating to
  match whatever you capture.

* The auth, rate-limit and full-fetch tests use a stub Req adapter
  (`test/support/reddit_stub.ex`), which scripts responses per request kind
  so a test can say "401 first, then 200".

* YouTube works the same way: `test/fixtures/youtube_search.json` for
  parsing and `test/support/youtube_stub.ex` for the fetch path. **No test
  spends a quota unit.** To capture a fresh payload from your own key:

  ```sh
  curl -s "https://www.googleapis.com/youtube/v3/search?part=snippet\
&q=yourbrand&type=video&order=date&maxResults=5&key=$YOUTUBE_API_KEY" \
    > test/fixtures/youtube_search.json
  ```

  That costs 100 units. The parse tests assert on specific video ids, so
  they'll need updating to match whatever you capture.

Tests run with `start_fetchers: false` and `start_tui: false`, so they get
the processing layer and nothing else: no 30s polls racing assertions.
`:config_file` and the database both point at `tmp/`, so a test can never
write over a real config or real collected history. Persistence tests run
in a sandboxed transaction that is rolled back afterwards.

## Configuration reference

Compile-time defaults live in `config/config.exs`:

| Key | Default | Meaning |
| --- | --- | --- |
| `:keywords` | `["realoffice", "real office"]` | Brand terms to search for |
| `:poll_interval_ms` | `30_000` | Per-platform poll interval |
| `:window_ms` | 24h | Window the dashboard's counters cover |
| `:retention_ms` | 48h | Age at which mentions are pruned |
| `:max_mentions` | `2_000` | Hard cap on stored rows |
| `:mock_mode` | `true` | Serve fixtures instead of calling APIs |
| `:mock_platforms` | `[]` | Per-platform overrides of `:mock_mode` |
| `:start_fetchers` | `true` | Whether the tree starts the fetching layer |
| `:start_tui` | `false` | Whether the tree starts the dashboard |
| `:renderer` | `RatatouilleRenderer` | The TUI drawing layer |
| `:config_file` | per-user path | Where runtime-editable settings are saved |
| `:db_retention_days` | `30` | How long mentions are kept on disk |
| `:history_limit` | `200` | Mentions per platform restored on boot |
| `:sentiment` | see above | Scoring weights, bands and windows |
| `:sentiment_dir` | unset | Directory of overriding word lists |
| `:alerts_enabled` | `true` | Whether the alert engine runs |
| `:alert_baseline_days` | `7` | Days of same-hour history behind the volume baseline |
| `:alert_notifiers` | log + Slack | Channels an alert is sent to |
| `:weekly_reports_enabled` | `false` | Whether the weekly report scheduler runs |
| `:weekly_report_day` / `:weekly_report_hour` | `1` / `7` | When the weekly pass runs, UTC |
| `:reports_dir` | unset | Where reports are written; overridden by `SMM_REPORTS_DIR` |
| `:ssh_enabled` | `false` | Whether the SSH server starts |
| `:ssh_port` | `2222` | Port the SSH server listens on |
| `:start_persistence` | `true` | Whether the tree starts the repo and migrator |
| `:persist_writes` | `true` | Whether mentions are written to disk |
| `SmmMonitor.Fetchers.Twitter` | see above | Page size, monthly post budget, billing cycle day |
| `SmmMonitor.Fetchers.Instagram` | see above | Which sources to poll, hashtags, page sizes |
| `:platforms` | four entries | Platform → module, enabled flag, opts |

Reddit has its own block, since these are deployment choices rather than
app-wide ones:

```elixir
config :smm_monitor, SmmMonitor.Fetchers.Reddit,
  subreddits: ["smallbusiness", "marketing", "socialmedia", "Entrepreneur"],
  limit: 50,          # items per request; Reddit caps a listing at 100
  sort: "new",
  time_filter: "week" # hour, day, week, month, year, all
```

And YouTube:

```elixir
config :smm_monitor, SmmMonitor.Fetchers.YouTube,
  max_results: 25,               # results per search; the API caps a page at 50
  order: "date",                 # date | relevance | rating | title | viewCount
  daily_quota_budget: 8_000,     # stop polling once this many units are spent
  published_within_ms: :timer.hours(24)
```

A platform may also set its own `:interval_ms` in the `:platforms` config;
YouTube does, because its quota makes the global 30s cadence unaffordable.

No brand name, subreddit or search term is hardcoded anywhere in `lib/` —
every query is built at runtime from the client being polled for. Every
platform searches for the *same* client's brand terms, and each client's
Reddit subreddit list is its own.

## Known limitations

* Mentions older than the retention window are gone for good. Reports
  and CSV exports can only cover what is still on disk, so a 90-day
  report on a 30-day retention shows 30 days and says nothing about the
  missing 60. Raise `SMM_RETENTION_DAYS` before you need the history,
  not after.
* Retention deletes rows but SQLite doesn't shrink the file — see disk
  space above.
* The clients screen edits clients, brand terms and subreddits only.
  Credentials and mock/live remain env-var controlled and need a restart.
* Sentiment is a word list; sarcasm, negation beyond one word, and
  domain-specific language will all fool it.
* **Credentials are per install, not per client.** Every client is
  searched with the same Reddit app, YouTube key and X token, so the API
  budgets are shared and divide as clients are added — see "How API
  limits are shared between clients". Monitoring clients under separate
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
  would fix this is described above.
* YouTube's default 5-minute poll spends the daily budget in under seven
  hours. Set `SMM_YOUTUBE_POLL_INTERVAL_MS=1080000` for all-day coverage.
* YouTube quota accounting is our own estimate — Google doesn't report
  remaining quota — so it can't see another process sharing the key.
* **Instagram cannot do brand-wide search.** It sees posts that tag your
  account, comments on your own posts, and (opt-in) public posts
  carrying a tracked hashtag — nothing else. @-mentions in other
  people's captions are webhook-only and out of reach for a polling
  tool. See the Instagram section above; this is a platform limit, not
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
