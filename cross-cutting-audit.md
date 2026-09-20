# Cross-Cutting Simplification Audit (Interplay Focus)

- **Date**: 2026-09-20
- **Scope**: entire repo (all ~77 production files), overriding concern = **interplay between subsystems**, not per-subsystem internals. The per-subsystem pass is already covered by `dev/SIMPLIFICATION_PLAN.md` (6-agent, implementation applied, Phases A–C complete, 270 tests) and `simplification-audit.md` (src/core). This report focuses on the seams *between* those subsystems.
- **Method**: read all cross-subsystem integration points (`main.zig`, `events.zig`, `refresh.zig`, `persist.zig`, `restart.zig`, `signals.zig`, `input.zig`, `bar/bar.zig`, `build.zig`, `config.zig`, `tracking.zig`, `model.zig`, `utils.zig`, parser), grepped for every cross-module symbol boundary (grab/ungrab, refresh consumption, atom cache, workspace-bit helpers, test-gate rows, generated registries), and verified claims against the *current tree* before flagging.
- **Preamble acknowledgement**: This audit accepts the repo's own carved-in-stone constraints — sync boundary sacred (wire sends stay behind `src/core/sync/` + allowlist), pure layers (model/tiling/config) xcb-free, core never imports optional modules, modularity-by-deletion, `zig fmt` enforced via `check-layers.sh`. Nothing below proposes violating those.

---

## 1. Verified-Present / Verified-Clean (do NOT re-flag)

These plan items are already applied in the current tree; recorded here so future audits don't re-flag them, and so the interplay analysis below can trust them.

| Item | Evidence |
|---|---|
| Reload single-`committed` defer collapse (plan B1) | `src/core/events.zig` `handleConfigReload` — single `var committed = false; defer if (!committed) {…}` read-back point, confirmed at read time (~lines 298–302). |
| `barChanged` includes `brightness_format`/`brightness_device` (plan B30) | `src/config/config.zig` barChanged (~1603–1642) compares both brightness fields. |
| Pipeline `init()` param drop (plan A7) | `src/main.zig:110` calls `pipeline.init()` with no arg. |
| Loop-caps merge via shared `collapseMotionRun` (plan B2) | `src/core/events.zig` `collapseMotionRun` with comptime `charge_tail`; both drain sites route through it. Two budget tiers remain (128 batch / 256 queued) as pinned constants — verified intentional, not duplicated logic. |
| Atom cache single-sourced | `src/core/utils/utils.zig` `getAtomCached`/`getAtomOrZero`; all call sites route through it (wire-backed). No parallel cache found. |
| `utils.Rect` single-sourced | Used by tiling modules, `window/modules/fullscreen.zig:352`, `dev/plugin-template/layout.zig:44`, test helpers. No competing rect type. |
| Color hex parsing single-sourced | One real hex parser (`parser.parseColor`, `parser.zig:365/500/774`), covered by `parser_test.zig`. |
| Refresh consumers are *only* bar+toggle title | `refresh.ensureRefreshRateDetected` called only at `bar/bar.zig:1143` and `bar/modules/title/title.zig:163`; `detectedHz(conn)` consumed only at `title.zig:487` (carousel). |

---

## 2. The dominant finding: switchboards, not seams

The defining property of this codebase's cross-subsystem surface is that **optionality is enforced by hand-maintained switchboards**, not by structure. Adding/removing one optional subsystem requires coordinated edits in ~5 independent places:

1. Discovery tables in `build.zig` (`optional_modules`, `sub_registry_specs`, `empty_owner_defaults`) — `build.zig:430–760`.
2. Test-gate rows — `build.zig:248–280`.
3. `check-modularity.sh` scenarios.
4. `build.zig.zon` deps + `SystemLibraries` (see §3).
5. Reserved-name machinery — `build.zig:361`.

Each of these is *correct today* (the 270-test suite compiles all 8 allowed slice combinations), but they are five separate vectors of truth that a future contributor must walk in lockstep. The segmentation verification test (`build.zig ~395`) enforces that all three discovery tables stay in sync with each other — good — but it cannot see the test-gate table, the modularity script, or the `.zon` deps.

**Verdict**: worth one comment-block in `build.zig` pointing at all five surfaces (present at `build.zig:361` for reserved names only, not at the aggregate), not worth a meta-framework to derive them. LOW priority.

---

## 3. `SystemLibraries` / `.zon` mirror — confirmed concrete gap (the one easy win)

`build.zig:1553–1592` defines `SystemLibraries` with a `comptime` block comparing:
- `zon_links` — a *hardcoded in-build.zig* array (line 1576), and
- `linked_libs` — also *hardcoded in build.zig*.

The check therefore compares the table to itself and can never catch drift against `build.zig.zon`'s real `.links` table (the third copy), which the comptime block never reads. `IMPROVEMENTS.md:346` already records this as OPEN. The easy fix is to `readFileAlloc`/parse `build.zig.zon` at configure time (`b.build_root.handle.readFileAlloc` is already used 4× in build.zig) instead of hardcoding `zon_links`. HIGH value per unit of risk; self-contained; no purity impact.

---

## 4. Cross-system interplay findings

### 4.1 Event loop: mandatory core service registered unconditionally, optional consumer gated

`events.zig` registers RasdRandR/inputs unconditionally:
- `src/core/events.zig:144–146` `isRandrEvent`, dispatched at `:163`.
- `src/core/events.zig:643` `refresh.runPendingRedetect(cs.conn)` runs every loop iteration regardless of `has_bar`.
- `src/core/events.zig:410–411` mapping/randr raw-compare before mask (gated with documented rationale).

Meanwhile every *consumer* of that pipeline lives in the bar: `bar.zig:1143` (`ensureRefreshRateDetected`) and `title.zig:163/487`. In a bar-less build (which the 270-test matrix *does* compile), the entire RandR detect/redetect/notify machinery stays alive with zero consumers — pure cost, plus the RandR event subscription. The pattern is "mandatory core register, optional consumer", and is the clearest object lesson in *why* optionality-by-deletion has runtime deadness as its tax. LOW severity (bar-less builds are exotic), but exactly the kind of interplay the mandate asks for. Mitigation would be PURE gate: skip the RandR subscription when `!has_bar` (no module import required — `events.zig` already checks `build_options` via `cs.has_bar` elsewhere).

### 4.2 Time does not exist without a bar

`events.run` deadlock-duty is delegated to the bar: `pollTimeoutMs`/`onPollWakeup` are supplied by `bar.zig` only. Without `has_bar`, the loop blocks on `poll(-1)` and wakes only on X events and the self-pipe signal wake (`signals.zig` atomic bitmap + wake token). Deleting the clock/carousel/prompt segments removes their deadline sources (another confirmed intended consequence). This is a coherent design but a *global, undocumented* property: the WM's notion of time is a bar feature. Worth one comment at the `poll_timeout_ms` computation in `events.run`. LOW.

### 4.3 Grab/ungrab: two disciplines, four copy-sites, comment-carried pairing

Server-grab sites confirmed in the current tree:
- `src/window/pipeline.zig:194,219,231,260` — the sync-boundary grabs (pair: sync.step transition).
- `src/bar/bar.zig:1300,1503` — bar's *own second discipline*: grabs server, calls `pipeline.reconcileNow()` (the no-grab variant), then ungrab+flush (applyVisibility ~1503–1524, toggleBarSegmentAnchor ~1324).
- `src/window/actions.zig:870` — flip workspace grab.
- `src/core/sync/sink.zig:~148` — unify grab.

They correctly do NOT nest (bar uses the no-grab reconcile variant, `sync/` allows bar/visibility per the allowlist). The pairing "grab → … → ungrabAndFlush" is comment-carried and duplicated textually; plan item D3 (`withServerGrab` helper) remains open. The four pipeline grabs could collapse to that helper; the bar grabs are intentionally separate (second discipline) and fine as-is. MEDIUM–LOW.

### 4.4 Workspace-tag arithmetic: two spellings of one concept

- `src/model/model.zig:18` `bit(WSId)` — the pure canonical unguarded bit.
- `src/window/tracking.zig:~155` `workspaceBit` — a guard-bearing facade (rejects ≥64) layering over it.

Both route through the same model math; the only difference is the guard. Currently consistent, but they read as two independent APIs. Cheap reconciliation: keep `model.bit` canonical, have `tracking.workspaceBit` be an explicitly-documented guarded facade (or fold the guard at its 2–3 call sites and delete it). LOW.

### 4.5 Restart/persist: ordering is enforced by prose, not structure

- `restart.zig` + `main.zig` `HANA_RESTORE`: adoption happens *after* surfaces init because `bar.winId` is the anchor (`main.zig` ordering comments ~81–99); version-gated (`loadToGlobal` rejects non-4). Verified coherent and comment-documented — the ordering constraints are load-bearing prose with no compile enforcement, which is acceptable for a 195-line `main.zig`.
- Reload interplay: `input.buildKeybinds` runs *unconditionally* pre-swap; `keysChanged` only gates the regrab, not the resolver rebuild — this is deliberate (action pointers must point into the new config; resolver *const pointers rebuilt before swap = safe borrow). Interplay is correct; latent hazard if a future editor "optimizes" by gating the rebuild on `keysChanged`.
- `persist.save` = full `std.json` stringify to RAM; streaming suggestion (audit #9) still open. LOW.

### 4.6 `build.zig` line-scanning hinterland

Confirmed at :613 (tiling seam), :770–771/783 (`declaresBinding`, `readFileAlloc` + skips `//` comment lines), plus `deriveOwnerContract` and `importEdgesOf` needle-scans (which succeed but don't skip doc comments or string literals — a doc comment mentioning `module:` or an `@import("…")` could produce a false owner/edge; today harmless because the inject-all pass adds everything anyway). The four separate `readFileAlloc` calls (392, 619, 771, 1383) are parallel but distinct scans; consolidating is nice-to-have, not required.

### 4.7 Verified-not-dead (speculative work that is actually used)

- `signals.zig` self-pipe + atomic bitmap: wired into `events.run` wake path (verified drains before consume ordering).
- `visibility_test` / `borders_test` are `x_gated` in the `test_gates` table though the tests themselves are pure — i.e., guards are *more* conservative than the code; acceptable, not a false-modularity.

---

## 5. Top-10 ranked follow-up list

| # | Item | File:line | Difficulty | Value |
|---|---|---|---|---|
| 1 | `.zon` links read from the real file in `comptime` (kill the self-comparison) | `build.zig:1553–1592` | LOW | HIGH |
| 2 | `withServerGrab` helper for the 4 pipeline grabs (D3) | `pipeline.zig:194–260` | LOW | MED |
| 3 | Gate RandR subscription + redetect on `has_bar` | `events.zig:144,163,643` | LOW | MED |
| 4 | Single "the 5 switchboard surfaces" comment block | `build.zig:~360` | TRIVIAL | MED |
| 5 | Fold `tracking.workspaceBit` into `model.bit` (annotated facade) | `tracking.zig:155` | LOW | LOW |
| 6 | Comment "time is a bar feature" at `poll_timeout_ms` | `events.zig` run() | TRIVIAL | LOW |
| 7 | Comment on `keysChanged`-rebuild coupling (do-not-gate warning) | `events.zig` reload | TRIVIAL | LOW |
| 8 | Stream `persist.save` (audit #9) | `persist.zig:221` | MED | LOW |
| 9 | Consolidate 4× `readFileAlloc` scans in build.zig | `build.zig:392,619,771,1383` | MED | LOW |
| 10 | `deriveOwnerContract`/`importEdgesOf` resilient scan (skip strings/docs) | `build.zig` | MED | LOW |

---

## 6. Constraint check

- Sync boundary: untouched by all proposals (bar's second grab discipline is allowlisted; D3 helper lives inside pipeline next to the existing grabs). ✔
- Purity: RandR gating uses `build_options` already present in `events.zig`; no new core→module import. ✔
- Modularity-by-deletion: preserved throughout; deadness findings (4.1, 4.2) are flagged as the *cost of deletion*, not bugs. ✔
- fmt/lint: no code changes in this audit; all proposals are edits-that-must-passes-`check-layers.sh` once applied. ✔