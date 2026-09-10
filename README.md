# SMM Monitor

A terminal dashboard for tracking client brand mentions across social
platforms. Built for RealOffice's social media management work — no web
frontend, no database, just a TUI you can leave running in a pane.

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
| `MIX_ENV=prod mix release` | Builds a self-contained release (see below). |
| `mix test` | The test suite (no fetchers, no TUI — see `config/test.exs`). |

To hand the dashboard to someone else, build a release and run it with the
TUI flag set:

```sh
MIX_ENV=prod mix release
SMM_TUI=1 _build/prod/rel/smm_monitor/bin/smm_monitor start
```

There's deliberately no escript: Ratatouille's termbox NIF can't be loaded
out of an escript archive, so the binary would start and immediately fail
on `ExTermbox.Bindings.init/0`. A release keeps the NIF in a real `priv`
directory and works.

### Keyboard shortcuts

| Key | Action |
| --- | --- |
| `a` | All platforms |
| `t` `i` `r` `y` | Twitter · Instagram · Reddit · YouTube |
| `c` | Config screen (see below) |
| `j` / `k`, `↑` / `↓` | Scroll the mentions table |
| `PgUp` / `PgDn` | Scroll a screen at a time |
| `g` / `Home` | Jump to the newest mention |
| `q` | Quit (or `Ctrl-C`) |

On the config screen, `j`/`k` move between fields, `e` or `Enter` starts
editing, `Enter` saves and `Esc` cancels. **While you're editing a field
every key is typed**, including `q` and the tab letters — so a brand term
like "quality" or "clarity" goes in fine. `Ctrl-C` always quits.

## Changing what's tracked, without a restart

Press `c` for the config screen:

```
┌─config · edit and fetchers pick it up next poll──────────────────────────────┐
│                                                                              │
│  › brand terms   realoffice, real office                                     │
│    subreddits    smallbusiness, marketing, socialmedia, Entrepreneur         │
│                                                                              │
│  PLATFORM MODE                                                               │
│    reddit        live                                                        │
│    youtube       mock                                                        │
│    twitter       mock                                                        │
│    instagram     mock                                                        │
│                                                                              │
│  mock/live is set by environment variables and needs a restart               │
│                                                                              │
│  ✓ brand terms saved — fetchers pick this up on their next poll              │
└──────────────────────────────────────────────────────────────────────────────┘
```

Two fields are editable, and a change takes effect on each platform's
**next poll** — no restart. Reddit polls every 30s, YouTube every 5
minutes by default, so give it a moment.

| Field | What it does |
| --- | --- |
| **brand terms** | The search terms, shared by every platform. Comma-separated; multi-word terms are quoted as phrases automatically. At least one is required. |
| **subreddits** | Which subreddits Reddit watches. Comma-separated. Leave it empty to search all of Reddit. |

The platform mode rows are **read-only**. Mock/live and credentials are
environment-controlled and still need a restart — see the table at the end
of this section.

### Where it's saved

`~/.config/smm_monitor/config.json` (honouring `XDG_CONFIG_HOME`), or
wherever `SMM_CONFIG_FILE` points. It holds only the two editable fields:

```json
{
  "version": 1,
  "keywords": ["realoffice", "real office"],
  "subreddits": ["marketing", "smallbusiness"],
  "updated_at": "2026-09-10T09:15:00Z"
}
```

**No credentials are in it**, so it's safe to read, diff and hand to
someone. The screen shows the path it's writing to.

Not under `priv/`, which is the obvious-looking choice: `:code.priv_dir/1`
resolves to the *build* copy (`_build/dev/lib/smm_monitor/priv/`), not the
source tree, so settings saved there are a build artifact — `mix clean`
would discard them, and a release replaces its `priv` directory wholesale
on upgrade. Your saved brand terms should outlive a rebuild.

### If the file is missing or broken

Neither stops the app booting.

| Situation | What happens |
| --- | --- |
| **Missing** | Normal — it's the state before anyone has changed anything. The env-var/compile-time defaults are used, and the file appears on the first save. |
| **Corrupt** (bad JSON, or valid JSON of the wrong shape) | Logged, moved aside to `config.json.corrupt` so you can inspect it, and the defaults are used. The config screen says the previous file was unreadable rather than hiding it. |
| **One bad field** | That field falls back to its default; the others are still read. A malformed `subreddits` doesn't cost you your `keywords`. |
| **Unwritable** (read-only disk) | The change still applies in memory for this run — losing your edit because the disk objected would be worse — and a warning is logged. |

Writes are atomic (written to a temp file, then renamed), so an
interrupted write leaves the previous file intact rather than a truncated
one.

### What needs a restart

| Setting | Changed how |
| --- | --- |
| Brand terms | **Config screen, live** |
| Reddit subreddits | **Config screen, live** |
| Mock/live per platform (`SMM_MOCK_*`) | Env var + restart |
| API credentials (`REDDIT_*`, `YOUTUBE_API_KEY`) | Env var + restart |
| Poll intervals, quota budget, window/retention | Env var + restart |

Credentials are deliberately not editable from the screen: they belong in
the environment, not in a file the dashboard writes.

## Alerting on negative spikes

Collecting mentions only helps if someone notices when they turn. Every
minute, each platform's recent negative mentions are compared against
*that platform's own normal*, drawn from stored history, and an alert is
raised when the two diverge far enough.

When one fires, it appears as a banner across the top of the dashboard —
amber for a warning, red for critical:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  !! NEGATIVE SPIKE  reddit: 27 negative mentions in the last 1h              │
│                     (normally about 1.2) — 23.0x above baseline             │
└──────────────────────────────────────────────────────────────────────────────┘
```

...and goes to every configured channel: the log always, and a webhook if
you've set one up.

### Why a baseline, not a threshold

"Alert at 10 negative mentions an hour" is wrong for every client at
once. One with five mentions a day would never trip it; one with five
thousand would trip it permanently. So the comparison is always against
what that platform normally does.

A spike has to clear **three** guards, and each stops a specific kind of
false alarm:

| Guard | Default | Stops |
| --- | --- | --- |
| **Ratio** | 3x baseline | The actual signal — a normal busy afternoon isn't an emergency |
| **Floor** | 5 mentions | Going from 0.2 to 2 negatives is an "infinite spike". You should not be woken for two grumpy posts. |
| **Warm-up** | 24h of history | You can't detect an anomaly without a normal. Without this, every fresh install's first hour looks like a crisis. |

Above 6x it's **critical** rather than a warning.

### Slack (or any webhook)

```sh
SMM_ALERT_WEBHOOK_URL=https://hooks.slack.com/services/T00/B00/xxxx
```

The payload carries a `text` field that Slack, Discord and most chat
webhooks render directly, plus the raw numbers for anything generic:

```json
{
  "text": ":rotating_light: reddit: 27 negative mentions in the last 1h ...",
  "severity": "critical",
  "platform": "reddit",
  "observed_negative": 27,
  "observed_total": 41,
  "baseline_negative": 1.2,
  "ratio": 23.0,
  "at": "2026-09-10T09:53:28Z"
}
```

Leave it unset and alerts go to the log only — an unconfigured webhook is
the normal state, not an error.

### You will not be spammed

A spike outlasts one evaluation, so without a cooldown a single bad
afternoon would post to Slack sixty times an hour. Each platform is
limited to **one alert an hour** (`SMM_ALERT_COOLDOWN_MS`).

The cooldown clears as soon as that platform drops back below threshold,
so a genuinely new spike after a recovery alerts immediately rather than
waiting out the remainder of an old one.

### Tuning

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_ALERTS_ENABLED` | `true` | Whether alerting runs at all |
| `SMM_ALERT_WINDOW_MS` | 1h | The window compared against the baseline |
| `SMM_ALERT_BASELINE_DAYS` | `7` | How much history the baseline is drawn from |
| `SMM_ALERT_RATIO` | `3.0` | Multiple of baseline that counts as a spike |
| `SMM_ALERT_FLOOR` | `5` | Minimum negatives before anything can fire |
| `SMM_ALERT_WARMUP_MS` | 24h | History needed before alerting starts |
| `SMM_ALERT_CRITICAL_RATIO` | `6.0` | Multiple that counts as critical |
| `SMM_ALERT_COOLDOWN_MS` | 1h | Minimum gap between alerts for one platform |
| `SMM_ALERT_WEBHOOK_URL` | — | Where to POST alerts, if anywhere |

> **A note on accuracy.** Alerts are only as good as the sentiment
> scoring behind them, which is still a keyword list. It will miss
> sarcasm and phrasings that aren't in the word lists — "the site is
> down", for instance, currently scores neutral. Treat an alert as "go
> and look", not as a measurement.

### Failure policy

Alerting is the last thing that should be allowed to break collection.
A failing notifier is logged and the others still run; a database that
can't answer means no baseline, which reads as "still warming up" rather
than as a reason to alert.

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

**What a viewer can see:** every mention collected, the brand terms and
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
| `SMM_MOCK_YOUTUBE=false` | YouTube live, everything else mocked. |
| Both of the above | Reddit and YouTube live, Twitter and Instagram mocked. |
| `SMM_MOCK_REDDIT=true` | Reddit mocked, even with credentials set. |
| `SMM_MOCK_MODE=false` | Global default flips to live. Twitter and Instagram have no live implementation, so they stay on fixtures regardless. |

A per-platform flag unset means *"inherit `SMM_MOCK_MODE`"*, not *"go
live"* — so you can't accidentally start hitting an API by never setting
it. The two live platforms are independent: turning YouTube on has no
effect on Reddit and vice versa.

**A platform without credentials keeps serving mock data** rather than
failing. Set `SMM_MOCK_REDDIT=false` but forget the client secret (or
`SMM_MOCK_YOUTUBE=false` with no API key) and you'll get fixtures plus one
clear warning in the log:

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

### Environment variables

| Variable | Used by |
| --- | --- |
| `SMM_MOCK_MODE` | Global switch; `true` (default) forces fixtures everywhere |
| `SMM_MOCK_REDDIT` | Per-platform override for Reddit. Unset inherits the global. |
| `SMM_MOCK_YOUTUBE` | Per-platform override for YouTube. Unset inherits the global. |
| `SMM_KEYWORDS` | Comma-separated brand terms — the *default* before anything is saved from the config screen |
| `SMM_CONFIG_FILE` | Where runtime-editable settings are saved |
| `SMM_SSH_ENABLED` | Serve the dashboard over SSH (default false) |
| `SMM_SSH_PORT` | Port to listen on (default 2222) |
| `SMM_SSH_AUTHORIZED_KEYS` | Public keys allowed to connect |
| `SMM_SSH_HOST_KEY_DIR` | Where the server's host key is kept |
| `SMM_DB_PATH` | Where collected mentions are stored |
| `SMM_RETENTION_DAYS` | How long mentions are kept on disk (default 30) |
| `SMM_HISTORY_LIMIT` | Mentions per platform restored on boot (default 200) |
| `SMM_POLL_INTERVAL_MS` | Poll interval per platform (default 30000) |
| `SMM_REDDIT_SUBREDDITS` | Comma-separated subreddits to watch. Empty searches all of Reddit. |
| `REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET` / `REDDIT_USER_AGENT` | Reddit **(live)** |
| `SMM_YOUTUBE_POLL_INTERVAL_MS` | YouTube's own poll interval (default 300000 = 5 min) |
| `SMM_YOUTUBE_DAILY_QUOTA_BUDGET` | Units to spend per day before standing down (default 8000) |
| `YOUTUBE_API_KEY` | YouTube **(live)** |
| `TWITTER_BEARER_TOKEN` | Twitter/X (stubbed) |
| `INSTAGRAM_ACCESS_TOKEN` / `INSTAGRAM_USER_ID` | Instagram (stubbed) |

## What's real and what's stubbed

| Platform | Status |
| --- | --- |
| **Reddit** | **Live.** OAuth2 script app, `client_credentials` grant, multireddit `/search` sorted by new. Token cached in the worker and refreshed before expiry; rate limit tracked from Reddit's own headers. Free tier. |
| **YouTube** | **Live.** Data API v3 `search.list` with an API key. Quota tracked against a daily budget in the worker, standing the platform down when spent. Polls on its own slower interval. Free tier. |
| **Twitter/X** | **Stubbed.** Recent search needs a paid Basic tier; there's no free read tier to develop against. The payload mapping (`Twitter.parse/1`) is written and tested; only the HTTP call is missing. |
| **Instagram** | **Stubbed.** Needs a Business/Creator account, a linked Facebook Page and app review — and the Graph API only surfaces mentions *of your own account*, not arbitrary brand terms. Mapping written and tested. |

Both stubs list the exact remaining steps in their moduledocs. Because
every non-Reddit platform is fixture-backed, their tabs, counts and
sentiment bars all work today — the dashboard looks and behaves the same
whether or not you have any credentials.

**Sentiment is keyword-based**, not ML: positive and negative word lists,
with handling for negations ("not great") and intensifiers ("very good").
It's good enough to make the bar useful and cheap enough to run on every
mention at write time. `Sentiment.analyze/1` is the seam to swap in
something real — text in, `{sentiment, score}` out.

**Storage is ETS only.** Nothing is persisted; restarting starts from an
empty table. Mentions are pruned by both age (`:retention_ms`) and row
count (`:max_mentions`).

## Architecture

Three layers, each supervised independently:

```
SmmMonitor.Supervisor                    (one_for_one)
├── SmmMonitor.Config                    runtime-editable settings, file-backed
├── SmmMonitor.Repo                      SQLite, the durable mention log
├── SmmMonitor.Persistence.Migrator      migrates on boot, then :ignore
├── SmmMonitor.Persistence.Writer        off-critical-path writes
├── SmmMonitor.Persistence.Retention     daily prune
├── SmmMonitor.Processing.Processor      ETS owner, scoring, aggregation
├── SmmMonitor.Alerts                    negative-sentiment spike detection
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

**Config.** One GenServer holding the settings a person changes while the
tool is running: the brand terms and Reddit's subreddit list. Application
env is the right home for settings fixed at boot — credentials, intervals,
quota budgets — but it isn't meant to be written to at runtime, so these
live here instead. It's the single source of truth: fetchers read their
search terms from it on every poll, which is what makes an edit land on
the next poll rather than the next restart. Started first, ahead of the
fetchers that read from it.

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
| `:alerts_enabled` | `true` | Whether spike detection runs |
| `:alerts` | see above | Ratio, floor, warm-up and critical thresholds |
| `:alert_notifiers` | log + webhook | Channels an alert is sent to |
| `:ssh_enabled` | `false` | Whether the SSH server starts |
| `:ssh_port` | `2222` | Port the SSH server listens on |
| `:start_persistence` | `true` | Whether the tree starts the repo and migrator |
| `:persist_writes` | `true` | Whether mentions are written to disk |
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
every query is built from the shared `:keywords` setting and this config at
runtime. Both live platforms search for the *same* brand terms.

## Known limitations

* Mentions older than the retention window are gone for good; there's no
  archive or export.
* Retention deletes rows but SQLite doesn't shrink the file — see disk
  space above.
* The config screen edits brand terms and subreddits only. Credentials
  and mock/live remain env-var controlled and need a restart.
* Sentiment is a word list; sarcasm, negation beyond one word, and
  domain-specific language will all fool it.
* Credentials are global, not per-client. Monitoring several brands with
  separate API accounts needs per-client state — worth designing before
  wiring up Instagram for more than one brand.
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
* Twitter and Instagram are still fixture-backed; both need paid or
  reviewed API access.
* SSH access has no rate limiting or audit trail beyond one log line per
  connection — run it behind a VPN or firewall rather than exposed.
* Remote sessions are read-only; there's no per-user permission model,
  only "host terminal" versus "everyone else".
* Alerts fire on negative-sentiment spikes only — not on volume spikes,
  keyword matches, or a named competitor appearing.
* Alerts live in memory, so a restart forgets recent ones and clears any
  cooldown in force.
