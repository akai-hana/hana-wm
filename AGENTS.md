# hana — agent instructions

hana is a modular X11 window manager (+ integrated bar) written in Zig **0.16.0**
(`build.zig.zon` pins it; CI matches it). Read this before touching the tree.

## Golden rules

1. **Never run `zig build test` or `zig build run` bare on a machine with a live
   hana session.** They connect to the real display and grab substructure
   redirect/focus — stealing it from your running WM. Always wrap:
   `dev/scripts/xtest.sh zig build test` (starts its own Xvfb, sets
   `HANA_REQUIRE_X=1`, tears down after).
   A bare `zig build test` is also *silently green*: every X-gated test becomes a
   `SkipZigTest`, so the summary covers ~44 fewer tests than it looks like.
2. **`src/` must stay `zig fmt` clean.** Check with `zig fmt --check .`
   (CI runs `zig fmt --check src`). Run `zig fmt` on files you touch.
3. **No `TODO`/`FIXME` markers in `src/`** — the tree is empty of them by design;
   open work lives in the issue tracker, not the source.
4. **File stems are a global namespace.** Every `.zig` file under `src/` becomes a
   module named after its *basename* (directories ignored), auto-discovered by
   `build.zig`, so a stem can exist only once in the whole tree. Renaming a file
   touches every `@import`; moving it between directories does not. Check the
   stem table with `zig build modules`.
5. **Layer rules are enforced by `zig build check`** (`dev/scripts/check-layers.sh`):
   `model`, `tiling` and `config` stay xcb-free; wire-mutating XCB requests and
   server grabs belong only behind the reconcile boundary
   (`core/reconcile.zig` → `sink.zig` → `requests.zig`).
6. **Modules are self-contained and live beside their peers** (bar modules under
   `bar/modules/`, window modules under `window/modules/`, layouts under
   `tiling/modules/`). Deleting a module's file(s) drops the feature and the tree
   must still compile. The core never names an optional module directly: it goes
   through the contracts in `src/core/architecture/contract.zig`
   (`contract_x11.zig` for the X-typed half) and the build-generated registries
   (`window_modules`, `tiling_modules`, `bar_modules`).
   New community modules must compile against the templates in
   `dev/plugin-template/` (gated by `zig build check-plugin-template`, part of
   `zig build check`).

## Commands

| Task | Command |
|---|---|
| Build (Debug default; `-Drelease` for end users) | `zig build` |
| Unit tests (isolated Xvfb — **the** test command) | `dev/scripts/xtest.sh zig build test` |
| Single test file | `dev/scripts/xtest.sh zig build test -Dtest-filter=model_test` |
| Type-check + layer guards + plugin-template gate | `zig build check` |
| Pre-commit gate (fmt + check, `--test` adds suite) | `dev/scripts/check-before-commit.sh --test` |

Only wrap a gate in `ZBUILD_THROTTLE=1` (nice + pinned cores + `-j2`) when the
user explicitly asks for throttled/lightweight runs — default to full speed.
| Feature-deletion matrix (heavy: ~31 cold builds) | `dev/scripts/check-modularity.sh -j 4` |
| Latency benchmarks (opt-in) | `zig build test -Dbench` → `.zig-cache/bench/timings.txt` |
| Key-dispatch latency instrumentation | `zig build -Dprofile-key` |
| E2E scenario parity | `cd dev/harness && ./run-scenario.sh --compare <S01-spawn-tiled ...>` |
| List module stems | `zig build modules` |

Minimum bar after any non-trivial change:
`zig fmt --check .` + `zig build check` + the affected tests through `xtest.sh`.
CI additionally runs the full suite, `zig build`, and the modularity matrix.

## Layout

- `src/core/` — event loop, X11 layer, reconcile boundary, `architecture/`
  (contracts + `model.zig`, the single source of truth for window state,
  deliberately X11-free).
- `src/window/`, `src/tiling/`, `src/bar/`, `src/input/`, `src/config/` —
  subsystems; optional ones (`tiling`, `bar`, most modules) can be deleted.
- `src/test/` — unit tests, organized by area (`core`, `window`, `tiling`,
  `bar`, `input`, `config`, `harness`, `bench`).
- `dev/harness/` — end-to-end X scenarios with recorded goldens under
  `dev/harness/golden/` (the only tracked part; `out/` is local).
- `config/` — hot-reloadable TOML (user-facing; see `config/README.md`).

## Notes

- `model` (in `src/core/architecture/model.zig`) is the single writer of window
  state; sync goes single-writer through the model (guarded by `zig build check`).
- Unit tests that need a display self-skip with `SkipZigTest` when none is
  available; `xtest.sh` sets `HANA_REQUIRE_X=1` so that path can never go green
  by skipping.
- Binary hot-reload exists (`reload_hana`), but a rebuilt binary on `:0` must
  never be spawned bare from a dev session — use `xtest.sh` or `dev/harness`
  with its isolated Xvfb.
