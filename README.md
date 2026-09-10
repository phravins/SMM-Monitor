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
├── SmmMonitor.Processing.Processor      ETS owner, scoring, aggregation
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
`:config_file` points at `tmp/`, so a test can never write over a real
config.

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

* No persistence of *mentions* — a restart loses the stored window. The
  config screen's settings do persist.
* The config screen edits brand terms and subreddits only. Credentials
  and mock/live remain env-var controlled and need a restart.
* Sentiment is a word list; sarcasm, negation beyond one word, and
  domain-specific language will all fool it.
* Credentials are global, not per-client. Monitoring several brands with
  separate API accounts needs per-client state — worth designing before
  wiring up Instagram for more than one brand.
* No alerting. A spike in negative sentiment shows on the bar but doesn't
  notify anyone.
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
