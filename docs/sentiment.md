# How sentiment is scored

[← Back to the README](../README.md)

Every mention gets a number between `-1.0` and `1.0` as it arrives, and
the positive/neutral/negative label you see is derived from it. The
number is what the dashboard averages and what alerting compares; the
label is for reading at a glance.

This is a lexicon scorer, not a model. It runs on every mention in the
pipeline, so it stays local, deterministic and fast — no model to load,
no API to call, no per-mention cost. What makes it more than a keyword
count is three things it does before adding anything up.

**It splits the text into clauses.** Sentence ends and contrastive
conjunctions ("but", "however", "although", "though", "whereas", "yet")
each start a new clause, and a clause after one of those conjunctions
counts double. In English that is where the speaker's real point
usually lands:

> "great tool, would recommend, **but the mobile app keeps crashing**"

is a bug report with a compliment attached, not praise. A flat word
count files it under positive and the complaint disappears.

**It handles negation.** A negator flips the polarity of sentiment words
within the next few tokens, so "not good", "didn't love it" and "not at
all helpful" are all negative — and "not bad at all" is positive. The
window is a few tokens rather than only the next word because that is
how people actually write. It stops at the window's edge, so "not the
rollout we hoped for, though support was excellent" stays positive
about support.

**It handles intensifiers and downtoners.** "very good" outscores
"good"; "slightly slow" is a grumble rather than a complaint, and lands
in the neutral band where it belongs. Modifiers survive negation, so
"not very reliable" is a firmer complaint than "not reliable".

Words carry strong (2.0) or mild (1.0) weight rather than a flat 1.
Each clause is normalised against a saturation point, then the clauses
are combined weighted by how much sentiment each carried — a clause
with three sentiment words has more say than one with a single word.

### What changed, in practice

| Mention | Before | Now |
| --- | --- | --- |
| "great tool, would recommend, but the mobile app keeps crashing" | positive | **neutral** |
| "realoffice was down again this morning" | neutral | **negative** |
| "hardly useful for our workflow" | neutral | **negative** |
| "realoffice is slightly slow but it does the job" | negative | **neutral** |

The first two are the ones that matter for a brand monitor: a complaint
filed as praise is a complaint nobody sees, and an outage that doesn't
register as negative is the mention you most needed to catch.

### Tuning the word lists

The lists are plain text under `priv/sentiment`, one word per line, `#`
for comments:

```
priv/sentiment/
├── strong_positive.txt   weight +2.0   excellent, brilliant, flawless
├── mild_positive.txt     weight +1.0   good, useful, helpful
├── strong_negative.txt   weight -2.0   terrible, broken, outage, down
├── mild_negative.txt     weight -1.0   slow, confusing, clunky
├── negators.txt          flips the next few words
├── intensifiers.txt      x1.5          very, really, absolutely
└── downtoners.txt        x0.5          slightly, somewhat, fairly
```

Editing them needs no recompile. Adding your own vocabulary is the
single highest-value change you can make here: the words your clients'
customers use — a product name used as a verb, an in-house term for a
recurring bug — are worth more than any amount of tuning the weights.

On a deployed box the release directory is replaced on each deploy, so
tuned lists belong outside it. Point `SMM_SENTIMENT_DIR` at a directory
and any file present there wins, category by category:

```bash
mkdir -p /etc/smm-monitor/sentiment
cp priv/sentiment/mild_negative.txt /etc/smm-monitor/sentiment/
# edit it, then add to /etc/smm-monitor/env:
SMM_SENTIMENT_DIR=/etc/smm-monitor/sentiment
```

Override one list and the rest are still read from the packaged copies.
There is no file watcher, deliberately — scoring that shifted mid-run
with no record of why would make the history unreadable. Reload from a
remote console instead:

```elixir
SmmMonitor.Processing.Sentiment.Lexicon.reload()
SmmMonitor.Processing.Sentiment.Lexicon.sources()  # which file won, per category
```

Only mentions scored after the reload use the new lists. Stored rows
keep the score they were given, so tuning a list never rewrites what
past mentions meant.

The weights themselves are configurable if you need them, though the
word lists are almost always the better lever:

```elixir
config :smm_monitor, :sentiment,
  strong: 2.0,
  mild: 1.0,
  intensifier: 1.5,
  downtoner: 0.5,
  # Raw clause score at which the normalised score hits +/-1.0.
  saturation: 4.0,
  # Scores inside this band are reported as neutral.
  neutral_band: 0.15,
  # How much more a clause after "but" counts.
  contrast_weight: 2.0
```

### What it still gets wrong

Sarcasm and idiom defeat it, as they defeat every lexicon: "great, another
outage" scores positive. A mention that is genuinely half praise and half
complaint with no "but" between them averages toward neutral, which is
honest but tells you less than reading it would. And a word that isn't in
the lists contributes nothing at all — which is why adding your own
vocabulary beats tuning weights.

If you want to see the working for a particular mention, `score/1`
returns it:

```elixir
iex> SmmMonitor.Processing.Sentiment.score("love the product but support is slow").clauses
[
  %{text: "love the product", raw: 2.0, signals: 1, contrast: false, score: 0.5},
  %{text: "support is slow", raw: -1.0, signals: 1, contrast: true, score: -0.25}
]

The second clause follows "but", so it carries twice the weight of the
first despite the smaller number — which is what pulls the mention down
to neutral rather than leaving it as praise.
```

