---
name: hana-harness
description: Work with hana's end-to-end X scenario harness (dev/harness). Use when running, debugging, or re-recording golden parity scenarios (S01–S23), or when a behavior change might shift recorded goldens.
---

# hana scenario harness

End-to-end behavioral tests that boot an isolated Xvfb, spawn the hana binary,
drive real clients with xdotool, and snapshot geometry/EWMH/state dumps.

## Rules

- Always build Debug first (`zig build`); `dump_state` and info-level logs need
  it. `BUILD_DEBUG=1` makes the harness do it for you.
- Scenarios run on their own Xvfb (`HARNESS_DISPLAY`, default `:99`) — never
  point them at the live session.
- A golden diff means either a real behavior change or a flake. Diagnose from
  `dev/harness/out/<SC>/` before touching goldens.
- Re-record (`--golden`) only for *intentional, understood* behavior changes,
  and say so explicitly when reporting. Never re-record just to silence a diff.
  Goldens for S01–S23 are currently green in CI on `dev`, so drift fails CI.

## Commands

```sh
# compare all scenarios against goldens (CI behavior on dev)
cd dev/harness
./run-scenario.sh --compare $(ls scenarios/*.sh | sed 's|scenarios/||; s|\.sh$||')

# single scenario, keep Xvfb + hana alive for inspection
./run-scenario.sh --keep --compare S13-reload

# re-record one scenario after an intentional change
./run-scenario.sh --golden S13-reload
```

## Layout

- `scenarios/<SC>.sh` — scenario body (sourced by run-scenario.sh)
- `scenarios/<SC>.config.toml` — optional whole-config override
- `config-home/hana/config.toml` — base harness config, copied per run
- `out/<SC>/` — raw + normalized artifacts of the last run (gitignored)
- `golden/<SC>/` — tracked baseline (the only tracked output)
