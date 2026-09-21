# Core/Hub simplification audit — `src/core/*`

**Date:** 2026-09-21
**Scope:** `src/core/{core,events,pipeline,plugin,persist,restart,screen,scale,signals,spawn}.zig` (the closed core / hub). `src/core/sync/`, `src/core/x11/`, `src/core/utils/` belong to the CORE-PLUMBING agent and are read only as seams.
**Method:** full re-read of all 10 hub files (5,020 LOC across `src/core`), grep/caller tracing for every hook, import, and `pub` surface; cross-checks against `SIMPLIFICATION_PLAN_v3.md` (the baseline), `dev/scripts/check-layers.sh`, and build-generated registries.
**Baseline (v3):** 16,553 code LOC, `zig fmt` clean, `zig build check` exit 0. This report is additive to v3: same constraints, do-not-re-read v3 items except as zero-risk re-opens.

---

## Verified v3 claims that bound this audit

| v3 item | Finding |
|---|---|
| CORE-1 unified event drain | Landed. One comptime-parameterized `drainEvents` (events.zig:420) shared by batch + queued drains; motion collapse shared via `collapseMotionRun` (events.zig:474). No parallel loops remain. |
| CORE-2 canonical seam headers | Landed. x11/wire.zig and other seam headers carry the shared "no code beyond this point" sentence. |
| CORE-6 marker removal | Landed **in core scope**: no `C#`/`P#`/`Gap N`/`W#` marker remains in `src/core/` (only false positives: idmap.zig's hash constant `0x9E3779B97F4A7C15` and utils.zig prose "Gap and border widths"). NOTE: `(Gap 1/2/3/4 atomicity fix)` markers still live in `src/window/actions.zig:282,869,965,992` and `src/window/focus.zig:262` — window-layer remit, not reported here. |
| Contract is real, not a mandated no-op | Confirmed FALSE-to-claim. Every `Surfaces` hook has ≥1 consumer (grep-verified, e.g. `updateBarVisibilityForWorkspace` at window/actions.zig:839); every `WindowModule` field has ≥1 binder AND ≥1 consumer. |
| Closed-core holds structurally | Confirmed. events.zig/pipeline.zig reach optional subsystems ONLY via generated `plugins.Surfaces`, `window_modules`, `tiling_seam` (build.zig:163-182, generated, collision-guarded at build.zig:590). Core never names an optional subsystem by module. |
| No TODO/FIXME in src/ | Confirmed (rg, exit 0). |
| fmt clean | Confirmed baseline; no formatting-only edits proposed. |

---

## Findings — core/hub scope

Format: `ID (COREH-NN)` · location · axis · issue · fix · est LOC delta · confidence. No finding below is `[DEF]` (each is provably behavior-preserving after re-verification inside its own file).

### COREH-01 — dead import `constants` in events.zig
- **Location:** `src/core/events.zig:9` (`const constants = @import("constants");`)
- **Axis:** Dead code
- **Issue:** Zero `constants.` references in the file (rg-verified). v3 moved config constants into file-local consts (events.zig:37-53) and the import was left behind.
- **Fix:** Delete line 9.
- **LOC delta:** −1 · **Confidence:** H

### COREH-02 — dead import `wincache` in pipeline.zig (plus stale doc)
- **Location:** `src/core/pipeline.zig:14` (`const wincache = @import("wincache");`); stale refs at `:124-125` ("border width from wincache.width()") and `:148` ("Ported from wincache.color")
- **Axis:** Dead code / doc drift
- **Issue:** The only `wincache.` mentions in the file are comments. Border width now comes from `core.borderWidth()` (pipeline.zig:129) and colors from `colorOf` (pipeline.zig:152-155). The import also leaves a now-pointless core→window compile edge.
- **Fix:** Delete line 14; update the `ctx()` doc comment at :124-125 to name `core.borderWidth()`. Keep the :148 historical note (it explains intent).
- **LOC delta:** −1 · **Confidence:** H

### COREH-03 — dead import `types` in pipeline.zig
- **Location:** `src/core/pipeline.zig:18` (`const types = @import("types");`)
- **Axis:** Dead code
- **Issue:** Zero `types.` references in the file (rg-verified). Leftover from an earlier take on `ReconcileOpts` parameterization.
- **Fix:** Delete line 18.
- **LOC delta:** −1 · **Confidence:** H

### COREH-04 — `loadToGlobal` returns `!bool` but cannot error
- **Location:** `src/core/persist.zig:256-287`
- **Axis:** API ergonomics
- **Issue:** Signature `pub fn loadToGlobal(allocator, path) !bool`. Line-by-line the body cannot return an error: `readFileAlloc` failure → `catch` → `return false` (:263-266); `parseFromSlice` failure → `catch` → `return false` (:269-272); version mismatch → `return false` (:273-278). There is not a single `try` in the body and every potential `!` path is converted to a value. Consumers are forced into ceremonial `try`: `main.zig:135` (`if (try persist.loadToGlobal(...))`).
- **Fix:** Declare `bool` (drop `!`); drop the `try` at main.zig:135. Both call sites and persist_test are unaffected otherwise.
- **LOC delta:** −1 · **Confidence:** H

### COREH-05 — `pub const max_claims` with no external consumers
- **Location:** `src/core/screen.zig:33` (`pub const max_claims = if (build_options.has_bar) 1 else 0;`)
- **Axis:** Naming / API surface
- **Issue:** Zero consumers outside screen.zig (rg-verified); it sizes the private `claims` ledger (:38). The only claimer id is exposed correctly via `bar_id` (:36), which the bar uses; `max_claims` is internal plumbing that leaked `pub`.
- **Fix:** De-publish (drop `pub`).
- **LOC delta:** 0 (keyword drop) · **Confidence:** H

### COREH-06 — dead `binary_path_override` parameter in restart.init
- **Location:** `src/core/restart.zig:61-81`
- **Axis:** Dead code
- **Issue:** `pub fn init(alloc, binary_path_override: ?[]const u8)`. Sole caller is `main.zig:79` (`restart.init(alloc, null)`); no test calls it (rg over src/test). The override branch (:62-65) is unreachable in every build, yet the doc (restart.zig:58-60) still justifies it "(e.g. tests)".
- **Fix:** `pub fn init(alloc: std.mem.Allocator) void`; delete the branch and trim the doc.
- **LOC delta:** −8 (incl. doc) · **Confidence:** H (removing a pub parameter is an API change, but the only caller and zero tests pass `null`; behavior is identical)

### COREH-07 — stale header mention of `count_minimized`
- **Location:** `src/core/persist.zig:8` ("home_ws and count_minimized are derived and NOT serialized.")
- **Axis:** Doc drift
- **Issue:** `count_minimized` exists nowhere in `src/` (rg-verified); persist.zig's own header at :322-324 documents that "no feature counters live here anymore" and minimize maintains its sequence internally. The surviving mention contradicts the same file.
- **Fix:** Delete "and count_minimized".
- **LOC delta:** 0 (in-line reword) · **Confidence:** H

### COREH-08 — stale "DPI scaling run pre-swap" in reload doc
- **Location:** `src/core/events.zig:276` ("Keybind resolution and DPI scaling run pre-swap on the new config.")
- **Axis:** Doc drift
- **Issue:** The config-reload path performs no DPI work: events.zig has zero `scale.`/`detectDpi` references (rg-verified) and `scale.detectDpi` runs once at boot (`main.zig:54`). The comment over-claims step 1.
- **Fix:** Reword to "Keybind resolution runs pre-swap…".
- **LOC delta:** 0 (reword) · **Confidence:** M (verified by absence of any DPI code in the reload path)

### COREH-09 — bare `bool` focus-ordering argument at 6 call sites
- **Location:** `src/core/pipeline.zig:202-218` (`reconcileGrabFocus(o, t, focus_before: bool)`); call sites main.zig:147 `false`; window/actions.zig:101,187,360,563 `true`; :967 `false`
- **Axis:** Readability
- **Issue:** The focus-before-geometry ordering decision is a naked literal at every call site; the meaning of `true`/`false` is only recoverable from pipeline.zig:199-201.
- **Fix:** A small `enum { before, after }` (or labelled-struct arg). Mechanical rename at 7 sites; the branching body at :213-215 is untouched.
- **LOC delta:** 0 (net) · **Confidence:** M (style-level; deliberate omission if the codebase prefers plain bools — see "avoidance of findings" below)

### COREH-10 — `core.borderWidth()` computed twice per ctx() build
- **Location:** `src/core/pipeline.zig:110` (`tilingEnv` → `.border = core.borderWidth()`) plus `:129` (`ctx()` → `const border_width = core.borderWidth()`); same scan base `screen_h` (:106/:128)
- **Axis:** Duplication (repeated fact computation)
- **Issue:** Every reconcile-candidate build calls `core.borderWidth()` twice (each: `getState()` + `scaleBorderWidth`) and scales `gap_width` alongside with the same `screen_h`. Both results are identical.
- **Fix:** Compute `border_width` once in `ctx()` and feed it into `tilingEnv`'s margins, or have `tilingEnv` take the precomputed border. Micro-opt; output byte-for-byte identical.
- **LOC delta:** −1 · **Confidence:** H (behavior-preserving)

### COREH-11 — header claims a marker convention that no longer exists
- **Location:** `src/core/pipeline.zig:5-8` ("Call sites (all marked `// PIPELINE:`):")
- **Axis:** Doc drift
- **Issue:** v3's marker pass (CORE-6) stripped the `// PIPELINE:` call-site markers; only one survives, in window-layer code (`src/window/window.zig:1465`, out of scope). The header's "all marked" promise is now unverifiable at the sites it lists.
- **Fix:** Reword to describe the call sites directly, or drop the marker note.
- **LOC delta:** 0 (reword) · **Confidence:** H

---

## Per-file walkthrough

### `src/core/core.zig` (148) — clean
`XK`/`Connection`/`Screen`/`WindowId`/`WorkspaceId`/`FocusSuppressReason` types; single optional `State` (5 fields, finally-named, comment explains why not five `undefined` globals); `Facts` + comptime `factAccessors` (focus/window/fullscreen/layout revs) — the sole remaining indirect-consumption seam and it is tight; `tilingEnabled`/`borderWidth` config-fact accessors (the "core reads tiling facts so the layout stays a plugin" move); `getState`/`init` panic-guarded; `dpi_info` atomic kept outside `State` with a safe default. Consumers of every export verified. **No findings.**

### `src/core/events.zig` (665) — 2 findings
Dead import `constants` (COREH-01); stale "DPI scaling" doc (COREH-08). Everything else reviewed line-by-line:
- `asHandler` comptime shape-check guard (events.zig:62-77) — justified safety, keeps the generic table sound.
- `dispatch_table` (36 slots, masks.synthetic_event_mask strip, bounds guard at :188-195), type-0 error pseudo-event branch (:166-174) — documented, handling real diagnostic value.
- `isRandrEvent` raw-compare-before-mask (events.zig:157-163) with a first-class rationale comment — this is the "subtle semantics" that must NOT be compressed.
- `fillGrabCookies`/`checkGrabCookies` pairing, `grabKeybindings` — fire-all-then-check-all cookie batching is legitimate, single-owner.
- `handleConfigReload` ordering (1-4) + pointer-swap + `committed` defer + source-vs-fallback distinction + `detectChanges` gating — every step is commented with the load-bearing reason (including the historical use-after-free it prevents).
- `handleReexec` persist-before-disconnect-before-exec sequence — sound.
- `drainEvents`/`collapseMotionRun` budget + `charge_tail` + pending-token semantics — dense but precisely documented ordering-preserving logic; the shared drain is exactly what CORE-1 built and further unification would erase the comments, not the code.
- `run()` poll loop with signals-before-flags ordering rationale, `std.os.linux.poll` manual errno idiom (consistent with spawn/scale usage elsewhere), timeout only reaching into the bar via `surfaces.pollTimeoutMs()`. Not over-engineered: the load-bearing comment per branch earns its place.

### `src/core/pipeline.zig` (330) — 4 findings
Dead imports `wincache` (COREH-02) and `types` (COREH-03); double `borderWidth()` (COREH-10); marker-convention doc (COREH-11); plus COREH-09 (bool ordering arg). Structure verified:
- `model()`/`mut()`/`Gate` capability gate with compile-time `*const` tripwire and panic-guarded pre-init access — idiomatic and used exactly as documented (transition-layer modules declare private Gates).
- `ctx()`/`tilingEnv()` shared with the test fixture so fixture mirrors production env resolution.
- The "closure idiom" `withServerGrab` + value-capturing struct bodies; all five reconcile-slot entry points have ≥1 real caller (main.zig:147; actions.zig:101/187/360/563/967; focus.zig:565/568), `reconcileUnderGrabNowFullscreen`'s EWMH/bar-arm loops route through the `window_mods` registry uniformly.
- `preReconcileDuties` direct-`instance` touch documented with the value-in/value-out rationale.
- `grabCtx()` manual-grab seam consumed at actions.zig:871, floating.zig:208, fullscreen.zig:381.

### `src/core/plugin.zig` (481) — no findings
The open-contract file. Verified every `Surfaces` (24 hooks) and `WindowModule` field (29 hooks) against its binders and consumers — not a mandated no-op. `providerOf` registry-first lookup with the "registry passed in, not captured" import-edge note; `DirtySources`/`bar_id`-style comptime `null` channels; `View`/`List`/`HintsView`/`Env` vocabulary moved onto the contract so `sync` + layout modules share one definition. Long, but every field carries a binding-rule comment ("at most one module binds this"). This is the intended cost of deletion-modularity, not bloat.

### `src/core/persist.zig` (385) — 2 findings
Dead `!` on `loadToGlobal` (COREH-04); stale `count_minimized` header mention (COREH-07). Structure: shadow-record wire format with `presence`/`ext` seam, version stream (persist_version=4), `max_restore_bytes` 1 MiB cap, atomic write (temp+fsync+rename), adoption loop and `applyModelLevel` covering-intent restore + registry-kind degradation fallback (`resumableDefaultKind`, single in-file caller — kept, it carries the degraded-restore rationale), shared `restoreMembers` helper (genuine dedupe across tiled_order + focus_mru). `save`/`loaded`/`applyModelLevel` consumers verified (events.zig:407, main.zig:135, window.zig:826, actions.zig:688, window.zig:791).

### `src/core/restart.zig` (136) — 1 finding
Dead `binary_path_override` param (COREH-06). Otherwise clean: pure flag surface mirroring proc.zig's reload flag; unconditional-reexec rationale; readlink `/proc/self/exe` truncation guard (:72-77); deliberates `execv` (not execvp, no PATH lookup) inheriting environ/DISPLAY/HANA_RESTORE; no-fork rationale for xinit session liveness; double-`mustDupeZ` + setenv + execv with `noreturn`; comment chain explains the "close X before exec or BadAccess" ordering it enforces.

### `src/core/screen.zig` (111) — 1 finding
`max_claims` de-pub (COREH-05). The claim ledger is genuinely minimal and well-named: `Edge`/`Claim`/`claims` comptime-sized, `workArea` saturating subtraction, surface-window registration + `isSurfaceWindow`/`mappedSurfaceWindow` recognition used by management/focus/drag (floating.zig:160, window.zig:337, pipeline.zig:143). No dead code, no magic numbers (all named per-v3 hygiene).

### `src/core/scale.zig` (169) — no findings
Named consts with units (min/max reasonable DPI, 4 KB/16 KB probe windows, mm_per_inch, font_baseline_height); `XftProbe` result struct that distinguishes got_string / dpi / possibly_truncated; two-stage RESOURCE_MANAGER probe with the truncation subtlety documented; geometry fallback + reasonability band; `scaleFontSize`/`scaleBarHeight` consumed by bar (bar/metrics.zig:43, bar/bar.zig:99/144) and `bar_min_height_px` exposed for config validation. Clean.

### `src/core/signals.zig` (284) — no findings
The notable design — pipe byte is only a WAKE TOKEN, signal state lives in an async-signal-safe bitmap (`pending_signals`, atomics) so a pipe-full burst can never lose TERM/INT/reload — is correct and fully documented. `writeSignalByte` full-pipe recovery loop; SIGUSR2 out-of-band backtrace handler with frame-pointer walk bounded to `rsp..rsp+8MiB`; per-signal `pending_signals` bit consumption via `ctz`; `else => {}` arm is strictly defensive (only the 5 installed handlers ever set bits) — benign, left alone. clean.

### `src/core/spawn.zig` (264) — no findings
Double-fork with a single O_CLOEXEC pipe; two independently-scheduled writers (tag_pid / tag_failed) with order-independent `finishSpawn` classification under PIPE_BUF-atomicity; "buffer full ⇒ both messages present, EOF not needed" drain shortcut; capacity pre-check before fork (rejects instead of silently dropping routing); EAGAIN retry semantics; `reapPendingChildren` WNOHANG-only policy; workspace snapshot before fork for `[exec, switch_workspace]` sequences. The 16-entry `BoundedList` buffer with `swapRemove` is the right shape. Clean.

---

## Re-opens (zero-risk, v3-item re-checks that now hold in the current tree)

- **RE-OPEN CORE-1 (drain unification)** — holds; see table above.
- **RE-OPEN CORE-2 (seam headers)** — holds; wire.zig + sync seam headers consistent.
- **RE-OPEN CORE-6 (marker strips)** — holds for `src/core/`; the window-layer `(Gap 1..4)` markers remain (out of scope; flag for the window agent).
- **RE-OPEN MODEL-1 (config-reload defaulting consolidation)** — holds; `model.applyConfigReload` at model.zig:509 + `actions.applyConfigReload` routing (events.zig:368), single template seed (main.zig:116).

## Avoidance of findings (checked-and-clean, deliberately not raised)

- **Helper split `dispatch`/`dispatchOwned`** — one-liner but the ownership distinction is load-bearing (owned vs borrowed event); merging would bury it.
- **`if (build_options.has_bar)` gate sites in events.zig** — each is required for comptime compile-out; that is the feature, not repetition.
- **Repeated `catch |err| debug.err(...)` chains in handleConfigReload/run** — mirror-site-error handling for distinct subsystems; consolidating would couple them.
- **The grab-bracket asymmetry** (`withServerGrab` in pipeline vs `sync.reconcileUnderGrab`'s profiler-armed grab in sync/): reconcileUnderGrabNow now routes through sync's own grab; unifying fully would move the profiler responsibility across the sync boundary. Coordination note for CORE-PLUMBING only — not filed as core finding.
- **The `else => {}` in `dispatchSignal`** and the 1024-cookie scratch buffer = 16 KB stack — bounded, documented, defensive by design.

## Ranked top simplifications

1. **COREH-01 + COREH-02 + COREH-03 — delete the three dead imports.** −3 LOC, zero risk, also removes the last core→wincache import edge. *H.*
2. **COREH-06 — drop the always-null `binary_path_override`.** −8 LOC incl. doc, removes a dead branch and dead parameter; only caller passes null. *H.*
3. **COREH-04 — `loadToGlobal: !bool → bool`.** −1 LOC + `main.zig:135` loses a ceremonial `try`. *H.*
4. **COREH-05 — de-pub `max_claims`.** *H.*
5. **COREH-10 — hoist the double `borderWidth()`.** *H.*
6. **COREH-07 + COREH-08 + COREH-11 — three stale/doc-drift rewords.** *H/M.*
7. **COREH-09 — labelled focus-ordering arg.** Style-only; the biggest *design* change of the set and the only judgment call.

**Net:** ≈ −13 lines in core scope plus three doc rewords; none `[DEF]`. The deliverable conclusion: after v3, the hub is in high-quality shape — remaining complexity is concentrated in single-owner, heavily-commented subtle paths (asHandler guard, isRandrEvent masking semantics, drain budget semantics, signal pipe-token design, spawn message classification) whose compression would trade away the comments that make them correct. The highest-value reduction is the dead-import/ded-entry trio plus the restart override, which together leave the hub fully self-consistent with its own documentation.