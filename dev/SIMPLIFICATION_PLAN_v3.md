# hana — Simplification Task List v3 (third audit campaign)

Date: 2026-09-20. Method: one analysis agent deployed per `src/` subsystem (`bar`,
`config`, `core`, `input`, `model`, `tiling`, `window`) plus a whole-codebase
interconnection agent. Every finding below was verified against the live tree with
`rg` + full-file reads before being listed; every "already applied" item from the
v1/v2 campaigns was re-verified as live before being excluded.

Baseline (this campaign's start): `zig fmt --check .` clean, `zig build check` exit 0
(layer rules + plugin-template), 16,553 code LOC (`tokei src -f -s code --exclude
src/test/`).

Mandate (unchanged from v1/v2): reduce LOC while preserving identical behavior, or
improve human readability. Risk and effort are not a constraint; the resulting
codebase must be the best achievable. Inviolable: the sync boundary (raw wire sends
stay behind `src/core/sync/` + `dev/scripts/check-layers.sh` allowlist), pure
`model`/`tiling`/`config` layers (xcb-free), the core never names an optional module
(deletion-modularity), no TODO/FIXME, `zig fmt` clean.

## Evaluation axes (every file was assessed on all of these)

1. DEAD CODE — unused exports, params, fields, imports, arms, branches (rg-verified).
2. DUPLICATION — near-identical functions, repeated literals/concepts, parallel arrays of truth.
3. OVER-ENGINEERING — comptime/generic/oops indirection that is net-negative at this scale.
4. READABILITY — bare bools at call sites, huge single functions, dense hot loops, abstruse flow.
5. NAMING — near-identical names for distinct roles, inverted-voice predicates, field-name splits.
6. COMMENT QUALITY — contradictory/stale headers, unresolvable marker codes, drift vs reality.
7. API ERGONOMICS — `!`-typed functions that cannot error, `null`/sentinel overload, dead params.
8. CONSOLIDATION — small files/functions that merge cleanly; single-source-of-truth violations.
9. STRUCTURAL / LAYERING — header truth vs guard script, seam surfaces, switchboards.
10. DOC DRIFT — planning/notes files that no longer match the tree.

## Verification gates (every change)

1. `zig fmt --check .` clean.
2. `zig build check` — exit 0 (runs `check-layers.sh` + plugin-template).
3. `zig build test` — full suite (270 tests; X-gated via `dev/scripts/xtest.sh`).
4. `tokei src -f -s code --exclude src/test/` — LOC delta reported per phase.
5. Plugin-template / modularity matrix where a public plugin-contract signature changes.

---

# A. Findings by subsystem

## A.1 `src/bar/` (BAR)

| ID | Location | Category | Issue | Fix | Est. LOC | Conf. |
|----|----------|----------|-------|-----|----------|-------|
| BAR-1 | bar.zig:1777 | DEAD CODE | `orelse { s.drag_segment = null; return; }` assigns null to a field already null | `const id = s.drag_segment orelse return;` | −3 | H |
| BAR-2 | bar.zig:1761 | READABILITY | `if (s.vis.shown == false) return;` — the only `== false` spelling among 10 `!s.vis.shown` guards | unify to `if (!s.vis.shown) return;` | −1 | M |
| BAR-3 | segdraw.zig:81/137 vs slider.zig:256/347, brightness.zig:367, volume.zig:263, systatus.zig:138 | NAMING | `natural_width` (contract) vs `probe_natural_width` (providers) — same concept, two spellings | uniform naming across providers | 0 | L (deferred, contract-touching) |
| BAR-4 | metrics.zig (44 lines) | OVER-ENGINEERING | `metrics.recompute()` has exactly one caller (bar.zig:142); module is a near-singleton accessor pair | investigate folding `scaled_font_size` into `bar.State` | −25 | L (deferred pending read) |

## A.2 `src/config/` (CONFIG)

| ID | Location | Category | Issue | Fix | Est. LOC | Conf. |
|----|----------|----------|-------|-----|----------|-------|
| CONFIG-1 | parser.zig:299,324 | DEAD CODE | `Document.allocator` written once, never read | delete field + init-literal entry | −2 | H |
| CONFIG-2 | parser.zig:352-354 | DEAD WRAPPER | `paletteColorOf` = `colorFromValue` with 2 internal callers | replace calls, delete wrapper | −4 | H |
| CONFIG-3 | parser.zig:132-134 | DEAD-ISH HELPER | `Section.recordKey` has a single caller (`recordLine`) | inline body (keep `catch {}`) | −3 | H |
| CONFIG-4 | parser.zig:331-333 | DEAD WRAPPER | `Document.get` is a pure alias of `root.get` (2 callers) | delete; call sites → `doc.root.get` | −3 | H |
| CONFIG-5 | parser.zig:267 | DEAD CODE | `typeLabel` `u32` arm unreachable (getAs supports i64/bool/u8/[]u8/[]Value/ScalableValue) | drop arm | −1 | H |
| CONFIG-6 | schema.zig:340 | DEAD CODE | `getInRange` `u32`/`usize` arms never instantiated (only u8/u16 knobs exist) | shrink to `u8, u16` | −1 | M |
| CONFIG-7 | config.zig:63-73,79,1403 | OVER-ENGINEERING | `position: u8` re-encodes `BarSegmentAnchor` as magic 0/1/2 + two `@enumFromInt` casts | type the field as `types.BarSegmentAnchor` | −4 | H |
| CONFIG-8 | config.zig:859-869 | DUPLICATION | `section.markConsumed(entry.key)` at 3 sites per loop | hoist to loop top | −2 | H |
| CONFIG-9 | parser.zig:857,893,929,935 | DUPLICATION | 4 copies of `had_errors=true; warnLine; skipToNewline` | `skipBadLine(self, fmt, args)` helper | −6 | M |
| CONFIG-10 | config.zig:306-318,381 | API/COMMENT | `SearchPaths`/`searchPaths` pub with zero external consumers; stray `\n` in err_msg | de-pub both; drop trailing `\n` | −2 | M |
| CONFIG-11 | config.zig:910,933,1115,1130 | READABILITY | magic bounds `16`, `64`, master-count `10` in two text spots | named consts (`max_master_count`, modifier-buffer size) | 0 | M |
| CONFIG-12 | config.zig:515-529,75,1107-1117,1435-1438; parser.zig:208-212,342-347; schema.zig:90-177 | DUPLICATION | `"tiling.layouts."`, `"workspace.rules."`, `"rules."`, `"bar.colors"`, `"bar.layout."`, `"tiling"` as raw literals in ≤3 files each | hoist section/palette names into `types` consts, reference everywhere | −8 | M (string-sensitive; tests pin) |
| CONFIG-13 | types.zig:414, schema.zig:151, parser.zig:346, config.zig:1589 | DEAD KNOB | `bar.text_color` has zero runtime readers; only role is palette-reference target | keep (palette-canon) or delete — DESIGN DECISION → Deferred | n/a | H |
| CONFIG-14 | config.zig:1574-1657 | OVER-ENGINEERING | three hand-mirrored reload detectors (~60 fields); verified complete today | keep as-is (reflection is net-negative) — Deferred | n/a | H |

## A.3 `src/core/` (CORE)

| ID | Location | Category | Issue | Fix | Est. LOC | Conf. |
|----|----------|----------|-------|-----|----------|-------|
| CORE-1 | events.zig:476-505 + 514-542 | DUPLICATION | two parallel event-drain loops differing only by pull-fn/cap/charge_tail | one comptime-parameterized `drainEvents` (+ delete `takeEvent`) | −25 | H (hot path; suite pins) |
| CORE-2 | sync.zig:1-4, sink.zig:1-2, wire.zig:1-2 | COMMENT | three seam headers contradict each other and the guard script | one shared canonical sentence | −8 | H |
| CORE-3 | x11/masks.zig:30-54 | OVER-ENGINEERING | 20-line comptime `blk:` fold whose own comment admits it equals an explicit table; test pins the literal | replace with the 8-entry explicit table | −11 | H |
| CORE-4 | events.zig:591-598,635 | REDUNDANCY | `bar_deadline_active` smuggles the same bits as `poll_timeout_ms >= 0` | delete flag; `if (ready == 0 and poll_timeout_ms >= 0)` | −4 | H |
| CORE-5 | events.zig:563-566 | READABILITY | 4-field facts gate as hand `or`-chain | `std.meta.eql(facts_before, facts)` | −3 | H |
| CORE-6 | events.zig:277,297,307,365,389,455,478,558; sink.zig:88; spawn.zig:66,125; signals.zig:214; restart.zig:68; scale.zig:83; pipeline.zig:273 | COMMENT | ~16 bare markers `C1…C15`/`P5`/`Gap 2` with no legend anywhere; the prose is complete without the code | strip prefixes, keep prose | 0 | M |
| CORE-7 | utils/utils.zig:71-77 + callers sync.zig:227-230, input.zig:175-178 | DEAD PARAM | `WindowedProfiler` `comptime tag` only used as `_ = tag;`; arg duplicated into fmt literal | drop the param @ both call sites | −5 | H |
| CORE-8 | pipeline.zig:201-224,264-269 | API SURFACE | `reconcileUnderGrabNowWithFocus`/`...WithFocusAfter` are one-line bool-bakers over `reconcileGrabFocus` | delete bakers; 6 call sites call `reconcileGrabFocus(o, t, true/false)` with intent comment | −12 | M |
| CORE-9 | utils/constants.zig:98,103 vs events.zig:105,204-205,249 | COHESION | `event_dispatch_table`/`max_keybind_cookies` used only in events.zig | move into events.zig as file consts | 0 | H |
| CORE-10 | restart.zig:61-80 | ROBUSTNESS | OOM on re-exec copy silently disables re-exec with no log | add `debug.err` in catch arms | +3 | M (deferred? see §C) |

## A.4 `src/input/` (INPUT)

| ID | Location | Category | Issue | Fix | Est. LOC | Conf. |
|----|----------|----------|-------|-----|----------|-------|
| INPUT-1 | keybind.zig:33-41 | DEAD WRAPPER | `KeybindResolver.build` single caller (input.zig:102), chains two pub fns; tests never use it | inline into `input.buildKeybinds`, delete wrapper | −12 | H |
| INPUT-2 | input.zig:61-71 | OVER-ENGINEERING | `keyHeld`/`setKeyHeld`/`clearKeyHeld` one-liners over `held_keys` BitSet | inline `isSet`/`set`/`unset` at 3 sites | −11 | H |
| INPUT-3 | input.zig:342-352 | READABILITY | `sendWmDelete` single caller (closeWindow:371) 11 lines + 4-line doc | fold into `closeWindow` (keep `forceDestroy`) | −8 | M (optional; see §C) |
| INPUT-4 | input.zig:404,406 | DUPLICATION | two f32 sites hand-roll `if (dir == .forward) X else -X` while i32 uses `dirSign` | add `dirSignF` inline fn | ~0 | M |
| INPUT-5 | input.zig:256-263,269-270 | DUPLICATION | `clicked_window`/`super_held` derived twice in `handleButtonPress` | hoist once | −4..−6 | M |
| INPUT-7 | keysyms.zig:16, xkbcommon.zig:10, input.zig:113 | DEAD PUB | `pub const xkb` (2 files, zero readers) + `lookupKeybinding` single caller | make private (`const`) | 0 (−3 keywords) | H |
| INPUT-8 | dev/scripts/check-layers.sh:110-116 | STALE GUARD | xkbcommon.zig allowlist entry documents a flush it no longer trips (0 wire symbols) | drop the case so future wire use fails loudly | 0 | H |
| INPUT-9 | xkbcommon.zig:20 | COHESION | `x11_min_keycode` named but living in xkbcommon, not constants.zig (prior half-finished move) | move to constants.zig; keep health heuristics local | 0 | M |
| INPUT-10 | build.zig:56-101 | INFORMATIONAL | `has_input` does not exist — input is not actually deletable today | documented (no code change); surfaced to user → Deferred |
| INPUT-6 | input.zig:408-409 + types/config schema | SCHEMA | `.move_window_next/.move_window_prev` differ only by sign; merge to `Dir` changes user config verbs | DESIGN DECISION → Deferred | −5 | L |

## A.5 `src/model/` (MODEL)

| ID | Location | Category | Issue | Fix | Est. LOC | Conf. |
|----|----------|----------|-------|-----|----------|-------|
| MODEL-1 | model.zig:507-518 | DEAD CODE / DRIFT | `applyConfigReload` has NO production caller — reload path is `actions.seedParamsFromConfig` (actions.zig:717-783) which re-implements the defaulting; model fn is test-only (v2 counter-claim retracted) | adopt: route `seedParamsFromConfig` through it (kills ~25 duplicated defaulting lines + gives the viewport-preserve invariant a production caller) | −0..−25 | H (dead claim) / M (fix shape) |
| MODEL-2 | tracking.zig:156-159 | DUPLICATION | `tracking.workspaceBit` guarded facade duplicates `model.bit`; guard can never fire (all callers pre-bound) | fold into `model.bit` anymore (tie into WIN-4) | −4 | M |
| MODEL-3 | model.zig:313-319 | DEAD WORK | `unregister` does a `getPtr` probe (2nd binary search) feeding a guard the `remove` return already gives | `if (!m.store.remove(win)) return;` then ws-scan | −2 | M |
| MODEL-4 | model.zig:243-247 | COMMENT | `slotOf` doc references the deleted `storeSlotOf` mirror | rewrite doc; `pub inline fn slotOf` | −2 | H |
| MODEL-5 | model.zig:22-24,273 | DEAD ALIAS | `MAX_WS` used once | inline `constants.max_workspaces` | −1..−3 | L |
| MODEL-6 | model.zig:124,186 | OVER-ENGINEERING | `Store.Error = error{StoreFull}` named once | inline `error{StoreFull}!*V` in `put` | −1 | H |
| MODEL-8 | model.zig:229-233 | COMMENT | `at`/`Iterator` doc overlap | trim to one line | −3 | M |
| MODEL-9 | model.zig:329-333 | READABILITY | `visibleEntry` nested if → single boolean expression | `if (e.presence == .parked) return false; return m.all_view_active or e.mask & bit(ws) != 0;` | −2 | H |
| MODEL-7 | model.zig:332,352 + layers | API | `e.mask & bit(ws) != 0` spelled ~8× | optional `taggedOn` helper | ~−3 net | L (deferred, over-engineering risk) |
| MODEL-10 | — | VERIFIED-NOT-WORTH | `qualifies`, `Iterator`, `Item` and the primitive family are correctly factored | do not fold | — | — |

## A.6 `src/tiling/` (TILING)

| ID | Location | Category | Issue | Fix | Est. LOC | Conf. |
|----|----------|----------|-------|-----|----------|-------|
| TILING-1 | actions.zig:737-749 | DUPLICATION | 3rd copy of layout resolve+warn+fallback (left behind C5's `layoutKindOf` hoist) | `layoutKindFallingBack(name, fallback)` (or fallback param on `layoutKindOf`) | −5 | H |
| TILING-5 | tiling.zig:191-199 + all modules + template | DEAD PARAM | `emitView`'s `visible` bool is always `true` (parked path uses `emitHidden`) | drop the param; collapse `emit`/`emitHidden` pub aliases (TILING-7) | −2 decl, args ×10 | H (M churn; plugin-template gate self-verifies) |
| TILING-2 | fibonacci.zig:45-51 | REDUNDANCY | field-by-field `Region` copy of an `outerArea` result | `var cur = outer;` | −4 | H |
| TILING-6 | tiling.zig:8 | DEAD CODE | unused `build_options` import | delete | −1 | H |
| TILING-3 | leaf.zig:21-22 | REDUNDANCY | `outerArea` → hand-spliced `Region` literal | pass the returned `Region` | −2 | H |
| TILING-4 | fibonacci.zig:56-58 | DEAD BRANCH | `const top = if (last) win else focusedElse(...)` is a tautology | `const top = tiling.focusedElse(v, windows[i..], win);` | −1 | H |
| TILING-8 | grid.zig:57-59 | OVER-ENGINEERING | `widenedLastRowCellWidth` wrapper over `paneCell`, single call | inline | −4 | M |
| TILING-9 | master.zig:191-196 | DEAD CODE | `count > 0 and` guard unreachable (n≥1); `StackBoost`/`fromBalance` pub with no consumers | drop guard + `pub` | −1 | M |
| TILING-10 | tiling.zig:277 | SINGLE-SOURCE | `[256]u8` re-declares the layout cap | size `[model.max_layouts]u8` | 0 | M (deferred: layering) |
| TILING-11 | tiling.zig:201 | COMMENT | cites `pushWindowOffscreenAndInvalidate` (name doesn't exist; sync primitive is `Sink.park`) | reword | 0 | H |

## A.7 `src/window/` (WIN)

| ID | Location | Category | Issue | Fix | Est. LOC | Conf. |
|----|----------|----------|-------|-----|----------|-------|
| WIN-1 | modules/fullscreen.zig:218-223 | DEAD CODE | `fullscreenOccupied` zero callers; doc claims a consumer that uses a different fn | delete fn + shorten doc | −7 | H |
| WIN-2 | borders.zig:28-42,62 | DEAD PARAM | `coveredByOccupant`'s `is_covering` axis: prod hardcodes false; only borders_pure_test uses true | drop param (fold build dispatch); rewrite test | −8 | H |
| WIN-3 | window.zig:1373-1395 | ALGORITHMIC | per-sweep O(F·S) covering scan for border colors | occupant table once per sweep (O(S) → O(1) lookups) | +12..+18 | M (perf; NOT a LOC cut — deferred) |
| WIN-4 | tracking.zig:125,126,157,164 | SINGLE-SOURCE | three literal `64`s duplicate `constants.max_workspaces` (already imported) | replace with the constant; keep `>=` guard | −3 | H |
| WIN-5 | model.zig:362-370 vs modules/fullscreen.zig:195-216 | DOC GAP | model OR-semantics vs module AND-semantics occupant queries undifferentiated | cross-reference doc comments at both definitions (no behavior change) | +10..+14 | M (comments) |
| WIN-6 | window.zig:176-178 | DEAD CODE | `window.getState` zero callers (State is private anyway) | delete + fix deinit comment | −3 | H |
| WIN-7 | floating.zig:28,33,37; actions.zig SeedOverrides/seedLookups; tracking.zig:171; minimize:count; workspaces:switchTo | DORMANT PUB | 5+ exports consumed only in-file or in tests | de-pub; annotate `count`/`switchTo` test-only | −6 | H |
| WIN-8 | icccm.zig:291 | COMMENT | cites removed `queryWMProtocolsPropsConsume` | rewrite to describe live cookie path | −1 | H |
| WIN-9 | window.zig:1373,1398,1406; icccm.zig:58/308/326 | READABILITY | bare bools (`sweepWorkspaceBorders(.false/.true)`, `icccm.reset(true/false)`) | enum params or collapse wrappers | ≤+6 | M (deferred if lines vs clarity trade) |
| WIN-10 | borders.zig:16-20 vs 46-64 | NAMING | `borderColorOf` (pure picker) vs `color()` (stateful resolver) near-identical names | rename `color()` → `resolveBorderColor`; drop redundant 2nd `store.get` | ~0 | M |

## A.8 Cross-cutting (CC)

| ID | Location | Category | Issue | Fix | Est. LOC | Conf. |
|----|----------|----------|-------|-----|----------|-------|
| CC-1 | plugin.zig Surfaces / bar.zig:1644-1675 / events.zig:651-652 | DEAD RETURN | `Surfaces.updateClock` returns `bool`; sole caller discards it (`_ =`) | narrow contract to `void`; rewrite arms | −3 | H |
| CC-2 | plugin.zig Surfaces ~53-58 / bar.zig:1683-1688 / events.zig:74-78 | DEAD SLOT | `Surfaces.handlePropertyNotify` is a mandated no-op forwarded per-event for nothing | make the hook `?*const fn… = null`, skip forward when null | −1..−3 | M (nullable vs drop → Deferred choice) |
| CC-3 | build.zig:1424-1471 + check-layers.sh Rule 3 | DOC | the two pure-layer guards are complementary (import-edge scan vs text sweep) but the why is undocumented | cross-reference comments both sides; note Rule 3 is the sole body/reference guard | 0 | H |
| CC-4 | IMPROVEMENTS.md | DOC DRIFT | 3 OPEN rows already resolved in-tree (`.zon` mirror, sync.st pub, inline-@import count) | triage the OPEN list against the tree | 0 | H |
| CC-5 | tracking.zig:143,156,173 vs model.zig:18-20 | DUPLICATION | = MODEL-2/WIN-4 (workspaceBit + 64 literals) — tracked there | — | — | — |
| CC-6 | check-layers.sh Rules 1-2 | STRUCTURE | per-file allowlists grow silently; `src/bar/**` may be the real rule now | consider regex scoping — Deferred (guard script decision) | 0 | L |
| CC-7 | dev/scripts/check-layers.sh, build.zig test_gates, check-modularity.sh | SWITCHBOARD | optionality vector, add/remove-module walk stays manual (5 surfaces) | add one comment block pointing at all five surfaces | 0 | M |

---

# B. Ranked implementation order

**Phase 1 — zero-risk deletions, dead-param cuts, comment/header hygiene (no semantic risk):**
CONFIG-1..CONFIG-8, CONFIG-10, CONFIG-11; CORE-2..CORE-7, CORE-9; INPUT-1, INPUT-2,
INPUT-4, INPUT-5, INPUT-7, INPUT-8, INPUT-9; MODEL-3, MODEL-4, MODEL-5, MODEL-6,
MODEL-8, MODEL-9; TILING-2, TILING-3, TILING-4, TILING-6, TILING-8, TILING-9,
TILING-11; WIN-1, WIN-6, WIN-7, WIN-8, WIN-10; BAR-1, BAR-2; CC-1, CC-3, CC-4.

**Phase 2 — consolidation (behavior-preserving, suite + plugin-template pinned):**
TILING-1 (resolve straggler), TILING-5+TILING-7 (emit signature), MODEL-2+WIN-4
(workspaceBit/64 single-source), MODEL-1 (adopt applyConfigReload), CORE-8 (focus
bakers), CORE-1 (drain-loop merge), CONFIG-12 (section-name consts), CC-2 (nullable
PropertyNotify slot), WIN-2 (coveredByOccupant param).

**Phase 3 — documentation & decisions:**
WIN-5 (occupant-semantics comments), CORE-6 marker-code prose, BAR-4 investigation,
the deferred questions below.

---

# C. Deferred items & questions (dedicated section — please decide)

1. **MODEL-1 shape** — adopt (`seedParamsFromConfig` routed through
   `applyConfigReload`, −~25 in actions, gives the viewport invariant a production
   caller) vs delete (−13). Implemented as the adoption; if the per-workspace
   override ordering regresses the suite, fall back to delete.
2. **CONFIG-13** — `bar.text_color` knob has zero runtime readers; its only live role
   is palette-reference target. Delete the field+knob, or keep as documented
   palette-canon?
3. **CONFIG-14** — the three reload detectors stay hand-mirrored (verified complete);
   reflection-based derivation is net-negative. Keep.
4. **INPUT-6** — merge `.move_window_next/.move_window_prev` into an action taking
   `Dir`? Changes user-facing config verbs and schema tests; belongs to a
   config-schema decision.
5. **INPUT-10** — input is not actually deletable (no `has_input` build option),
   despite input being described as optional. Add a `has_input` deletion scenario, or
   document input as always-built?
6. **CORE-10** — add OOM diagnostics to restart re-exec path (+3 LOC, robustness);
   in tension with the "reduce lines" bar.
7. **BAR-3** — `natural_width` vs `probe_natural_width` naming split is real but
   touches the public segment contract; uniform-naming PR wanted?
8. **BAR-4 / metrics.zig** — fold into `bar.State` (−~25) or keep the 44-line module?
   (Read before deciding.)
9. **CC-2** — nullable `Surfaces.handlePropertyNotify` hook (keep future bar-side
   extension point) vs fully drop the slot (window layer already handles PropertyNotify)?
10. **CC-6** — check-layers.sh per-file allowlists vs `src/bar/**` / `src/window/**`
    scoping; filename-as-policy-key rename hazards.
11. **WIN-3** — O(N²)→O(N) border-sweep covering cache PRICE is +12..+18 LOC (a perf
   fix disguised as a law of the audit's "algorithmic" axis). Proceed, or leave the
   sweep as-is?
12. **WIN-9** — bare-bool → enum refactor for `sweepWorkspaceBorders`/`icccm.reset`
    costs lines for clarity; worth it?
13. **WIN-7** — `minimize.count()`/`workspaces.switchTo` test-only seams: annotate in
    place (recommended) vs delete vs gate on `build.test`?
14. **MODEL-7** — add `taggedOn(e, ws)` helper to kill the repeated mask idiom, or
    keep the explicit spellin g?
15. **TILING-10** — bind `cycleKind`'s `[256]u8` to `model.max_layouts` (couples
    model↔tiling) or keep the independent config-side cap?
16. **INPUT-3** — fold `sendWmDelete` into `closeWindow` (−8) or keep the documented
    micro-helper (project style prefers these)?
17. **CC-4 / IMPROVEMENTS.md** — triage the OPEN list against the tree so it steers
    instead of misdirecting; do it as a docs pass?
18. **MODEL-5** — drop `MAX_WS` alias (inline the constant) or keep for readability?
19. **sync boundary & purity** — nothing in this plan crosses them; any proposal that
    would have is included here first.
20. **Deletion-modularity post-check** — after all changes, re-run the ~25-build
    modularity matrix (`dev/scripts/check-modularity.sh`) to confirm no accidental
    import coupling was introduced.

## Execution status (2026-09-20, this pass)

(To be filled in as each phase lands, with `zig fmt` / `zig build check` / `zig build
test` results and the tokei delta.)