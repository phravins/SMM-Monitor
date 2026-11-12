# Connecting platforms

[← Back to the README](../README.md)

SMM Monitor collects from six platforms. Five are switched on by
giving them credentials; Bluesky needs no account and is switched on
with one setting. **A platform that is switched on collects live data;
one that is not collects nothing** and shows as not connected. Nothing
is invented unless you ask for demo data with `SMM_DEMO=1`.

| Platform | Cost | Set up from | What it can actually find |
| --- | --- | --- | --- |
| **Reddit** | Free | Setup wizard or environment | Public posts matching your brand terms, across Reddit or in chosen subreddits |
| **YouTube** | Free daily quota | Setup wizard or environment | Public videos matching your brand terms |
| **X (Twitter)** | Paid API plan | Environment | Recent public posts matching your brand terms (last 7 days) |
| **Instagram** | Business account | Environment | Only your own account's surroundings — [see below](#what-instagram-monitoring-can-and-cannot-see) |
| **Bluesky** | Free, no account | Environment (`SMM_BLUESKY_ENABLED=true`) | Every new public post that names your brand, within a second or two — [see below](#bluesky) |
| **Discord** | Free | Environment (`DISCORD_BOT_TOKEN`) | Messages that name your brand, in the servers you invite the bot to — [see below](#discord) |

**Start with Reddit.** It is free, it takes about three minutes, and it
behaves most like what people expect the whole app to do.

## First, point it at your own brand

Before connecting anything, make sure it is searching for the right
words. A fresh install watches `realoffice, real office`, which are
placeholders, not yours.

Press `c` for the clients screen:

![The clients screen showing one client called OSWORKS with its brand
terms, subreddits and alert thresholds, and a PLATFORM MODE panel
listing each platform's mode](images/clients.png)

*The **PLATFORM MODE** panel at the bottom is worth knowing about: it
tells you, at a glance, which platforms are live, which are not
connected, and which are showing demo data.*

Then:

| Key | What it does |
| --- | --- |
| `j` / `k` | Move between clients |
| `h` / `l` | Move between a client's fields |
| `e` or `Enter` | Edit the field you're on |
| `Enter` | Save |

Set **name** to the brand and **brand terms** to the words people
actually write — for OSWORKS, something like `osworks, os works,
osworks.in`. Add subreddits worth watching while you're there.

While you're editing a field, every key is typed as text, including `q`
and the tab letters — so a brand term like "quality" goes in fine.
`Ctrl-C` always quits.

## Two ways to give it keys

**The setup wizard** (Reddit and YouTube only). In the dashboard press
`c`, then `S`, and paste the keys when asked. They are saved to
`~/.config/smm_monitor/settings.json` (mode `0600`, in a `0700`
directory) and take effect **immediately**: the platform is polled
straight away, without a restart. Re-running the wizard and pressing
`Esc` on a step keeps the key you saved before; typing a new one
replaces it.

**Environment variables** (all four platforms). Put them in a `.env`
file (see [`.env.example`](../.env.example)) or, on a server, in
`/etc/smm-monitor/env` (see [DEPLOY.md](../DEPLOY.md)). They are read at
startup, so changing one needs a restart.

```sh
cp .env.example .env        # fill in what you have
set -a; . ./.env; set +a
smm-monitor                 # or: mix smm.tui from a checkout
```

If a key is set in both places, **the environment wins**: a server's
configuration should not be overridden by someone at the keyboard.

You do **not** need any `SMM_MOCK_*` switch. Older versions of this
README told you to set `SMM_MOCK_REDDIT=false` and friends; a key on its
own is now enough. The switches still exist, but only to force demo data
on one platform: `SMM_MOCK_TWITTER=true` shows invented X posts even if
a bearer token is set.

`.env` is gitignored, and credentials are only read in
`config/runtime.exs`, so nothing is hardcoded and nothing is committed.

### Is it working?

The header ends with `LIVE` once at least one platform is collecting.
The status line at the bottom shows each platform's mode and the age of
its newest data, and the **PLATFORM MODE** panel on the clients screen
adds when it will be asked next:

```text
reddit:live 12s youtube:live 4m twitter:unconfigured instagram:unconfigured

reddit        live · 12s ago · next 18s
```

`unconfigured` means no credentials, `error` means the last poll failed,
and `stale` means the last successful poll is more than three
poll intervals old — usually a wrong key, a spent quota or no network.
The log says which.

## Reddit

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


### Adding them

Either press `c` then `S` in the dashboard and paste the client id and
secret, or set them in the environment:

```sh
REDDIT_CLIENT_ID=your_client_id
REDDIT_CLIENT_SECRET=your_client_secret
REDDIT_USER_AGENT="smm_monitor/0.1 (by /u/yourusername)"
```

> **On the user agent:** Reddit rejects requests with a generic or empty
> user agent, and asks that you identify yourself. Including your Reddit
> username is the convention.

Which subreddits are searched is set **per client** on the clients
screen. A client with no subreddits searches all of Reddit.
`SMM_REDDIT_SUBREDDITS` only seeds the first client on a fresh install.

### What Reddit gets asked

Each poll is **one** HTTP request. The configured subreddits are combined
into a single multireddit search (`/r/marketing+smallbusiness/search`)
rather than one request per subreddit, so watching twenty subreddits costs
the same quota as watching one.

Search terms are the client's brand terms; multi-word terms are quoted
as phrases, and terms are OR-ed together. `realoffice, real office`
becomes `realoffice OR "real office"`.

At the default 30-second poll interval that's 2 requests/minute against a
60/minute budget. The fetcher tracks the quota Reddit reports on every
response and stops five requests short of the limit, so a burst from
something else sharing the credentials can't push you into a hard 429.


Each poll asks for posts from the **last day** (`time_filter: "day"`),
so a post is picked up while it is still current. Links in the dashboard
and in reports always point at `https://www.reddit.com` plus the post's
permalink, never at whatever external URL a post links to.

## YouTube

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

### YouTube quota

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
| 5 min | 288 | 28,800 | Budget gone after **~6.7 hours**, dark until the reset |
| 10 min | 144 | 14,400 | Dark after ~13 hours |
| 15 min | 96 | 9,600 | Dark after ~20 hours |
| **18 min** *(default)* | **80** | **8,000** | **Covers a full day** |
| 30 min | 48 | 4,800 | Comfortable, half the budget unused |

The default is 18 minutes, the fastest interval that lasts the whole
day for **one client**. A faster interval gives a responsive dashboard
for a working morning and then nothing. With several clients the budget
is shared, so slow it down further — see
[clients.md](clients.md#making-the-budget-go-further):

```sh
SMM_YOUTUBE_POLL_INTERVAL_MS=3300000   # 55 minutes, for three clients
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

One `search.list` call per poll, per client, for videos matching that
client's brand terms (joined with YouTube's `|` OR syntax, phrases
quoted), ordered by date, published within the last 24 hours. The channel
title becomes the mention's author, the video title and description become
its text.


## X / Twitter

### Getting an X (Twitter) API bearer token

Recent search needs a **paid tier**. The free tier can post but cannot
read search results, so there is no free path to this data — budget for
it before wiring it up.

1. Go to <https://developer.x.com/en/portal/dashboard> and sign in with
   the account that will own the integration.
2. Create a **Project** (not just an App). Recent search is a v2
   endpoint, and v2 endpoints only work with keys attached to a Project —
   a standalone App returns 403 no matter how valid its token is.
3. Inside the Project, create an **App**.
4. Subscribe the Project to a paid tier. Basic is the cheapest that
   includes `/2/tweets/search/recent`.
5. Open the App's **Keys and tokens** tab and generate a **Bearer
   Token**. Copy it immediately — the portal shows it once, and
   regenerating invalidates the old one.

That token is the whole credential: app-only auth, no user context, no
refresh flow, nothing to cache. Treat it like a password.

```bash
export TWITTER_BEARER_TOKEN='AAAAAAAAAAAAAAAAAAAAA...'
```

### X's two limits, and why they're tracked differently

X bounds recent search twice, and confusing the two is how an
integration goes dark for three weeks:

| Limit | Reported? | How it's handled |
| --- | --- | --- |
| **Requests per 15 minutes** | Yes — `x-rate-limit-*` headers | Read from every response; backs off before the window empties, waiting exactly until the reset |
| **Posts per month** (the Project's post cap) | **No header at all** | Counted locally against a conservative budget, like YouTube's quota |

The monthly cap is the one that ends a month early. Nothing in a
response says how close it is, so `SMM_TWITTER_MONTHLY_POST_BUDGET`
holds a self-imposed ceiling — **10,000 by default, deliberately low**.
Set it to what your plan actually allows:

```bash
export SMM_TWITTER_MONTHLY_POST_BUDGET=50000
# If your billing cycle doesn't start on the 1st:
export SMM_TWITTER_BILLING_CYCLE_DAY=12
```

Standing down early costs coverage that this one variable fixes.
Overrunning the cap costs the rest of the month, so the default errs the
recoverable way. The real figure is at `GET /2/usage/tweets` in the
developer portal — worth checking after the first week and setting the
budget from what you see.

Two things keep the spend down without any tuning: the query excludes
retweets (500 retweets of one complaint would read as 500 complaints
*and* cost 500 posts), and the counter charges for posts actually
returned rather than the page size requested.

### What X gets asked

One `GET /2/tweets/search/recent` per client per poll, for that
client's brand terms OR-ed together with phrases quoted, minus retweets,
over the last 7 days. Author handles come back through the `author_id`
expansion. A tweet whose author is missing from that expansion — a
deleted or protected account — still becomes a mention under `@unknown`,
because the text is the point.

Polling defaults to 5 minutes rather than 30 seconds, since the monthly
cap rather than the 15-minute window is what this platform runs out of.
`SMM_TWITTER_POLL_INTERVAL_MS` overrides it.


## Instagram

### Getting Instagram Graph API access

More setup than the others, because Meta scopes everything to an account
you control:

1. The Instagram account must be a **Business or Creator** account, not
   personal. (Instagram app → Settings → Account type.)
2. It must be **linked to a Facebook Page** you administer. (Page →
   Settings → Linked accounts → Instagram.)
3. Create an app at <https://developers.facebook.com/apps> — type
   **Business** — and add the **Instagram Graph API** product to it.
4. In **Graph API Explorer**, select your app, then generate a User
   Access Token with these permissions: `instagram_basic`,
   `instagram_manage_comments`, `pages_show_list` and
   `pages_read_engagement`.
5. **Exchange it for a long-lived token.** The token the Explorer gives
   you expires in about an hour:

   ```bash
   curl -s "https://graph.facebook.com/v21.0/oauth/access_token\
   ?grant_type=fb_exchange_token\
   &client_id=<APP_ID>\
   &client_secret=<APP_SECRET>\
   &fb_exchange_token=<SHORT_LIVED_TOKEN>"
   ```

6. **Find the Instagram Business Account ID** — not the username, and
   not the Facebook Page id:

   ```bash
   # The Page linked to the Instagram account:
   curl -s "https://graph.facebook.com/v21.0/me/accounts?access_token=<TOKEN>"

   # Then, with that Page's id:
   curl -s "https://graph.facebook.com/v21.0/<PAGE_ID>\
   ?fields=instagram_business_account&access_token=<TOKEN>"
   ```

   The `instagram_business_account.id` in that response — a 17-digit
   number beginning `1784…` — is what goes in the env var.

7. Going beyond your own test accounts needs **App Review** for those
   permissions. In development mode the app works for accounts with a
   role on it, which is enough to monitor your own brand.

```bash
export INSTAGRAM_ACCESS_TOKEN='EAAG...'
export INSTAGRAM_BUSINESS_ACCOUNT_ID='17841400000000000'
```

⚠️ **Long-lived tokens expire after 60 days.** Refresh before then, or
Instagram silently stops returning data. The fetcher detects this
specific failure and logs `expired_access_token` rather than a generic
400, because a 60-day clock that fails quietly is worth naming.

### What Instagram monitoring can and cannot see

**Read this before trusting the Instagram tab.**

Reddit, YouTube and X all answer the question this tool exists to ask:
*who mentioned this brand anywhere on the platform?* **Instagram does
not.** There is no endpoint in the Graph API — at any tier, for any
amount of money — that takes a keyword and returns public posts
containing it. Instagram removed that capability years ago and has not
replaced it.

So Instagram monitoring here is **not** brand-wide search. It is three
narrow, account-scoped views, and you choose which ones to poll:

| Source | What it sees | Limits |
| --- | --- | --- |
| `tags` *(default)* | Posts by other people that **@-tag your account** in the media | Only posts where they actually tagged you |
| `comments` *(default)* | Comments on **your own** posts | Your posts only; bounded by `:media_limit` |
| `hashtag` *(opt-in)* | Public posts carrying a **tracked hashtag** | 30 unique hashtags per rolling 7 days; last 24 hours only; **no author** |

What **none** of them sees:

- **Someone writing "realoffice is broken" in a caption without tagging
  you.** Meta delivers @-mentions in other people's captions and
  comments *only by webhook* — a push to a public HTTPS endpoint. There
  is no pull equivalent, so a polling tool on a private box cannot
  retrieve them. Not implemented here, and not implementable without a
  public callback URL.
- **Stories, Reels-only mentions, or private accounts.** Out of scope
  for these edges.
- **Who posted a hashtag result.** Meta strips usernames from hashtag
  search — no personally identifying information is returned — so those
  mentions are attributed to `#realoffice` rather than to a person. That
  is honest; `@unknown` would imply we looked and failed.

Practically: **Instagram will under-report** compared to the other three
platforms, and a quiet Instagram tab means "nobody tagged us", not
"nobody mentioned us". If Instagram coverage is commercially important,
the honest options are Meta's webhooks (a public endpoint plus App
Review) or a third-party listening vendor with its own crawl — not a
setting in this app.

Turn the hashtag source on if you want the widest coverage the API
allows:

```bash
export SMM_INSTAGRAM_SOURCES=tags,comments,hashtag
export SMM_INSTAGRAM_HASHTAGS=realoffice,realofficeapp
```

Keep that hashtag list **short and stable**: Meta counts 30 *unique*
hashtags per rolling 7 days per account, and editing the list churns
through that budget. Hashtag ids are cached in the worker between polls,
since they never change.

### What Instagram gets asked

Per poll, one request per enabled source: `/{account-id}/tags`,
`/{account-id}/media` with the comments nested via field expansion (one
request, not one per post), and for hashtags an `ig_hashtag_search`
lookup — cached after the first — plus one `recent_media` call per tag.

Meta reports rate limiting as a **percentage of an opaque hourly
allowance** in `x-business-use-case-usage`, not as a count of requests
left. The fetcher backs off at 90%, because the percentage arrives on
the response *after* the call that caused it.

Each source runs independently. Meta's permissions are granular, and a
token that reads tags often cannot read comments — so one source failing
is logged and the others still return mentions. Only a poll where every
source failed counts as an error.


## Bluesky

Bluesky is the one platform that is **pushed, not polled**. Instead of
asking every few minutes "anything new?", SMM Monitor keeps one
connection open to **Jetstream**, a public service run by Bluesky that
sends every new post on the network as it is written. Each post is
checked against every client's brand terms as it arrives; the ones that
match are stored, and everything else is thrown away unread. A mention
is usually on screen a second or two after it was posted.

It needs **no account, no app and no API key**.

### Switching Bluesky on

```sh
SMM_BLUESKY_ENABLED=true
```

Restart, and a **Bluesky** tab appears (or press `b`). The footer shows
`bluesky:stream` while connected. It is off by default for one reason:

> **It downloads every post on Bluesky, all day.** The stream carries
> the whole network whether or not anything matches, so the bandwidth
> is steady and does not depend on how many clients you have. That is
> unnoticeable on a server or office line, but worth thinking about on
> a metered or mobile connection. The exact figure varies with how busy
> Bluesky is and has not been measured for this release.

With no client set up, nothing would be matched, so it does not
connect at all until there is one.

### Choosing a Jetstream server

The default is `wss://jetstream2.us-east.bsky.network/subscribe`.
Bluesky runs a few others (`jetstream1.us-east`, `jetstream1.us-west`,
`jetstream2.us-west`), and you can [run your own](https://github.com/bluesky-social/jetstream):

```sh
SMM_BLUESKY_JETSTREAM_URL=wss://jetstream1.us-west.bsky.network/subscribe
```

It must be `wss://`; an unencrypted `ws://` address is refused.

### How Bluesky matching works

The stream sends posts, not search results, so the app decides itself
which client a post is about. A brand term matches as a **whole word or
phrase**, ignoring case (accented capitals included) but not accents:

| Term | Matches | Does not match |
| --- | --- | --- |
| `realoffice` | `RealOffice`, `#realoffice`, `@realoffice`, `RealOffice's` | `surrealofficer`, `realoffices` |
| `real office` | `real office`, `Real  Office`, a line break between the words | `realoffice` |
| `café été` | `CAFÉ ÉTÉ` | `cafe ete` (accents count) |

A post that names two clients is stored once for each, as on the other
platforms. Editing a client's terms takes effect within five seconds,
without reconnecting.

### Downtime and restarts

Every message carries the time Jetstream saw it. The latest one is
saved every 10 seconds to `bluesky.cursor`, next to the database. On a
reconnect or a restart the app asks Jetstream to replay from a few
seconds before that point, so a dropped connection or a short outage
loses nothing. The replay goes back **at most an hour**; after a longer
outage it picks up from an hour ago. Posts seen twice are stored once.

A connection that drops is retried after 1, 2, 4 ... up to 60 seconds.
A connection that stays open but goes silent for a minute is treated
as stalled and replaced.

### Who wrote it

The stream names authors by an account id (`did:plc:...`), not a
handle. When matched posts are stored, the ids not seen before are
looked up in one request to Bluesky's public profile service and shown
as `@handle`. If that lookup fails, the id is shown instead and nothing
else is affected.

### What Bluesky gets asked

One WebSocket to the Jetstream server, asking only for
`app.bsky.feed.post` and, after the first connection, a `cursor`. Then,
for each batch of matched posts with authors not yet known, one
`GET https://public.api.bsky.app/xrpc/app.bsky.actor.getProfiles` for up
to 25 of them. Nothing about your clients or brand terms is sent to
Bluesky: matching happens on your machine.

## Discord

Discord has no public search: nobody outside a server can read it. So
SMM Monitor joins Discord as a **bot that you invite to the servers you
want watched**: your own community, or a client's, with their
permission. Like Bluesky it is **pushed, not polled**. The bot keeps one
connection open to Discord's Gateway, every new message in those servers
arrives about a second after it is sent, and the ones that name a
client's brand terms are stored. Everything else is thrown away unread.

It is free.

### Creating the bot

1. Open the [Discord Developer Portal](https://discord.com/developers/applications)
   and choose **New Application**. Any name will do; members see it as the
   bot's name.
2. Under **Bot**, choose **Reset Token** and copy the token. It is shown
   once. Treat it like a password: anyone holding it can act as the bot.
3. Still under **Bot**, switch on **Message Content Intent**. Without it
   Discord refuses the connection, and the bot stops with a log line
   saying what to turn on. Bots in fewer than 100 servers need no review
   from Discord to use it.
4. Copy the **Application ID** from **General Information**.

### Inviting it

Open this link with your application id in place of `APP_ID`, pick a
server, and approve:

```text
https://discord.com/oauth2/authorize?client_id=APP_ID&scope=bot&permissions=66560
```

`66560` is **View Channels** and **Read Message History** and nothing
else: the bot cannot post, react, moderate or see anything a member with
those two permissions could not. You need the **Manage Server**
permission to invite a bot. Repeat for each server. To keep the bot out
of a channel, deny it **View Channel** there, as for any member.

### Adding the token

```sh
DISCORD_BOT_TOKEN=paste-the-token-here
```

Restart, and a **Discord** tab appears (or press `d`). The footer shows
`discord:stream` while connected. The token is read from the environment
only; the setup wizard does not ask for it.

### Listening to fewer places

By default the bot reads every channel it can see in every server it is
in. Two settings narrow that:

```sh
# Only these servers...
SMM_DISCORD_GUILDS=123456789012345678
# ...and/or only these channels (and the threads inside them).
SMM_DISCORD_CHANNELS=234567890123456789,345678901234567890
```

When either is set, a message is read only if its server is in the first
list or its channel is in the second. To copy an id, turn on **Developer
Mode** in Discord (User Settings → Advanced), then right-click a server or
channel and choose **Copy ID**. Ids are long numbers; anything else stops
the app at start-up with the setting's name, so a typo does not silently
watch nothing.

### Tell the members

A bot reading a community's messages is something its members should
know about, even though only messages that name a brand are kept. Say so
where they will see it, such as the server's rules or welcome channel,
and only invite the bot where you are entitled to. Discord's
[Developer Policy](https://discord.com/developers/docs/policies-and-agreements/developer-policy)
applies to how the data is used.

### What it reads, and what it skips

- **Read:** new messages from people, including replies and messages in
  threads, in channels the bot can view.
- **Skipped:** direct messages, messages from bots and webhooks, system
  messages (joins, pins, boosts), and messages with no text.
- **Not followed:** edits and deletions. A mention stays as it was first
  sent.

In a stored mention the author shows as their display name and channel,
for example `Maya (#general)`, and Discord's `<@123…>` mention codes are
turned back into names. The link opens the message in Discord, for anyone
who is a member of that server.

### Downtime and restarts

Short drops cost nothing: the bot resumes its session and Discord replays
what was sent in the meantime. For longer gaps, such as a restart or an
outage too long to resume, the id of the last message seen in each
channel is saved every 10 seconds to `discord.cursor`, next to the
database. After reconnecting, the bot asks Discord for what was posted in
those channels since, 100 messages at a time and up to 1,000 per channel,
respecting Discord's rate limits. Messages seen twice are stored once.

A connection that drops is retried after 1, 2, 4 ... up to 60 seconds. If
Discord rejects the token or the Message Content Intent, the bot stops
rather than retrying in a loop: the footer shows `discord:stopped`, the
log says what to fix, and it tries again after 10 minutes.

### What Discord gets asked

One WebSocket to `gateway.discord.gg` (or the resume address Discord gives
it), identifying with the token and asking for server, message and
message-content events. After a restart, one
`GET https://discord.com/api/v10/channels/{id}/messages?after={id}&limit=100`
per channel that had messages before. Nothing about your clients or brand
terms is sent to Discord: matching happens on your machine.

## What each platform actually gives you

All six platforms run on live APIs. What differs is **how much of the platform each
one can see**, which matters more than whether the code is written:

| Platform | Coverage | How it works |
| --- | --- | --- |
| **Reddit** | **Platform-wide search.** Any post matching the brand terms. | OAuth2 script app, `client_credentials` grant, multireddit `/search` sorted by new. Token cached and refreshed before expiry; rate limit read from Reddit's headers. Free tier. |
| **YouTube** | **Platform-wide search** of video titles and descriptions. Comments are not searched — see below. | Data API v3 `search.list` with an API key. Daily quota tracked against a budget; stands down when spent. Free tier. |
| **Twitter/X** | **Platform-wide search**, last 7 days, retweets excluded. | v2 `/2/tweets/search/recent` with an app-only bearer token. Two limits tracked separately: the 15-minute window from headers, the monthly post cap locally. **Paid tier required.** |
| **Instagram** | **Not brand-wide.** Only posts that tag your account, comments on your own posts, and (opt-in) public posts carrying a tracked hashtag. | Graph API, scoped to one Business account. The Graph API has no keyword search at any tier — see [What Instagram monitoring can and cannot see](#what-instagram-monitoring-can-and-cannot-see). |
| **Bluesky** | **Everything new, as it is posted.** Every public post from the moment of connecting (and up to an hour back after downtime). No search of older posts. | Jetstream WebSocket, matched locally against brand terms. No account. Off by default because of the steady bandwidth. |
| **Discord** | **Only servers the bot is invited to.** Every new message there, as it is sent (and what was missed during downtime, in channels seen before). No search of other servers. | Gateway WebSocket as a bot, matched locally against brand terms. Needs Message Content Intent. |

Every platform independently collects nothing when its credentials are
missing, and says so in the log. So a half-configured install shows real
Reddit data next to an empty Instagram tab rather than a crash — and
never next to invented Instagram data, which would look exactly like the
real thing. `SMM_DEMO=1` serves fixtures everywhere when that is what
you actually want.

**Coverage is uneven, on purpose.** Reddit, YouTube, X and Bluesky
answer "who mentioned us anywhere?"; Instagram answers "who tagged us, and what did
people say on our own posts?"; Discord answers "what are people saying in
the communities we are part of?". A quiet Instagram or Discord tab does
not mean nobody is talking about the brand there.


## Clearing out old demo mentions

If you ran with `SMM_DEMO=1` before connecting a platform, the invented
posts are still stored. They stay in the database and skew your trends
and reports. Quit the app and delete the file:

```sh
rm ~/.local/share/smm_monitor/mentions.db
```

It is recreated, empty, on the next start. Your clients and saved keys
live elsewhere and are not affected.

## What to expect once it's live

Real monitoring is quieter than the demo. A brand that isn't being
discussed produces an empty table, which is the correct answer rather
than a fault.

The [trend charts](reports.md#seeing-the-trend) build up one day at a
time — a freshly connected install has no history, so give it a couple
of days before the shape means anything. Only 30 days are kept by
default (`SMM_RETENTION_DAYS`), which is the ceiling on any window you
pick.
