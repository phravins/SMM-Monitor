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
| `j` / `k`, `↑` / `↓` | Scroll the mentions table |
| `PgUp` / `PgDn` | Scroll a screen at a time |
| `g` / `Home` | Jump to the newest mention |
| `q` | Quit |

## Live data

Everything runs on fixtures until you say otherwise. To go live, set
`SMM_MOCK_MODE=false` and provide credentials:

```sh
cp .env.example .env
# fill in the keys you have
set -a; source .env; set +a
mix smm.tui
```

A platform without credentials **keeps serving mock data** rather than
failing — a missing key degrades one tab instead of emptying the
dashboard. The status line at the bottom shows each worker's actual mode.

| Variable | Used by |
| --- | --- |
| `SMM_MOCK_MODE` | Global switch; `true` (default) forces fixtures everywhere |
| `SMM_KEYWORDS` | Comma-separated brand terms to search for |
| `SMM_POLL_INTERVAL_MS` | Poll interval per platform (default 30000) |
| `REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET` / `REDDIT_USER_AGENT` | Reddit |
| `YOUTUBE_API_KEY` | YouTube |
| `TWITTER_BEARER_TOKEN` | Twitter/X (stubbed — see below) |
| `INSTAGRAM_ACCESS_TOKEN` / `INSTAGRAM_USER_ID` | Instagram (stubbed) |

Credentials are read in `config/runtime.exs`, which runs on every boot
(including from a release). Nothing is hardcoded and nothing is committed.

## What's real and what's stubbed

| Platform | Status |
| --- | --- |
| **Reddit** | Implemented. App-only OAuth, `/search` sorted by new. Free tier. |
| **YouTube** | Implemented. Data API v3 `search.list` with an API key. Free tier, but `search.list` costs 100 quota units per call — raise `SMM_POLL_INTERVAL_MS` before running it live for long. |
| **Twitter/X** | **Stubbed.** Recent search needs a paid Basic tier; there's no free read tier to develop against. The payload mapping (`Twitter.parse/1`) is written and tested; only the HTTP call is missing. |
| **Instagram** | **Stubbed.** Needs a Business/Creator account, a linked Facebook Page and app review — and the Graph API only surfaces mentions *of your own account*, not arbitrary brand terms. Mapping written and tested. |

Both stubs list the exact remaining steps in their moduledocs. Because
they're mock-backed, their tabs, counts and sentiment bars all work today.

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

  @impl true
  def fetch(context) do
    # Call the API, then map onto SmmMonitor.Mention.new/1 attrs:
    #   %{id:, platform:, author:, text:, url:, timestamp:}
    # Keep the mapping in a public parse/1 so it's testable without HTTP.
    {:ok, mentions}
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

Tests run with `start_fetchers: false` and `start_tui: false`, so they get
the processing layer and nothing else: no 30s polls racing assertions.

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
| `:start_fetchers` | `true` | Whether the tree starts the fetching layer |
| `:start_tui` | `false` | Whether the tree starts the dashboard |
| `:renderer` | `RatatouilleRenderer` | The TUI drawing layer |
| `:platforms` | four entries | Platform → module, enabled flag, opts |

## Known limitations

* No persistence — a restart loses the window of stored mentions.
* Sentiment is a word list; sarcasm, negation beyond one word, and
  domain-specific language will all fool it.
* Credentials are global, not per-client. Monitoring several brands with
  separate API accounts needs per-client state — worth designing before
  wiring up Instagram for more than one brand.
* No alerting. A spike in negative sentiment shows on the bar but doesn't
  notify anyone.
