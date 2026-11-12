# Architecture and development

[← Back to the README](../README.md)

How SMM Monitor is put together, how to add a platform, and how to run
the tests. For running it as a service, see [DEPLOY.md](../DEPLOY.md).

## Data flow

```
 Reddit · YouTube · X ·               Bluesky (Jetstream) ·
   Instagram · Threads                    Discord (Gateway)
        (HTTPS APIs, polled)               (WebSocket, pushed)
              │                                    │
              ▼                                    ▼
 Fetchers.Worker ── one per platform,     Fetchers.StreamWorker ── one
              │      polls every client    │   connection, matches every
              │      in turn, tracks       │   post against all clients
              │      rate limits/quotas    │   (Matching), batches 1s/100
              └──────────────┬─────────────┘
                             ▼
 Processing.Processor ── cleans text, scores sentiment, drops
              │          duplicates and posts older than the window
      ┌───────┴────────┐
      ▼                ▼
    ETS             SQLite (Persistence.Writer)
 (read path)     (durable log: clients, mentions, alerts)
      │                │
      ├──▶ TUI (local terminal, and one copy per SSH session)
      ├──▶ Alerts ──▶ log + Slack webhook
      └──▶ Reports (trends screen, CSV, PDF)
```

## Supervision tree
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
│   ├── PlatformSupervisor(:instagram) → Worker(:instagram)
│   ├── PlatformSupervisor(:threads)   → Worker(:threads)
│   ├── PlatformSupervisor(:bluesky)   → StreamWorker(:bluesky)
│   └── PlatformSupervisor(:discord)   → StreamWorker(:discord)
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

**Streaming.** A platform whose config entry says `kind: :stream` gets a
`StreamWorker` instead of a `Worker`, under the same kind of
per-platform supervisor. It holds one WebSocket open
(`SmmMonitor.WebSocket`, a small RFC 6455 client written for this app
rather than a Hex dependency) and receives posts as they happen instead
of asking for them. Three things differ from polling:

* **Matching is local.** A stream sends everything, so the worker keeps
  a compiled `SmmMonitor.Matching` matcher for all active clients and
  runs each post through it; a post naming two clients becomes two
  mentions. The matcher is rebuilt when the client list changes, without
  reconnecting.
* **Writes are batched.** Matched posts are handed to the processor once
  a second, or as soon as 100 are waiting, so a busy stream is not one
  GenServer call per post. The platform module's `enrich/2` runs on each
  batch first (Bluesky uses it to turn author ids into handles).
* **Reconnects are the normal case.** A dropped connection, a close from
  the server, an oversize message or a failed handshake all lead to a
  reconnect with exponential back-off and jitter (1s doubling to 60s).
  A platform that returns `{:stop, reason}` (a revoked token, say) is
  left alone for 10 minutes. No clients means no connection at all.
  The platform decides what a server's close code means
  (`handle_close/2`) and whether a missed heartbeat acknowledgement means
  a dead connection (`heartbeat/1` returning `{:reconnect, state}`), so
  Discord can stop on a rejected token and resume on anything else.

`StreamWorker.status/1` returns the same map shape as `Worker.status/1`,
plus `transport: :stream`, `connection` (`:connected`, `:reconnecting`,
`:idle` or `:stopped`) and counters (`events_seen`, `matched`,
`inserted`). `SmmMonitor.Fetchers.status/1` and `poll_now/1` route to
whichever worker a platform has, so the TUI never needs to know which
kind it is talking to.

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

**Freshness.** Each worker records when it last polled successfully
(`last_success_at`) and when it will poll next (`next_poll_at`), and
`Worker.status/1` returns both. The dashboard's status line turns them
into `12s ago · next 18s`, and marks a platform `stale` when its last
success is more than three intervals old. `Worker.poll_now/1` triggers
an immediate poll; the setup wizard calls it when a key is saved, so a
new key is tried at once instead of on the next schedule.


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
`mock_fetch/2`, so the platform shows up in demo mode (`SMM_DEMO=1`)
*before* the API work is done. Until `ready?/1` returns true it reports
itself not connected and collects nothing. The supervisors build their children from config, so no
supervisor needs editing. Add credentials to `config/runtime.exs` and
`.env.example` if the platform needs them.

The one place that isn't automatic: `TUI.Model`'s tab shortcuts are a fixed
map (`a`/`t`/`i`/`r`/`y`/`b`/`d`/`e`) — pick a free letter and add it there.
A letter the config screen already uses (`d` removes a client there, `e`
edits one) needs that screen's clauses placed above the tab-key clause in
`handle_key`, as `d`, `e` and `h` are.
Add `tab: :when_on` to the config entry if the platform is off by
default, so its tab only appears once it is switched on.

### A streaming platform

A platform that pushes posts over a WebSocket uses
`SmmMonitor.Fetchers.Stream` instead, and `kind: :stream` in its config
entry. The module never touches the socket; it says where to connect
and what each message means:

```elixir
defmodule SmmMonitor.Fetchers.Example do
  use SmmMonitor.Fetchers.Stream, platform: :example, display_name: "Example"

  @impl true
  def ready?(context), do: is_binary(context.credentials[:token])

  @impl true
  def url(_context, _state), do: {:ok, "wss://stream.example.com/v1"}

  # Each decoded JSON message. Return posts as Mention.new/1 attrs; the
  # worker matches them to clients, so don't filter by brand here.
  @impl true
  def handle_message(%{"type" => "post"} = msg, state),
    do: {:ok, [to_attrs(msg)], [], state}

  def handle_message(_other, state), do: {:ok, [], [], state}
end
```

The other callbacks have defaults:

| Callback | Default | Use it for |
| --- | --- | --- |
| `headers/1` | none | Extra handshake headers |
| `on_open/1` | send nothing | Frames to send once connected |
| `heartbeat_ms/1`, `heartbeat/1` | no heartbeat | A keep-alive the server expects. `heartbeat_ms/1` is asked again after every message, so a server that announces its interval (Discord's Hello) can start it late. `heartbeat/1` may return `{:reconnect, state}` |
| `idle_timeout_ms/0` | 60 s | Reconnect after this long with no message |
| `tick/1` | `{[], state}` | Periodic work, such as saving a cursor. Returns `{posts, state}`; the posts are matched and batched like live ones (Discord's catch-up arrives this way) |
| `handle_close/2` | reconnect | What a close code from the server means: `{:reconnect, state}` or `{:stop, reason, state}` |
| `close_code/1` | `1000` | The code sent when closing. Discord uses `4000` while it has a session, because `1000` ends the session |
| `max_message_bytes/0` | 1 MB | The largest message accepted |
| `on_disconnect/1` | nothing | Saving state when the connection drops |
| `enrich/2` | nothing | Work on each batch of matched posts |

`handle_message/2` can also return `{:reconnect, state}` or
`{:stop, reason, state}`. `lib/smm_monitor/fetchers/bluesky.ex` is the
simple worked example, including resuming from a saved cursor
(`SmmMonitor.Fetchers.CursorFile` writes it privately and atomically).
`lib/smm_monitor/fetchers/discord.ex` uses everything: a late
heartbeat, session resume, close codes, and a rate-limited catch-up
from `tick/1`.


## Testing

```sh
mix test
```

The suite covers the processing and aggregation logic, mention parsing for
every platform, the brand-term matcher, the WebSocket client and stream
worker, the TUI model's state transitions, and the supervision
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

* Streaming runs against `SmmMonitor.FakeWsServer`
  (`test/support/fake_ws_server.ex`), a WebSocket server on 127.0.0.1
  that a test drives directly: send a message, a malformed frame or a
  close code, or drop the TCP connection, and assert on what the worker
  does. Bluesky's parsing uses recorded Jetstream messages, and its
  profile lookups go through `test/support/bluesky_stub.ex`. Discord's
  tests play the Gateway from the fake server (Hello, identify, resume,
  close codes), and its catch-up requests go through
  `test/support/discord_stub.ex`, where a test's handler answers each
  request (by channel, say) and can return rate-limit headers.

* Threads uses `test/fixtures/threads_search.json` and
  `threads_mentions.json` for parsing, and `test/support/threads_stub.ex`
  for the fetch path and token renewal: responses are scripted by URL
  fragment (`/keyword_search`, `/mentions`, `/refresh_access_token`), and
  a `clock` setting fixes the time, so the 24-hour and 7-day renewal rules
  are tested without waiting. Instagram and Threads read Meta's error
  codes through one module, `SmmMonitor.Fetchers.MetaGraph`.

Tests run with `start_fetchers: false` and `start_tui: false`, so they get
the processing layer and nothing else: no 30s polls racing assertions.
`:config_file` and the database both point at `tmp/`, so a test can never
write over a real config or real collected history. Persistence tests run
in a sandboxed transaction that is rolled back afterwards.


Before sending a change, run the same checks CI does:

```sh
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix test
```

## Running from source

This works with no API keys at all:

```sh
mix deps.get
mix smm.tui
```

With no keys every platform shows as not connected. Add keys (see
[platforms.md](platforms.md)), or run `SMM_DEMO=1 mix smm.tui` for a
moving dashboard built from invented sample data. Press `q` to quit.

### Requirements

* Elixir ~> 1.15 with OTP 26 or 27 (OTP 27.3.3+ if you enable SSH — see
  [ssh.md](ssh.md#requirements))
* A C toolchain (`build-essential`) and `erlang-dev` — Ratatouille compiles
  a termbox NIF on install
* Python 3 with `reportlab` for PDF reports (optional; CSV needs nothing)

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

### The commands

| Command | What it does |
| --- | --- |
| `mix smm.tui` | Starts the supervision tree and the dashboard. The usual way. |
| `SMM_TUI=1 mix run --no-halt` | Same thing via the app's own config flag. |
| `mix run --no-halt` | Runs the fetchers and processing layer headless, no UI. |
| `./scripts/build_release.sh` | Builds a self-contained release and packages it (see [DEPLOY.md](../DEPLOY.md)). |
| `mix test` | The test suite (no fetchers, no TUI — see `config/test.exs`). |

To run it as a background service on a server — systemd unit, dedicated
user, env file for secrets — see **[DEPLOY.md](../DEPLOY.md)**. The release
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


## Building the downloadable binaries

The binaries the installer downloads are built by
[Burrito](https://github.com/burrito-elixir/burrito), which wraps a
release — BEAM code, the Erlang runtime, both native NIFs — into one
file. Tagging a version builds all four and attaches them to a GitHub
Release; `.github/workflows/release.yml` is the whole pipeline.

To build one yourself you need `zig` and `xz` on PATH:

```sh
scripts/build-standalone.sh linux        # or linux_arm, macos, macos_intel
```

All four cross-build from one Linux machine — that is Burrito's trick —
and land in `burrito_out/`.

Use the script rather than `mix release standalone`. Burrito rebuilds
NIFs for the target it is packaging and expects them in
`$MIX_APP_PATH/priv`, which exqlite honours and ex_termbox (which
predates the convention) does not. Left to itself, the Linux binary ends
up carrying a glibc library inside a musl runtime and dies on startup
with `__snprintf_chk: symbol not found`. The script compiles the NIFs
for the target first, where the release will actually find them, and
puts the native ones back afterwards.

### Why there is no Windows .exe

The dashboard is drawn with Ratatouille, which draws with termbox, which
is POSIX — `termios`, `select`, and:

```
termbox.c:9:10: fatal error: 'sys/select.h' file not found
```

That is not a toolchain problem with a flag to fix. A Windows build
would produce an executable that starts, finds nothing to draw with, and
shows an empty window — so the Windows installer sets it up in WSL
instead, where it is the Linux build and works normally. If termbox ever
learns to speak to the Windows console, one line in `mix.exs` is the
whole change.

### The macOS binaries are not signed

macOS may refuse to run a downloaded binary from an unidentified
developer. Files fetched with `curl` aren't quarantined, so the
installer's binaries run without argument; one downloaded through a
browser needs `xattr -d com.apple.quarantine ~/.local/bin/smm-monitor`
or a trip through System Settings → Privacy & Security.


Each release also publishes a `SHA256SUMS` file. The installer
downloads it and refuses to install a binary whose checksum does not
match. The release workflow pins the Erlang/OTP version it bundles
(`OTP_VERSION` in `.github/workflows/release.yml`); keep it on a patched
release, since every binary carries that runtime's SSH code.

## Application config keys

Environment variables are listed in [configuration.md](configuration.md).

Compile-time defaults live in `config/config.exs`:

| Key | Default | Meaning |
| --- | --- | --- |
| `:keywords` | `["realoffice", "real office"]` | Brand terms to search for |
| `:poll_interval_ms` | `30_000` | Per-platform poll interval |
| `:window_ms` | 24h | Window the dashboard's counters cover |
| `:retention_ms` | 48h | Age at which mentions are pruned |
| `:max_mentions` | `2_000` | Hard cap on stored rows |
| `:mock_mode` | `false` | Serve invented demo data instead of calling APIs (`SMM_DEMO`) |
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
| `:ssh_bind` | `"127.0.0.1"` | Address the SSH server listens on |
| `:start_persistence` | `true` | Whether the tree starts the repo and migrator |
| `:persist_writes` | `true` | Whether mentions are written to disk |
| `SmmMonitor.Fetchers.Twitter` | see above | Page size, monthly post budget, billing cycle day |
| `SmmMonitor.Fetchers.Instagram` | see above | Which sources to poll, hashtags, page sizes |
| `SmmMonitor.Fetchers.Bluesky` | see below | Switch, Jetstream server, cursor file |
| `SmmMonitor.Fetchers.Discord` | see below | Server and channel allow-lists, cursor file |
| `SmmMonitor.Fetchers.Threads` | see below | Sources, search budget, token file |
| `:platforms` | seven entries | Platform → module, `kind` (`:poll` or `:stream`), enabled flag, `tab: :when_on`, opts |

Reddit has its own block, since these are deployment choices rather than
app-wide ones:

```elixir
config :smm_monitor, SmmMonitor.Fetchers.Reddit,
  subreddits: ["smallbusiness", "marketing", "socialmedia", "Entrepreneur"],
  limit: 50,          # items per request; Reddit caps a listing at 100
  sort: "new",
  time_filter: "day"  # hour, day, week, month, year, all
```

And YouTube:

```elixir
config :smm_monitor, SmmMonitor.Fetchers.YouTube,
  max_results: 25,               # results per search; the API caps a page at 50
  order: "date",                 # date | relevance | rating | title | viewCount
  daily_quota_budget: 8_000,     # stop polling once this many units are spent
  published_within_ms: :timer.hours(24)
```

And Bluesky (set from the environment in `config/runtime.exs`):

```elixir
config :smm_monitor, SmmMonitor.Fetchers.Bluesky,
  enabled: false,          # SMM_BLUESKY_ENABLED
  jetstream_url: nil,      # SMM_BLUESKY_JETSTREAM_URL; nil = public server
  # cursor_file: "/path",  # unset = bluesky.cursor next to the database;
                           # nil = don't save, start from "now" each time
  resolve_handles: true    # look up handles for author ids
```

And Discord (the token is a credential, `DISCORD_BOT_TOKEN`):

```elixir
config :smm_monitor, SmmMonitor.Fetchers.Discord,
  guilds: [],              # SMM_DISCORD_GUILDS; [] and channels [] = everywhere
  channels: [],            # SMM_DISCORD_CHANNELS; threads follow their parent
  # cursor_file: "/path",  # unset = discord.cursor next to the database;
                           # nil = don't save, no catch-up after a restart
  # gateway_url: "ws://127.0.0.1:4000/"  # tests only
```

And Threads (the token is a credential, `THREADS_ACCESS_TOKEN`):

```elixir
config :smm_monitor, SmmMonitor.Fetchers.Threads,
  sources: [:search, :mentions],  # SMM_THREADS_SOURCES; :replies is opt-in
  daily_query_budget: 2_000,      # SMM_THREADS_DAILY_QUERY_BUDGET; Meta's cap is 2,200
  search_limit: 50,               # posts per search; Meta caps it at 100
  max_terms: 10                   # brand terms searched per client per poll
  # token_file: "/path",          # unset = threads_token.json next to the database;
                                  # nil = keep renewals in memory only
```

A platform may also set its own `:interval_ms` in the `:platforms` config;
YouTube does, because its quota makes the global 30s cadence unaffordable.

No brand name, subreddit or search term is hardcoded anywhere in `lib/` —
every query is built at runtime from the client being polled for. Every
platform searches for the *same* client's brand terms, and each client's
Reddit subreddit list is its own.

