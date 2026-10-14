---
description: Golden-parity replay of the end-to-end X scenarios
argument-hint: "[scenario...]"
---
Verify behavioral parity against the recorded goldens:

```sh
zig build   # Debug binary: dump_state/info logs require it
cd dev/harness
./run-scenario.sh --compare ${1:-$(ls scenarios/*.sh | sed 's|scenarios/||; s|\.sh$||')}
```

Scenarios run on an isolated Xvfb (`HARNESS_DISPLAY`, default `:99`), never the
live session. If a scenario diffs, inspect `dev/harness/out/<SC>/` artifacts.
Only re-record goldens (`--golden`) when the behavior change is *intentional*
and understood; a golden update is a semantic assertion, not a way to make a
diff disappear. `--keep` leaves Xvfb + hana up for interactive debugging.
