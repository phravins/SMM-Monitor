# Deploying SMM Monitor

SMM Monitor ships as a self-contained BEAM release: a directory
containing the app, its dependencies and the Erlang runtime. The target
server needs **neither Elixir nor Erlang installed**.

There is no Docker image and no CI pipeline — this is the manual
build-and-copy path, matching how other OSWORKS tools are deployed.

**One constraint before you start:** the release bundles the Erlang
runtime, so it is tied to the OS and CPU architecture it was built on.
Build on the same Ubuntu release as the server (or on the server itself).
An artifact built on Ubuntu 24.04 x86-64 will not run on Alpine or ARM.

**Build with a patched Erlang/OTP.** The release bundles whatever OTP the
build machine has. If you turn on SSH access (§5), that OTP must be
27.3.3 or newer (or 26.2.5.11+ / 25.3.2.20+); older versions carry
CVE-2025-32433, a pre-authentication remote code execution bug in
Erlang's SSH server, and SMM Monitor refuses to start its SSH server on
them. Check the build machine's full OTP version with:

```sh
erl -noshell -eval '{ok,V}=file:read_file(filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"])),io:put_chars(V),halt().'
```

---

## 1. Build the release

On your dev machine or a build runner:

```sh
git clone https://github.com/phravins/SMM-Monitor.git
cd SMM-Monitor
./scripts/build_release.sh
```

That runs `MIX_ENV=prod mix release` and packages the result:

```
==> Built smm_monitor 0.1.0 at _build/prod/rel/smm_monitor
==> Packaged dist/smm_monitor-0.1.0-linux-x86_64.tar.gz (8.5M)
```

If you'd rather do it by hand:

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release --overwrite
```

<details>
<summary>Build prerequisites</summary>

Elixir 1.15+, and a C toolchain for the two native dependencies:

```sh
sudo apt-get install -y build-essential erlang-dev
```

`ex_termbox` (the local TUI) also needs Python for its bundled build
script; see [the README](README.md#2-from-source) if it fails on Python 3.11+.
</details>

---

## 2. Fresh install on a new server

Ubuntu 22.04 or 24.04. Run as a user with sudo.

### 2.1 Create the service user

```sh
sudo useradd --system --no-create-home --shell /usr/sbin/nologin smm-monitor
```

**Why a dedicated user:** the app holds API credentials and a database of
client mentions, and it listens on a port. Running it as `root` would
mean any flaw in it — or in a dependency — is a flaw in the whole
machine. As `smm-monitor` it owns nothing but its own state directory.
`--no-create-home` and `nologin` mean nobody can log in as it.

### 2.2 Unpack the release

The release goes in a **versioned** directory with `current` as a
symlink. That is what makes a rollback a symlink swap rather than a
re-upload.

```sh
sudo install -d -m 0755 /opt/smm-monitor
sudo tar -xzf /tmp/smm_monitor-0.1.0-linux-x86_64.tar.gz -C /tmp
sudo mv /tmp/smm_monitor /opt/smm-monitor/0.1.0
sudo ln -sfn /opt/smm-monitor/0.1.0 /opt/smm-monitor/current
sudo chown -R root:root /opt/smm-monitor/0.1.0
```

The release is owned by `root` and the service user only reads it — the
app has no business rewriting its own code.

### 2.3 Configuration and secrets

```sh
sudo install -d -m 0750 -o root -g smm-monitor /etc/smm-monitor
sudo install -o root -g smm-monitor -m 0640 \
  /opt/smm-monitor/current/env.example /etc/smm-monitor/env
sudo editor /etc/smm-monitor/env
```

(It ships inside the release; the source is `rel/overlays/env.example`.)

`0640 root:smm-monitor` means the service can **read** its secrets but
not **rewrite** them, and no other user on the box can read them at all.

Fill in the credentials you have. Every setting is optional — with an
empty file the service starts, and each platform without credentials
shows as **NOT CONNECTED** and collects nothing. It never invents
mentions. To see the dashboard with sample data first, set `SMM_DEMO=1`
(and remove it before going live). Every variable is described in
[docs/configuration.md](docs/configuration.md).

> **Quote any value containing a space or a bracket.** systemd strips the
> quotes, and it keeps the file safe to `source` if you want to test a
> setting by hand.

### 2.4 Install the service

```sh
sudo cp /opt/smm-monitor/current/smm-monitor.service \
  /etc/systemd/system/smm-monitor.service
sudo systemctl daemon-reload
sudo systemctl enable --now smm-monitor
```

(It ships inside the release too; the source is
`rel/overlays/smm-monitor.service`.)

You do **not** need to create `/var/lib/smm-monitor` yourself — the unit
declares `StateDirectory=`, so systemd creates it, chowns it to the
service user, and passes the path to the app.

### 2.5 Verify

```sh
systemctl status smm-monitor
journalctl -u smm-monitor -n 40 --no-pager
```

A healthy first boot looks like this:

```
[info] database: applied 1 migration(s)
[info] ssh: generating a host key at /var/lib/smm-monitor/ssh/ssh_host_rsa_key (first boot)
[info] ssh: dashboard available on 127.0.0.1:2222 (0 authorised key(s))
[warning] reddit: no credentials, so nothing is being collected from it. Add them with `c` then `S` in the dashboard (Reddit and YouTube), or set this platform's environment variables. Nothing will be invented in the meantime.
```

Those warnings are the app telling you exactly what it is missing. Add
the credentials and restart.

> **`(0 authorised key(s))`** means nobody can connect to the dashboard
> yet. That is the fail-closed default — see §5. The `ssh:` lines only
> appear with `SMM_SSH_ENABLED=true`.
>
> If you see `ssh: refusing to start - this Erlang/OTP ships ssh ...`
> instead, the release was built with an unpatched OTP. Everything else
> keeps running; rebuild with OTP 27.3.3+ (see the top of this page).

---

## 3. Deploy an update

```sh
# On the build machine
./scripts/build_release.sh
scp dist/smm_monitor-0.2.0-linux-x86_64.tar.gz deploy@server:/tmp/

# On the server
sudo tar -xzf /tmp/smm_monitor-0.2.0-linux-x86_64.tar.gz -C /tmp
sudo mv /tmp/smm_monitor /opt/smm-monitor/0.2.0
sudo chown -R root:root /opt/smm-monitor/0.2.0
sudo ln -sfn /opt/smm-monitor/0.2.0 /opt/smm-monitor/current
sudo systemctl restart smm-monitor
journalctl -u smm-monitor -f
```

Database migrations run automatically on start — there is no separate
migration step.

**What survives an update**, because none of it lives inside the release
directory:

| | Where | Survives? |
| --- | --- | --- |
| Mention database | `/var/lib/smm-monitor/mentions.db` | ✅ |
| SSH host key | `/var/lib/smm-monitor/ssh/` | ✅ — so nobody gets a `known_hosts` warning |
| Clients, brand terms and every mention | `/var/lib/smm-monitor/mentions.db` | ✅ |
| Legacy single-brand config | `/etc/smm-monitor/config.json` | ✅ — read once on upgrade |
| Authorized keys | `/etc/smm-monitor/authorized_keys` | ✅ |
| Secrets | `/etc/smm-monitor/env` | ✅ |
| Tuned sentiment word lists | `/etc/smm-monitor/sentiment/` | ✅ |

### Rollback

```sh
sudo ln -sfn /opt/smm-monitor/0.1.0 /opt/smm-monitor/current
sudo systemctl restart smm-monitor
```

Keep the last two or three versions in `/opt/smm-monitor/` for this. The
one caveat: rolling back **across a migration** is not automatic — the
schema stays migrated, so an old release must still understand the new
schema. Additive migrations are fine; a destructive one needs thought
before you ship it.

### After changing `/etc/smm-monitor/env`

```sh
sudo systemctl restart smm-monitor
```

Secrets, ports and poll intervals are read at boot. **Clients, their
brand terms and their subreddits are not** — add, edit and pause those
live from the clients screen (`c`), no restart needed (see
[docs/clients.md](docs/clients.md)).

### Upgrading to the multi-client version

There is nothing to do, and nothing to back up beyond your usual copy of
`mentions.db`. On the first boot after the deploy:

* the migration adds `client_id` to the `mentions` table, creates the
  `clients` table, and assigns every existing mention to a holding
  client. It logs how many it moved:

  ```
  scope_mentions_to_clients: assigned 48213 existing mention(s) to the
  "Unassigned" client
  ```

* that client is then named from whatever brand you were tracking, read
  from `/etc/smm-monitor/config.json` (falling back to `SMM_KEYWORDS`):

  ```
  clients: no clients stored yet - created "Real office" from the previous
  single-brand settings (config_file): realoffice, real office
  ```

Both lines are worth grepping for after the deploy — together they say
your history survived and is attached to a client that is still being
polled for.

The config file is left untouched and never written to again, so a
rollback to the previous release is a symlink swap as usual. The one
caveat is the usual one for migrations: the old release doesn't know
about `client_id`, but the column is additive and nullable to it, so it
keeps working.

### Tuning the sentiment word lists

The packaged lists ship inside the release, so edits there are lost on
the next deploy. Copy the ones you want to tune out to
`/etc/smm-monitor/sentiment/` instead and point the app at them:

```sh
sudo install -d -m 0750 -o root -g smm-monitor /etc/smm-monitor/sentiment
sudo cp /opt/smm-monitor/current/lib/smm_monitor-*/priv/sentiment/mild_negative.txt \
  /etc/smm-monitor/sentiment/
sudo editor /etc/smm-monitor/sentiment/mild_negative.txt
# then add to /etc/smm-monitor/env:
#   SMM_SENTIMENT_DIR=/etc/smm-monitor/sentiment
sudo systemctl restart smm-monitor
```

Any file present there wins; the rest are still read from the release,
so you override one category without copying all seven. See
[docs/sentiment.md](docs/sentiment.md) for what each list does.

---

## 4. Logs

The release logs to stdout and systemd routes it to the journal.

```sh
journalctl -u smm-monitor -f              # follow live
journalctl -u smm-monitor -n 100          # last 100 lines
journalctl -u smm-monitor --since "1 hour ago"
journalctl -u smm-monitor -p warning      # warnings and errors only
journalctl -u smm-monitor --since today | grep ALERT
```

Production logs at `:info`, so a healthy boot is visibly healthy rather
than silent. Things worth grepping for:

| Pattern | Meaning |
| --- | --- |
| `ALERT` | An alert fired: sentiment, volume or a watch phrase |
| `RESOLVED` | An alert cleared, with how long it ran |
| `nothing is being collected` | A platform is missing credentials |
| `refusing to start` | SSH is off because the bundled OTP is unpatched |
| `quota budget spent` | YouTube stopped polling until midnight Pacific |
| `rejected connection` | Someone tried to connect with an unauthorised key |
| `could not store` | A database write failed |

Journal retention is systemd's, not ours. If you want the service capped
separately, set `SystemMaxUse=` in `/etc/systemd/journald.conf`.

---

## 5. Giving the team dashboard access

SSH access is **off** unless `/etc/smm-monitor/env` has
`SMM_SSH_ENABLED=true`. When on, the service listens on port 2222
(`SMM_SSH_PORT`) on **127.0.0.1 only** (`SMM_SSH_BIND`), so nothing
outside the server can reach it until you decide how. It authorises
**nobody** until you add a key:

```sh
# Paste the .pub file a colleague sent you
sudo tee -a /etc/smm-monitor/authorized_keys < alice.pub
```

No restart needed — the file is re-read on every connection attempt.
Viewers get the dashboard, read-only: no shell, no commands, no file
transfer (SFTP is disabled).

### Reaching it from another machine

Pick one:

**An SSH tunnel (recommended, no config change).** Anyone who can
already log in to the server over normal SSH runs:

```sh
ssh -N -L 2222:127.0.0.1:2222 you@your-server     # leave running
ssh -p 2222 viewer@127.0.0.1                       # in a second terminal
```

**A private network or VPN address.** Bind to the server's address on
that network, restart, and allow only that network:

```sh
# /etc/smm-monitor/env
SMM_SSH_BIND=10.0.0.5
```

```sh
sudo systemctl restart smm-monitor
sudo ufw allow from 10.0.0.0/8 to any port 2222 proto tcp
```

Colleagues then connect with `ssh -p 2222 viewer@10.0.0.5`.

`SMM_SSH_BIND=0.0.0.0` listens on every interface. Only use it behind a
firewall that limits port 2222 to trusted addresses.

> **Do not expose 2222 to the internet.** The authentication is sound,
> but there is no rate limiting and no audit trail beyond one line per
> connection. See [docs/ssh.md](docs/ssh.md) and
> [docs/security.md](docs/security.md).

> **Upgrading from a version where SSH listened on every interface?**
> Remote viewers will stop reaching it until you choose one of the
> options above. That version also left SFTP switched on, so any
> authorised viewer could have read `/etc/smm-monitor/env`: rotate the
> API keys and webhook URLs in it.

---

## 6. Troubleshooting

**Service won't start.** `journalctl -u smm-monitor -n 50` first. Then
run the release by hand as the service user, which surfaces errors that
systemd swallows:

```sh
sudo -u smm-monitor \
  STATE_DIRECTORY=/var/lib/smm-monitor \
  CONFIGURATION_DIRECTORY=/etc/smm-monitor \
  /opt/smm-monitor/current/bin/smm_monitor start
```

**`Permission denied` on the database.** The state directory is not owned
by the service user:

```sh
sudo chown -R smm-monitor:smm-monitor /var/lib/smm-monitor
```

**`bin/smm_monitor remote` says the node isn't running.** Expected. The
release sets `RELEASE_DISTRIBUTION=none` — this is a single node that
never clusters, and leaving distribution on makes it depend on epmd and
on the host resolving its own hostname, which is a common way for a
service to fail to start on a fresh box. If you need a remote shell on a
particular server, set `RELEASE_DISTRIBUTION=sname` and `RELEASE_NODE` in
`/etc/smm-monitor/env` and restart.

**Wrong architecture.** `cannot execute binary file: Exec format error`
means the release was built on a different platform. Rebuild on a
matching one.

**A platform shows NOT CONNECTED.** Look for `nothing is being
collected` in the journal; it names the platform. Add its credentials to
`/etc/smm-monitor/env` and restart.

**The header says DEMO DATA.** `SMM_DEMO=1` (or the older
`SMM_MOCK_MODE=true`) or one of `SMM_MOCK_REDDIT` / `SMM_MOCK_YOUTUBE` /
`SMM_MOCK_TWITTER` / `SMM_MOCK_INSTAGRAM` / `SMM_MOCK_BLUESKY` /
`SMM_MOCK_DISCORD` / `SMM_MOCK_THREADS` / `SMM_MOCK_MASTODON` is set in
`/etc/smm-monitor/env`. Remove the line and restart; credentials alone
make a platform live.

**A platform shows `error` or `stale` in the footer.** The last polls
failed. `journalctl -u smm-monitor -p warning -n 50` shows why, usually
an expired token or a spent quota.

---

## Reference: what goes where

| Path | Owner | Contents |
| --- | --- | --- |
| `/opt/smm-monitor/<version>/` | `root` | The release. Replaced on deploy. |
| `/opt/smm-monitor/current` | `root` | Symlink to the live version. |
| `/etc/smm-monitor/env` | `root:smm-monitor` `0640` | Secrets. Read at boot. |
| `/etc/smm-monitor/authorized_keys` | `root:smm-monitor` | Who may view the dashboard. |
| `/etc/smm-monitor/config.json` | `smm-monitor` | Legacy single-brand config. Read once on upgrade to seed the first client, then never written again. |
| `/etc/smm-monitor/sentiment/` | `root:smm-monitor` | Word lists overriding the packaged ones. Optional. |
| `/var/lib/smm-monitor/mentions.db` | `smm-monitor` `0600` | Collected mentions. |
| `/var/lib/smm-monitor/threads_token.json` | `smm-monitor` `0600` | The renewed Threads token, if Threads is on. Next to it, `bluesky.cursor`, `discord.cursor` and `mastodon.cursor` when those are on. |
| `/var/lib/smm-monitor/ssh/` | `smm-monitor` | SSH host key. |
| `/etc/systemd/system/smm-monitor.service` | `root` | The unit. |

Nothing the app writes lives inside `/opt/smm-monitor/<version>/`, which
is what makes a deploy a directory swap and a rollback a symlink swap.

The unit sets `UMask=0077`, and the app creates its own directories
`0700` and its files `0600`, so the database, reports and SSH host key
are readable by the service user only.
