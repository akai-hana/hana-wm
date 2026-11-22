# #### test/ #### #
# "THE GATEKEEPER" #

Unit and integration tests for hana, grouped by area. The build discovers the
`*_test.zig` files under this directory.

## Groups

- `core/`: model, events, pipeline, reconcile, sink, process, timers, DPI,
  usable area, tiling contract.
- `config/`: parser, sections, binds, rules, reload, fallback, snapshots.
- `input/`: keymap, mouse, xkb, dispatch.
- `window/`: admission, actions, focus, floating, fullscreen, minimize,
  workspaces, EWMH, struts, borders, queries.
- `bar/`: rendering, carousel, clock, completion, fonts, metrics, sliders,
  systatus, volume, brightness, visibility, vim motions.
- `tiling/`: tiling engine behavior.
- `bench/`: focus and tiling latency benchmarks.
- `fuzz/`: the fuzz target.

## Running

```sh
dev/scripts/xtest.sh zig build test -Doptimize=Debug
```

`xtest.sh` starts an isolated Xvfb and sets `HANA_REQUIRE_X=1`, so
display-gated tests run instead of skipping. Without an X server, the
X11-backed fixture skips and reports the skip; with `HANA_REQUIRE_X=1` a
missing display is a hard failure.

One file: `-Dtest-filter=<stem>`. Benchmarks: `zig build bench -Dbench=true`.
Fuzzing: `dev/scripts/xtest.sh zig build test -Dtest-filter=fuzz_test --fuzz=100000`.

## Harness

`harness/` holds the shared fixtures: `helpers.zig` (model fixtures and
goldens), `fixture.zig` (X11-backed integration fixture), `test_sink.zig` (the
recording `Sink` double), and `cfg.zig` (config section test case). End-to-end
scenario scripts live in `dev/harness/`.
