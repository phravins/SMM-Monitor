# Security

[← Back to the README](../README.md)

What SMM Monitor protects, how, and what is still missing. If you find a
security problem, please report it privately to the maintainers rather
than in a public issue.

## What there is to protect

| Asset | Where it lives | Who could want it |
| --- | --- | --- |
| API credentials (Reddit, YouTube, X, Instagram) | Environment, or `settings.json` for wizard-entered keys | Anyone wanting to use your paid API quota, or Instagram access to your business account |
| Slack webhook URLs | Environment, or the database (per-client webhooks) | Anyone wanting to post into your Slack channels |
| Collected mentions, clients and alert history | SQLite database | Competitors; mostly public posts, but the client list and the analysis are yours |
| Reports | The reports directory | As above, and they are handed to clients |
| The server itself | — | Anyone who can reach the SSH port |

And what SMM Monitor reads that it should **not** trust:

* **Every post it collects.** The text of a mention is written by a
  stranger. It ends up on your terminal, in Slack messages, in CSV files
  opened in Excel, and in PDFs.
* **API responses**, which can be malformed or (on a hostile network)
  forged.

## How it is protected

### Secrets

* Credentials are only read from the environment or from
  `settings.json`, and are never written to the database, the log or the
  screen.
* `settings.json` is written `0600` inside a `0700` directory, through an
  exclusively created temporary file, so another user on the machine can
  neither read it nor swap it out mid-write. An existing file with looser
  permissions is tightened when it is loaded.
* Crash reports and process inspection redact credentials: the Reddit
  token struct hides its token, and the poller's state is scrubbed
  before it is logged. The stream worker (Bluesky, Discord, Mastodon) does the same: its
  platform state shows as `redacted` in crash reports and `:sys`
  inspection.
* HTTP error responses are shortened before they are logged, so an API
  that echoes your request back does not put a key in the log.
* Slack webhook URLs are shown masked on the clients screen (host plus
  the last four characters), and SSH viewers only see `set` or
  `not set`.
* The database, reports and their directories are created readable only
  by the user SMM Monitor runs as. The systemd unit adds `UMask=0077`.
  The streams' resume positions (`bluesky.cursor`, `discord.cursor` and
  `mastodon.cursor`, next to the database) are written `0600` through an exclusively created
  temporary file and a rename. Discord's lists the ids of the channels
  being watched, so it is treated like the database.

### Streaming connections (Bluesky, Discord, Mastodon)

* `wss://` connections check the server's certificate against the
  system CA store and check that it matches the host name. Plain
  `ws://` is refused unless the host is the local machine, so a
  mistyped `SMM_BLUESKY_JETSTREAM_URL` or `SMM_MASTODON_STREAMING_URL`
  cannot send traffic in the clear.
* A single message is capped at **1 MB** (8 MB for Discord, whose
  server list for a large server can exceed 1 MB), and a frame over the
  cap is refused from its header alone, before any of it is read into
  memory.
  The server's handshake response is capped at **16 KB**. Either one
  closes the connection and it is reopened with back-off.
* The connection only *receives*. Bluesky is never told the brand terms:
  every post on the network arrives and is matched locally, so no
  third party learns which brands you watch. The only outgoing request
  is the public profile lookup that turns an author's DID into a
  handle, and it carries author ids only.

### The Discord bot

* The bot token is sent in exactly three places: the Gateway's identify
  and resume messages, and the `Authorization` header of the catch-up
  requests to `https://discord.com/api/v10`. It is never put in a URL,
  a log line, the status shown on screen or a crash report.
* Discord tells the bot where to reconnect to resume a session. That
  address is used only if it is `wss://` and its host ends in
  `.discord.gg`, with no user name or password in it; anything else
  falls back to `gateway.discord.gg`. A tampered or malformed address
  therefore cannot be used to collect the token.
* The invite link asks for **View Channels** and **Read Message
  History** only (`permissions=66560`). The bot cannot post, react,
  moderate, or read direct messages; it asks for the server, message
  and message-content events and nothing else.
* Server, channel and message ids are checked to be plain numbers
  before a link is built, and links always point at
  `https://discord.com/channels/...`. A message with a malformed id is
  dropped.
* Like Bluesky, Discord is never told the brand terms. Messages that do
  not match are discarded unread and never stored.
* Errors from the catch-up requests are logged with the HTTP status
  and channel id only, never the response headers.

### The Mastodon token

* The token is sent only in the `Authorization` header, over TLS with
  the certificate checked: on the WebSocket handshake to the streaming
  host, and on the catch-up requests to
  `https://{MASTODON_INSTANCE}/api/v1/timelines/public`. It is never put
  in a URL, a log line, the status shown on screen or a crash report.
  The lookup that finds the streaming host (`/api/v2/instance`) is sent
  without it.
* The streaming host comes from your own server's answer, or from
  `SMM_MASTODON_STREAMING_URL`. It is used only if it is `wss://` with no
  user name or password in it; anything else falls back to
  `wss://{MASTODON_INSTANCE}`. A handshake that is redirected or answers
  404 makes the next attempt ask the server again rather than follow it.
* `MASTODON_INSTANCE` must be a plain host name (an `https://` address is
  reduced to its host); one with a port, path, query or user name stops
  the app at start-up.
* Ask for `read:statuses` only. With it the token can read posts and
  nothing else: it cannot post, follow, or read your direct messages.
  A token the server refuses stops the stream instead of retrying it
  every minute.
* Errors from the server are logged with the HTTP status and Mastodon's
  error text only, never the request or response headers.

### The Threads token

* The token goes only to `https://graph.threads.net`, over HTTPS with
  the certificate checked. Meta's API takes it as a query parameter, so
  request URLs are never logged, and errors are logged with the HTTP
  status and Meta's message only. A network error is logged by its
  reason alone, because the exception would carry the request.
* The token is left out of the fetcher's state when it is inspected,
  and the poller's whole platform state is redacted from status and
  crash reports.
* A renewed token is kept in `threads_token.json`, next to the database,
  written `0600` through an exclusively created temporary file and a
  rename. The token from `THREADS_ACCESS_TOKEN` is never written to disk:
  the file stores a SHA-256 hash of it, only to notice when a different
  one is pasted. A token read from the file is used only if it looks
  like one (printable characters, no spaces, at most 4 KB), so a
  tampered file cannot inject anything into a request.
* Post and account ids are checked to be plain numbers before they go
  into a request path or a mention id, and usernames are checked
  against Threads' own character set; anything else is dropped or shown
  as `@unknown`. Links are kept only when they are `https` links to
  `threads.com` or `threads.net` with no user name in them.
* The connected account is read-only here: SMM Monitor never posts,
  replies or deletes, and does not ask for the permissions to.

### News feeds

News needs no credential, but every feed is a document from a server
you do not control, so it is read as hostile input.

* Feed addresses must be `https://` with no user name or password in
  them; anything else stops the app at start-up. Redirects are followed
  by hand, at most 3, and only to `https`. A redirect to `http`, to an
  address with a password in it, or past the third hop counts as a
  failed fetch.
* A response is read in pieces and dropped as soon as it passes 5 MB.
  Compression is not asked for, so a small download cannot unpack into
  a huge one.
* The XML is parsed with Saxy, which never expands entities declared in
  a `DOCTYPE` and never fetches external ones, so a feed cannot run a
  "billion laughs" attack or read a file off the machine. At most 100
  items are read from a feed, and headlines, summaries and names are
  capped in length.
* An article's link is kept only when it is `http` or `https` with no
  user name or password; `javascript:`, `data:` and the like are
  dropped. Text goes through the same clean-up as every post.
* Requests send no cookies, and the `User-Agent` names only the software
  (`smm_monitor/<version> (feed reader)`), never you or your clients.
* Feeds are named in the log by host and path only, so a feed address
  that carries a key in its query string never reaches the log. A
  network error is logged by its reason alone.
* With Google News search switched on, the only thing sent to Google is
  each brand term, as the search query.

### Remote access (SSH)

Off by default. When it is on:

* It listens on **127.0.0.1** unless `SMM_SSH_BIND` says otherwise.
* Public-key authentication only, checked against an `authorized_keys`
  file that is re-read on every attempt. A missing or empty file lets
  nobody in.
* No shell, no exec, and **no SFTP**. Viewers get the dashboard and
  nothing else, read-only.
* It refuses to start on an Erlang/OTP runtime affected by
  CVE-2025-32433 (pre-authentication remote code execution in Erlang's
  SSH server). The released binaries bundle OTP 27.3.4.17.

Details: [ssh.md](ssh.md).

### Untrusted text from posts

* Control characters, terminal escape sequences, bidirectional
  overrides, zero-width and invisible formatting characters are removed
  from every mention before it is stored or drawn, and long runs of
  combining marks ("Zalgo text") are capped. A post cannot move the
  cursor, recolour the screen or disguise one word as another.
* Slack alerts escape `&`, `<` and `>`, so a post cannot trigger
  `@channel`, mention users or plant a disguised link. The post excerpt
  is sent as plain text and capped at 300 characters.
* CSV cells starting with `=`, `+`, `-`, `@`, tab or carriage return
  are prefixed with `'`, so a spreadsheet shows them as text instead of
  running them as formulas.
* Reddit links always point at `https://reddit.com` plus the post's or
  comment's permalink, never at whatever external link the post carries.
* Subreddit names are checked against Reddit's own rule (letters, digits
  and underscores, up to 21 characters) before they go into a request
  path, so a name typed on the clients screen cannot steer a request to
  another Reddit endpoint. Redirects from a subreddit listing are not
  followed.
* Bluesky links are built from the post's author id and record key,
  both checked against a strict pattern first, and always point at
  `https://bsky.app`. Handles from the network are checked the same way
  before they are shown; one that fails is replaced by the author id.
* Mastodon links are built on your own server
  (`https://{MASTODON_INSTANCE}/@user@server/{id}`) from the post id and
  account name, both checked against a strict pattern first, never taken
  from the post. A post whose id or account name fails is dropped.
  Posts arrive as HTML; tags are removed and entities decoded before
  the text goes through the same clean-up as every other post, so markup
  cannot reach the screen, a report or Slack.
* Discord's `<@id>`, `<#id>`, `<@&id>` and custom-emoji codes are turned
  into plain `@name`, `#channel` and `:emoji:` text, and names go through
  the same clean-up as message text, so a user name cannot carry escape
  sequences on to the screen.
* Values read back from the database are matched against a fixed list
  rather than turned into new atoms, so stored data cannot exhaust the
  Erlang atom table.

### Downloads and builds

* The installers only use HTTPS, including for redirects, and the Linux
  and macOS installer checks the binary against the release's
  `SHA256SUMS` before installing it.
* The release workflow runs with read-only repository permissions except
  for the one job that publishes, verifies the Zig toolchain against a
  pinned checksum, and does not reuse caches from other branches.
* PDF reports run Python in isolated mode (`-I`), from a fixed
  interpreter found once (`SMM_PYTHON` to override), with its input in a
  private temporary directory.

### The systemd service

[`rel/overlays/smm-monitor.service`](../rel/overlays/smm-monitor.service)
runs as a dedicated unprivileged user with a read-only view of the
system, a private `/tmp`, no new privileges, a restricted set of system
calls and address families, and `UMask=0077`.
`MemoryDenyWriteExecute` is deliberately not set: the Erlang JIT needs
memory that is both writable and executable.

## Fixed in this release

An audit of the previous version found the following, all fixed:

| Severity | Problem | Fix |
| --- | --- | --- |
| High | SFTP was accidentally left enabled on the SSH server, so any authorised viewer could read and write files as the service user, including the env file with every API key | SFTP switched off; a test checks it stays off |
| High | Released binaries bundled OTP 25.3.2.8, affected by CVE-2025-32433 | Binaries now bundle OTP 27.3.4.17; the SSH server refuses to start on an affected runtime |
| Medium | SSH listened on every network interface | Listens on 127.0.0.1 by default (`SMM_SSH_BIND`) |
| Medium | Post text could inject Slack formatting, `@channel` and disguised links into alerts | Escaped; excerpt sent as plain text |
| Medium | CSV reports were open to spreadsheet formula injection | Risky cells prefixed with `'` |
| Medium | Webhook URLs were shown in full on screen, including to SSH viewers | Masked; SSH viewers see `set` / `not set` |
| Medium | Tokens and credentials could appear in crash logs | Redacted; error bodies shortened |
| Medium | Installers did not verify what they downloaded | HTTPS-only, SHA256 checked |
| Medium | Database, reports and settings directories used default permissions | `0700` directories, `0600` files, `UMask=0077` |
| Low | Several smaller issues: settings file race, PDF helper's temp file and Python lookup, atom creation from stored data, invisible Unicode in posts, Reddit links to external sites, `http://` webhooks accepted, compiled Python files committed, release workflow permissions, unclear errors for bad numeric settings, key file paths in logs | Each fixed |

**If you ran an earlier version with SSH enabled**, upgrade and rotate
the API keys and webhook URLs in your env file, since any authorised
viewer could have read them.

## Known gaps

These were found in the same audit and are not fixed yet:

* **`authorized_keys` options are ignored.** Lines such as
  `from="10.0.0.0/8" ssh-ed25519 ...` are read for the key only; the
  `from=` restriction is not enforced. Restrict by network instead
  (`SMM_SSH_BIND`, firewall).
* **No idle timeout for SSH sessions.** A viewer who leaves a session
  open stays connected until they close it or the server restarts.
* **SSH sessions accept environment variables** sent by the client
  (inherited from the SSH library). They do not affect the dashboard,
  but they are not refused either.
* **No limit on API response size for polled platforms.** A very large
  HTTP response from Reddit, YouTube, X or Instagram is read in full.
  Streaming connections are capped (see above).
* **The cross-compiler wrapper used for release builds** (`burrito-cc`)
  builds a command with `eval`. It only ever sees arguments from the
  build itself, never user input.
* **Unicode tag characters and zero-width joiners are kept**, because
  emoji flags and emoji sequences need them. They are invisible but
  cannot control the terminal.
* **SSH has no rate limiting or audit log** beyond one line per
  connection. Keep it behind a tunnel, VPN or firewall.

## Checklist for a server install

* [ ] `/etc/smm-monitor/env` is `root:smm-monitor`, mode `0640`.
* [ ] SSH stays on `127.0.0.1`, or the port is firewalled to trusted
      addresses.
* [ ] `authorized_keys` lists only current team members.
* [ ] The X and Instagram tokens have only the permissions the
      [platforms guide](platforms.md) lists, and the YouTube key is
      restricted to the YouTube Data API.
* [ ] Slack webhooks post to channels you expect.
* [ ] You upgrade when a new release is published; each binary carries
      its own Erlang runtime, so OS updates do not patch it.
