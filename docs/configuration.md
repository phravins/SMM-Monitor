# Configuration

[← Back to the README](../README.md)

Almost everything works without configuration. This page lists every
setting there is, for when you need one.

## Where settings come from

There are three sources. When the same setting appears in more than one,
the earlier source in this list wins:

1. **Environment variables**, read once at startup. On a laptop they
   come from your shell or a `.env` file
   ([`.env.example`](../.env.example) is a commented starting point).
   On a server they come from `/etc/smm-monitor/env`
   ([`rel/overlays/env.example`](../rel/overlays/env.example), see
   [DEPLOY.md](../DEPLOY.md)).
2. **The setup wizard** (`c` then `S` in the dashboard). It saves the
   brand and the Reddit and YouTube keys to `settings.json`. Changes
   apply immediately.
3. **The clients screen** (`c`). Clients, brand terms, subreddits and
   alert settings are stored in the database and apply on the next
   poll. They are not environment variables at all; `SMM_KEYWORDS` and
   `SMM_REDDIT_SUBREDDITS` only seed the first client on a fresh
   install.

Environment values are not a shell script when systemd reads them: no
`$VAR` expansion and no command substitution. Quote any value that
contains a space.

A number setting that is not a number (`SMM_SSH_PORT=twenty`) stops the
app at startup with a message naming the variable, rather than failing
somewhere later.

## Platform credentials

Any platform without credentials collects nothing and shows as not
connected. Walkthroughs for getting each one are in
[platforms.md](platforms.md).

| Variable | Platform | Notes |
| --- | --- | --- |
| `REDDIT_CLIENT_ID` | Reddit | Also settable from the wizard |
| `REDDIT_CLIENT_SECRET` | Reddit | Also settable from the wizard |
| `REDDIT_USER_AGENT` | Reddit | Include your Reddit username; Reddit rejects generic agents |
| `YOUTUBE_API_KEY` | YouTube | Also settable from the wizard |
| `TWITTER_BEARER_TOKEN` | X | Needs a paid X API plan |
| `INSTAGRAM_ACCESS_TOKEN` | Instagram | Long-lived token; expires after 60 days |
| `INSTAGRAM_BUSINESS_ACCOUNT_ID` | Instagram | The 17-digit account id. `INSTAGRAM_USER_ID` is accepted as an older name |
| `DISCORD_BOT_TOKEN` | Discord | The bot's token from the Developer Portal. Environment only |

Bluesky needs no credentials. It is switched on with a setting, because
its stream uses bandwidth around the clock
([platforms.md](platforms.md#bluesky)):

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_BLUESKY_ENABLED` | `false` | `true` connects to Bluesky's Jetstream and matches every new post against your clients' brand terms |
| `SMM_BLUESKY_JETSTREAM_URL` | `wss://jetstream2.us-east.bsky.network/subscribe` | A different Jetstream server, including one you run. Must be `wss://` |

Discord reads every channel the bot can see in every server it has been
invited to. Two optional lists narrow that
([platforms.md](platforms.md#listening-to-fewer-places)). A message is
read when its server is in the first list or its channel (or a thread's
parent channel) is in the second:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_DISCORD_GUILDS` | empty (all servers) | Comma-separated server ids |
| `SMM_DISCORD_CHANNELS` | empty (all channels) | Comma-separated channel ids. Threads inside them are included |

Ids are the long numbers Discord's **Copy ID** gives. Anything else stops
the app at start-up with the setting's name.

## Polling and platform limits

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_POLL_INTERVAL_MS` | `30000` (30 s) | Poll interval for platforms without their own (Reddit) |
| `SMM_YOUTUBE_POLL_INTERVAL_MS` | `1080000` (18 min) | YouTube's interval. 18 minutes lasts a day of quota for one client |
| `SMM_YOUTUBE_DAILY_QUOTA_BUDGET` | `8000` | Quota units to spend per day before pausing until midnight Pacific |
| `SMM_TWITTER_POLL_INTERVAL_MS` | `300000` (5 min) | X's interval |
| `SMM_TWITTER_MONTHLY_POST_BUDGET` | `10000` | Posts to read per billing cycle before pausing. Set it to your plan's cap |
| `SMM_TWITTER_BILLING_CYCLE_DAY` | `1` | Day of the month your X post cap resets |
| `SMM_INSTAGRAM_POLL_INTERVAL_MS` | `900000` (15 min) | Instagram's interval |
| `SMM_INSTAGRAM_SOURCES` | `tags,comments` | Any of `tags`, `comments`, `hashtag` |
| `SMM_INSTAGRAM_HASHTAGS` | the brand terms | Hashtags to search when `hashtag` is on. Meta allows 30 unique per week |
| `SMM_MAX_MENTIONS` | `2000` | Most mentions held in memory for the dashboard |

The budgets are shared by every client, because they belong to the API
key. See [clients.md](clients.md#how-api-limits-are-shared-between-clients)
before adding many clients.

## What to track (first run only)

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_KEYWORDS` | `realoffice,real office` | Brand terms for the first client on a fresh install |
| `SMM_REDDIT_SUBREDDITS` | four marketing subreddits | Subreddits for the first client. Empty searches all of Reddit |
| `SMM_CONFIG_FILE` | `~/.config/smm_monitor/config.json` | The pre-clients config file, read once when upgrading |

## Storage

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_DB_PATH` | `~/.local/share/smm_monitor/mentions.db` | The SQLite database |
| `SMM_RETENTION_DAYS` | `30` | Days of mentions kept on disk |
| `SMM_HISTORY_LIMIT` | `200` | Mentions per platform loaded back into the dashboard on start |
| `SMM_SETTINGS_FILE` | `~/.config/smm_monitor/settings.json` | The setup wizard's saved answers |
| `SMM_SETUP_COMPLETE` | unset | Set to `1` to skip the setup wizard (servers, scripts) |

Bluesky's stream position is saved as `bluesky.cursor` in the same
directory as the database, so a restart carries on where it left off.
Discord's is `discord.cursor`: the last message id seen in each channel
(up to 500 channels), used to fetch what was missed after a restart. Both
are `0600` and safe to delete; the next run then starts from now.

`~/.config` and `~/.local/share` follow `XDG_CONFIG_HOME` and
`XDG_DATA_HOME` when they are set. Under systemd, the defaults are
`/etc/smm-monitor` and `/var/lib/smm-monitor` instead.

SMM Monitor creates its own directories readable only by the user it
runs as (`0700`), and its database, settings file and reports readable
only by that user (`0600`). If you point a setting at an existing
directory such as `/tmp`, it leaves that directory's permissions alone.

## Alerts

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_ALERTS_ENABLED` | `true` | Set `false` to turn the alert engine off |
| `SMM_ALERT_WEBHOOK_URL` | unset | Slack incoming webhook for every client. Must be `https://`. Unset means alerts are only logged |
| `SMM_ALERT_BASELINE_DAYS` | `7` | Days of same-hour history that "normal volume" is measured against |

Per-client webhooks and thresholds are set on the clients screen. See
[alerts.md](alerts.md).

## Reports

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_REPORTS_DIR` | `reports` next to the database | Where CSV and PDF reports are written |
| `SMM_WEEKLY_REPORTS` | `false` | Set `true` to write a report per active client every week |
| `SMM_WEEKLY_REPORT_DAY` | `1` | Day of the week for weekly reports, 1 = Monday |
| `SMM_WEEKLY_REPORT_HOUR` | `7` | Hour of that day, UTC |
| `SMM_PYTHON` | `python3` on `PATH` | The Python used to draw PDF reports (needs `reportlab`) |

See [reports.md](reports.md).

## Sentiment

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_SENTIMENT_DIR` | unset | A directory of word lists that replace the packaged ones, file by file |

See [sentiment.md](sentiment.md).

## Remote access over SSH

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_SSH_ENABLED` | `false` | Serve the dashboard over SSH |
| `SMM_SSH_PORT` | `2222` | Port to listen on |
| `SMM_SSH_BIND` | `127.0.0.1` | Address to listen on. `0.0.0.0` means every interface |
| `SMM_SSH_AUTHORIZED_KEYS` | `~/.config/smm_monitor/authorized_keys` | Public keys allowed to connect |
| `SMM_SSH_HOST_KEY_DIR` | `~/.local/share/smm_monitor/ssh` | Where the server's host key is kept |

SSH needs a patched Erlang/OTP runtime. See [ssh.md](ssh.md).

## Display and demo data

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_DEMO` | unset | Set to `1` to show invented sample mentions everywhere. The header then says `DEMO DATA`. `SMM_MOCK_MODE=true` is the older spelling |
| `SMM_MOCK_REDDIT`, `SMM_MOCK_YOUTUBE`, `SMM_MOCK_TWITTER`, `SMM_MOCK_INSTAGRAM`, `SMM_MOCK_BLUESKY`, `SMM_MOCK_DISCORD` | unset | `true` forces demo data on that one platform, even with credentials. You never need `false`: credentials alone make a platform live |
| `SMM_TUI` | on in the downloaded binary, off otherwise | `1` draws the dashboard in this terminal (`SMM_TUI=1 mix run --no-halt`, or a release started with `bin/smm_monitor start`). `0` runs headless: collecting, alerting and serving SSH only |

Application config keys (for `config/*.exs`) are listed in
[architecture.md](architecture.md#application-config-keys).
