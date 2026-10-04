# Entry, build system, tests, templates

Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

---

### `build.zig` (~450 lines) — module auto-discovery + registry codegen  **★**
**Now:**
```
for every src/**.zig: register as an importable module
  (module name = path relative to src/, / -> _)
sub-registry generation (text scan for the binding spelling):
  tiling_modules, window_modules, bar_modules, surfaces,
  slider_subs, systatus_subs, title_subs, prompt_subs
  -> one .zig file per registry: sorted entries + addons array
build_options: has_tiling / has_fullscreen / has_workspaces /
  has_bar ... (per-subsystem presence flags)
test runner: every src/test/**.zig is a test step
default: ReleaseFast; std_options enable segfault handler
```
**Verdict:** ★ — the entire plugin system is the build system: a new layout/window-feature/bar-segment is a dropped file, and the registry is regenerated automatically. The text-scan binding detection is documented (and `title/geom.zig`'s header warns never to quote a binding literally in a comment).
**Ideal:** unchanged. **Path:** none.

### `src/main.zig` (238 lines) — boot sequence  **★**
**Now:**
```
main():
  --check-config? -> runCheckConfig() (no X11; exit 1 on any
    warn/err diagnostic — CI gate)
  connectToX() -> XSession (owning; errdefer disconnect;
    errored connections are already torn down)
  atoms.initAtomCache (before any atom reader — DPI needs it)
  input.initXkb
  config.load -> dpi resolution (config override > Xft.dpi >
    physical guess — order is a config question)
  config_ptr = heap box (atomic-swap reload target)
  core.init(...)              // publishes State
  hz.ensureRefreshRateDetected(x.conn)   // arm refresh-rate detection once
                                         // (display feature; needs the root window)
  input.setup (grabs read live config — after core.init)
  input.buildKeybinds
  restart.init (resolve exec path before any reexec request)
  defer: deinitOwnedConfig (LIFO: before deinitKeybinds, which
    owns bindings that borrow from the box)
  requests.advertiseEwmhSupport
  signals.setup
  events.grabKeybindings
  window.init
  pipeline.init (owns the model)
  actions.seedParamsFromConfig (boot-time config seeding)
  surfaces.init (composition root — bar never named here)
  requests.flush
  restore.adoptSession (re-exec hand-off, if env says so)
  events.run()
  delete restore file on GRACEFUL exit only (crash/re-exec
    must keep it — the XIDs it names are already recycled)
```
**Verdict:** ★ — boot order is load-bearing (atom cache before DPI, core.init before grabs, LIFO defers matching ownership) and every ordering constraint is documented at the site that needs it. The graceful-vs-crash restore-file distinction is correct.
**Ideal:** unchanged. **Path:** none.

### `src/hz.zig` — relocated during review
Refresh-rate detection was mislocated at `src/` root: its own header said it
"lives under src/bar", and `check-layers.sh`'s allowlist already expected
`src/bar/hz.zig` (rule 1 was failing on `src/hz.zig:356`). The fix, after
weighing the dependency graph: detection is a *display* feature (the rate is
read by bar title pacing and the floating drag throttle), so it now lives as a
single `src/core/display/hz.zig` (see `01-core.md`) — value and RandR probe
in one file, compiled into every tree, armed once at boot from `main.zig`,
with the event loop calling it directly. The three RandR hooks left the
`Surfaces` contract (`contract_x11.zig`, build.zig's generated no-op set,
and `bar.zig`'s binding all dropped them).

---

## `src/test/**` — 51 files

Coverage follows the architecture: pure kernels are unit-tested, protocol seams are tested against recorders (the `Sink` vtable), and the latency suite guards the hot paths. Grouped:

**core pure (`core/`):** `bounded_test` (BoundedList/Store ops), `idmap_test` (open-addressing + tombstones), `ids_test` (WorkspaceId validity), `dpi_math_test`, `masks_test` (lock-modifier combinatorics), `timers_test` (the min-over-all-sources reduce with four sources).
**core x11/loop:** `sink_test` (ConfigureWire slot order — the width/height swap bug class), `events_test`, `signals_test`, `spawn_test` (CLOEXEC hygiene), `usable_area_test`.
**engine:** `model_test` (1618 lines — the model's exhaustive suite), `reconcile_test` (delta-send correctness), `pipeline_test`, `tiling_test` (every layout's compute), `persist_test` (wire format v5 + blob adoption), `tracking_test`.
**window:** `actions_test`, `focus_test`, `borders_test` + `borders_pure_test`, `wincache_test` (invalidation coverage), `ewmh_test`, `workspaces_test`, `fixture` (shared X-less fixture).
**config:** `config_test`, `parser_test`, `schema_test`, `scratch` (test scratch dir helper).
**input:** `input_test` (press classification), `keymap_test` (reverse index), `keysyms_test`.
**bar:** `metrics_test` + `width_state_test` (the injected-probe pattern), `visibility_test`, `clock_test` (staleness math), `carousel_test` (pure motion), `vim_test` (modal engine), `completion_test`, `meter_test`, `slider_test`, `commit_test` (throttle coalescing), `systatus_test` (parseCpuLine/parseRamField/parseCapacity), `volume_test` (ladder policy), `brightness_test` (sysfs against a fabricated root), `font_probe_test`, `native_alsa_test`, `native_pulse_test`.
**latency:** `perf_test`, `focus_latency_test`, `tiling_latency_test` — hot-path guards.

**Verdict:** ★ overall — the suite tests the right things (pure kernels, protocol shapes, policies) without needing a live X server. Two gaps worth noting, neither blocking:
1. No Xvfb end-to-end integration run in-tree (boot → map → tile → focus against a real server) — the closest is the latency suite.
2. The god-file splits (below) should each land with a *new* test pinning the extracted unit's contract (e.g. `bar/layout_test.zig` for the center-row math).

**Path:** (1) add per-extraction tests alongside each refactor phase; (2) optionally add an Xvfb-gated integration test step to the build (opt-in, skipped when Xvfb is absent).

---

## `dev/plugin-template/**` — addon templates  **★**

- `layout.zig` — `pub const module: Layout` binder example (how to add a tiling layout).
- `provider.zig` — `WindowModule` hook example (how to add a window feature).
- `segment.zig` — bar `Segment` binder example (how to add a bar segment).

**Verdict:** ★ — the templates mirror the three registry types exactly; dropping a copy into the right directory and running the build is the whole onboarding path.
**Ideal:** unchanged. **Path:** none.
