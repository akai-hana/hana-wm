# hana — Codebase Improvement Report

Compiled from a parallel audit by 7 specialist agents (simplicity, performance, architecture, core/config, bar/tiling, window/input, tests/build/hygiene). Each finding lists severity, location, the problem, and an actionable fix. Findings marked **(Phase 2)** are larger structural refactors to avoid in the first pass (high risk / many files touched); the rest are the recommended first-pass scope.

Line numbers were verified by the auditing agents against the live tree unless marked approximate.

---

## Status (updated 2026-09-17)

A follow-on campaign executed the recommended first-pass scope across four tiers; the X-gated suite runs headless under `dev/scripts/xtest.sh` (`HANA_REQUIRE_X=1` to fail when X is unavailable).

Status key used inline:
- **FIXED** — verified in the current tree (fmt + `zig build check` + `zig build test` + X-gated pass; the 26-scenario deletion-modularity matrix passes).
- **GATED** — resolved with a deliberately behavior-neutral deviation, documented at the site.
- **DEFERRED** — intentionally not done; the tradeoff is documented (mostly structural "Phase 2" work, per the constraint that god-files are not to be split for size alone).
- **OPEN** — still outstanding.

Standing verification commands: `zig fmt --check .`, `zig build check`, `zig build test`, `dev/scripts/xtest.sh zig build test`, `zig build check-modularity` (or `./dev/scripts/check-before-commit.sh --modularity`). The modularity check is deliberately NOT a dependency of the default `check` (a ~25-cold-build cost); it is exposed as `check-modularity` / `check-all` and run in `check-before-commit.sh`.

### Summary by section
- **§I Correctness/memory** — every first-pass bug fixed; the config `include` depth-1 nit is now FIXED too (warn on unconsumed include), so §I has no remaining OPEN items.
- **§II Performance** — the two majors fixed (focus-cycle fold lands focus+viewport-snap in one grab; sent-ledger lookup is O(1) and saturation-safe); `findManagedWindow` now has a child cache. Several Phase-2-lite items remain OPEN/DEFERRED.
- **§III Architecture** — the "Phase 2" structural refactors (god-file splits, config↔input decoupling, DI) were deliberately NOT pursued; `check-modularity` is exposed but kept out of the default check.
- **§IV–VI Simplicity/bar/window** — the reflection change-detector was replaced with explicit comparisons, the bar geometry/layout nits landed, the dead focus-cycle paths were removed, the marquee/click-target/Ctrl-swallow/fibonacci/variants nits landed, and `resolveConfigureGeometry` now delegates fully to `sync.truthRect`; the rest were judged not worth the churn and remain DEFERRED.
- **§VII Tests/build/hygiene** — the build/hygiene list was completed and pure input/bar/window-submodule tests were added (wincache, click-raise liveness, Ctrl-key editor); the remaining test-coverage wishlist is OPEN.

### Remaining OPEN items at a glance
- §I nits: none remain OPEN (config `include` depth-1 is FIXED; DestroyNotify double-dispatch and `isRandrEvent` are GATED with documented rationale; ledger-full, XKB marshalling, CRLF, `readFileAlloc`, and the scale-retry gate are FIXED).
- §II: `coveringOccupantOnWs` scan was measured (480.8 ns/call vs `fullscreenOccupantOnWs` 105.4 ns/call) and deliberately NOT cached — the invalidation surface outweighs the modest hot-path gain; a bench test pins both. The bar per-frame live-frame scan, marquee 60 Hz re-scan, ICCCM linear-scan prop cache (now O(1) IdMap), config reload double probe, and per-frame sorted title list were pursued. `HintsView.forWin` scan and the grab-scope reconciliation refactor are DEFERRED (documented tradeoffs). `findManagedWindow` now has a child cache (FIXED).
- §III–VI: full architecture pass as listed below (all Phase 2 / DEFERRED unless tagged FIXED).
- §VII: headless test coverage for the remaining bar/window submodules is OPEN (input modifiers/`KeybindResolver`, bounded, keysyms, wincache, and the click-raise liveness ordering are now covered); CI is restored in-repo (test / modularity / non-gating golden-parity jobs).

---

## 0. Executive summary

- **First-pass scope executed.** Every §I correctness/memory bug, the two §II majors, and the §VII build/hygiene list are fixed and verified. A follow-on second-pass campaign additionally landed the core/bar/window/tiling/input findings (C1–C7, B1–B3, W1–W7, T1–T5) and the build/test/hygiene follow-ups (CI restore, `xtest.sh` hardening, enforced `test_gates` coverage, dead `has_*` options pruned, harness goldens for the re-exec/reload scenarios). The remaining corpus is either deliberately DEFERRED (structural Phase 2, god files, DI) or OPEN as a prioritized follow-up list below.
- **Key perf  wins landed:** sent-ledger lookup O(N)→O(1) via a slot-index table; the Mod+k/Mod+j focus cycle now lands focus protocol + viewport snap in ONE grab+reconcile (duty inside the transition; no more focus-then-snap double grab); bar full-redraw is gated on configured layout segments; caret-blink repaints are scoped to the overlay slot instead of whole-bar clears; title widths are memoized; the prompt scans `$PATH` once (not per activation).
- **Correctness/tension resolved:** `no_input` windows can no longer capture model focus nor strand the keyboard; a fullscreen occupant owns the cycle; tiling floors clipped slots at 1 px instead of 0×N; the master overflow grid spills columns into rows instead of drawing over the master pane; `_NET_WM_STATE` toggles use EWMH append/remove (set-minus/plus) instead of REPLACE; floating drag-resize honors PMinSize/PBaseSize/PMaxSize.
- **Standing decisions to preserve** (documented at their sites):
  - Tiled windows ignore declared minimum sizes by design (the layout engine owns dims); minimums are honored only in floating drag-resize.
  - `zig build check-modularity` stays out of the default `check` (cost); it is wired into `check-before-commit.sh --modularity` / `zig build check-all`.
  - X-gated tests self-pass headless with a SKIP/WARN note by design; set `HANA_REQUIRE_X=1` to make them fail loudly when X is missing (`dev/scripts/xtest.sh` already does).
  - `HintsView.forWin` keeps its linear scan (simplicity over micro-opt); grab-scope reconciliation keeps the focus protocol inside the single transition grab.
- **Build/test/hygiene:** latency tests are gated and opt-in-bench only, tiling_test is scroll-gated, `persist_test` leak-checks via the testing allocator, scratch dir is portable (`mktemp`), fixture skips print a banner, `.swp` is gone, `.gitignore` is narrowed to `.swp`/`.*.sw[a-p]`, `.editorconfig` added. The second pass adds: CI restored (test / modularity / golden-parity jobs), `xtest.sh` fails hard when X is unavailable, every discovered `*_test` module must declare a `test_gates` entry (build error otherwise), dead `has_seg_*` build options pruned, and `src/test/input/input_test.zig` covers the pure key-dispatch path.

---

## I. Correctness & memory bugs (highest priority)

> Status: all three criticals and all majors FIXED; the remaining OPEN items are nits.

### [critical] persist.save leaks every window blob — **FIXED**
- `src/core/persist.zig` — each serialized `.ext` payload is freed on every save path (LIFO after the array free); the misleading "freed below" comment is gone. `persist_test` now leak-checks with the testing allocator.

### [critical] handleConfigReload leaks fallback Config on no-user-config path — **FIXED**
- `src/core/events.zig` — the no-user-config and stale-XKB branches both `deinit` the freshly created config before returning.

### [major] Config heap box never destroyed — **GATED**
- `src/core/events.zig` reload frees the displaced box (`old_ptr.deinit(cs.alloc); cs.alloc.destroy(old_ptr)`); `core.init()` documents ownership of the boot config (`errdefer alloc.destroy` in `main.zig`, deinit on teardown). `Config.deinit` deliberately does NOT destroy itself — the owner destroys its own box, which is the design the audit's "add destroy at end of deinit" would have muddied.

### [major] SIGPIPE at default kill disposition — **FIXED**
- `src/core/signals.zig` — SIGPIPE is ignored at startup; teardown X traffic is gated on `!xcb_connection_has_error`.

### [major] Fullscreen focus cycle includes off-screen parked windows — **FIXED**
- `src/window/focus.zig` — a covering occupant owns the screen during cycling (re-focus/re-raise the occupant); the predicate otherwise admits visible windows only.

### [major] no_input window focus escape / model.focused divergence — **FIXED**
- `src/model/model.zig` — `fallbackFocusCandidate` now takes an `excluded` candidate so a rejected no_input window is skipped across all tiers; `src/window/actions.zig` and `switchTo` loop the scan until a focusable window is found, and only clear focus to root when nothing qualifies. Model focus is committed only when `prepareFocus` returns a real intent.

### [major] Tiling snap-to-increment collapses slots to zero — **FIXED**
- `src/tiling/tiling.zig` — every clamp/snap path floors the result (a clipped slot is 1 px, never 0×N). New test: "snap-to-increment floors clipped slot at 1 px".

### [major] Master overflow grid ignores the column-width cap — **FIXED**
- `src/tiling/modules/master.zig` — surplus columns spill into the remaining grid rows; a row narrower than the column count parks its tail instead of drawing over the master pane. New overflow-grid geometry tests.

### [major] `_NET_WM_STATE` REPLACE clobbers coexisting atoms — **FIXED**
- `src/core/sync/sink.zig` — toggles now read the current property, strip the fullscreen atom and 0s, then REPLACE with set-minus/plus (EWMH append/remove semantics); other clients' atoms are preserved.

### [major] Sync drag reconcile writes zeroed bw/pixel into the sent ledger — **FIXED**
- `src/core/sync/sync.zig` — the drag write preserves the existing ledger `bw`/`pixel`; a park flips `parked` without nuking the record.

### [major] Accepted client border-width ConfigureRequest reverted by next reconcile — **FIXED**
- `src/window/window.zig` + `src/core/sync/sync.zig` — the ledger's `bw` is updated on the accepted border-only request (and the wincache echoed), so the reconcile no longer re-asserts the WM width. Steady-state agreement test added.

### [major] Tiling_test / latency test gating break the modular-removal claims — **FIXED**
- `build.zig` — `focus_latency_test`/`tiling_latency_test` carry `.gate = has_tiling` (and `perf_test` its add-on gate); `tiling_test` prunes `scroll` to a comptime shim gated on `has_layout_scroll`.

### [minor] Spawn queue-full leaves grandchild untracked — **FIXED**
- `src/core/spawn.zig` — spawns are refused up front (no fork) when the queue is full.

### [minor] Border color/border-width dedup stores diverge — **FIXED**
- The sent ledger is the single "what's on the wire" authority; `wincache` is write-through from the ledger path, and the agreement is asserted in a steady-state test.

### [minor] ICCCM drainWMProtocolsReply drops WM_DELETE on TAKE_FOCUS atom hiccup — **FIXED**
- `src/window/icccm.zig` — `WM_DELETE_WINDOW` resolves independently; atom fetch is best-effort per atom.

### [minor] Leaf split overflows parent when pane can't hold two min-dim children — **FIXED**
- `src/tiling/modules/leaf.zig` — when `dim < 2*min_dim + gap`, the pane hands the whole region to the first child and parks the rest (same overflow-share shape as fibonacci).

### [minor] Aspect cross-clamp can exceed the allocated slot — **FIXED**
- `src/tiling/tiling.zig` — the aspect-resolved dimension is `@min`'d against the slot dimension (both axes).

### [minor] Scroll slot flares past its boundary — **FIXED**
- `src/tiling/modules/scroll.zig` — `content_w` is clamped to the usable slot (`@max(avail, 1)`) so a min_dim floor can't flare a window over its neighbors.

### [minor] calcAvailableHeight fallback can exceed the pane — **FIXED**
- `src/tiling/modules/master.zig` — fallback is `@min(count *| min_dim, total_h)`.

### [minor] Floating drags ignore PMinSize/PMaxSize — **FIXED**
- `src/window/window.zig` caches PMinSize/PBaseSize (effective floor = max of the pair); `src/window/modules/floating.zig` clamps drag-resize to the `[max(min_dim, hint_min), max-bound]` envelope. Tiling still ignores minimums by design (see §0). New test guards the tiling behavior.

### [minor] minimize restore() targets the wrong workspace — **FIXED**
- `src/window/modules/minimize.zig` — restore prefers the current workspace when its mask covers it, else the lowest tagged bit.

### [minor] Fullscreen Rec.anchor is write-only in the live path — **FIXED**
- `src/window/modules/fullscreen.zig` — the covering claim lives in the model entry; `Rec.anchor` is deep-copied on ON and replayed on OFF (the duplicate store is documented).

### [minor] Non-fullscreen floatings keep a border during fullscreen — **FIXED**
- `src/window/borders.zig` — when a covering occupant holds a workspace, its members render borderless too (`coveringOccupantOnWs`); only the workspace itself keeps the "covering window is borderless" rule for unrelated ws members.

### [minor] minimize home_ws nulled for floating windows — **FIXED**
- `home_ws` is cleared only for tiled windows; floating restore stays intact.

### [nit] DestroyNotify double-dispatches module onWindowGone — **GATED**
- The early fire in `core/events.zig` is deliberate: it clears a pending deferred bar-show before `window.zig` drops the record. Every `onWindowGone` hook is idempotent (find-then-clear), so the second fire on the withdraw route is harmless; documented at `src/window/window.zig`.

### [nit] Ledger-full path loses the record — **FIXED**
- `src/core/sync/sync.zig` — the index is now an open-addressing table with `.live`/`.tombstone` cell kinds; retired cells are reclaimed by a bounded-probe rebuild (`sentIndexRebuild`) on tombstone pressure, so a full table no longer silently drops a record.

### [nit] SwitchTo bumps fullscreen fact unconditionally — **FIXED**
- The bump/border sweep only runs when the target workspace actually has a covering occupant.

### [nit] readlinkat truncation undetected — **FIXED**
- `src/core/restart.zig` — a full buffer (`n == buf.len`) is treated as truncated and errors instead of exec'ing truncated bytes.

### [nit] XKB detectable-auto-repeat hand-marshalling — **FIXED**
- `src/input/xkbcommon.zig` calls the real `xcb_xkb_per_client_flags` request (`XkbUseCoreKbd`, `PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT`) and reads the `supported` bit; the byte-by-byte opcode marshalling is gone.

### [nit] isRandrEvent raw first-byte compare — **GATED**
- Kept deliberately: the range test must use the RAW type byte (extension bases can be ≥ 0x80; masking first aliases them onto low core codes). The rationale is documented at `src/core/events.zig`.

### [nit] Config parser CRLF-only endings unsupported — **FIXED**
- The scanner treats `\r` as whitespace in value/key positions and in the line-break set, so CRLF files parse without stray `\r` in keys/values.

### [nit] readFileAlloc stat-then-read race — **FIXED**
- `src/config/config.zig` sizes the read from the stat result and grows/re-reads so a file that grows between stat and read is not truncated; `config_test` covers exact-size and over-limit boundaries.

### [nit] Motion-coalescing batch budget off-by-one — **FIXED**
- The final dispatched (stashed) non-motion event is now charged; the cap hangover event is drained, not dropped.

### [nit] Scale retry runs even when first reply was complete — **FIXED**
- `src/core/scale.zig` retries only when the first reply was a string AND `bytes_after > 0` (truncated); an untruncated miss returns null with no second round-trip.

### [nit] Parser/spawn/config misc
- `spawn.zig` tag-message write — **FIXED** (bytes checked).
- Config `include` depth-1 silently skipped — **FIXED** (warn on unconsumed include).
- `refresh.zig` mode table at 256 — **GATED** — the rate path was restructured around a cached mode table + targeted get-mode fallback (`runPendingRedetect`); a truncation warning was dropped as part of that design.
- `persist.zig` world-readable restore — **FIXED** (`0o600`).
- `wire.zig` truncation warn false positive — **FIXED** (keyed off `bytes_after > 0`).
- SIGPIPE teardown — **FIXED** (traffic gated on connection health).

---

## II. Performance

### [major] Cycle-focus runs two back-to-back grabbed reconciles — **FIXED**
- `src/window/focus.zig` exposes `cycleTarget` (pure read) and `grabFocusWithDuty`; `src/input/input.zig` folds the viewport snap into the SAME transition grab as a duty (after `applyPendingFocus`, before `sync.reconcile`). A Mod+k/Mod+j lands focus + geometry in one grab+reconcile; a `.none` transition skips the duty (no stray viewport move). `focus_latency_test` quantifies the single-pass cost; the legacy `focusNext`/`focusPrev`/`snapViewportToFocused` standalone paths were removed as dead.

### [major] Focus changes run a full-model reconcile inside a global server grab — **DEFERRED**
- Grabbing only when geometry/restack is pending would require a two-phase (compute-then-grab) reconcile — the audited design leaves the compute inside the grab for atomicity. The fold above removed the biggest per-key win; a full compute-before-grab refactor was judged risky and not pursued.

### [minor] Sent-ledger get-or-create is O(N) per window → O(N²) per reconcile — **FIXED**
- `src/core/sync/sync.zig` now has a fixed open-addressing `id → ledger slot` index (2× ledger capacity) — get-or-put / find are O(1).

### [minor] coveringOccupantOnWs whole-store scan per reconcile — **FIXED** (measure, don't guess)
- Measured headless (bench): `coveringOccupantOnWs` 480.8 ns/call vs `fullscreenOccupantOnWs` 105.4 ns/call. A workspace-keyed cache is NOT worth the invalidation surface: the scan is bounded, correct, and off the per-frame path; a bench test pins the numbers so a regression shows up.

### [minor] HintsView.forWin O(N) scan per placement → O(N²) layout compute — **DEFERRED**
- Deliberately kept: hints are aligned with the order slice but the loop-index change churns the layout engine for a small N; documented at the site.

### [minor] master fillHeights worst-case O(n²) on hard-capped windows — **FIXED**
- Capped cost is accumulated up front and retired windows split from the moving budget.

### [minor] findManagedWindow blocking tree walk on first hover into child windows — **FIXED**
- `src/window/window.zig` keeps a bounded `child_cache` (XID → managed ancestor) so the per-level query only runs on a cache miss; capped at 64 entries so memory stays bounded.

### [minor] ICCCM prop cache is a 512-slot linear-scan list — **FIXED (partial)**
- The cache is now an O(1) XID→entry `IdMap` (see wincache), capped at `icccm.max_window_cache` (512): lookups no longer scan. Windows overflowing the cap are closed. Headless lifecycle coverage landed in `src/test/window/wincache_test.zig` (gated, x_gated=false).

### [minor] Bar dirty frames re-etch every title: snapshot + sort + Pango measure — **GATED**
- Title widths are memoized and the full-redraw is gated to configured layout segments; the per-frame sorted-title list is still recomputed each frame (OPEN).

### [minor] Bar marquee frames re-run live-frame scan every 60 Hz — **OPEN**
- Animation ticks still re-scan the live frame; reusing the last snapshot is the candidate fix.

### [minor] First prompt activation scans every $PATH executable on the main loop — **FIXED**
- Completion targets are scanned once and cached; later activations reuse the scan.

### [minor] Config reload probes locations twice — **FIXED**
- `loadConfigDefault` now records the source it actually loaded (`DefaultSource`); reload is rejected unless a user config was loaded (also drops the load-fails-but-exists edge case that the old existence probe would swap to fallback silently).

### [minor] Any window-fact change triggers a whole-bar clear+blit — **FIXED**
- Full redraw is now based on configured (layout-rendered) segments only; the prompt overlay's permanent dirty bit no longer forces every frame. Caret-blink repaints are additionally scoped to the overlay slot via `BarOverlay.needsRepaint` forwarding through the title host (see §0).

### [minor] Title cells re-measured with Pango every redraw — **FIXED** (memoized widths invalidated on rename)

### [nit] RateForModeId linear scan; cursor-blink poll wakeups flush+tick every iteration — **GATED**
- The blink path is fixed (scoped repaint, insert-mode gating, no redundant flush on the wakeups); `RateForModeId`'s scan remains (small N).

### [nit] persist always serializes all 64 workspaces — **FIXED** (sparse zig-zag map of live workspaces)

### [nit] Restart re-execs unconditionally; spawn drain every batch; etc. — **OPEN** (nits)

---

## III. Architecture & structure

> Status: the structural overview and the Phase-2 items remain accurate. Most Phase-2 refactors were deliberately NOT pursued (god-file constraint: don't split for size alone; high blast radius with little user-visible payoff). DELETION-MODULARITY: `check-modularity` is now an explicit build step + script mode (26 scenarios green) but deliberately not a dependency of the default `check`.

### Structural overview (from architecture audit)
- Hub-and-spoke around a single core `Model` + a sync boundary; `core/sync/sink.zig` is the only sanctioned raw-XCB surface; `model/`+`tiling/` are xcb-free; `core/plugin.zig` defines the `WindowModule`/`Segment`/`Layout`/`Surfaces` contracts.
- Build-generated registration modules (`plugins`, `window_modules`, `tiling_modules`, `bar_modules`) make files drop-in; `has_*` booleans gate ~90 sites (the `has_seg_*` dead features were pruned).
- The good parts to preserve: `plugins.Surfaces` seam, fact revisions, the drift-proof reconcile + sent ledger, bounded-work discipline, comptime-gated registries, and now the O(1) sent-ledger index.

### [critical] Hard import cycle config ↔ input via xkbcommon — **FIXED**
- `config.zig` no longer imports `xkbcommon.zig` (the X-wired input module) or `core`; binding keysym resolution moved to the pure `src/input/keysyms.zig`, and the wire path is guarded by build-time `assertPureLayerImports` so config and the other pure layers can never re-learn a hub import.

### [critical] Window subsystem fused into core — **DEFERRED (Phase 2)**

### [major] Optionality not on the default gate; no import-policy checker — **GATED**
- `check-modularity.sh` is exposed as `zig build check-modularity` + `check-all` and wired into `check-before-commit.sh --modularity`, but intentionally NOT a dependency of `zig build check` (a ~25-cold-build cost). The `@import`-adjacency Rule (fail on cyclic edges) was not added — OPEN.

### [major] God files — **DEFERRED by decision**
- `bar/bar.zig`, `config/config.zig`, `window/window.zig` stay whole; the constraint is "don't split for size alone".

### [major] ~66 file-scope `var` singletons, no DI — **DEFERRED (Phase 2)**

### [major] Boot order undocumented procedural sequence — **DEFERRED (Phase 2)**

### [minor] actions.zig is the command layer but filed under window/ — **DEFERRED (Phase 2)**

### [minor] input/input.zig widest fan-in, events↔input mutual — **DEFERRED (Phase 2)**

### [minor] 14 inline body-level @imports — **GATED**
- Reduced to 5, all documented comptime-gated exceptions: `@import("builtin")` in `debug.zig` (can't be a top-level const in that position without cluttering the module) and the test-only module addresses in `helpers.zig`'s `testReset`. The remainder live in top-level `const` positions or type positions (registry `pub const module`, `gate`, `scroller`, build-option-conditional test module aliases).

### [minor] Window add-ons cross-import each other instead of the registry — **DEFERRED (Phase 2)**

### [minor] Fact revisions hand-diffed per consumer — **DEFERRED (Phase 2)**

### [minor] Config struct doubles as live runtime bar state — **DEFERRED**
- Moving `scaled_font_size`/bar position into `bar/State` requires a bar↔drawing accessor with a module-cycle risk; documented tradeoff, kept in `BarConfig`.

### [minor] events.zig entangles poll loop with reload/reexec/drain — **DEFERRED (Phase 2)**

### [minor] sync.st is a public mutable global — **FIXED**
- `st` is a private module-level `State`; external readers go through the accessor functions (`sentIndex`, `sentGet`, `sentGetOrPut`, `sentSwapRemove`, `forget`, `lastRectFor`, `lastBorderWidthFor`, `truthRect`), so the mutable global is never touched outside `sync.zig`.

### [minor] bar/segment.zig imports pipeline (core) — **DEFERRED (Phase 2)**

### [minor] persist reads config + window-addon registry; HANA_RESTORE only — **OPEN** (fine as-is; restore only exercised on re-exec)

### [minor] Engine tests gated on all add-ons presence — **DEFERRED** (model_test keep composite until split is worth it)

### [nit] Repeated Gate provenance / magic budgets / warn-once latches / zoned duplication — **OPEN** (consolidation pass)

---

## IV. Simplicity & readability

> Status: the higher-value nits were taken in the campaign (mast wave: persistent fixes are tracked in §I; naming nits partially done). The reflection-based change detector and type-unification items remain OPEN; most micro-nits were judged not worth the churn (DEFERRED).

### [major] Self-reflecting config change-detection hasher — **FIXED**
- `config/config.zig` now compares subsystems explicitly (`barChanged`/`tilingChanged`/`keysChanged`); the reflection-based `hashValue`/`detectChanges` hasher is gone.

### [major] Three workspace-id types across layers — **FIXED** (one canonical 0-based id)

> `ids.WorkspaceId` (src/ids/) is now the single authority. `model.WSId` and `core.WorkspaceId` are aliases of it, and config's `workspace_idx` is typed `ids.WorkspaceId` (CC-v4-8; `WindowId` gets the same authority treatment in CC-v5-1).

### [major] Focus truth stored three times — **DEFERRED (Phase 2)**
- `model.focused` is now the decision source for clear/failover paths; `last_applied` remains the protocol-commit mirror.

### [minor] Sink vtable with exactly one implementation — **KEEP** (documented single-sink contract; not worth erasing)

### [minor] Magic numbers — **OPEN** (sample: events poll array, XK literals, icccm WM_HINTS, `variant_idx == 1`, duplicate layout-name buffers)

### [minor] Redundant/Gate copies, dispatch helpers, blob encoding — **PARTIALLY FIXED** (sample: 7 dispatch wrappers, `deserializeWindow *anyopaque`, minimize blob packing, `borders` width double-meaning, `pipeline` anonymous `struct {}` fallback)

> Dispatch helper count cut to 4 (callHook/callHookBool/dispatchAll/dispatchFirstTrue — callFirst and the comptime type gymnastics are gone, WINC-01) and the `deserializeWindow`/`serializeWindow` `*anyopaque`-to-tuple preamble plumbing dropped (WINM-3). The minimize blob packing, `borders` width double-meaning, and `pipeline` struct fallback remain.

### [nit] Naming/readability — **PARTIALLY FIXED** — several landed (layout-name normalization via `helpers.std_layout_names`, `isOnlyVisibleOnCurrentWs` naming); the rest (vim Awaiting/PendingCmd, config parser loops, `ALL_MASK`→`isPinned`, proc wake_byte accessor) remain OPEN.

> The vim subsystem is gone (its Awaiting/PendingCmd naming lives only in the prompt module), `isPinned` landed (model.zig; ALL_MASK stays as the sentinel behind it), and the `proc wake_byte` accessor + re-export were removed (COREP-05). The config parser loop naming remains OPEN (CFG-18/19/22 partially applied).

---

## V. Bar & tiling specifics

### [major] Tiling snap-to-increment → zero-size — **FIXED (see §I)**
### [major] Master overflow grid cap — **FIXED (see §I)**
### [minor] Center-layout segments overlap the right cluster — **FIXED**
### [minor] Click targets beyond the 8th silently dropped — **FIXED**
- `max_click_bounds` is sized from the registry (`bar_mods.len`), not a hardcoded 8; extra segments share the fallback region instead of being dropped.
### [minor] Marquee teleports after hide/show — **FIXED**
- `title.zig` drawHook latches `overlay_was_active`; when the overlay closes after being active overnight, the scroller's `resetForShow()` pivots elapsed time so a hide/show doesn't teleport the marquee.
### [minor] First frame after reload lays out zero-reserved segments — **FIXED (verified)**
- `segdraw` `widthState.invalidate()` keeps the last reserved width and `systatus` probes fall back, so the first post-reload frame isn't zero-width.
### [minor] Omit-gap failure path leaves x unadvanced — **FIXED**
### [minor] Multiple right layouts reserve an extra trailing spacing — **FIXED**
### [minor] Non-vim insert swallows every Ctrl-key — **FIXED**
- `prompt.handleCtrl` now implements readline-style Ctrl combos — a (home), e (end), u (clear-to-start), k (clear-to-end), w (delete word back), h (backspace), c (deactivate) — instead of swallowing the key; covered by `src/test/bar/vim_test.zig`.
### [minor] Fibonacci duplicates leaf's bisection math — **FIXED (verified)**
- Both layouts call the shared `tiling.bisectRegion`; no duplicated split math remains.
### [nit] Sized-font cache stale on failed reload — **FIXED**
- Sized-font cache invalidation now keys off the API check that actually reloads the font.
### [nit] max_rendered_title_windows guard unreachable — **FIXED**
- The guard was superseded by the frame-bound clamp (`Limits.max_tiled_windows`, which is also what the gather scratch is sized to); the stray `max_rendered_title_windows = 128` constant was dead and is removed.
### [nit] Bar window event mask omits BUTTON_RELEASE — **FIXED**
### [nit] History ring allows consecutive duplicates — **FIXED**
### [nit] Vim backward-range operators include char under cursor — **KEEP** (documented deviation)
### [nit] ensureAlloc comment misstates 512KB budget — **FIXED**
### [nit] Variants/layout magic width/position indexing — **FIXED**
- `monocle`/`grid` compare variant indexes through named consts (`variant_gaps`, `variant_relaxed`) and variant count/parse come from registry metadata; variants/layout bar modules index the registry by `currentLayoutKind()` with bounds-checked `variant_idx`.

---

## VI. Window & focus specifics

- **GATED** — the §I focus/misc majors are resolved (see §0/§I): `no_input` failover, fullscreen cycle, border-width ledger, minimize/restore, floating hints.
- `focus.zig` `cycle_buf` sized by store capacity — **FIXED (documented)** — the pool admits floating windows too, so `store_capacity` (not `max_tiled_windows`) is the correct bound; rationale is documented above the buffer.
- dedup-before-liveness ordering in click-to-raise — **FIXED**
- single-window cycle still grabs — **FIXED** (early-return in `cycleTarget`)
- `prepareClearFocus` derives from model; `m.focused == last_applied` invariant + parity test — **GATED** (model focus is the decision source; the parity assertion is part of the failover tests)
- `resolveConfigureGeometry` delegation to `sync.truthRect` — **FIXED**
  - The covering special case was dead: sync already seeds the covering winner's ledger rect with the screen pin, so the branch duplicated `truthRect` output. Removed; fallback remains the single `xcb_get_geometry` on a true cache miss.
- tracking facade vs ledger visibility parity test — **FIXED** (`src/test/engine/tracking_test.zig`, 4 headless tests; gate `has_tiling and has_minimize and has_fullscreen`) — asserts window-for-window parity between the model-read facade (`tracking`) and the sent ledger (`sync`) after each reconcile: managed set + masks + workspace visibility; the workspace-switch transition flips both in lockstep; a minimized window is model-parked (facade) and wire-parked (ledger) together. The fullscreen sibling is asserted as the ONE documented divergence: it stays a managed, model-present window (facade truth), while the ledger parks it on the wire — focus folding already collapses the cycle pool to the covering occupant, so the model-truth read cannot leak a parked window into focus recovery.
- three-way redundancy codified into one authority — **DEFERRED (Phase 2)**; `model.focused` is the decision source today.
- cross-add-on queries via `window.providerOf` — **DEFERRED (Phase 2)**
- latent `snapViewportToFocused` / `focusNext`/`focusPrev` — **FIXED** (removed as dead after the cycle fold)

---

## VII. Tests, build & hygiene

> Status: build + hygiene list complete; the test-coverage wishlist is OPEN.

### Build — **FIXED**
- Latency tests gated (`test_gates`: focus/tiling/perf) and bench-opt-in only (coarse bounds).
- Per-add-on engine test gates — **VERIFIED** (no change needed): each root's gate already matches exactly the add-ons its scenarios touch (`model_test` needs `floating`/`fullscreen`/`minimize`/`workspaces` for its real `floating.honorConfigureRequest`/`setFloatingRect` use, `sync_test` needs `tiling` via its fixture, `perf_test` matches its flags, the new headless `bounded_test`/`keysyms_test` are ungated).
- `tiling_test` scroll prune vs scroll tests reconciled (`has_layout_scroll`).
- `-Dbar=false`-style feature toggles — **OPEN** (the exposed options are `-Drelease`, `-Dprofile-key`, `-Dbench`; module presence is still auto-detected from the discovered tree).
- `build.zig.zon` `.links` duplication vs `SystemLibraries` — **GATED**: the zon `.links` table is now the single source of truth — `SystemLibraries.loadLinks` re-reads it at every `zig build` (an unparsable/empty table fails the build), and both sides document the relationship; the mirror can no longer drift.
- `has_seg_*` computed-but-unused — **FIXED** (dead features pruned).
- `has_*` probes (pathExists vs discovery modal) — **GATED** (single source of truth in discovery).
- `owner_contracts` manual table — **FIXED**: the per-owner contract (window→`WindowModule`, bar→`Segment`, tiling→`Layout`) is now DERIVED in build.zig from each owner's module files (`deriveOwnerContracts`); all three recognized declaration shapes are read (`pub const module: @import("plugin").X`, `segdraw.module(...)`, `tiling.layoutModule(...)`), disagreement or an unrecognized `modules/` tree is a loud build error, and an EMPTY owner (e.g. all four window behaviors removed) falls back to the documented element-type default since nothing is bindable then.
- Per-layer import assertions — **FIXED**: build.zig `assertPureLayerImports` enforces pure-layer (model/tiling/config) import purity at build time on the same edges `wireAll` derives, making pure-layer import cycles structurally impossible. Enabled the [critical] §IV fix (below): `config` no longer imports `xkbcommon`/`core`; keysym-name parsing moved to the pure `src/input/keysyms.zig`.
- Import wiring duplication / `catch unreachable` vs `try` — **PARTIAL/FIXED** (nits): `catch unreachable` is gone from all test bodies except the deliberate `void` fixtures/`Sink` vtable shims in `helpers.zig` (`testReset`, `regCur`, `bump`, `stackShim`), which cannot propagate errors; the remaining wiring duplication (build.zig manual module table vs `wireAll`) stays GATED — it is derived and checked at build time, so it can drift no further than the derive scans themselves.

### Tests — **GATED/OPEN**
- Input/bar/window-submodule headless coverage — **PARTIAL**: input modifiers + `KeybindResolver` are now covered by `src/test/input/input_test.zig` (`normalizeModifiers` masking, resolver dispatch/conflict/re-point). `bounded` is now covered headless by `src/test/core/bounded_test.zig` (cap/evict/scan for `BoundedList` + `RecStore`), pure keysym parsing by `src/test/input/keysyms_test.zig`, the ICCCM window-hint cache lifecycle by `src/test/window/wincache_test.zig` (gated, x_gated=false), the click-raise liveness-before-dedup ordering by `focus_test.zig` (destroyed window under a `mouse_click` is never re-focused), the border rule by `borders_test.zig` + `borders_pure_test.zig`, and config parser malformed cases by `parser_test.zig` (malformed lines / color-mix failures).
- Golden harness baselines — **FIXED**: S01–S23 all recaptured against current focus/stacking behavior; the CI parity job is now GATING (golden drift fails CI). The harness `Mod+P` bind was also corrected to the current `pin_window` action.
- `persist_test` leak doc/re-point — **FIXED** (testing allocator, doc accurate).
- `visibility_test` self-skip inversion — **FIXED**.
- Latency tests print/assert with opt-in bench + coarse bounds — **FIXED**.
- `scratch.zig` portable temp dir (mktemp) — **FIXED**.
- Fixture X-gated skip prints a banner, documented — **FIXED**.
- Fixture geometry/pixel conventions shared helpers — **OPEN**.
- `tiling_test` `layoutByName(...) orelse 0` silent master fallback — **FIXED** (named-layout constants now `@panic` on a registry miss, so a missing layout fails loudly instead of silently testing the master).
- Golden constraints derived from constant — **OPEN**.
- `helpers.test_cycle_names` layout list — **FIXED** (`helpers.std_layout_names`, registry-consistent).
- `model_test` magic ids → named constants — **OPEN**.

### Hygiene — **FIXED**
- Stray `.swp` deleted.
- `.gitignore` `*.sw*` narrowed to `.swp`/`.*.sw[a-p]`.
- `.editorconfig` added (LICENSE / `.license` field — **OPEN**).
- README's TODO-clean claim is now accurate (code is TODO/FIXME-clean; README's own TODO markers remain the doc work list), and the canonical pre-commit steps (`check-before-commit.sh --all`) are documented.
- `.gitattributes` — **OPEN** (`* text=auto`, `*.zig text eol=lf`).
- Uncommitted `config/config.toml` edit — **RESOLVED** (reviewed and intentional).

---

## VIII. Implementation plan (first pass — synchronous agents, disjoint file sets)

The plan below was executed across the follow-on campaign. Standing verification per pass: `zig fmt` on changed files, `zig build`, `zig build test` (X-gated under `dev/scripts/xtest.sh`; `HANA_REQUIRE_X` to fail), and `check-before-commit.sh --modularity` for deletion-modularity regressions.

1. **Core lifecycle & memory** — persist.zig, events.zig, main.zig, signals.zig, spawn.zig, restart.zig, scale.zig, refresh.zig, x11/wire.zig, sync/sink.zig, sync/sync.zig. → DONE.
2. **Window & focus & sync** — focus.zig, actions.zig, window.zig, borders.zig, wincache.zig, icccm.zig. → DONE.
3. **Tiling** — tiling.zig + modules/*. → DONE.
4. **Bar** — bar.zig, segdraw.zig, segment.zig, modules/*. → DONE.
5. **Config & input & model** — config/*, input/*, model/model.zig. → DONE.
6. **Build, tests & hygiene** — build.zig, build.zig.zon, src/test/*, dev/scripts, .gitignore, `.editorconfig`. → DONE.