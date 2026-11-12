# Alerting

[← Back to the README](../README.md)

Collecting mentions only helps if someone notices when they turn. Every
minute each active client is measured over its own rolling window and put
to three conditions. Any that trips raises an alert; when it stops
tripping, an all-clear follows.

```
:rotating_light: Acme Corp: sentiment fell to -0.62 over 34 mentions in the last 1h (threshold -0.30)
:rotating_light: Acme Corp: "refund" mentioned 4 times in the last 1h — "third ticket about a refund, still nothing"
:white_check_mark: Acme Corp: sentiment recovered to 0.12 (lasted 47 min)
```

### The three conditions

They answer different questions on purpose. A brand can have terrible
sentiment at a perfectly ordinary volume, a huge volume spike at neutral
sentiment, or one quiet post containing "lawsuit" that matters more than
either.

| Condition | Asks | Trips when |
| --- | --- | --- |
| **Sentiment** | *Are people unhappy?* — absolute | The mean sentiment over the window is at or below the threshold |
| **Volume** | *Is this louder than normal for this client?* — relative | Mentions reach a multiple of that client's own usual level **for this hour** |
| **Watch phrases** | *Did anyone say the word?* — literal | A mention contains one of the client's phrases, case-insensitively |

Each has a guard against firing on small numbers, because all three are
embarrassing without one: sentiment needs a minimum number of mentions
to average, volume needs an absolute floor, and volume also needs at
least two days of history before it claims to know what normal is.

### Default thresholds

A client added from the clients screen alerts sensibly with nothing
typed:

| Setting | Default | Meaning |
| --- | --- | --- |
| Window | **1 hour** | Every condition is measured over this rolling window |
| Sentiment threshold | **-0.30** | Alert when the mean sentiment is at or below this |
| Minimum mentions | **5** | ...but not until there are this many to average |
| Volume multiple | **3.0x** | Alert at three times the usual for this hour |
| Volume floor | **10** | ...but not on fewer than ten mentions |
| Watch phrases | **empty** | No phrase alerts until you add some |
| Webhook | **the global one** | Unless this client has its own |

**Watch phrases start empty deliberately.** There is no list of words
that is right for every brand — "refund" is routine for a retailer and
alarming for a SaaS — so guessing would either cry wolf or say nothing.
Good starting points: `lawsuit`, `refund`, `scam`, `fraud`, `data
breach`, `outage`, `cancel my`.

### Setting up Slack

1. Go to <https://api.slack.com/apps> and **Create New App** → *From
   scratch*. Name it (e.g. "SMM Monitor") and pick your workspace.
2. In the app's sidebar choose **Incoming Webhooks** and turn the toggle
   **On**.
3. Click **Add New Webhook to Workspace**, choose the channel the alerts
   should land in, and **Allow**.
4. Copy the webhook URL. It looks like
   `https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXX`.
   **Treat it as a secret** — anyone holding it can post to that
   channel. It must be an `https://` URL; anything else is refused.
5. Put it in the environment and restart:

   ```bash
   export SMM_ALERT_WEBHOOK_URL='https://hooks.slack.com/services/T00.../B00.../XXX'
   ```

   On a deployed box that goes in `/etc/smm-monitor/env` alongside the
   API credentials.

Test it without waiting for a real incident:

```bash
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"SMM Monitor webhook test"}' \
  "$SMM_ALERT_WEBHOOK_URL"
```

If that posts to the channel, alerting will too.

### One channel, or one per client?

**Both, and the per-client one wins.** The global `SMM_ALERT_WEBHOOK_URL`
covers everything by default; any client can override it from the
clients screen with a webhook of their own.

That is deliberate, because neither alone works:

* **Global only** puts every client's alerts in one channel — right for
  a small agency, and unusable the moment a channel is *shared with* a
  client, since they would see everyone else's incidents.
* **Per client only** means setting a URL on every client before any
  alerting works at all, which is a poor first five minutes.

A client with an override sends **only** there, never to both: an alert
in two channels gets acknowledged in neither.

### Configuring a client's alerts

Press **`c`** for the clients screen and move to the client with `j`/`k`.
The alert settings are the last four fields — `h`/`l` moves between
them, `e` edits:

```
  ▸ 2. Acme Corp  (acme-corp)
        name                Acme Corp
        brand terms         acme, acme corp
        subreddits          saas, startups
      › alert phrases       lawsuit, refund, scam
        alert if sentiment  at or below -0.45
        alert if volume     at or above 3.0x the usual for this hour
        slack webhook       https://hooks.slack.com/services/T00/B00/acme
```

Changes are picked up on the next evaluation, within a minute — no
restart. Leaving the webhook empty falls back to the global one.

Rejections explain themselves: sentiment runs from -1.00 to 1.00 so a
threshold outside that never changes anything, a volume multiple of 1x
or less would alert on every ordinary hour, and a webhook URL that isn't
`https://` is a typo rather than a preference.

### One alert per incident, not one per minute

A condition that stays true is **one problem, not sixty**. Each is
tracked as an incident: opened the first time it trips, kept quiet while
it keeps tripping, and closed with an all-clear when it recovers.
Exactly two messages reach the channel — *started*, and *over, lasted 47
min*.

That is the difference between a channel people read and one they mute,
and it is why this isn't a cooldown. A cooldown ("don't repeat for an
hour") is wrong in both directions: it goes quiet while a problem is
still running, and says nothing at all when the problem ends.

Clearing uses a **margin** rather than the trigger threshold, so a number
sitting on the line doesn't alert and resolve alternately for an hour.
Sentiment has to recover past the threshold by 0.05; volume has to fall
to 80% of the trigger multiple.

A genuinely new incident after a recovery alerts again immediately —
recovering is not the same as being silenced.

### Why a baseline, not a fixed number, for volume

"Alert at 20 mentions an hour" is wrong for every client at once. One
with five mentions a day would never trip it; one with five thousand
would trip it permanently. So volume is always compared against **that
client's own recent normal**.

And normal is **the same hour on previous days**, not a flat weekly
average. Brands have a daily rhythm: a flat average says a Tuesday
lunchtime and a Sunday night should look alike, so it alerts every
weekday morning and misses a genuine weekend storm.

The average only counts days that actually had mentions in that hour. A
client added yesterday has one day of history, not seven, and dividing
by seven would count days that never happened and turn an ordinary hour
into a spike.

### A volume spike is not bad news

It says *something is happening*, not *something is wrong* — a product
launch and a data breach look identical to it. The sentiment condition
is what separates them, and the volume alert carries the window's
sentiment so you can tell at a glance which one you're looking at.

### Sentiment alerts inherit the scorer's limits

> ⚠️ Sentiment is a **lexicon scorer**, not a model. It is fooled by
> sarcasm and by phrasings that aren't in the word lists — see [How
> sentiment is scored](sentiment.md) and the tuning section
> there. Treat a sentiment alert as "go and look", not as a measurement.

### Email is not built

Slack only, for now. Email would mean adding Swoosh, an SMTP or API
provider, a sender identity that survives SPF and DKIM, and a bounce
story — none of it hard, all of it more surface than a webhook POST, and
none of it useful if the team already lives in Slack.

If you want it, the seam is `SmmMonitor.Alerts.Notifier`: a module with
`notify/1` and `configured?/0`, added to `:alert_notifiers`. The Slack
notifier is 200 lines and an email one would be shorter.

### Turning it off

```bash
SMM_ALERTS_ENABLED=false      # the whole engine
```

Or per client, from the clients screen — a paused client isn't
evaluated at all, and a client can have alerting switched off while
still being monitored.

### Failure policy

Alerting is the last thing that should be allowed to break collection.
A failing notifier is logged and the others still run; a database that
can't answer means no baseline, which reads as "still warming up" rather
than as a reason to alert. The log notifier is always on, so an alert is
recorded somewhere even when every webhook is down.

