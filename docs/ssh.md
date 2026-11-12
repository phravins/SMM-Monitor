# Remote access over SSH

[← Back to the README](../README.md)

Anyone on the team can view the live dashboard from their own terminal,
without a login on the machine it runs on:

```sh
ssh -p 2222 viewer@localhost      # through a tunnel or VPN, see below
```

The dashboard renders in their terminal exactly as it does locally. Each
connection gets its own tab, client selection and scroll position while
reading the same underlying data, so two people can look at different
clients at the same time.

**Remote sessions are read-only.** The clients screen renders, because
what is being tracked is useful context, but editing is refused with a
message saying where it can be changed. Only the host terminal can
change settings.

## Requirements

The SSH server needs an Erlang/OTP runtime with a patched `ssh`
application: **OTP 27.3.3 or later, 26.2.5.11 or later, or 25.3.2.20 or
later.** Older versions are affected by
[CVE-2025-32433](https://nvd.nist.gov/vuln/detail/CVE-2025-32433), a
flaw that lets anyone who can reach the port run code on the server
**before logging in**.

SMM Monitor checks this when it starts. On an unpatched runtime it logs
an error and does not open the port; the rest of the app keeps running.
The downloadable binaries carry a patched runtime. If you run from
source, check yours with:

```sh
erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'
```

## Turning it on

Off by default; a dashboard that starts listening on a port because
someone upgraded is not a pleasant surprise.

```sh
SMM_SSH_ENABLED=true          # opens the port
SMM_SSH_PORT=2222             # default; unprivileged, so no root needed
SMM_SSH_BIND=127.0.0.1        # default; the address to listen on
```

On first boot it generates a host key and logs where it is listening:

```
[info] ssh: generating a host key at ~/.local/share/smm_monitor/ssh/ssh_host_rsa_key (first boot)
[info] ssh: dashboard available on 127.0.0.1:2222 (3 authorised key(s))
```

### Reaching it from another machine

By default the server listens on **127.0.0.1 only**, so it cannot be
reached from the network at all. That is deliberate. The recommended way
for a teammate to connect is an SSH tunnel through an account they
already have on that machine (or on a bastion host next to it):

```sh
ssh -N -L 2222:127.0.0.1:2222 you@monitor-host     # leave this running
ssh -p 2222 viewer@localhost                        # in another terminal
```

Or over a VPN (WireGuard, Tailscale and so on): set `SMM_SSH_BIND` to
the machine's VPN address, for example `SMM_SSH_BIND=100.64.0.7`.

`SMM_SSH_BIND=0.0.0.0` listens on every interface. Only do this if a
firewall limits the port to addresses you trust — see
[Is it safe to expose publicly?](#is-it-safe-to-expose-publicly). An
address that does not parse stops the SSH server from starting, with a
message saying so.

> **Upgrading?** Older versions listened on every interface. If your
> team connected directly to `your-host:2222`, set
> `SMM_SSH_BIND=0.0.0.0` (behind a firewall), or switch them to a tunnel.

## Adding a team member

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

## The host key

Generated once on first boot and kept at
`~/.local/share/smm_monitor/ssh/` (override with `SMM_SSH_HOST_KEY_DIR`).

It must stay stable: clients pin it in `known_hosts` on first connection,
and a key that rotated every restart would greet everyone with `REMOTE
HOST IDENTIFICATION HAS CHANGED` and refuse to connect. It's generated
with Erlang's own crypto, so `ssh-keygen` doesn't need to be installed on
the server, and written `0600` in a `0700` directory.

## Security

**Traffic is encrypted.** This is a real SSH server (Erlang's `:ssh`), so
the transport gets the same encryption, integrity and host-key
verification as any other SSH connection.

**Only the dashboard is exposed.** Shell and exec requests are refused,
and the SFTP subsystem is switched off (`{:subsystems, []}`): a
connecting client can draw the dashboard and nothing else. There is no
way to get a command prompt or read a file through this port, and a
test (`test/smm_monitor/ssh/server_test.exs`) checks that an `sftp`
request is refused. Password authentication is never offered; a public
key is the only way in.

> Versions before this one left SFTP switched on by accident, which let
> any authorised viewer read and write files as the service user —
> including the environment file holding the API keys. If you ran an
> older version with SSH enabled, upgrade, and consider rotating the
> keys in that file.

**What a viewer can see:** every client, every mention collected, the
brand terms and subreddits being tracked, alert thresholds, and whether
each platform is live, not connected or showing demo data.

**What they cannot see:** any API credential — those live in the
environment or in `settings.json` and are never drawn on screen. Slack
webhook URLs are secrets too (anyone holding one can post to that
channel), so the clients screen shows only the host and the last four
characters, and a remote viewer sees only `set` or `not set`.

### Is it safe to expose publicly?

**Put it behind a VPN, a tunnel or a firewall.** Not because of a known
weakness in this version, but because the honest risk assessment is:

* The authentication itself is sound — Erlang's `:ssh` with public-key
  auth, no passwords, no shell, no SFTP.
* But this is a small service. It has had nowhere near the scrutiny
  OpenSSH has, it has no fail2ban-style throttling, no connection rate
  limiting, and no audit logging beyond a line per connection.
* An unauthenticated attacker reaching the port can attempt key auth
  indefinitely, and any future bug in Erlang's SSH code (like
  CVE-2025-32433) is reachable by anyone who can reach the port.

If you do open it, the firewall rule is **inbound TCP on
`SMM_SSH_PORT`** (2222 by default) — and restrict the source range to
your office or VPN rather than `0.0.0.0/0`.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMM_SSH_ENABLED` | `false` | Start the SSH server |
| `SMM_SSH_PORT` | `2222` | Port to listen on |
| `SMM_SSH_BIND` | `127.0.0.1` | Address to listen on (`0.0.0.0` for every interface) |
| `SMM_SSH_AUTHORIZED_KEYS` | `~/.config/smm_monitor/authorized_keys` | Public keys allowed to connect |
| `SMM_SSH_HOST_KEY_DIR` | `~/.local/share/smm_monitor/ssh` | Where the server's host key is kept |

On a systemd install the two paths default to `/etc/smm-monitor/` and
`/var/lib/smm-monitor/ssh` — see [DEPLOY.md](../DEPLOY.md).
