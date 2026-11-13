# Connecting platforms

[← Back to the README](../README.md)

SMM Monitor collects from nine platforms. Seven are switched on by
giving them credentials; Bluesky and News need no account and are
switched on with one setting. **A platform that is switched on collects live data;
one that is not collects nothing** and shows as not connected. Nothing
is invented unless you ask for demo data with `SMM_DEMO=1`.

| Platform | Cost | Set up from | What it can actually find |
| --- | --- | --- | --- |
| **Reddit** | Free | Setup wizard or environment | New posts and comments in chosen subreddits, within about 15 s; or posts across all of Reddit, by search |
| **YouTube** | Free daily quota | Setup wizard or environment | Public videos matching your brand terms |
| **X (Twitter)** | Paid API plan | Environment | Recent public posts matching your brand terms (last 7 days) |
| **Instagram** | Business account | Environment | Only your own account's surroundings — [see below](#what-instagram-monitoring-can-and-cannot-see) |
| **Bluesky** | Free, no account | Environment (`SMM_BLUESKY_ENABLED=true`) | Every new public post that names your brand, within a second or two — [see below](#bluesky) |
| **Discord** | Free | Environment (`DISCORD_BOT_TOKEN`) | Messages that name your brand, in the servers you invite the bot to — [see below](#discord) |
| **Threads** | Free, with a Meta app | Environment (`THREADS_ACCESS_TOKEN`) | Recent public posts naming your brand, and mentions of your account — **after Meta's App Review**; before it, only your own posts — [see below](#threads) |
| **Mastodon** | Free, with an account | Environment (`MASTODON_INSTANCE`, `MASTODON_ACCESS_TOKEN`) | Every new public post your Mastodon server knows about that names your brand, within a second or two — [see below](#mastodon) |
| **News** | Free, no account | Environment (`SMM_NEWS_FEEDS`, optionally `SMM_NEWS_SEARCH=google`) | New articles naming your brand in the RSS and Atom feeds you list, and optionally in Google News — [see below](#news) |

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
Rate limits are counted per client id. The fetcher follows the figure
Reddit reports with each response rather than assuming one.


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

Which subreddits are watched is set **per client** on the clients
screen. A client with no subreddits searches all of Reddit.
`SMM_REDDIT_SUBREDDITS` only seeds the first client on a fresh install.

### What Reddit gets asked

Reddit is read two ways, depending on the client.

**A client with subreddits has them read, not searched.** Every poll,
15 seconds by default, fetches the newest posts and the newest comments
in those subreddits:

```
GET https://oauth.reddit.com/r/marketing+smallbusiness/new?limit=100
GET https://oauth.reddit.com/r/marketing+smallbusiness/comments?limit=100
```

The app matches them against the client's brand terms itself, the same
whole-word way as Bluesky and Mastodon. That has two advantages over
search:

* **Speed.** A post shows up on the next poll, so within about 15
  seconds. Reddit's search index can take minutes to include a new post.
* **Comments.** A brand named only in the comments under someone else's
  post is seen. Search returns posts only.

Every client's subreddits are read together, 50 subreddits to a
request, once per poll. Adding a client costs nothing extra unless it
adds subreddits. Each client is then handed only the items from its own
subreddits. A poll that finds more new items than one page holds (100)
reads up to three pages, so a burst or a short pause loses nothing.

**A client with no subreddits has all of Reddit searched**, since there
is no listing of everything to read instead. Search runs every **30
seconds**, whatever the poll interval. The search terms are the
client's brand terms: multi-word terms are quoted as phrases and terms
are OR-ed together, so `realoffice, real office` becomes
`realoffice OR "real office"`. Search asks for posts from the **last
day** (`time_filter: "day"`).

**What it costs.** With subreddits it is two requests a poll for every 50
subreddits (one with `SMM_REDDIT_COMMENTS=false`), so 8 a minute at the
default interval. Each client with no subreddits adds 2 searches a
minute. Reddit reports the quota left on every response. The fetcher
reads it before every request and stops five requests short, so a burst
from something else sharing the credentials can't push you into a hard
429.

**Subreddit names are checked** before they go anywhere near a request:
anything that is not a valid subreddit name (letters, digits and
underscores, up to 21 characters) is ignored and logged once. If Reddit
refuses a subreddit because it is private, banned or misspelt, the
fetcher finds which one it was and logs it. That subreddit is skipped
for an hour while the client's other subreddits are still read.

| Setting | Default | What it does |
| --- | --- | --- |
| `SMM_POLL_INTERVAL_MS` | `15000` | How often the subreddit listings are read |
| `SMM_REDDIT_COMMENTS` | `true` | Read comments as well as posts. `false` halves the requests |
| `SMM_REDDIT_SEARCH_INTERVAL_MS` | `30000` | How often all of Reddit is searched for a client with no subreddits |

Items older than a day are never handed to a client. Links in the
dashboard and in reports always point at `https://reddit.com` plus the
post's or comment's permalink, never at whatever external URL a post
links to.

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

## Threads

Threads is Meta's, and it works much like Instagram: a Meta app, a user
token, and polling every 5 minutes. Unlike Instagram, it has a real
**keyword search**: one query per brand term per poll, for posts since
the last poll.

### Read this before trusting the Threads tab

**Until Meta approves your app in App Review, keyword search only finds
posts by the connected account itself.** Meta's words: "If your app has
not been approved for `threads_keyword_search`, the search will be
performed only on posts owned by the authenticated user." Mentions work
the same way: until `threads_manage_mentions` is approved, only posts by
people with a role on your app come back.

So a freshly connected Threads tab is a working pipe with almost nothing
in it. That is the correct answer, not a fault. To see what the public is
saying, submit the app for App Review with `threads_keyword_search` and
`threads_manage_mentions` and publish it. Nothing in SMM Monitor changes
when Meta approves it: the same requests start returning more.

To check the pipe works before then, post something from the connected
account that names one of your brand terms; it shows up within one poll.

### Getting a Threads access token

1. Create an app at <https://developers.facebook.com/apps> and pick the
   **Access the Threads API** use case. The app gets two ids; use the
   **Threads app ID** and **Threads app secret** (left menu → Settings),
   not the other pair.
2. Under **Use cases → Customize**, add the permissions
   `threads_keyword_search` and `threads_manage_mentions` (`threads_basic`
   is always on). Add `threads_read_replies` too if you will turn on the
   replies source.
3. In the same settings, add a **redirect callback URL** under Client
   OAuth Settings. It only has to be an `https` address you can see in
   the browser bar afterwards, for example `https://localhost/`.
4. Add the Threads account you want to connect as a tester: **App roles →
   Roles → Add People → Threads Tester**. Then, signed in as that account,
   accept the invite at <https://www.threads.com/settings/account> under
   **Website permissions**.
5. Signed in as that account, open this address in a browser (one line,
   with your app id and redirect URL filled in):

   ```text
   https://threads.com/oauth/authorize?client_id=<THREADS_APP_ID>&redirect_uri=https://localhost/&scope=threads_basic,threads_keyword_search,threads_manage_mentions&response_type=code
   ```

   Approve it. The browser lands on your redirect URL with `?code=…` on
   the end. Copy the code (leave off a trailing `#_` if there is one). It
   works once, for an hour.
6. Swap the code for a short-lived token, then that for a 60-day one:

   ```bash
   curl -s -X POST https://graph.threads.net/oauth/access_token \
     -F client_id=<THREADS_APP_ID> \
     -F client_secret=<THREADS_APP_SECRET> \
     -F grant_type=authorization_code \
     -F redirect_uri=https://localhost/ \
     -F code=<CODE>

   curl -s "https://graph.threads.net/access_token\
   ?grant_type=th_exchange_token\
   &client_secret=<THREADS_APP_SECRET>\
   &access_token=<SHORT_LIVED_TOKEN>"
   ```

   The second answer's `access_token` is the one you want.

```bash
export THREADS_ACCESS_TOKEN='THAA...'
```

Restart, and a **Threads** tab appears (or press `e`, for thr**e**ads).
The footer shows `threads:live`.

### The token renews itself

A long-lived Threads token lasts 60 days, and Meta swaps it for a fresh
60-day one on request once it is a day old. SMM Monitor does that for you:
a day after it first uses a token, and then once a week. The renewed token
is kept in `threads_token.json`, next to the database, readable only by
you (`0600`). The token you put in `THREADS_ACCESS_TOKEN` is never written
to disk; the file only keeps a hash of it, to notice when you paste a
different one, in which case yours wins.

So you never need to touch it again, **as long as the app runs at least
once in any 60-day stretch**. If renewals keep failing, a warning is logged
every hour during the last week. Once it has expired, the log says
`expired_access_token` and you need a new one from step 5.

### What Threads gets asked

Per poll and per client:

| Source | Request | Counts against search budget |
| --- | --- | --- |
| `search` *(default)* | `GET /keyword_search?q=<term>&search_type=RECENT&since=…`, one per brand term (at most 10) | Yes |
| `mentions` *(default)* | `GET /{account-id}/mentions?since=…` | No |
| `replies` *(opt-in)* | `GET /{account-id}/threads`, then `GET /{post-id}/replies` for each of the last 10 posts with replies | No |

Plus one `GET /me` the first time mentions or replies are read, and the occasional
`GET /refresh_access_token`. Everything goes to `graph.threads.net` over
HTTPS. The first poll looks back a day; after that each one asks for what
is new since the newest post seen, with a 10-minute overlap so a post Meta
indexes late is not missed. Repeats are stored once.

The mentions feed belongs to your account, not to any one client, so a
mention is stored for a client **only if it names one of that client's
brand terms**. A mention that names none of them is not stored. Replies to
your own posts go to every client, like comments on Instagram.

```bash
# Which sources to read (default: search,mentions):
export SMM_THREADS_SOURCES=search,mentions,replies
```

### The search budget

Meta allows **2,200 keyword searches per rolling 24 hours per Threads
account**, shared with every other app that account has authorised.
SMM Monitor counts its own and stops at 2,000 by default
(`SMM_THREADS_DAILY_QUERY_BUDGET`, up to 2200), leaving room for others.
When it is spent, search pauses until the oldest search in the window is a
day old; mentions carry on.

One search is one brand term for one client for one poll, so the sum to
check is *clients × brand terms × polls a day*:

| Poll interval | Polls a day | Brand terms (across all clients) a 2,000 budget covers |
| --- | --- | --- |
| 5 min *(default)* | 288 | 6 |
| 15 min | 96 | 20 |
| 30 min | 48 | 41 |
| 60 min | 24 | 83 |

If yours does not fit, the log says so at the first poll and suggests an
interval (`SMM_THREADS_POLL_INTERVAL_MS`). Meta's own limit still stands
behind this count, which starts again from zero when the app restarts.

### What it skips

- **Private profiles**: Meta never returns their posts.
- **Sensitive keywords**: Meta returns nothing for some terms.
- **Edits and deletions** after a post is stored.
- Posts older than a day when first connected.

## Mastodon

Mastodon is not one site but thousands of servers (instances) that pass
posts between each other, the fediverse. There is no central search.
Each server knows the posts written on it, plus the posts its users'
follows bring in from other servers, and it can send every new public
one the moment it learns of it. SMM Monitor listens to **one server's
live stream**, so like Bluesky and Discord it is **pushed, not polled**:
a post is checked against every client's brand terms as it arrives, the
ones that match are stored, and everything else is thrown away unread.

It is free, but it needs an account on a Mastodon server. Since
Mastodon 4.2, servers only stream public posts to a signed-in user.

### Choosing a server

**What you see is what your server knows about.** A big, well-connected
server such as `mastodon.social` hears from a large part of the
fediverse; a small one mostly hears from its own users and the accounts
they follow. If your brand's audience gathers on a particular server,
an account there is worth more than one on a big general server. You
can use an account you already have.

### Getting an access token

1. Sign in to your server's website and open **Preferences →
   Development → New application**.
2. Give it any name, such as `SMM Monitor`. Leave the redirect URI as it
   is.
3. Under **Scopes**, untick everything that is ticked by default and
   tick only **`read:statuses`**. That lets the token read posts and
   nothing else: it cannot post, follow, or see your messages.
4. Save, open the application you just made, and copy **Your access
   token**. Treat it like a password.

If the menu is missing, your server's admin may have switched off
making applications; ask them, or use an account on another server.

### Adding it

```sh
MASTODON_INSTANCE=mastodon.social
MASTODON_ACCESS_TOKEN=paste-the-token-here
```

`MASTODON_INSTANCE` is the server's name, as in your address
`@you@mastodon.social`. `https://mastodon.social/` works too; anything
that is not a plain `https` server name stops the app at start-up with
the setting's name.

Restart, and a **Mastodon** tab appears (or press `m`). The footer shows
`mastodon:stream` while connected. The token is read from the
environment only; the setup wizard does not ask for it.

### Everything it knows, or only its own posts

```sh
# federated (the default): every public post the server knows about.
# local: only posts written by accounts on that server.
SMM_MASTODON_TIMELINE=local
```

`local` is the right choice when a server is the community you care
about, for example a regional or industry server. `federated` finds
more.

> **The federated stream of a big server is a firehose.** It carries
> every public post the server hears about, whether or not anything
> matches, all day. That is unnoticeable on a server or office line but
> worth thinking about on a metered connection. A small server's local
> stream is light. The exact figures depend on the server and have not
> been measured for this release.

Many servers run their live stream on a separate host. The app asks the
server where it is (`GET /api/v2/instance`, a public endpoint) and
connects there; for `mastodon.social` that is
`wss://streaming.mastodon.social`. If the lookup fails it tries the
server's own name. To set it yourself:

```sh
SMM_MASTODON_STREAMING_URL=wss://streaming.example.social
```

It must be `wss://`; an unencrypted `ws://` address is refused.

### What it reads, and what it skips

- **Read:** new public posts, including replies. A content warning is
  kept in front of the text as `[CW: …]`, so a brand term in it still
  matches.
- **Skipped:** boosts (the original post arrives in its own right),
  unlisted, followers-only and direct posts, and posts with no text.
- **Not followed:** edits and deletions. A mention stays as it was first
  posted.

The author shows as `@user@server`, wherever they live. Posts are
written in HTML; it is turned into plain text before it is stored or
shown. The link opens the post **on your own server**, which shows
posts from anywhere, so you can reply or boost from your account.

### Downtime and restarts

The id of the newest post seen is saved every 10 seconds to
`mastodon.cursor`, next to the database. After a reconnect or a restart
the app asks your server's public timeline for what arrived since, 40
posts at a time and **at most 400**, respecting the server's rate limits.
Mastodon ids carry the time a post was made, so after an outage longer
than **an hour** it does not catch up at all and starts from now. Posts
seen twice are stored once.

This is best effort. A big server's federated timeline can carry more
than 400 posts in a few minutes, so after anything longer than a short
drop some posts will be missed. The local timeline usually catches up
completely.

A connection that drops is retried after 1, 2, 4 ... up to 60 seconds.
One that stays silent for three minutes is treated as stalled and
replaced. Mastodon pings an open stream every 30 seconds or so, and a
ping counts, so a quiet local timeline stays connected.

If the server turns the token away, the stream stops rather than
retrying in a loop: the footer shows `mastodon:stopped`, the log says to
check `MASTODON_ACCESS_TOKEN` and its `read:statuses` scope, and it
tries again after 10 minutes. The same happens if the server's admin has
switched live feeds off, which Mastodon 4.5 lets them do.

### What Mastodon gets asked

Before the first connection (and again if the streaming host stops
answering), `GET https://{instance}/api/v2/instance`, without the token,
to find the streaming host. Then one WebSocket to
`wss://{streaming host}/api/v1/streaming`, with the token in the
`Authorization` header, subscribing to `public` (or `public:local`).
After a reconnect, `GET https://{instance}/api/v1/timelines/public?min_id={id}&limit=40`,
with the token, for up to 10 pages. Nothing about your clients or brand terms is sent
to the server: matching happens on your machine.

## News

News sites, trade press and blogs nearly all publish an **RSS or Atom
feed**: a list of their latest articles that any reader can fetch. SMM
Monitor reads the feeds you give it every 10 minutes and keeps the
articles that name a brand. Like Reddit it is **polled**, not pushed, so
an article shows up within about 10 minutes of the feed carrying it.

No account and no key. Two sources, and you can use either or both:

- **Your feeds** (always on once you list some): the publications that
  matter to you, matched against every client's brand terms on your
  machine.
- **Google News search** (off unless you switch it on): one search per
  brand term, which finds articles from publications you have not
  listed. Read [the caveat below](#google-news-search) first.

### Adding feeds

```sh
SMM_NEWS_FEEDS=https://opsledger.example/feed/,https://saasbriefing.example/atom.xml
```

A comma-separated list. For more than a handful, put them in a file, one
per line, and point to it:

```sh
SMM_NEWS_FEEDS_FILE=/etc/smm_monitor/feeds.txt
```

```text
# Trade press
https://opsledger.example/feed/
https://saasbriefing.example/atom.xml   # weekly, but worth it

# Local
https://journal.example/rss
```

`#` starts a comment, at the start of a line or after a space. Both
settings can be used together; repeats are read once. Each address must
be `https://`. A plain `http://` feed, or one with a user name or
password in it, stops the app at start-up, naming the setting (and the
file's line number) so it is quick to fix. Up to 100 feeds are read.

To find a site's feed, look for an RSS icon or a "Subscribe" link, or
try adding `/feed`, `/rss` or `/atom.xml` to its address. Most WordPress
sites have one at `/feed/`. RSS 2.0, RSS 1.0 and Atom all work.

Restart, and a **News** tab appears (or press `n`).

### Google News search

```sh
SMM_NEWS_SEARCH=google
# Which Google News edition to search: language and country.
SMM_NEWS_EDITION=en-GB
```

Each poll, for each client, the app asks Google News for articles from
the last day containing each brand term as an exact phrase: at most 5
terms a client. The headline is shown without the " - Publisher" Google
adds, and the publisher is shown as the author. The link goes to Google
News, which forwards to the article.

> **Check Google's terms before you switch this on for a business.**
> Google publishes these search feeds for personal, non-commercial use,
> and has no official API for Google News. Using them to monitor brands
> for clients may not fit those terms; that is for you to decide, which
> is why it is off by default. Your own feed list has no such catch:
> publishers offer their feeds for anyone to read.

If Google starts refusing requests (`429`), searching pauses for as long
as Google asks (30 minutes if it does not say), with one line in the
log. Your feeds carry on as normal.

`SMM_NEWS_EDITION` (default `en-US`) is a language and a country, such
as `fr-CA` or `pt-BR`. It changes which edition is searched, not the
language of your brand terms.

### What counts as new

Articles published in the **last 24 hours** that name a brand term,
matched as whole words in the headline and summary, the same way every
other platform matches. The first time a feed is read, you see what it
carried from the last day; after that, only what is new. Each client is
shown each article once.

An article with no date at all is taken as old on the first read (it
could be from any year), and as new when it first appears after that,
dated when it was first seen. A date in the future is read as now.

### Polite to publishers

Feeds are fetched **once per poll**, however many clients you have, and
at most 4 at a time. Each request sends back the `ETag` and
`Last-Modified` the feed gave last time, so an unchanged feed answers
`304 Not Modified` with no body. The requests name the software
(`smm_monitor/<version> (feed reader)`) and nothing about you or your
clients.

A feed that fails is tried again after 1, 2, 4, 8, then every 16 polls,
with one warning when it starts failing and one line when it is back.
A `429` or `503` is honoured for as long as its `Retry-After` asks (30
minutes if it does not say, a day at most). If a feed has **moved
permanently** (a `301` or `308`), it is followed, and the log says once
which address to put in `SMM_NEWS_FEEDS` instead.

If every feed is failing, the footer shows `news:error`, and the log
says why for each.

### Limits

- **What the publisher writes into the feed.** Usually the headline and
  a summary or the first paragraph, sometimes the whole article. A brand
  named only deep in an article whose feed carries a short summary is
  not found.
- **10 minutes.** Feeds are polled; `SMM_NEWS_POLL_INTERVAL_MS` changes
  how often, but many sites only update their feed every few minutes
  anyway, and polling a feed every minute is rude.
- **100 articles per feed and 5 MB per fetch.** A larger response is
  dropped and the feed counts as failing.
- **No paywalled or private feeds** that need a log-in. A feed with a
  key in its address works; the key is never written to the log, which
  names feeds by host and path only.
- **No older articles.** Only what the feed carries now, from the last
  day.

### What News gets asked

`GET` on each feed address you listed, with `Accept`, `User-Agent` and
the conditional headers above, no cookies, and no compression asked
for. Redirects are followed by hand, at most 3, and only to `https`.
With search on, `GET
https://news.google.com/rss/search?q="{term}"+when:1d&hl=…&gl=…&ceid=…`
for each brand term: your brand terms are the one thing sent to Google.

## What each platform actually gives you

All nine platforms run on live APIs. What differs is **how much of the platform each
one can see**, which matters more than whether the code is written:

| Platform | Coverage | How it works |
| --- | --- | --- |
| **Reddit** | **New posts and comments in chosen subreddits**, or **platform-wide search** of posts for a client with none. | OAuth2 script app, `client_credentials` grant. Multireddit `/new` and `/comments` listings matched locally; `/search` sorted by new when there are no subreddits. Token cached and refreshed before expiry; rate limit read from Reddit's headers. Free tier. |
| **YouTube** | **Platform-wide search** of video titles and descriptions. Comments are not searched — see below. | Data API v3 `search.list` with an API key. Daily quota tracked against a budget; stands down when spent. Free tier. |
| **Twitter/X** | **Platform-wide search**, last 7 days, retweets excluded. | v2 `/2/tweets/search/recent` with an app-only bearer token. Two limits tracked separately: the 15-minute window from headers, the monthly post cap locally. **Paid tier required.** |
| **Instagram** | **Not brand-wide.** Only posts that tag your account, comments on your own posts, and (opt-in) public posts carrying a tracked hashtag. | Graph API, scoped to one Business account. The Graph API has no keyword search at any tier — see [What Instagram monitoring can and cannot see](#what-instagram-monitoring-can-and-cannot-see). |
| **Bluesky** | **Everything new, as it is posted.** Every public post from the moment of connecting (and up to an hour back after downtime). No search of older posts. | Jetstream WebSocket, matched locally against brand terms. No account. Off by default because of the steady bandwidth. |
| **Discord** | **Only servers the bot is invited to.** Every new message there, as it is sent (and what was missed during downtime, in channels seen before). No search of other servers. | Gateway WebSocket as a bot, matched locally against brand terms. Needs Message Content Intent. |
| **Threads** | **Platform-wide search of recent posts, once Meta approves the app.** Before App Review, only your own account's posts. Plus mentions of your account. No private profiles. | Threads API `/keyword_search` and `/mentions`, polled every 5 minutes with a long-lived user token the app renews itself. 2,200 searches a day, shared with other apps. |
| **Mastodon** | **What one server knows about.** Every new public post on its federated (or local) timeline, as it arrives, and up to an hour back after downtime. No search of older posts, and no view of servers yours does not hear from. | Streaming API WebSocket with a `read:statuses` user token, matched locally against brand terms. |
| **News** | **The feeds you list**, plus (opt-in) Google News search. New articles from the last day whose headline or summary names the brand. Only what each publisher puts in its feed. | RSS 2.0, RSS 1.0 and Atom over HTTPS, polled every 10 minutes with conditional requests, matched locally. Google News search feeds when switched on. |

Every platform independently collects nothing when its credentials are
missing, and says so in the log. So a half-configured install shows real
Reddit data next to an empty Instagram tab rather than a crash — and
never next to invented Instagram data, which would look exactly like the
real thing. `SMM_DEMO=1` serves fixtures everywhere when that is what
you actually want.

**Coverage is uneven, on purpose.** Reddit, YouTube, X, Bluesky and
(after App Review) Threads answer "who mentioned us anywhere?"; Instagram answers "who tagged us, and what did
people say on our own posts?"; Discord answers "what are people saying in
the communities we are part of?"; Mastodon answers "what is reaching our
corner of the fediverse?"; News answers "what are the publications we
follow writing about us?". A quiet Instagram, Discord, Mastodon or News tab
does not mean nobody is talking about the brand there.


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
