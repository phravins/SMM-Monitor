# SMM Monitor

SMM Monitor watches social media for mentions of the brands you manage
and shows them in your terminal as they happen. It searches Reddit,
YouTube, X (Twitter) and Instagram for each client's brand terms, scores
every post as positive, neutral or negative, warns you in Slack when
something needs attention, and writes CSV and PDF reports you can hand
to a client.

It is a single program with no web server and no account to sign up
for. Leave it running in a terminal window, or on a server your team
connects to over SSH.

![The SMM Monitor dashboard: a header line, tabs for each platform, a
sentiment summary and a table of recent mentions](docs/images/dashboard.png)

*The dashboard. This screenshot uses demo data, so its header says so.*

## Contents

- [How it works](#how-it-works)
- [Installation](#installation)
- [First run](#first-run)
- [Connecting your platforms](#connecting-your-platforms)
- [Using the dashboard](#using-the-dashboard)
- [How fresh is the data?](#how-fresh-is-the-data)
- [Security at a glance](#security-at-a-glance)
- [Troubleshooting](#troubleshooting)
- [Upgrading to this version](#upgrading-to-this-version)
- [More documentation](#more-documentation)

## How it works

```text
  Reddit   YouTube   X (Twitter)   Instagram     Bluesky   Discord
     │        │          │            │             │         │
     └────────┴─────┬────┴────────────┘             └────┬────┘
                    ▼                                    ▼
       one poller per platform            one live stream, matched
       (asks every 30 s to 18 min,        against brand terms as
        within rate limits and quotas)    posts are written
                    │                                   │
                    └─────────────────┬─────────────────┘
                                      ▼
                   clean · score sentiment · de-duplicate
                                      │
                         ┌────────────┴────────────┐
                         ▼                         ▼
                  in-memory view            SQLite database   30 days of history
                         │                         │
                         ├─▶ dashboard (this terminal, or over SSH)
                         ├─▶ alerts (log, Slack)
                         └─▶ trends and reports (CSV, PDF)
```

- **Clients.** You monitor *clients*, not loose keywords. Each client
  has a name, its brand terms (for example `acme, acme corp`), the
  subreddits worth watching, and its own alert settings. The dashboard
  shows one client at a time.
- **Polling.** Each platform is asked for new posts on a timer. Reddit
  every 30 seconds, X every 5 minutes, Instagram every 15 and YouTube
  every 18. The intervals are set by what each API allows for free, or
  for what you pay.
- **Streaming.** Bluesky and Discord are not polled. One connection
  each stays open and receives new posts as they are written: every
  post on Bluesky, and every message in the Discord servers you invite
  the bot to. Those that name a client's brand are stored within a
  second or two.
- **Sentiment.** Every post gets a score from −1.0 to 1.0 from a word
  list. That is fast and needs no external service, but it can be
  fooled by sarcasm. See [docs/sentiment.md](docs/sentiment.md).
- **Storage.** Mentions are kept in a SQLite file on your machine for
  30 days by default. Nothing is sent anywhere except to the platform
  APIs and, if you set one up, your Slack webhook. Bluesky and Discord
  are never told your brand terms: their posts are matched on your
  machine.

**Is the data real?** The top line of every screen ends with one word:

| Header says | Meaning |
| --- | --- |
| `LIVE` (green) | Real posts, from at least one connected platform. |
| `NOT CONNECTED` | No platform has keys yet. Nothing is collected and nothing is made up. |
| `DEMO DATA` (amber) | Invented sample posts, because you asked for them (`SMM_DEMO=1`). |

Everything else on screen (sentiment, trends, reports) is only as real
as that word says.

## Installation

Pick one:

| You want to… | Use |
| --- | --- |
| Use it on your laptop | [The installer](#1-the-installer-macos-linux-windows) |
| Change the code | [From source](#2-from-source) |
| Run it all the time for a team | [On a server](#3-on-a-server) |

### 1. The installer (macOS, Linux, Windows)

**macOS or Linux.** Paste into a terminal:

```sh
curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/phravins/SMM-Monitor/main/scripts/install.sh | sh
```

**Windows.** Paste into PowerShell:

```powershell
iwr -useb https://raw.githubusercontent.com/phravins/SMM-Monitor/main/scripts/install.ps1 | iex
```

Then start it:

```sh
smm-monitor          # on Windows: wsl smm-monitor
```

What the installer does:

1. Works out your operating system and processor, and downloads the
   matching binary from the latest
   [release](https://github.com/phravins/SMM-Monitor/releases).
2. **Checks the binary's SHA-256 checksum** against the release's
   `SHA256SUMS` file, and stops if they don't match.
3. Puts it in `~/.local/bin`. It needs no admin rights and installs
   nothing else; the binary carries its own Erlang runtime (about
   17 MB).

On **Windows** it installs the Linux version inside WSL, because the
terminal library the dashboard is drawn with has no Windows build. If
WSL is missing, the script tells you the one command that adds it
(`wsl --install`). Use **Windows Terminal**: the old console window
draws the dashboard's lines as boxes.

Installer options, set before `sh`:

| Variable | Use |
| --- | --- |
| `SMM_INSTALL_DIR=/usr/local/bin` | Install somewhere else |
| `SMM_VERSION=v0.2.0` | A specific release instead of the latest |
| `SMM_SKIP_CHECKSUM=1` | Install a release published before releases had `SHA256SUMS` |

To **uninstall**, delete the binary and the copy of the runtime it
unpacked:

```sh
rm ~/.local/bin/smm-monitor
rm -rf ~/.local/share/.burrito     # macOS: ~/Library/Application\ Support/.burrito
```

Your clients, mentions and settings are in `~/.config/smm_monitor` and
`~/.local/share/smm_monitor`. Delete those too if you want everything
gone.

### 2. From source

You need:

- **Elixir 1.15 or newer** with **Erlang/OTP 26 or 27**. If you will turn
  on SSH access, use OTP **27.3.3 or newer** (or 26.2.5.11 or newer);
  older versions have a serious SSH vulnerability and SMM Monitor will
  refuse to start its SSH server on them.
- A C compiler and the Erlang headers (`build-essential` and `erlang-dev`
  on Debian/Ubuntu), to build two native libraries.
- Optional: Python 3 with `reportlab` (`pip install reportlab`) for PDF
  reports. CSV reports need nothing.

```sh
git clone https://github.com/phravins/SMM-Monitor.git
cd SMM-Monitor
mix deps.get
mix smm.tui
```

`mix smm.tui` starts everything and draws the dashboard. Press `q` to
quit. To add API keys without the wizard, copy the example environment
file, fill it in, and load it first:

```sh
cp .env.example .env              # then edit .env
set -a; . ./.env; set +a
mix smm.tui
```

<details>
<summary>If <code>mix deps.get</code> fails while building ex_termbox</summary>

The terminal library builds with an old copy of `waf` that uses a file
mode Python 3.11 removed. If you see `ValueError: invalid mode: 'rUb'`,
patch the bundled copy and build again:

```sh
sed -i "s/def readf(fname,m='r',encoding='latin-1'):/&\n\tm=m.replace('U','')/" \
  deps/ex_termbox/c_src/termbox/.waf3-*/waflib/Utils.py
mix deps.compile ex_termbox
```

This is a problem in the upstream package, not in this project.
</details>

Other commands: `mix test` runs the test suite,
`mix run --no-halt` runs without the dashboard (collecting and alerting
only), and `scripts/build-standalone.sh linux` builds a single-file
binary. See [docs/architecture.md](docs/architecture.md).

### 3. On a server

For an always-on install that your team views over SSH, run it as a
systemd service: a dedicated user, secrets in `/etc/smm-monitor/env`,
data in `/var/lib/smm-monitor`. The server needs neither Elixir nor
Erlang installed. Step-by-step instructions are in
**[DEPLOY.md](DEPLOY.md)**.

## First run

![The first-run setup screen asking "What should I watch for?" with a
text field for a brand or keyword](docs/images/first-run.png)

The first time it starts, SMM Monitor asks a few questions:

1. **What should I watch for?** Your brand name, or a few terms separated
   by commas. Press `Esc` here to look around with demo data instead.
2. **Reddit client id**, then **Reddit secret** (optional).
3. **YouTube API key** (optional).
4. **Review** your answers, then `Enter` to start.

`Esc` on a key question means "not now". You can add keys later: press
`c`, then `S`, to run the setup again. Keys you add **take effect
straight away**; that platform is polled within a few seconds. Running
the setup again and skipping a step keeps the key you saved before.

Your answers are saved to `~/.config/smm_monitor/settings.json`,
readable only by you. On a server the setup is skipped automatically.

## Connecting your platforms

A platform starts collecting as soon as it has credentials. Without them
it shows as not connected and collects nothing. Bluesky needs no
credentials, only switching on. Discord works through a bot you invite
to your own (or a client's) servers.

| Platform | Cost | How to connect | What it can find |
| --- | --- | --- | --- |
| **Reddit** | Free | Setup wizard, or `REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET` / `REDDIT_USER_AGENT` | Posts matching the brand terms, across Reddit or in chosen subreddits |
| **YouTube** | Free (daily quota) | Setup wizard, or `YOUTUBE_API_KEY` | Videos whose title or description matches |
| **X (Twitter)** | Paid API plan | `TWITTER_BEARER_TOKEN` | Posts from the last 7 days that match |
| **Instagram** | Business account | `INSTAGRAM_ACCESS_TOKEN` and `INSTAGRAM_BUSINESS_ACCOUNT_ID` | Only posts that tag your account, comments on your own posts and, optionally, hashtags. Instagram has **no keyword search** |
| **Bluesky** | Free, no account | `SMM_BLUESKY_ENABLED=true` | Every new public post that names the brand, about a second after it is written. Off by default because the stream downloads all of Bluesky around the clock |
| **Discord** | Free | `DISCORD_BOT_TOKEN`, then invite the bot | Messages that name the brand, in the servers the bot is invited to, about a second after they are sent. Discord has no public search |

**Start with Reddit:** it is free and takes about three minutes.

1. Sign in to Reddit and open <https://www.reddit.com/prefs/apps>.
2. Choose **create another app**, pick the **script** type, and enter
   `http://localhost:8080` as the redirect URI. It is not used.
3. The **client id** is the short string under the app's name; the
   **secret** is labelled `secret`.
4. In SMM Monitor press `c`, then `S`, and paste them.

The header changes to `LIVE` within a few seconds.

Step-by-step guides for every platform, including quotas and what
each one can and cannot see, are in
**[docs/platforms.md](docs/platforms.md)**. Environment variables always
win over keys typed into the wizard. You no longer need any
`SMM_MOCK_*=false` setting.

## Using the dashboard

### Keyboard shortcuts

| Key | Action |
| --- | --- |
| `]` / `[` | Next / previous client |
| `1`–`9` | Jump to that client |
| `a` | All of this client's platforms |
| `r` `y` `t` `i` | Reddit · YouTube · Twitter/X · Instagram only |
| `b` | Bluesky only (its tab appears once it is switched on) |
| `d` | Discord only (its tab appears once it has a token). On the config screen `d` still removes a client |
| `←` / `→` | Previous / next tab |
| `j` / `k`, `↓` / `↑` | Scroll the mentions table |
| `PgDn` / `PgUp` | Scroll a page at a time |
| `g` / `Home` | Back to the newest mention |
| `h` | Trends: mentions and sentiment per day |
| `w` / `W` | On the trends screen: 7, 14 or 30 days |
| `R` | Write a report for this client |
| `c` | Clients screen |
| `q` | Quit (`Ctrl-C` always quits) |

### Clients

Press `c` for the clients screen. `+` adds a client, `e` or `Enter`
edits the highlighted field, `j`/`k` move between clients, `h`/`l`
between fields, `p` pauses a client (it keeps its history), `d` twice
removes it along with its mentions, and `s` shows it on the dashboard.
`S` runs the setup again. Changes apply on the next poll, with no
restart.

Each client has: **name**, **brand terms**, **subreddits** (empty means
all of Reddit), **alert phrases**, **alert if sentiment** at or below a
value, **alert if volume** is a multiple of normal, and its own
**Slack webhook**. See [docs/clients.md](docs/clients.md). It also
explains why API quotas are shared between clients, which matters once
you have more than two or three.

### Trends, alerts and reports

- **Trends** (`h`): mention volume and average sentiment per day, for 7,
  14 or 30 days. See [docs/reports.md](docs/reports.md).
- **Alerts**: a client alerts when sentiment drops below its threshold,
  when volume jumps well above its normal level for that hour, or when a
  watched phrase such as `refund` or `lawsuit` appears. Alerts go to the
  log and, if you set `SMM_ALERT_WEBHOOK_URL` or a client webhook, to
  Slack. Each incident alerts once, then sends an all-clear. See
  [docs/alerts.md](docs/alerts.md).
- **Reports** (`R`): a CSV of every mention and, if Python and
  `reportlab` are installed, a PDF summary for the client. They are
  saved under `~/.local/share/smm_monitor/reports`. Weekly reports can
  be written automatically (`SMM_WEEKLY_REPORTS=true`). See
  [docs/reports.md](docs/reports.md).

## How fresh is the data?

The status line at the bottom of the dashboard shows each platform's
mode and how old its newest data is:

```text
reddit:live 12s youtube:live 4m twitter:unconfigured instagram:unconfigured
```

The **PLATFORM MODE** panel on the clients screen (`c`) adds when each
platform will be asked next:

```text
reddit        live · 12s ago · next 18s
youtube       live · 4m ago · next 14m
twitter       unconfigured
```

Bluesky and Discord show `stream` while connected, `reconnecting` while
they wait to try again, and `idle` when there is no client to match for.
Discord shows `stopped` (and, after 90 seconds, `stale`) when Discord
has rejected the token or the Message Content Intent. The log says
which, and it tries again after 10 minutes.

If a platform's last good fetch is more than three intervals old, it is
marked **`stale`**. That usually means a wrong or expired key, a spent
quota, or no network. A platform whose last poll failed shows `error`.
`unconfigured` means it has no credentials.

| Platform | Default interval | Why | Change with |
| --- | --- | --- | --- |
| Reddit | 30 seconds | 60 requests a minute allowed | `SMM_POLL_INTERVAL_MS` |
| X | 5 minutes | Monthly post cap | `SMM_TWITTER_POLL_INTERVAL_MS` |
| Instagram | 15 minutes | Meta's hourly allowance | `SMM_INSTAGRAM_POLL_INTERVAL_MS` |
| YouTube | 18 minutes | 10,000 free quota units a day, 100 per search | `SMM_YOUTUBE_POLL_INTERVAL_MS` |
| Bluesky | Live (about 1 s) | Posts are pushed as they are written; stale after 90 s of silence | — |
| Discord | Live (about 1 s) | Messages are pushed as they are sent; Discord checks in every 41 s, so a quiet server stays fresh | — |

Each poll asks only for recent posts (the last day on Reddit and
YouTube), and anything already seen is skipped, so a post appears once.
The screen redraws every second.

## Security at a glance

- **Your keys stay on your machine.** They are read from the
  environment or `settings.json` (mode `0600`). They are never shown on
  screen, written to the database, or logged. Slack webhook URLs are
  masked on screen.
- **Your data stays on your machine.** The database and reports are
  readable only by your user. The only outbound connections are to the
  platform APIs and your Slack webhook.
- **SSH access is off by default.** When on, it listens on `127.0.0.1`
  only, accepts public keys only, offers no shell and no file transfer,
  and is read-only. It refuses to start on an Erlang runtime with the
  CVE-2025-32433 SSH flaw. See [docs/ssh.md](docs/ssh.md).
- **Posts are treated as hostile.** Terminal control codes, invisible
  characters and Slack formatting in a post are removed or escaped, and
  CSV cells that a spreadsheet would run as formulas are neutralised.
- **Downloads are verified** against the release's SHA-256 checksums.

The threat model, the list of fixes in this version and the known gaps
are in [docs/security.md](docs/security.md).

## Troubleshooting

**"SMM Monitor could not start the dashboard."** The binary unpacks its
runtime once per version into `~/.local/share/.burrito` (macOS:
`~/Library/Application Support/.burrito`), and a stale copy is reused.
Delete it and start again: `rm -rf ~/.local/share/.burrito`. Your data
is not stored there. Re-running the installer also does this.

**The header says `NOT CONNECTED`.** No platform has credentials. Press
`c` then `S` to add Reddit or YouTube keys, or see
[docs/platforms.md](docs/platforms.md).

**A platform shows `error` or `stale`, or its tab stays empty.** The
reason is written to the log (on a server:
`journalctl -u smm-monitor -e`). Common causes: a
mistyped key, the YouTube API not enabled in Google Cloud, an expired
Instagram token (they last 60 days), or a spent quota. An empty tab can
also simply mean nobody is talking about the brand.

**The installer says the checksum is missing.** The release was published
before releases carried `SHA256SUMS`. Install it with
`SMM_SKIP_CHECKSUM=1`, or wait for the next release.

**No PDF, only a CSV.** Install Python 3 and `reportlab`
(`pip install reportlab`). If Python lives somewhere unusual, set
`SMM_PYTHON` to its path.

**Lines drawn as boxes or `?`, or a cramped layout.** Use a terminal
with UTF-8 support (Windows Terminal on Windows) and make the window at
least 80 columns wide; the 30-day trend chart wants about 60 columns.

**SSH: "refusing to start".** Your Erlang/OTP version is affected by
CVE-2025-32433. Use the downloaded binary, or upgrade OTP to 27.3.3 or
newer. See [docs/ssh.md](docs/ssh.md#requirements).

**macOS refuses to open it.** The binaries are not signed. If you
downloaded through a browser, run
`xattr -d com.apple.quarantine ~/.local/bin/smm-monitor`.

## Upgrading to this version

Re-run the installer, or `git pull && mix deps.get` from source. Your
clients, mentions and keys are kept. Things that behave differently:

- **SSH listens on `127.0.0.1` by default.** Teammates who connected
  straight to `your-host:2222` need a tunnel (`ssh -L`), a VPN, or
  `SMM_SSH_BIND=0.0.0.0` behind a firewall. See
  [docs/ssh.md](docs/ssh.md).
- **SSH needs a patched Erlang runtime** (OTP 27.3.3 or newer). The
  downloaded binaries have one.
- **If you had SSH enabled before,** rotate your API keys and webhook
  URLs: an SFTP bug let any authorised viewer read the env file.
- **`.env.example` no longer turns on demo data.** If you copied an old
  one, remove `SMM_MOCK_MODE=true` and any `SMM_MOCK_*` lines from your
  `.env`. Credentials alone make a platform live.
- **YouTube polls every 18 minutes** by default so the free quota lasts
  all day.
- **Slack webhooks must be `https://`.**
- **The installer verifies checksums.** For a release without
  `SHA256SUMS`, use `SMM_SKIP_CHECKSUM=1`.
- **Keys entered in the wizard apply immediately**, and correcting a key
  replaces the old one.

## More documentation

| Page | What's in it |
| --- | --- |
| [docs/platforms.md](docs/platforms.md) | Getting keys for Reddit, YouTube, X and Instagram; quotas; what each can see |
| [docs/clients.md](docs/clients.md) | Managing clients, and how API budgets are shared between them |
| [docs/alerts.md](docs/alerts.md) | Alert conditions, thresholds and Slack setup |
| [docs/reports.md](docs/reports.md) | The trends screen, CSV and PDF reports, weekly reports |
| [docs/sentiment.md](docs/sentiment.md) | How sentiment is scored and how to tune the word lists |
| [docs/ssh.md](docs/ssh.md) | Sharing the dashboard with your team over SSH |
| [docs/configuration.md](docs/configuration.md) | Every environment variable |
| [docs/security.md](docs/security.md) | Threat model, fixes in this release, known gaps |
| [docs/architecture.md](docs/architecture.md) | How it is built, running from source, testing, adding a platform |
| [docs/limitations.md](docs/limitations.md) | What it cannot do, and why |
| [DEPLOY.md](DEPLOY.md) | Running it as a service on a Linux server |
