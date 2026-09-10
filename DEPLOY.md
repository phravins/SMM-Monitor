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
script; see the README if it fails on Python 3.11+.
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
empty file the service starts in mock mode and shows fixture data, which
is a fine way to confirm the deploy works before adding real keys.

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
[info] ssh: dashboard available on port 2222 (0 authorised key(s))
[warning] reddit is configured for live data but its credentials are missing or incomplete - falling back to mock data.
```

Those warnings are the app telling you exactly what it is missing. Add
the credentials and restart.

> **`(0 authorised key(s))`** means nobody can connect to the dashboard
> yet. That is the fail-closed default — see §5.

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
| Runtime config (brand terms) | `/etc/smm-monitor/config.json` | ✅ |
| Authorized keys | `/etc/smm-monitor/authorized_keys` | ✅ |
| Secrets | `/etc/smm-monitor/env` | ✅ |

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

Secrets, ports and poll intervals are read at boot. The **brand terms and
subreddits are not** — change those live from the config screen, no
restart needed (see the README).

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
| `ALERT` | A negative-sentiment spike fired |
| `falling back to mock data` | A platform is missing credentials |
| `quota budget spent` | YouTube stopped polling until midnight Pacific |
| `rejected connection` | Someone tried to connect with an unauthorised key |
| `could not store` | A database write failed |

Journal retention is systemd's, not ours. If you want the service capped
separately, set `SystemMaxUse=` in `/etc/systemd/journald.conf`.

---

## 5. Giving the team dashboard access

The service listens on port 2222 (`SMM_SSH_ENABLED=true`). It authorises
**nobody** until you add a key:

```sh
# Paste the .pub file a colleague sent you
sudo tee -a /etc/smm-monitor/authorized_keys < alice.pub
```

No restart needed — the file is re-read on every connection attempt.
They connect with:

```sh
ssh -p 2222 viewer@your-server
```

> **Do not expose 2222 to the internet.** Bind it to a private network or
> reach it over your VPN. The reasoning is in the README's security
> section — the authentication is sound, but there is no rate limiting
> and no audit trail beyond one line per connection.

If the server is firewalled with `ufw`:

```sh
sudo ufw allow from 10.0.0.0/8 to any port 2222 proto tcp
```

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

**The dashboard shows fixture data.** Look for `falling back to mock
data` in the journal; it names the platform. Either the credentials are
missing, or `SMM_MOCK_REDDIT` / `SMM_MOCK_YOUTUBE` is not `false`.

---

## Reference: what goes where

| Path | Owner | Contents |
| --- | --- | --- |
| `/opt/smm-monitor/<version>/` | `root` | The release. Replaced on deploy. |
| `/opt/smm-monitor/current` | `root` | Symlink to the live version. |
| `/etc/smm-monitor/env` | `root:smm-monitor` `0640` | Secrets. Read at boot. |
| `/etc/smm-monitor/authorized_keys` | `root:smm-monitor` | Who may view the dashboard. |
| `/etc/smm-monitor/config.json` | `smm-monitor` | Brand terms, written by the config screen. |
| `/var/lib/smm-monitor/mentions.db` | `smm-monitor` `0750` | Collected mentions. |
| `/var/lib/smm-monitor/ssh/` | `smm-monitor` | SSH host key. |
| `/etc/systemd/system/smm-monitor.service` | `root` | The unit. |

Nothing the app writes lives inside `/opt/smm-monitor/<version>/`, which
is what makes a deploy a directory swap and a rollback a symlink swap.
