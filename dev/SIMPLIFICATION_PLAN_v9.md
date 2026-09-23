# hana — Simplification Task List v9 (seventh audit campaign — full-codebase)

Date: 2026-09-23. This plan consolidates the findings of one whole-codebase
interconnected agent plus one agent per `src/` subsystem (config, core, window,
bar core, bar modules, tiling, input, model+entrypoint). Every finding was
verified against the live tree by the responsible agent (full-file reads + `rg`
call-site inventories). Prior campaigns (v1..v6) were honored: items marked DONE
there are not re-filed, but each "claimed fixed" pattern was re-verified against
current source and any regression is flagged below as HIGH.

## Evaluation axes (every finding assessed on all of these)

1. **LoC reduction** — does the change remove lines while keeping behavior identical?
2. **Readability** — does the change make intent easier to hold for a future dev?
3. **Single-sourcing** — does it collapse N hand-maintained spellings of one concept?
4. **Deletion-modularity** — does it respect the "files/modules are deletable addons" ideology?
5. **Safety** — zero behavioral drift; layer rules (check-layers.sh) and plugin seams preserved.

## Verification gates (every change batch)

- `zig fmt --check .` clean
- `zig build check` green (incl. `check-layers.sh`)
- `zig build test` exit 0

---

# A. Findings by subsystem

Estimated total green-light LoC deltas are reported per subsystem. "Green-light"
= semantics-preserving, mechanically verifiable. "Deferred" items live in §C.

## A.1 `src/config/` (CFG — 12 findings, ≈ −33 LoC)

### [CFG-01] HIGH/High — parser.zig:366-410: weight-token grammar parsed three times
The `(weight:N%)` marker grammar is redundantly implemented in `isWeightToken`/
`weightFromToken`/`splitWeightPrefix`. One core `parseWeightPrefix(raw) ?struct{weight, rest}`;
re-express the three wrappers on top. `isWeightToken`/`weightFromToken` stay `pub`
(parser_test pins them). **−13**

### [CFG-09] HIGH/High — schema.zig:699-791 (6 sites): dupe-key + `errdefer` + `put` block repeated 6×
Extract `putSegmentEntry(comptime V, allocator, map, seg_key, value) !void`; each site
becomes one call. **−8**

### [CFG-02] MED/High — parser.zig:856-875: `skipWhitespace`/`skipWhitespaceAndNewlines` twin loops
One `inline fn skipInline(comptime newlines: bool)`; wrappers kept as `inline fn`. **−4**

### [CFG-05] LOW/High — config.zig:44-46: `parseWsToken` one-expression wrapper (2 callers)
Inline `std.fmt.parseInt(usize, tok, 10) catch null` at both call sites, delete fn. **−3**

### [CFG-10] MED/High — schema.zig:513-518: place-probe loop re-checks `hit == null`
Use `break` on the `inline for` (supported) instead of the guard. **−2**

### [CFG-04] LOW/High — config.zig:120-134: `readFileAlloc` doc 15 lines for a 40-line fn
Shrink to ~4 lines (signature contract + pointer to body comments). **0 (docs)**

### [CFG-08] LOW/High — config.zig:1807-1823: 17-line rationale header ahead of barChanged/tilingChanged
Compress to ~6 lines; drop historical-consolidation paragraph. **0 (docs)**

### [CFG-07] MED/High — config.zig:152: redundant `stat != null` conjunct
When `stat` is null, `known_size` is already 0; drop the conjunct. **−1**

### [CFG-11] MED/High — schema.zig:350-352: `bool`/`[]const u8` arms identical in shape
Merge into `bool, []const u8 => section.getAsOrWarn(T, key) orelse return default,`. **−1**

### [CFG-13] LOW/High — parser.zig:452-520: `extractMixOperands` repeats cap-check+store+increment 3×
`pushMixOperand(out, count, color, weight) bool`; each branch becomes one call. **−1**

### [CFG-03] LOW/High — parser.zig:298/108: magic reserve capacities 8/4
Name the constants with a one-line rationale. **0**

### [CFG-06] LOW/High — config.zig:418: `snapshotDirPath` pub with zero external consumers
`pub fn` → `fn`. **0**

## A.2 `src/core/` (CORE — 13 findings, ≈ −40..−47 LoC)

### [CORE-01] HIGH/Verified — events.zig:89-97, contract.zig:78: dead `Surfaces.handlePropertyNotify` forward
v6 EVS-01 claimed DONE; still present. Zero binders tree-wide. Delete the contract field + doc
and the always-null forward branch. **−7**

### [CORE-02] HIGH/Verified (diff-proven) — sync.zig:322-334: winner-seed if-chain re-nested to 4 deep
C-11 claimed the flatten; `dbc9f1e` proves it was applied then re-nested by the C-12
`on_current` commit. Reintroduce guard-clause form preserving `on_current`. **−5**

### [CORE-03] MED/Verified — sync.zig:130+527 vs pipeline.zig:135: `Ctx.cfg_bw` mirrors `env.margins.border`
Drop `cfg_bw`; read `ctx.env.margins.border` (or thread via ReconcileOpts). Requires owner
confirmation of the sync-config seam ([Q2] §C.2). **−3**

### [CORE-04] MED/Verified — sync.zig:226-236 vs pipeline.zig:180-185: two grab-bracket idioms
Fold `sync.reconcileUnderGrab` into `pipeline.withServerGrab`; retile profiler moves with it
([Q5] §C.2). **−4**

### [CORE-05] MED/Verified — pipeline.zig:147-150 duplicates borders.zig:17: border pixel pick
Single owner (core `colorOf`, already the sync-seam callback); borders delegates. **−4**

### [CORE-06] LOW/Verified — spawn.zig:115-123 vs 279-287: `[:0]` cmd resolution duplicated verbatim
One `resolveCmdZ(alloc, cmd, buf) ![:0]const u8`. **−6**

### [CORE-07] LOW/Verified — contract.zig:19-35 vs 135-146: serialize/deserialize seam prose duplicated
Keep header, reduce field docs to one line each ("see header"). **−10 (docs)**

### [CORE-08] LOW/Verified — events.zig:185: redundant `build_options.has_bar and` conjunct
`isRandrEvent` already returns false when `!has_bar`; drop outer conjunct + 2 comment lines. **−2**

### [CORE-09] LOW/Verified — spawn.zig:41-42 vs 71-72: `tag_failed` child tail duplicated
Shared `failWithTag(pipe_write) noreturn`. **−3**

### [CORE-10] LOW/Verified — scale.zig:95: `screen.*.root` redundant deref
`screen.root`. **0**

### [CORE-11] LOW/Verified — signals.zig:244: `dispatchSignal(byte)` param is a bitmap bit index
Rename param + reword doc. **0**

### [CORE-12] LOW/Verified — pipeline.zig:88-89: `sink()` name collides with type + method
Rename accessor `syncSink()`. **0**

### [CORE-13] INFO/Verified — `src/core/.events.zig.swp`, `src/core/.pipeline.zig.swp`
Delete both vim swap files (v6 claim stale). **−2 files**

## A.3 `src/window/` (WIN — 10 findings, ≈ −22..−34 LoC)

### [WIN01] M/H — fullscreen.zig:159-163: `fullscreenOccupantOnWs` near-duplicate of `model.coveringOccupantOnWs`
Module should delegate (thin binder) or drop the copy; `model.coveringOccupantOnWs` is the
single occupant query. Dries WIN10 too. **−8..−12**

### [WIN02] M/H — minimize.zig:135,175 + floating.zig:160 vs window.zig:75: `isCoveringMode` routed two ways
Use `window.isCoveringMode(m, win)` (the dispatcher) at those three sites. **−4..−6**

### [WIN03] M/H — actions.zig:39-41: `currentCoveringOccupant` one-call shim
Replace 3 calls with `model.coveringOccupantOnWs(m, m.current)` inline; delete helper. **−5..−7**

### [WIN04] M/M — actions.zig:91-96: `RetileOpts` duplicated against window.zig retile surface
Single `RetileOpts` type, one owner, re-exported. **−5..−8**

### [WIN05] M/H — window.zig:88-94: SizeHints `p_*` flag constants duplicated vs wincache/icccm
Keep the set in the WM_SIZE_HINTS/ICCCM owner (icccm.zig already owns `wm_hints_long_length`);
window.zig imports them; drop redundant re-export. **−6**

### [WIN06] L/M — borders.zig:17,56: `borderColorOf` 1-caller trivial ternary
Inline at the single call site; or keep only if the pure-seam isolation is wanted (owner call,
see [Q1] §C.2). **−1..−4**

### [WIN07] L/M — window.zig:988-1014/1399-1402: `warnOnce` 8-slot u3 mask, 2 bits used
Two plain bools; drop the inline fn + mask. **−3..−4**

### [WIN08] L/H — informational: the only 64s in window/ are named capacities
No workspace-cap literal in window/. No action. **0**

### [WIN09] L/H — informational: `providerOf` is the ONLY foreign-module binding, correctly localized
Do not deduplicate the seam. **0**

### [WIN10] L/M — fullscreen.zig:93-116 + minimize.zig:133-136: coveringMode recompute loops
With WIN01+WIN02 landed, both modules call the shared dispatcher. Count within WIN01. **−6..−10**

## A.4 `src/bar/` core+drawing (BAR — 15 findings, ≈ −65..−75 LoC)

### [BAR02] HIGH/MED — bar.zig:1716-1725: `updateClock` hand-rolls `callFirstTrue` fan-out
Replace with `if (!anyBoolHook(.secondsElapsed, .{fmt})) return;`. **−8**

### [BAR14] MED/MED — drawing.zig:763/791-833: `drawPaddedSegmentValue`/`paintedSegment` reimplement fill+baseline+draw
Extend `paintedSegment` with the value-partition; keep two pub thin adapters. Requires markup
confirmation [Q2] §C.1. **−10..−16**

### [BAR03] MED/HIGH — bar.zig:83-107: triplicated comptime empty-registry guard
One `hasRegisteredSegments()`; `if (comptime !hasRegisteredSegments()) unreachable;`. **−6..−9**

### [BAR13] HIGH/HIGH — drawing.zig:775-790: duplicated 8-line doc block
Delete the duplicate. **−8**

### [BAR04] HIGH/HIGH — bar.zig:674: `markAllSegmentsDirty` single-caller wrapper
Inline into `markDirty`. **−4**

### [BAR05] MED/HIGH — bar.zig:702-725: `hasPendingRepaintWork`/`hasLayoutSegmentDirty` duplicate the scan
`anyLayoutSegment(self, comptime pred)`. **−5..−6**

### [BAR11] LOW/HIGH — bar.zig:1333: `minimizedApiFromRegistry` one-use wrapper
Inline into `fillDrawCtx`. **−4..−5**

### [BAR06] MED/HIGH — bar.zig:113-127: `isRole`/`selfTickerIndex` duplicate registry-id search
One `roleIndexOf`; `isRole` returns `!= null`. **−4..−5**

### [BAR12] LOW/MED — bar.zig:462-466: `Clock.segs` block-init from comptime blk
`@splat(.{})` if Zig 0.16 accepts struct-valued splat ([Q1] §C.1). **−4**

### [BAR01] LOW/HIGH — bar.zig:230-233: `onPollWakeup` double-consumes redraw request
Delete `s.consumeRedrawRequest();` in `onPollWakeup`; `performDraw` is authoritative. **−2**

### [BAR07] LOW/HIGH — bar.zig:864-871: duplicated missing-segment warn/return blocks
Small `drewNothing()` helper or single resolve step. **−3**

### [BAR08] LOW/HIGH — bar.zig:1672-1679: reads 3 core fact revs twice
Hoist into consts. **~0**

### [BAR09] MED/HIGH — bar.zig:952: `extendDirtySpan` re-extends a span covered by `clearRegion`
Delete the call (mirror the left side). **−1**

### [BAR10] MED/MED — bar.zig:761: dead zero-ticker guard in `recordSelfTickerScope`
Drop the `self_ticking_ids.len == 0` guard. **−2..−3**

### [BAR15] LOW/HIGH — visibility.zig:62-64: `keepPromptOverride` restates the natural-visibility tail
Extract `naturalVisibility(ws, is_globally_visible)`. **−2..−3**

## A.5 `src/bar/` modules (v8 — 14 numbered findings, ≈ −48 LoC)

### [SY-01] H — systatus cpu/mem/batt: open+read stanza repeated 3×
Add `systatus.readSmallFile(path, buf) ?usize`. **−7**

### [S-02] M — brightness.zig:114-124 + native_alsa.zig:137-151: pct↔range maps implemented twice
Shared slider-core helper with comptime `nearest_rounding: bool` (rounding policy is a ruling
item, [Q3] §C.1 — helper supports both modes). **−6**

### [P-02] MH — prompt.zig:357-362: `copyToZ` single-caller
Inline at `loadCompletions`. **−5**

### [P-03] MH — prompt.zig:1032-1042 vs 1084-1099: visibility-clip duplicated
Shared `clipSpan(tl, se, px, w)`. **−4**

### [P-04] MH — prompt.zig:603-608: `resetPromptEditing` single caller
Inline into `activate`. **−4**

### [SY-02] M — cpu.zig:39-53: baseline/delta duplicate state-write + clamp
Single tail. **−4**

### [S-01] H — slider.zig:94-130: Throttle write tail ×3
Private `land(self, pct, write)`. **−3**

### [CL-01] H — clock.zig:101-103: `stale()` single caller
Inline into `secondElapsed`. **−3**

### [TG-01] H — tags.zig:41-43: `getCachedWorkspaceWidth` trivial getter
Use `ws_width` directly at the 2 sites. **−3**

### [TG-02] M — tags.zig:93-116: `[2]f32` + index consts → 2-field struct. **−3**

### [T-01] M — title.zig:250-252/268: duplicated ellipsis arm
Single ellipsis tail after the scroll branch. **−3**

### [P-06] H — vim.zig:359-362: `resolveCount` single-use wrapper
Inline. **−2**

### [P-05] H — prompt.zig:819-821+944-948: drun history path literal twice
Hoist `drun_history_suffix` const. **−1**

### [P-01] H — prompt.zig:505: magic `& 0x7F` → `masks.synthetic_event_mask`. **0**

## A.6 `src/tiling/` (TIL — 12 findings, ≈ −5..−6 real LoC + hygiene)

### [TIL-N3] High/High — fibonacci.zig:72: `splitAndAdvance` `gap` param duplicates `ctx.m.gap`
Drop the param; read `ctx.m.gap` in the 5 bodies. **−2**

### [TIL-N5] High/High — leaf.zig:41-47: dangling spliced comment (v5 NEW-16 still present)
Cut the `(split_y/split_x…)` parenthetical; keep one coherent contrast sentence. **−3**

### [TIL-N11] Low/High — grid.zig:59-64: `calcGridShape` one-use anon-struct wrapper
Fold into `compute` (optional). **−2..−4**

### [TIL-N1] Med-High/High — master.zig:266: last manual `2 *| ctx.m.border` → `utils.doubledBorder(ctx.m)`. **0**

### [TIL-N2] Med/High — fibonacci.zig:43,56 vs 75: `border2` computed twice; gate = `tiling.totalInset`
Single compute / reuse totalInset (saturation corner signed off in [Q3] §C.2). **−0..−1**

### [TIL-N4] Med/High — leaf.zig:28,32: `border2` per recursion node, used only in terminal branch
Move into the `if (n == 1)` branch. **0**

### [TIL-N6] Med/Medium — tiling.zig:182-184: `paneCell` single-owner (grid)
Move into grid.zig as private (deletion-modularity; [Q5] §C.2 owner call). **0 net**

### [TIL-N7] Med/High — tiling.zig:129-131: `satI16` pub with stale doc
De-pub + reword. **0**

### [TIL-N8] Med/High — master.zig:311-314: `calcAvailableHeight` re-derives rowPitch arithmetic
`m.gap +| count *| rowPitch(m)`. **0**

### [TIL-N9] Med/Medium — tiling.zig:292: `[256]u8` re-declares `model.max_layouts`
`[model.max_layouts]u8`. **0**

### [TIL-N10] Low-Med — grid.zig:8, monocle.zig:8: variant-index consts unenforced
Optional comptime assert. **0..+2**

## A.7 `src/input/` (IN — 11 findings, ≈ −28..−37 LoC)

### [IN01] M/H — input.zig:313-327: `closeWindow` repeats the destroy fallback 3×
Guarded `blk:` graceful path + single trailing destroy. **−3..−4**

### [IN02] LM/H — input.zig:354-360: `executeSequenceStep` one-use wrapper
Inline into the `.sequence` arm. **−4**

### [IN10] M/M — xkbcommon.zig:252-279: two full `baseSymbol` walks per keymap load
Fold the health count into `buildKeysymTable`; delete `keymapHasEnoughSymbols`. **−5..−8**

### [IN08] M/M — xkbcommon.zig:96,183,212,233,254,264: identity casts + inconsistent loop spellings
Drop `@as(usize,…)`, iterate u8-bare. (Build-verify before landing, [Q] §C.2.) **−4..−5**

### [IN03] M/M — xkbcommon.zig:129-131 vs 150-151: init/rebuild duplicate device+keymap acquisition
Shared `loadKeymap` (rebuild acquires retry; cold-path strengthening — owner sign-off, [Q] §C.2). **−1..−3**

### [IN04] L/M — input.zig:38-41: unanchored floating comment block
Delete. **−4**

### [IN05] L/H — input.zig:96-99 vs 106-110: `handleMappingNotify` doc restated inline
Collapse to one line. **−3..−4**

### [IN06] L/M — keysyms.zig:27,34: redundant `@ptrCast`
Pass bare ptrs (build-verify, [Q] §C.2). **−2**

### [IN07] L/M — keybind.zig:38-47: `contains` then `put` double-hash
`getOrPut`. **−1..−2**

### [IN09] L/LM — masks.zig:76-77: stale "ledger-less repeat path" reference
Reword. **−1..−2**

### [IN11] L/M — input.zig:45: `mouse_buttons` module const single-use
Move into `setupGrabs`. **0**

## A.8 `src/model/` + `src/main/` (MOD — 11 findings, ≈ −45 code + −30 comment lines)

### [MOD01] H/H — tracking.zig:183-190: `isOnCurrentWorkspaceAndVisible` production-dead
Delete fn + doc + the 10 test assertions. **−8..−10**

### [MOD02] H/H — tracking.zig:55-59: `getWindowWorkspaceMask` pub, 1 internal consumer
Fold into `isOnCurrentWorkspace`; de-pub; repoint the test. **−6..−7**

### [MOD03] M/H — tracking.zig:61-64,143-149: windowCount + countWindowsOnWorkspace alive only for dumpState
Fold into `input.dumpState`; delete both fns + docs. **−11..−13**

### [MOD04] M/H — window.zig:319-321: same-name passthrough re-export of `tracking.isOnCurrentWorkspace`
Call the facade directly at the one site; delete the local wrapper. **−3**

### [MOD05] M/H — model.zig: 4 doc blocks re-explain code (coveringOccupantOnWs, register, fallbackFocusCandidate, Store alias)
Compress; keep policy notes. **−12..−16 (comments)**

### [MOD06] M/H — model.zig:213-215: `taggedOn` doc over-claims single-spelling
Amend doc to name the pruned-entry `maskedOn` split. **−1 (doc)**

### [MOD07] M/M — `m.ws[m.current.index].params` idiom ×9
Add `model.currentParams(m)`; swap the 9 sites. **≈0..+2**

### [MOD08] M/M — bounded.zig:285-287: Iterator "no bounds dance" promise unmet by sync fused loop
Extend `Item` with `idx: usize`; rewrite sync passes onto `iterator()`. (**−5..−7**, perf-gated,
owner call §C.2.)

### [MOD09] L/H — main.zig:17-21 vs 114-115: duplicated surfaces/boot-guard commentary
Shrink. **−4 (comments)**

### [MOD10] L/H — main.zig:106: opaque slogan "the model path IS the path"
Rewrite as the causal dependency. **0**

### [MOD11] L/H — model.zig:184-189: `unregister` defeats the `home_ws` cache
Capture home first, then remove. **0 (perf) + clarity**

## A.9 Cross-cutting / whole-codebase (WCD — 13 findings, ≈ −150+ cumulative)

### [WCD-01] M-H — config.zig:1826-1870: barChanged/tilingChanged/keysChanged are hand-maintained second schemas
Make the detector provably a superset of the applying table (comptime field-name table or
`schema applies ⊆ barChanged compares` assert). **~0 (guard)**

### [WCD-02] MED — border font/focused pick ×3 (pipeline.colorOf, borders.borderColorOf, resolveBorderColor)
Hoist the pure pick into a layer-free leaf; borders keeps covering scan; pipeline delegates.
(Overlaps CORE-05. **−6..−8**)

### [WCD-03] MED — covering-occupant query in 3 shapes (model OR / fullscreen AND / actions hook)
One model OR scan + fullscreen thin constraint wrapper; delete actions shim (overlaps WIN01/03). **−10..−15**

### [WCD-04] MED — tests hand-roll `@import("tiling") else @import("std")` bypassing tiling_seam
Expose the production seam to the test build; delete the hand-rolled stand-in (fixture.zig:34-35,
model_test.zig:19-20). **−2**

### [WCD-05] LOW-MED — `Ctx.cfg_bw` duplicates `env.margins.border` (overlaps CORE-03). **−6..−9**

### [WCD-06] LOW — window.providerOf re-export chain + actions 7 local aliases
Pick one home; delete the alias block or the forwards. **−5..−7**

### [WCD-07] LOW-MED — WindowId/WorkspaceId spelled two ways (core vs model)
One visible pair + doc pointer (rename churn, ~0). Deferred (owner).

### [WCD-08] LOW-MED — 3 per-module atom mini-caches duplicate shared AtomCache
Delete wincache globals + icccm FocusAtoms; use `wire.getAtomCached` at read sites. **−14..−20**

### [WCD-09] MED — property-reply format/type validation hand-rolled 3 ways
One `takePropertyReply(conn, cookie, want_format, want_type)` in wire. **−8..−12**

### [WCD-10] LOW — grab brackets take 3 shapes (reconcileUnderGrab, withServerGrab, bar ungrabAndFlush)
Fold reconcile into withServerGrab; bar uses `utils.ungrabAndFlush` (overlaps CORE-04). **−6..−10**

### [WCD-11] LOW — workspace-number parsing trio with duplicated bound check
`tryParseWsToken = parseWsToken → checkWorkspaceBound`. **−5..−8**

### [WCD-12] LOW — layout canonical names hand-listed ×3 vs build registry
Comptime guard `flat_variant_keys ⊆ grammar ⊆ registry`. **~0 (guard)**

### [WCD-13] LOW — generated registry files each inline ~48 lines of comptime invariants
Emit one shared leaf generated module with the invariant specs. **−90..−130**

# B. Ranked execution order

Phase 1 — dead code & comment hygiene (zero-risk):
CORE-01, CORE-13, IN04, IN05(partial), IN09, CFG-04/06/08, MOD05/06/09/10,
BAR04/07/10/13, TIL-N5/N7.

Phase 2 — mechanical inlining & single-source (tests pin behavior):
CFG-01/02/05/07/09/10/11/13, CORE-06/08/09/10, BAR01/02/03/05/06/08/09/11/12,
IN01/02/06/07/08/11, P-02/03/04/05/06, S-01, SY-01/02, CL-01, TG-01/02, T-01,
TIL-N1/N3/N4/N8/N9, MOD01/02(partial)/03/04/07/11, WCD-06/08/09/11.

Phase 3 — structural consolidation (verify against pinned tests):
CORE-02/04/05, WIN01/02/03/04/05/07/10, WCD-02/03, MOD08, WCD-04.

Phase 4 — cross-subsystem guards & registries:
WCD-01/12/13, CORE-03 (owner gate), TIL-N6/10.

# C. Deferred items & questions (for the owner)

## C.1 From the audits (with specific questions)

1. **BAR12 / drawPaddedSegmentValue markup** (Q1/Q2 BAR): `@splat(.{})` on struct arrays in
   Zig 0.16; and BAR14's value-partition merge must be byte-identical on title/carousel.
2. **S-02 rounding policy ruling**: shared pct↔range helper with both rounding modes is the
   finding; a behavior change (unifying rounding) is NOT proposed without owner ruling.
3. **v8 §C items**: systatus/slider poll scaffold twins (recommend keep + cross-ref);
   volume backend-arm duplication; vim wordScanFwd/Bwd merge; title.zig:322 phantom
   `offsetFor` retire; slider `nowMs` pub-for-tests.
4. **BARCR-18**: bare-bool `applyVisibility(..., do_reconcile)` — still open.

## C.2 Cross-cutting / architecture questions

- **[Q1]** `borderColorOf` pure seam: is the layer-gated unit test of the pure ternary wanted
  (keep) or should it inline (drop)? (WIN06)
- **[Q2]** `Ctx.cfg_bw` removal: must the sync layer stay config-blind (thread `bw` through
  ReconcileOpts) or may it read `ctx.env.margins.border`? (CORE-03/WCD-05)
- **[Q3]** TIL-N2 gate saturation corner: `m.gap *| 2 + border2` (wrapping) vs
  `totalInset` (saturating) — identical for reachable margins; confirm use of `totalInset`.
- **[Q4]** `pipeline.Gate` per-module re-declaration (tracking/focus/window/actions): keep or
  promote to one shared Gate?
- **[Q5]** TIL-N6 `paneCell` relocation into grid vs engine-vocabulary consistency; and
  CORE-04 `retile_prof` ownership when folding the grab bracket.
- **[Q6]** MOD08: extend `Store.Iterator` with `idx` (perf-gated, not simplification-neutral).
- **[Q7]** MOD03/MOD-Q1: is `input.dumpState` a first-class surface (keep windowCount/
  countWindowsOnWorkspace) or a debug dump (fold)?
- **[Q8]** WCD-07 id aliases: rename-churn, ~0 LoC — acceptable to proceed?
- **[Q9]** IN03 rebuild hardening (retried device-id) — cold path strengthening, accept?
- **[Q10]** IN06/IN08 type-inference claims — verified by `zig build check` during landing.
- **[Q11]** WCD-10 bar-side: bar's manual ungrabAndFlush ordering constraint (paused bar must
  not flush mid-frame) — confirm the ordering survives the fold.

# D. Execution status (filled as this session proceeds)

- **Baseline (wave 1)**: fmt clean; `zig build check` + layer rules green; `zig build test`
  exit 0; tokei = 17,023 production LOC.

- **Phase 1 (zero-risk) — COMPLETE**, all gates green (`zig fmt --check .`, `zig build
  check` incl. check-layers, `zig build test` exit 0):
  - CORE-01 (dead `handlePropertyNotify` removed), CORE-13 (.swp files deleted).
  - IN04 (delete 4 unanchored floating comment lines), IN05 (collapse `handleMappingNotify`
    inline restatement to 2 lines), IN09 (reword masks.zig "ledger-less" → "detectable
    auto-repeat press/release stream").
  - CFG-04 (compress `readFileAlloc` doc 15→3 lines), CFG-06 (de-pub `snapshotDirPath`),
    CFG-08 (compress barChanged/tilingChanged header 17→6 lines).
  - MOD05 (`coveringOccupantOnWs`, `register`, `fallbackFocusCandidate`, `Store` doc slims),
    MOD06 (`taggedOn` doc names the facade split), MOD09 (surfaces import doc 5→2),
    MOD10 (main.zig slogan → causal dependency).
  - BAR04 (`markAllSegmentsDirty` inlined into `markDirty`), BAR07 (`reportDrewNothing`
    helper dedups the warn-return in `drawSegment`), BAR10 (dead zero-ticker guard dropped),
    BAR13 (duplicated doc block deleted).
  - TIL-N5 (dangling `split_y`/`split_x` splice removed), TIL-N7 (`satI16` de-pubbed,
    doc renamed "Internal narrow/clamp used by emitRect and insetRect").

- **Phase 1.5 (core mech, folded into wave 1, gates verified)**: CORE-06 (`resolveCmdZ`
  single-sources the stack/heap `[:0]` cmd copy in spawn.zig, −10), CORE-09 (`failWithTag`
  dedups the post-fork failure tail, −4), CORE-08 (redundant `has_bar and` conjunct dropped),
  CORE-10 (`screen.\*.root` → `screen.root` deref), CORE-11 (signals param rename),
  CORE-12 (`syncSink()` rename).