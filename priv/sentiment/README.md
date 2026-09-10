# Sentiment word lists

One word (or phrase) per line. Blank lines and lines starting with `#`
are ignored. Matching is case-insensitive and exact on whole words, so
`crash` does **not** match `crashing` — add each form you want caught.

| File | Weight | Meaning |
| --- | --- | --- |
| `strong_positive.txt` | +2.0 | Unambiguous praise: "excellent", "flawless" |
| `mild_positive.txt` | +1.0 | Mild approval: "good", "helpful" |
| `strong_negative.txt` | −2.0 | Unambiguous complaint: "terrible", "unusable" |
| `mild_negative.txt` | −1.0 | Mild criticism: "slow", "clunky" |
| `negators.txt` | ×−1 | Flips the next few words: "not", "never" |
| `intensifiers.txt` | ×1.5 | Strengthens: "very", "extremely" |
| `downtoners.txt` | ×0.5 | Weakens: "slightly", "somewhat" |

## Tuning these

Edit a file and restart. To keep your edits across a deploy, copy the
directory somewhere that isn't replaced by the release:

    sudo cp -r /opt/smm-monitor/current/lib/smm_monitor-*/priv/sentiment \
      /etc/smm-monitor/sentiment
    # then in /etc/smm-monitor/env:
    SMM_SENTIMENT_DIR=/etc/smm-monitor/sentiment

Any file missing from an override directory falls back to the packaged
one, so you only need to copy the lists you actually want to change.

A word in two lists of opposing sign is a mistake worth catching: the
test suite asserts the lists don't overlap.
