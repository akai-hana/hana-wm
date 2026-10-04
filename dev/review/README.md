# hana codebase review — index & roadmap

Codefile-per-codefile analysis of the entire tree (142 source files, ~47k LOC), with per-file: current-behavior pseudo-code, idealness verdict, from-scratch ideal pseudo-code, and a behavior-preserving refactor path.

## Documents

| Doc | Scope | Files |
|---|---|---|
| `01-core.md` | `src/core/**` (architecture, core, display, loop, proc, pure, x11) | 33 |
| `02-window.md` | `src/window/**` + feature modules | 12 |
| `03-config.md` | `src/config/**` | 12 |
| `04-tiling.md` | `src/tiling/**` + layouts | 7 |
| `05-input.md` | `src/input/**` | 5 |
| `06-bar-core.md` | `src/bar/*.zig` | 8 |
| `07-bar-modules.md` | `src/bar/modules/**` | 18 |
| `08-entry-build-tests.md` | `build.zig`, `main.zig`, `hz.zig`, `src/test/**`, `dev/plugin-template/**` | 54+ |

Verdict scale: **★ ideal** (ship as-is) · **◐ near-ideal** (minor nits) · **△ restructure** (god-file split, behavior-preserving) · **▽ redesign** (shape is wrong).

## Global verdict

**The codebase is already at or near its ideal architecture.** Of ~142 files: ~120 ★, ~15 ◐, 5 △, 0 ▽. The design has been through many prior refactor rounds (see `dev/SIMPLIFICATION_PLAN_v1..v10*.md`, the audit files), and the result is coherent:

- **Layering is real and enforced** (`dev/scripts/check-layers.sh`): pure core (`core/pure`, `core/architecture/model`) is xcb-free; `core/x11` is the only leaf that touches the wire; subsystems reach X11 through the `Sink` vtable and the reconciler.
- **The reconciler pattern is the crown jewel** (`core/x11/reconcile.zig` + `ledger.zig`): unconditional recompute from the pure model, delta-send against a write-only sent ledger, atomic under a server grab. Model stays authoritative; the ledger only elides identical requests.
- **Pluggability is the build system**: file presence = registry membership (`tiling_modules`, `window_modules`, `bar_modules`, `slider_subs`, `systatus_subs`, `title_subs`, `prompt_subs`, `surfaces`). Dropping a file degrades the WM; nothing stubs.
- **Allocation-free everywhere it matters**: `BoundedList`/`Store`/`IdMap` are stack containers; the model owns no allocator; the hot paths (event loop, reconcile, draw) allocate nothing.
- **Single-threaded by construction**: signalfd + self-pipe + poll-deadline reduction; module globals are race-free by design and documented as such (hz.zig's plain f64 is the reference argument).
- **Config semantics match the README contract**: file joining, includes, ScalableValue (percent/px), warn-and-keep-last-good, `--check-config` CI gating via a diagnostic count.

## Top findings (the actual remaining work)

1. **God-files** (all behavior-correct, all just too big; two of seven done):
   - ~~`config/config.zig` (2411)~~ **DONE** → 8 files, orchestrator now 429 lines (see `03-config.md`)
   - `bar/bar.zig` (2224 → 1683) → center_row DONE / visibility_glue DONE / input_events DONE / draw DONE / orchestrator (State + lifecycle)
    - `window/window.zig` (1558 → 1474) → hints DONE / identity DONE / record+admission+store
   - ~~`prompt/prompt.zig` (1546)~~ **DONE** → 4 files, orchestrator now 447 lines (see `07-bar-modules.md`)
   - `drawing.zig` (1293) → fonts / text / surface / padded (optional, ride with bar split)
    - ~~`window/actions.zig` (1117)~~ **DONE** → 5 group files + 233-line hub (geometry / layout_params / ws / wm / modulate — `geom`/`layout` stems taken by bar modules)
   - `core/loop/events.zig` (945) → dispatch table + loop mechanics
2. **No ▽ redesigns exist.** Nothing in the tree has the wrong shape; the work is extraction, not rethinking.
3. **Module-global mutable state is fine** — do not thread contexts through; it is safe under the single-threaded loop and would be a large, gainless churn. Revisit only if threads are ever introduced.
4. **Test suite is strong on pure kernels and protocol seams**; the two real gaps are (a) no Xvfb end-to-end integration step, (b) each extraction below should land with a new unit test pinning the extracted contract.
5. **File location is part of the design — one violation found and fixed during review.** `hz.zig` sat at `src/` root while its own header and `check-layers.sh`'s allowlist both expected it under `src/bar/` (rule 1 was failing on `src/hz.zig:356`). The fix, after weighing the dependency graph: refresh-rate detection is a *display* feature (the rate is read by bar title pacing and the floating drag throttle), so it now lives as a single `src/core/display/hz.zig` — value and RandR probe in one file, compiled into every tree, armed once at boot from `main.zig`, with the event loop calling it directly (the three RandR hooks left the `Surfaces` contract). Verified: `zig build`, `check-layers.sh`, and the bar/floating modularity scenarios all pass. **Lesson for the roadmap: every file's location should be checked against (a) its own header's claim, (b) the check-layers allowlist, (c) the check-modularity scenario matrix — all three are executable specifications of location.**

## Refactor roadmap (the future task)

Every phase is **independently shippable**: extract verbatim → re-export pub fns from the old module so importers are untouched → run the test suite → commit. No phase changes behavior.

- **Phase 0 — baseline.** Run the full suite (`zig build test`), record the pass state; every later phase must keep it green.
- **Phase 1 — `bar.zig` split (highest value). COMPLETE.** `bar/center_row.zig` (center-row budget/share math, pure over injected seams — the `layout` stem is taken by the layout segment, hence the name; `center_row_test.zig` pins the derivations headlessly), `bar/visibility_glue.zig` (the apply* visibility family + screen-claim/raise, verbatim move; the `events` stem is taken by the core event loop; check-layers' Rule 1 allowlist extended), `bar/input_events.zig` (expose/button/motion/release handlers + click dispatch, verbatim move; no wire mutations, so no allowlist change), and `bar/draw.zig` (performDraw / submitDrawBlockingFull / requestFullRedraw / foldModuleRedraw / redrawInsideGrab / redraw*Scoped / blit submission, verbatim move; the paint pass stays on `State` in `bar.zig`). All three spoke files form runtime-only import cycles with `bar.zig` (never comptime), gated by the full suite, check-layers, and all 31 modularity scenarios.
- **Phase 2 — `config.zig` split — DONE.** Extracted `config/{validate,snapshot,layout_names,diff,discover,sections,binds}.zig` (2411 → 429-line orchestrator); every name re-exported through `config.zig` so importers are untouched. Verified: full suite, `check-layers.sh`, all 31 `check-modularity.sh` scenarios.
- **Phase 3 — `prompt.zig` split — DONE.** Extracted `prompt/{editor,completion,render}.zig` (1546 → 447-line orchestrator); all names re-exported through `prompt.zig` so `vim.zig` and the tests are untouched. Verified: full suite, `check-layers.sh`, all 31 `check-modularity.sh` scenarios.
- **Phase 4 — `window.zig` + `actions.zig` splits — DONE.** window.zig: `window/hints.zig` (pure WM_NORMAL_HINTS parse; `hints_test.zig`) and `window/identity.zig` (pure WM_CLASS split; `identity_test.zig`); record + admission + store stay in window.zig (1558 → 1474). actions.zig: five group files — `window/geometry.zig` (drag/rect/moveFocused/viewport), `window/layout_params.zig` (cycle/variant/primary/swap + config seed), `window/ws.zig` (switchTo/moveWindowTo/tag/pin/allView), `window/wm.zig` (mapRequest/unmanage/fullscreen), `window/modulate.zig` (minimize/restore) — fns verbatim, single-group helpers moved along, multi-group transition tails (retile/focusFallback/prepareAndSetFocus/…) stayed pub in the 233-line hub, which re-exports all 35 pub fns so importers are untouched; the six files form the window layer's intentional runtime-only import cycles. Verified: full suite, check-layers, all 31 modularity scenarios.
- **Phase 5 — `events.zig` dispatch table. ALREADY DONE (stale item).** The ~60-arm switch already lives in a comptime-built `dispatch_table` (`core/loop/events.zig`: `[_]?EventHandler` array indexed by XCB event type, `asHandler` comptime signature enforcement, bounds-guarded O(1) dispatch); this roadmap item was written before that refactor landed. Drain/settle order untouched.
- **Phase 6 — `input.zig` mouse extraction — DONE.** Extracted `input/mouse.zig` (288 lines, verbatim: the four mouse handlers + private `handleWindowButtonPress`, `classifyMousePress` + `MousePress`/`MouseIntent`, `findMouseBind` + private `tryConfigMouseBind`, `reportUndeliverableMouseBinds`, and the `finishGrab`/`releaseGrab`/`keepDragGrab` grab-settle tail) from input.zig (653 → 410 lines). All eight pub names re-exported through input.zig, so the events.zig dispatch table, main.setup, and input_test.zig are untouched. mouse.zig dispatches config binds through `input.executeAction`/`input.grafted` (both now `pub`) — a mutual runtime-only import cycle like input.zig ↔ events.zig. check-layers Rule 1 allowlist extended: mouse.zig joins the bare-flush bucket (`finishGrab`'s `xcb_flush` pushes the buffer after the two `xcb_allow_events` replay/async calls — no mutation of its own). Verified: full suite (`zig build test`), `check-layers.sh`, all 31 `check-modularity.sh` scenarios.
- **Phase 7 — test hardening.** Xvfb-gated integration step (opt-in); per-extraction tests from Phases 1–6.

Estimated total: ~2-3 days of mechanical, low-risk work. Nothing here is required for correctness — the tree ships as-is today; this roadmap is polish that pays off in review speed and test targeting.

## How to read a file entry

```
### `path/file.zig` (lines)
**Now:**      high-level pseudo-code of current behavior
**Verdict:**  ★ / ◐ / △ / ▽ + why
**Ideal:**    from-scratch pseudo-code (or "unchanged" + delta)
**Path:**     ordered refactor steps (or "none")
```

Constraints honored throughout: functional user parity is preserved by every phase; no recommendation contradicts `README.md` ideals (layering, registry pluggability, warn-and-keep-last-good config); "ideal" means simple, efficient, performant, elegant — several files are already the reference implementation of a pattern (metrics.zig, visibility.zig, carousel.zig, systatus.zig, sink.zig).
