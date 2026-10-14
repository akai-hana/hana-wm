# hana codebase review — round 2 (index & roadmap)

Fresh codefile-per-codefile pass of the entire tree (~142 source files, ~48k LOC incl. tests),
re-judged against the post-Phase-6 tree (bar/config/prompt/actions/input/mouse extractions all
landed since round 1). Round-1 verdicts were treated as claims to re-verify, not inherit.

## Documents

| Doc | Scope | Files | Verdicts (★/◐/△/▽) |
|---|---|---|---|
| `01-core.md` | `src/core/**` (architecture, core, display, loop, proc, pure, x11) | 34 | 31 / 3 / 0 / 0 |
| `02-window.md` | `src/window/**` + feature modules | 19 | 17 / 2 / 0 / 0 |
| `03-config.md` | `src/config/**` | 12 | 7 / 5 / 0 / 0 |
| `04-tiling.md` | `src/tiling/**` + layouts | 7 | 7 / 0 / 0 / 0 |
| `05-input.md` | `src/input/**` | 6 | 5 / 1 / 0 / 0 |
| `06-bar-core.md` | `src/bar/*.zig` | 12 | 11 / 1 / 0 / 0 |
| `07-bar-modules.md` | `src/bar/modules/**` | 21 | 19 / 2 / 0 / 0 |
| `08-entry-build-tests.md` | `build.zig`, `main.zig`, `src/test/**`, `dev/plugin-template/**` | ~33 | 28 / 5 / 0 / 0 |

**Global: 125 ★ · 19 ◐ · 0 △ · 0 ▽.** No file is wrong-shaped. Round 1's open △ items all
landed (events dispatch table, config/prompt/actions/bar splits); round 2's only upgrades:
`wincache.zig` ◐→★ (invalidation coverage now complete) and `prompt/vim.zig` ◐→★ (shared-`Prefix`
cohesion is the correct shape, not a roughness).

## What round 2 actually found

No redesigns. The remaining work is three kinds: **two real defects** (one functional, one
latent-hazard), **seam/god-file slices** on the four biggest files, and **tooling/test hygiene**.

### Defects (fix first — behavior, not shape)

1. **`slider/volume.zig` mute gap (functional bug).** Right-click mute dispatches on the
   backend family, not the latched rung, so it silently no-ops on machines where the native
   backends apply (`native_pulse.zig` resolves `set_sink_mute` into `Lib` but never wraps it;
   `native_alsa.zig` likewise). The volume.zig header comment is also stale (claims the native
   backends "were removed"). Fix: add `setMuted` to both native backends and route `toggleMute`
   through the same latched rung as read/commit.
2. **`config/diff.zig` `tilingChanged` silent-drift hazard.** Hand-written field list with no
   comptime coverage check (unlike `barChanged`); a new tiling field reloads without triggering
   a rebuild. Derive it with the `cmpFor`/inline-for machinery.
3. **`window/window.zig` redundant EWMH scan.** The `_NET_WM_STATE` arm re-implements the
   want-vs-current guard that `fullscreenSetWindow` already performs internally — the covering
   scan runs twice per state message. Calling `fullscreenSetWindow(win, should_enter)` directly
   is wire-identical and drops the duplicate.
4. **`window/geometry.zig` `has_bar` coupling.** `activeViewport` gates the scroll-layout
   viewport on the bar's presence, but the clamp target (`usable_area.workArea`) is
   bar-independent — a scroll layout should work headless. Behavior-preserving fix: drop the
   gate, clamp to `workArea`.
5. **Latent:** `slider/slider.zig` `spawnCapture` drains only `sink.len` bytes before
   `pclose` — a child producing more than the OS pipe buffer would hang (never bites for
   current short commands).

### Seam slices (the four big files)

- **`config/color.zig` (unblocks two more).** The value-level color grammar in `parser.zig`
  (~310 lines) is a self-contained sub-language consumed only by `schema.zig`; extracting it
  (token-level `parseColor` stays in parser) breaks the schema↔split cycle and lets
  `schema.zig`'s bespoke `[bar.properties]` decoder (~165 lines) move to `config/bar_properties.zig`.
- **`input/dispatch.zig`.** The action interpreter (`executeAction`/`grafted`/`closeWindow`/
  `toggleBarPosition`/`dirSign`, ~110 lines) is a distinct concern whose co-location in
  `input.zig` forces the input↔mouse import cycle; `mouse.zig` is its only external consumer,
  so the extraction breaks the cycle cleanly.
- **`core/loop/events.zig` → `grabs.zig` + `reload.zig`.** Grab installation (~130 lines) and
  `handleConfigReload` (~95) are lifecycle concerns bundled with the loop; extracting both drops
  events.zig from 945 to ~700 and separates the per-event path from transitions.
- **`window/admission.zig`.** The admission slice in `window.zig` (~400 lines: rules map, spawn
  queue, the 5-cookie pipeline, the admission decision) has exactly two in-file consumers
  (`handleMapRequest`, `adoptRootWindows`) and its own state.

### Hygiene (optional, behavior-preserving)

- `drawing.zig`: hoist the ~185-line cairo/pango/glib extern block into a leaf-bindings file
  (precedent: `core/x11/xcb.zig`); also `SizedFontList.build` hides a `core.getState()` read.
- `bar.zig`/`center_row.zig`: hoist the duplicated `segId`/`hasRegisteredSegments` helpers into
  `segment.zig`; delete the dead `solveRowPlan` parameter (20.1 leftover).
- `config/sections.zig` (3 domains) and `config/binds.zig` (3 sub-grammars): separable
  families, both optional.
- `build.zig`: four independent ad-hoc source scanners (`classifyFile`, `declaresBinding`,
  `readTestGate`, `importEdgesOf`) → one shared scanner.
- `dev/plugin-template/`: covers 3 of the 7 addon families `sub_registry_specs` supports
  (missing: systatus-readout, slider, title, prompt/chrome-surface).
- Delete the one dead inline test outside `src/test/` (`bar/meter.zig:58`); fix the orphaned
  doc fragment above `systatus.zig`'s `miss_tolerance`; `model_test.zig`/`config_test.zig` mix
  separable concerns (optional splits).
- Cross-cutting watch-item: two parallel per-window caches (`icccm`'s allocation-free `IdMap`
  for focus props, `wincache`'s heap `HashMap` for hints+title) duplicate eviction/refresh
  triggers in `unmanageWindow`. Justified today by value-size asymmetry (~12B POD vs ~270B);
  converge into one per-window record cache if a third appears.

## Roadmap (each phase independently shippable; verify with `dev/scripts/xtest.sh zig build test`,
`dev/scripts/check-layers.sh`, `dev/scripts/check-modularity.sh`)

**Status: all four phases landed** (A and B in the round-2 implementation pass; C and D
after that). Two judgment calls deviated from the letter of the per-file specs:

- **D4 model_test split:** the workspaces third already had its own seam file
  (`src/test/window/workspaces_test.zig` covers moveWindowToWs/switchTo/pinToggle/
  allViewToggle/tag*), so the workspaces group was NOT re-homed — its model-axis tests
  (the `home_ws` cache, visibility, the tag-move record) stay in `model_test.zig`, and
  the split moved only the minimize (11 tests, plus the `fallbackFocusCandidate` policy,
  whose skip-candidates are minimized windows), fullscreen (9, including the module's own
  `PendingBarTable`) and floating (2) seams into `src/test/window/modules/`.
- **D4 config_test split:** the `Sandbox` fixture lives in `snapshot_test.zig` with the
  four snapshot tests; the non-snapshot tests that stage an isolated config dir
  (theme-quartet, 15.1, 15.12, checkConfig) keep using it through that module.

- **Phase A — defects** (no restructure): volume mute gap; `tilingChanged` derivation;
  `_NET_WM_STATE` duplicate scan; `has_bar` viewport gate; doc/test hygiene (stale headers,
  orphaned fragment, dead inline test).
- **Phase B — seams**: `config/color.zig` → `config/bar_properties.zig` → parser color-grammar
  removal (in that order; the first unblocks the other two); `input/dispatch.zig`;
  `events.zig` grabs/reload split; `drawing` bindings hoist; `segment.zig` helper hoist.
- **Phase C — god-file slices** (optional): `window/admission.zig`; `sections.zig` rules
  family; `binds.zig` action-name sub-grammar.
- **Phase D — tooling/tests** (optional): build.zig scanner consolidation; four missing
  plugin templates; TestSink extraction + fixture relocation; model/config test splits.

Estimated: Phase A is a day; B is 1–2 days; C/D are polish. Nothing here is required for
correctness — the tree ships as-is today; this is the delta between "near-ideal" and "ideal".
