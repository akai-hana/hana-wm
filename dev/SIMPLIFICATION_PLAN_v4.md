# hana — Simplification Task List v4 (fourth audit campaign)

Date: 2026-09-21. Method: this campaign deployed **one analysis agent per `src/`
subsystem, sub-divided into eleven parallel research agents** — `bar` (split:
bar-core engine vs bar-modules), `config`, `core` (split: hub/service files vs
plumbing `sync`/`x11`/`utils`), `input`, `model`, `tiling`, `window` (split:
window-core vs window modules), plus a **whole-codebase interconnection agent**.
Every finding below was verified against the live tree (`rg` + full-file reads)
by its owning agent before being listed; each v1/v2/v3 item was re-verified as
live (or applied) before being excluded, so this list is strictly additive.

Baseline (this campaign's start, post-v3): `zig fmt --check .` clean,
`zig build check` exit 0 (layer rules + plugin-template), 16,480 code LOC
(`tokei src -f -s code --exclude src/test/`), full suite 251/252 (the single
failure is the pre-existing `focus_test.zig:97` no_input ICCCM fixture admission).

Mandate (unchanged): reduce LOC while preserving identical behavior, or improve
human readability. Risk and effort are not constraints. Inviolable: the sync
boundary (raw wire sends stay behind `src/core/sync/` + `check-layers.sh`
allowlist), pure `model`/`tiling`/`config` layers (xcb-free), the core never
naming an optional module (deletion-modularity), no TODO/FIXME, `zig fmt` clean.

## Evaluation axes (every finding assessed on all of these)

1. DEAD CODE — unused exports, params, fields, imports, arms, branches (rg-verified, whole repo).
2. DUPLICATION — near-identical functions, repeated literals/concepts, parallel arrays of truth.
3. OVER-ENGINEERING — comptime/generic/oops indirection net-negative at this scale.
4. READABILITY — bare bools, huge single functions, dense hot loops, abstruse flow.
5. NAMING — near-identical names for distinct roles, inverted-voice predicates.
6. COMMENT QUALITY — contradictory/stale headers, unresolvable marker codes, drift vs reality.
7. API ERGONOMICS — `!`-typed functions that cannot error, `null`/sentinel overload, dead params.
8. CONSOLIDATION — small files/functions that merge cleanly; single-source-of-truth violations.
9. STRUCTURAL / LAYERING — header truth vs guard script, seam surfaces, switchboards.
10. DOC DRIFT — planning/notes files that no longer match the tree.

## Verification gates (every change batch)

1. `zig fmt --check .` clean.
2. `zig build check` — exit 0 (check-layers + plugin-template).
3. `dev/scripts/xtest.sh zig build test` — full suite (251/252 baseline).
4. `tokei src -f -s code --exclude src/test/` — LOC delta reported per phase.
5. `dev/scripts/check-modularity.sh` (#20 in C) where a contract/build surface changes.

---

# A. Findings by subsystem

## A.1 `src/bar/` — core engine (`bar.zig`, `drawing.zig`, `metrics.zig`, `refresh.zig`, `segdraw.zig`, `segment.zig`, `visibility.zig`, `win.zig`)

**BARCR — bar-core agent.**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| BARCR-01 | bar.zig:140 (callers 1144,1197) | 7 | `calcBarHeightAndFontSize() !u16` cannot error (all erroring subcalls swallowed) | drop the `!`; plain calls | −2 | H |
| BARCR-02 | bar.zig:1092 | 7 | `pub fn submitDraw()` zero consumers outside bar.zig | drop `pub` | ~0 | H |
| BARCR-03 | bar.zig:1415 | 7 | `pub fn raiseBar()` only internal callers | drop `pub` | ~0 | H |
| BARCR-04 | drawing.zig:299,359 | 1 | `DrawContext.depth` write-only (set in initWithVisual, never read) | delete field + init entry | −2 | H |
| BARCR-05 | segdraw.zig:21-23 | 1 | `widthState().get()` zero callers in the tree | delete method (keep `cached` var) | −4 | H |
| BARCR-06 | bar.zig:1260-1277; segment.zig:56-58; bar.zig:1070 | 1 | `MinimizedApi.is_minimized` assigned every frame, never invoked; whole `minimizedIsHidden` chain + provider probe exists only to make a cache gate pass | delete field/forwarder/probe; gate the cache on `.collect != null` | −10..−13 | H |
| BARCR-07 | bar.zig:1626,1631,1637 | 8 | three one-line RandR forwarders (`randrFirstEvent`/`handleRandrEvent`/`runPendingRedetect`) exactly alias `refresh.*` | bind `refresh.*` directly in the `surfaces` literal; delete forwarders | −9..−13 | H |
| BARCR-08 | bar.zig:1048-1049 | 1/4 | trailing `and s.hasPendingRepaintWork()` in the P2a fast-path is a tautology (re-verifies a fact the early-exit at :1037 forced); re-runs a full layout×segment scan + repaint hooks per marquee frame | drop the last predicate | −1 (+perf) | H |
| BARCR-09 | bar.zig:227,362,522,566,1099,1678 | 2/3 | `force` and `dirty.flag` are two same-purpose "full redraw" channels | merge into one flag + dirty-set (re-map three gate predicates) | −10..−14 | M [DEF] |
| BARCR-10 | bar.zig:979-1002 vs 1378-1396 | 8 | `drawClockOnly` and `redrawSegmentScoped` are the same region-scoped single-slot repaint skeleton differing only in bound source + blit flavor | one shared helper parameterized by (x, w, flush) | −12..−15 | M |
| BARCR-11 | bar.zig:602,1038,1047,1307 | 6 | bare marker codes `P2`/`P2a`/`B3` no legend | strip prefixes, keep prose | 0 | M |
| BARCR-12 | bar.zig:90 | 6/10 | header "(folded from metrics.zig)" is a leftover from a prior campaign | reword | 0 | L |
| BARCR-13 | metrics.zig:21 | 7 | `pub const default_scaled_font_size` zero consumers outside metrics.zig | drop `pub` | ~0 | H |
| BARCR-14 | plugin.zig:289-293 | 1/9 | `Segment.configurable` set by prompt, read by nothing anywhere | delete field + writer | 0 | H [DEF] (contract) |
| BARCR-15 | bar.zig:267; segment.zig:140; title/title.zig:106 | 2/8 | same cap `max_tiled_windows` re-declared as 3 private names | export once from segment.zig, reference the rest | −2 | M |
| BARCR-16 | bar.zig:924-929 vs 934-937 | 2/4 | `.center` layout measures every non-center segment twice per frame | cache claim-pass widths | 0 | H (dup) [DEF] (perf cache) |
| BARCR-17 | bar.zig:391,889,904,915,1010 | 5 | `frame` names three different things in one file | rename the DrawCtx local | 0 | M |
| BARCR-18 | bar.zig:1532,1561 | 4 | bare-bool `applyVisibility(…, false/true)` | named enum (costs lines) | ~0 | L |

## A.2 `src/bar/` — modules (`modules/**`)

**BARMOD — bar-modules agent.**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| BARMOD-01 | slider.zig:261-262 | 1 | `Instance.armed` never read/written (real state is `g_armed`) | delete field + doc | −2 | H |
| BARMOD-02 | native_alsa.zig:43 | 1 | `SNDRV_CTL_ELEM_ACCESS_READ` never referenced | delete | −1 | H |
| BARMOD-03 | native_pulse.zig:77 | 1 | `g_op_muted_current` declared, zero readers/writers | delete | −1 | H |
| BARMOD-04 | tags.zig:14 | 7 | `fallback_width` zero external consumers | de-pub (%1) | 0 | H |
| BARMOD-05 | tags.zig:36,41 | 7 | `invalidate()`/`getCachedWorkspaceWidth()` zero external consumers | de-pub | 0 | H |
| BARMOD-06 | clock.zig:25,36,46,74,85,112,122,127,53 | 7 | 9 clocks exports with zero out-of-file consumers (bar reads them via registry struct) | de-pub | 0 | H |
| BARMOD-07 | prompts 27,30; slider.zig:75 | 7 | `prompt.xk_back_space`/`xk_delete`, `slider.throttle_ms` zero consumers | de-pub | 0 | H |
| BARMOD-08 | slider.zig:240-242,388 | 1 | `slot_x` always 0 (only one write = 0); dead generality | drop field/write/doc; call `pctFromSlot(0, slot_w, offset)` | −5 | H |
| BARMOD-09 | prompt.zig:139-147 vs 179-186 | 2 | `insertChar`'s `xk_back_space` arm byte-identical to `backspace()` | `xk_back_space => backspace(es)` | −7 | H |
| BARMOD-10 | clock.zig:181, systatus.zig:76, native_pulse.zig:239, slider.zig:78 | 2 | ×4 copies of `@intCast(utils.realtimeNs() / std.time.ns_per_ms)` — exactly `utils.realtimeMs()` (which is currently a dead export, see COREP-03) | substitute `utils.realtimeMs()` | −9..−12 | H |
| BARMOD-11 | volume.zig:191-244, brightness.zig:309-344 | 2 | `applyPct`/`previewPct`/`currentPct` byte-identical across the two controls (only reread differs) | safe subset: hoist the subprocess-commit dance into a slider-core helper | −12..−16 | M |
| BARMOD-12 | title.zig:341-350 | 1 | `max_title_windows` clamp + `debug.warn` provably unreachable (snapshot list bounded by the same constant) | fold clamp/warn/alias | −6 | M |
| BARMOD-13 | systatus.zig + slider.zig | 8 | ~60 lines of near-identical per-segment scaffolding — **explicitly documented as a deliberate twin** | keep (recorded decision) | 0 | H |
| BARMOD-14 | prompt.zig:269 vs carousel.zig | 5 | `pill_ink_gap_px = 10` vs `gap_px = 8` — sibling files, near-identical names, unrelated meanings | rename both for disambiguation | 0 | L |
| BARMOD-15 | — | all | banding/width-slot helpers correctly centralized | verified-not-worth | 0 | — |

## A.3 `src/config/`

**CFG — config agent.**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| CFG-15 | parser.zig:310,897 | 1 | `Document.source_path` written every parse, read only by a test | delete field + assignment | −2 | H |
| CFG-16 | schema.zig:555 | 7 | `applySegmentColors` `pub`, sole call internal (schema.zig:545) | de-pub | ~0 | H |
| CFG-17 | config.zig:317 | 7 | `SearchPaths.deinit` still `pub` on a now-private type | drop `pub` | ~0 | H |
| CFG-18 | config.zig:541-542,913-914 | 4 | unnamed magic caps `[64]u8` (section name) / `[16]u8` (modifier token) — RE-OPEN of CONFIG-11 residue | name consts (`max_section_name_bytes`, `max_modifier_key_bytes`) | 0 | M |
| CFG-19 | config.zig:33 vs 943 | 5 | `tryParseWs1Based` vs `tryParseWorkspace` — single-digit-distance names with incompatible contracts | rename one | 0 | M |
| CFG-20 | config.zig:33-40; callers 1128,1236,1444 | 3 | `tryParseWs1Based` carries comptime warn plumbing (`fmt ?[]const u8` + anytype args) for one null call site | split warn from parse | −4 | M |
| CFG-21 | config.zig:1444 | 4 | `[workspace.rules.<x>]`/`[rules.<x>]` non-numeric sub-tables dropped **silently** (sole no-diagnostic bad-config path) | emit `warnLine` on null | +2 | M |
| CFG-22 | schema.zig:341-349 | 3/6 | `getInRange` guard + prose for u64/usize arms deleted by CONFIG-6 (guard comptime-true for u8/u16) | fold; drop stale aside | −3 | H |
| CFG-23 | config.zig ×14, parser.zig ×11, schema.zig:135, types.zig:325 | 6 | 27 bare audit-marker refs (`C1..C14`, `S1/S2/S4`, `T3`, `C8`) no legend | strip prefixes | 0 | H |
| CFG-24 | config.zig:520-529,859,213-224; parser.zig:206; schema.zig:91-99; config.zig:526-527 | 2 | section-name single-sourcing half-done (CONFIG-12 residue); `known_sections` re-declares strings in `types`; `bar.layout.*` anchors re-spelled | hoist remaining literals into `types` | −5 | M [DEF] |
| CFG-25 | config.zig:476,1036,1069,1122; types.zig:192 | 2 | `"master"` canonical layout name in 5 sites | `types.canon_master_layout` const | −1 | H |
| CFG-26 | config.zig:1051,1053,1344,1377,1397,1345,1408; types.zig:255,503 | 4 | bare bools at 8 sites (`freeX(…, true/false)`, `appendDupedStrings(…)`) | paired entry points or `keep` named const | −2 | M |
| CFG-27 | config.zig:1256-1315 | 4 | `parseLayoutsArray` densest control flow (polymorphic 3-forms-in-one-loop) | extract optional trailing workspace-group helper | +4/−0 | M |
| CFG-28 | config.zig:606-659 | 3/4 | `action_map` 54-line comptime block (quota-lifted two shadow-check loops) vs ~34 hand rows | fold into one table or document; classified deferred-grade | −8 | L |
| CFG-29 | config.zig:245-281,422-435,437-463 | 2/8 | three load pipelines re-roll the same tail | shared `parseAndBuild` | −5 | M |
| CFG-30 | types.zig:7 ↔ parser.zig:15 | 9 | circular sibling import `types ↔ parser` over `ScalableValue` (31 sites across 6 files) | move `ScalableValue` into types.zig | ~0 net | M |
| CFG-31 | check-layers.sh:192, build.zig:1397 | 9 | config purity guaranteed by NO automated body guard (Rule 3 sweeps only model+tiling; @cImport invisible to import-edge scan) | add `src/config` to Rule 3 `find` | +0..+3 | H/M |
| CFG-32 | config/README.md:60-64 | 10 | 4 quick-reference drifts: `indicator` under tiling-layout, undocumented `[master-stack.counts]` sub-table, undocumented `[fullscreen] enabled`, undocumented `bar.modules.workspaces` alias | README pass | 0 | M |
| CFG-33 | config.zig:96 vs 935 | 6 | `max_key_name_bytes` doc promises `error.KeyNameTooLong` for longer, but guard is `>=` | reword doc | 0 | H |
| CFG-34 | parser.zig:668-673 | 6 | array-depth diagnostic prints bare line number (only non-`warnLine` diagnostic) | route through `warnLine` | −1 | L |
| CFG-35 | schema.zig:443-447 | 6 | "got a union/other value" printer jargon; only reachable tag is boolean | reword | −1 | H |

## A.4 `src/core/` — hub/service files

**COREH — core-hub agent (full report also at `dev/simplification-audit.md`).**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| COREH-01 | events.zig:9 | 1 | dead import `constants` | delete line | −1 | H |
| COREH-02 | pipeline.zig:14 + 124-125,148 | 1/10 | dead import `wincache`; stale doc refs `wincache.width()`/`wincache.color` | delete import; reword docs | −1 | H |
| COREH-03 | pipeline.zig:18 | 1 | dead import `types` | delete line | −1 | H |
| COREH-04 | persist.zig:256-287; main.zig:135 | 7 | `loadToGlobal() !bool` cannot error (every path converted) | `bool`; drop ceremonial `try` | −1 | H |
| COREH-05 | screen.zig:33 | 7 | `pub const max_claims` zero external consumers | de-pub | 0 | H |
| COREH-06 | restart.zig:61-81; main.zig:79 | 1 | `binary_path_override` always null; sole caller passes null; doc justifies "e.g. tests" that don't exist | drop param + branch + doc | −8 | H |
| COREH-07 | persist.zig:8 | 10 | header mentions `count_minimized`, which no longer exists | delete mention | 0 | H |
| COREH-08 | events.zig:276 | 10 | reload doc claims "DPI scaling runs pre-swap" — reload does no DPI work | reword | 0 | M |
| COREH-09 | pipeline.zig:202-218; call sites main:147, actions:101,187,360,563,967 | 4 | bare `bool focus_before` ordering argument at 6 call sites | small enum `before`/`after` | 0 net | M |
| COREH-10 | pipeline.zig:110 vs 129 | 2 | `core.borderWidth()` computed twice per ctx() build (scaled twice by same screen_h) | compute once, feed tilingEnv | −1 | H |
| COREH-11 | pipeline.zig:5-8 | 10 | header claims a `// PIPELINE:` marker convention that no longer exists | reword/drop note | 0 | H |

## A.5 `src/core/` — plumbing (`sync/`, `x11/`, `utils/`)

**COREP — core-plumbing agent.**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| COREP-01 | sync.zig:11-23,341-345,224-227 | 10 | seam headers claim "every stored window computed/every send replayed" — false since the OFF-WORKSPACE FAST PATH skips provably-parked windows | reword canonical contract | 0 | H |
| COREP-02 | wire.zig:27-38; callers window.zig:189,1039 | 1 | `rectFromXcb` include_border param always `true` (both callers); dead `else 0` arm | drop param | −3 | H |
| COREP-03 | utils.zig:58-61 vs bar clock/systatus/pulse/slider | 1/2 | `utils.realtimeMs` zero consumers; identical expression hand-rolled ×4 in bar | delete+delete, or route the four via it (see BARMOD-10 — coordinated) | −3 (or −12 unified) | H |
| COREP-04 | utils.zig:44-51 | 7 | `clockNs` pub, only internal callers | de-pub | 0 | H |
| COREP-05 | utils.zig:24; proc.zig:26 | 1 | `wake_byte` dead pub chain (re-export + decl) except proc-internal write | drop re-export; de-pub in proc | −2 | H |
| COREP-06 | sync.zig:169,178,188 | 7 | ledger `sentGet`/`sentGetOrPut`/`sentSwapRemove` pub but used only by tests (verification seam) | annotate as test seam (keep — tests are first-class) | 0 | H |
| COREP-07 | sync.zig:234-244 vs pipeline.zig:185-190 | 8 | `reconcileUnderGrab` duplicates `withServerGrab`'s bracket; only diff is profiler timing | keep + document (fold would move profiler across boundary) | 0 | M [DEF] |
| COREP-08 | sync.zig:320-333 vs 496-515 | 2 | winner-seed re-encodes `computeDesire`'s non-parked predicate (two copies must stay in lockstep or winner loses priority) | extract `desireIsNonParked`, use in both | −8 | M |
| COREP-09 | sync.zig:299-311 | 2/4 | per-window double binary search (`store.get` then `store.slotOf`) | `slotOf` once, use `store.at(slot)` for the entry | −1 | L |
| COREP-10 | sync.zig:147-154,165-196; sync_test.zig:421-445,450-504 | 3 | second id-keyed index (`sent_index`/IdMap) + tombstone/rehash machinery duplicative of the model Store's own keying; ledger is inserted sorted by id | sorted ledger + binary-search slot + `orderedRemove`; delete index + 2 tombstone tests | −6 core / −60 tests | M [DEF] |
| COREP-11 | sink.zig:1-12 | 10 | header claims shim primitives "defined in core/x11/wire.zig" but 5 shims call `xcb.*` inline (legal — sink is the seam); also cites a nonexistent BELOW sibling | reword | 0 | H |
| COREP-12 | constants.zig:98-104 | 5/8 | `Limits` one-member namespace struct | flatten to flat const (rename via `model.max_tiled_per_ws` alias) | −3 | L |
| COREP-13 | sync.zig:56 | 3 | `Stack = enum{above}` single-variant riding `?Stack` | keep (documented concept at the seam) | 0 | L [DEF] |
| COREP-14 | wire.zig:287-342 | 3 | `ReplyCollector` generic family has exactly one instantiation (~40 lines of comptime machinery for `xcb_get_property`) | plain typed `collectPropertyReply` (keep poll-first comment) | −12 | M |
| COREP-15 | sync.zig:276-421 | 4 | `reconcile` 146 lines — found correctly flat (send-order invariant) | keep; maybe extract only the seed (see COREP-08) | 0 | L |

## A.6 `src/input/`

**IN — input agent.**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| IN-11 | xkbcommon.zig:59-79 vs check-layers.sh:144 | 9 | `enableDetectableAutoRepeat` issues raw wire (`xcb_xkb_per_client_flags` + reply, `xcb_get_extension_data`) NOT behind sync and NOT covered by any allowlist pattern; guard passes silently | widen pat1 family + allowlist entry documenting the best-effort setup | 0..+2 | M [DEF] |
| IN-12 | input.zig:102-104, call 189 | 1 | v3 de-pubbed `lookupKeybinding` but one-line alias survives with no doc value | call `keybind_resolver.lookup` directly; delete wrapper | −3 | H |
| IN-13 | xkbcommon.zig:192-197 vs keysyms.zig | 8 | `keysymGetName` pure xcb-free libxkbcommon call lives in the xcb-bound module; twin `keysymFromName` in pure keysyms.zig | move it (0 net; cosmetic today — only consumer is input-internal) | 0 | L |
| IN-14 | keybind.zig:22-23,36-51 | 2 | twin `AutoHashMapUnmanaged(u64,…)` maps with identical keys (`map` last-wins, `seen` first-wins-for-warn) | one map; change warn text first→previous | −6..−7 | M [DEF] |
| IN-15 | xkbcommon.zig:94,95,96,107,183; input.zig:59,117 | 2 | `256` keycode-space literal repeated 6× (only `x11_min_keycode` hoisted) | `constants.x11_max_keycode = 256` | −5+1 | L |
| IN-16 | input.zig:416,397 | 4 | two bare-bool/derived-bool calls in dispatch | stet (matches WIN-9 deferral) | ~0 | L |
| IN-17 | input.zig:177,225,233,293,307 | 2 | five handlers open with identical `setLastEventTime(event.time)`; bar-window guard recurs | informational (centralizing touches core dispatch) | ~0 | L |

## A.7 `src/model/`

**MOD — model agent.**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| MOD-01 | model.zig:254-256 | 7 | `pub const OrderList`/`MruList`/`StoreT` zero consumers outside file | de-pub | 0 | H |
| MOD-02 | model.zig:259 | 10 | `lowestBit` doc cites `[0, MAX_WS)` — alias removed by v3 MODEL-5 | reword to `constants.max_workspaces` range | 0 | H |
| MOD-03 | model.zig:92-94 | 6 | `Entry.covering_ws` doc "present iff presence == .covering" false for minimize-from-fullscreen ghosts (retained across parked) | rewrite doc | 0 | H |
| MOD-04 | model.zig:224 | 6 | `at` doc opens "Iterates in sorted-key order;" — residual copied from `Iterator`; `at` is an indexed accessor | drop clause | 0 | M |
| MOD-05 | model.zig:403 | 4 | `setFocus` `_ = m.store.getPtr(win) orelse return;` — pointer fetched, discarded | `if (!m.store.has(win)) return;` | 0 | L |
| MOD-06 | model.zig:322-325 vs sync.zig:368-371 | 2 | reconcile fast-path re-derives `!visibleEntry` inline (exact De Morgan of the model's private predicate) | promote `visibleEntry` to pub inline; sync calls it | −3..−5 | M |
| MOD-07 | ~13 prod + 5 test sites | 2/8 | RE-OPEN of v3 MODEL-7: tag-membership `mask & bit(ws)` idiom count revised to **13 production + 5 test** sites (v3 under-counted "~8") | `pub inline fn taggedOn(e, ws)` (keep `isPinned`/set-ops as-is) | +5 / −3..−6 net | M |

## A.8 `src/tiling/`

**NEW — tiling agent (TILING-10 remains deferred §C).**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| NEW-1 | tiling.zig:296-300 | 7 | `compute` takes `View` by value only to take `&v`; caller already owns one | `*const View`; 2 call sites add `&` | 0 | H |
| NEW-2 | tiling.zig:255-257 | 7 | `defaultKind` pub, zero external consumers | drop `pub` | 0 | H |
| NEW-3 | tiling.zig:81-86; master:31-36, leaf:12-17, fib:54-55 | 2/8 | 3× 4-field `LayoutCtx` literal; struct undocumented | `LayoutCtx.init(v, out)` + one doc sentence | −6 | H |
| NEW-4 | master:119-125 vs 281-284 | 2 | dual vertical-stacking (recursive accumulator vs closed form); equivalent by telescoping EXCEPT min_dim-floor corner where closed form can overlap rows | unify or pin with a comment + corner test | −8..−10 | M [DEF] |
| NEW-5 | master:152-153,173,177-179 | 4/6 | three rounding schemes in one fn; zero/boost branches behaviorally load-bearing (floor≠round) | comment the tri-scheme; do NOT merge | 0 | M [DEF] |
| NEW-6 | fibonacci.zig:2,10-14 + test:204 | 6 | "counter-clockwise" label vs verified clockwise right→down→left→up trace (y-down screen) | fix label (header, enum, test title) | 0 | M |
| NEW-7 | grid.zig:57-62 | 6 | "uses a 1x3 layout for n==3" vs literal `.cols=3,.rows=1` — row/col transposed | align comment | 0 | L |
| NEW-8 | scroll.zig:9-11 | 6 | "CALLER DUTIES" mandates caller snapping, but compute self-clamps | reword ("callers may pre-clamp") | 0 | L/M |
| NEW-9 | fib:52 vs leaf:50 | 2 | "too small for two children" two unrelated formulas (`2·gap+border2` vs `2·min_dim+gap`) | document divergence or share threshold | 0 | M |
| NEW-10 | monocle:21, fib:53, leaf:51 | 5 | same `focusedElse` helper, three fallback conventions (tail/current/head) | one comment each; or unify topology | 0 | L |
| NEW-11 | plugin-template/layout.zig:23-24 | 10 | "grid.zig the least complex layout" — monocle (34L) is now | point template at monocle | 0 | L |
| NEW-12 | master:227,253; fib:68 | 4 | 7-8 param helpers | bundle scalars or accept | 0 | L |
| NEW-13 | tiling.zig:225 | 1 | `name.len > 64` guard never fires (config normalizes to ≤32) | drop guard | −1 | H |
| NEW-14 | tiling.zig:163-168 | 6 | `bisectRegion` doc claims saturating `first+gap+second<=dim`, false when `gap>dim` (callers guard) | narrow doc | 0 | L |

## A.9 `src/window/` — core

**WINC — window-core agent.**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| WINC-01 | window.zig:82-94; actions.zig:494 | 1 | `callFirst`+`HookReturnOf` serve one consumer (actions:494 getDragLastRect); comptime type gymnastics | inline via `providerOf`; delete both | −13 | H |
| WINC-02 | borders.zig:44 vs window.zig:99 | 5 | three spellings of covering-mode dispatch; borders bypasses the facade | route borders through `window.isCoveringMode` | ~0 | H |
| WINC-03 | actions.zig:282,869,965,992; focus.zig:262 | 6 | bare `(Gap 1..4)` markers from a prior audit remain in-window | reword self-contained | 0 | H |
| WINC-04 | window.zig:176-178; pipeline.zig:124-125,148 | 10 | stale comments (geometry cache / wincache.width / wincache.color) | reword | 0 | H |
| WINC-05 | borders.zig:27; 8 call sites | 7 | `coveredByOccupant` `has_fullscreen: bool` — all 8 call sites pass comptime literals | `comptime has_fullscreen` (WIN-9 window-scope subset) | 0 | H |
| WINC-06 | wincache.zig:149 vs 172 | 8 | `updateBorderColor` wrapped 1:1 by `sendBorderColorIfChanged` | merge | −6 | H |
| WINC-07 | tracking.zig:165,180 | 7 | `isWindowOnWorkspace` pub, only internal consumer | de-pub | 0 | H |
| WINC-08 | wincache.zig:48 | 9 | `wincache` imports `icccm` solely for `max_window_cache` | hoist to `constants` | 0 | H |
| WINC-09 | window.zig:1071-1098 | 2 | two owners of "last border width sent" (wincache + sync ledger) written side-by-side | cross-reference comments at minimum; full merge crosses sync boundary | 0.. | M [DEF] |
| WINC-10 | actions.zig:37; model:361; sync:281; fullscreen:200-221 | 9 | three occupant-query spellings (module-AND/OR/core-OR) with documented semantic split | audit + cross-reference comments | 0 | M |
| WINC-11 | pipeline.zig:152 vs borders:54 | 2 | focused-pixel picker ported twice (documented) | informational | 0 | — |
| WINC-12 | bar/bar.zig:677,685 | 9 | bar is a legit wincache consumer (titles) — corrects COREH-02 claim; keep a read path | informational | 0 | — |

## A.10 `src/window/` — modules

**WINM — window-modules agent.**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| WINM-1 | fullscreen.zig:38,134-142,184-189,294-312,339-357 | 8 | `Rec.anchor` is a redundant mirror of `e.anchor` in every reachable in-process state (blob bytes unchanged) | shrink `Rec` to `{win}`; drop copy-back/replay | −8..−10 | M [DEF] |
| WINM-2 | fullscreen.zig:172-176,200-209,282-288; minimize.zig:131-135; persist.zig:333-338 | 1/2 | rec↔covering_ws invariant silently breaks for post-re-exec ghosts; queries diverge from model truth | fix b: re-append rec in `minimize.restore` when covering & rec-less | +3 | M [DEF] |
| WINM-3 | minimize.zig:249,256-258,271-281 | 1 | dead `*const model.Model` element in both preamble tuples (`p[0]` never read) | return `?Rec`/`?*model.Entry` | −5 | H |
| WINM-4 | minimize.zig:76-84 vs 292-296 | 2 | duplicated park logic `minimize()` vs `deserializeWindow` | shared `parkEntry` | −4 | H |
| WINM-5 | minimize.zig:99-102 | 4 | `switch`-as-boolean idiom | `e.anchor == .tiled` | −4 | H |
| WINM-6 | workspaces.zig:44-45,49-55 | 4 | double `old_h.eql(ws)` read | hoist once | −2..−3 | M |
| WINM-7 | fullscreen.zig:228-232; plugin.zig:186 | 7 | `moveCoveringTo` const-binds, forcing the lone `@constCast`; every sibling hook takes `*model.Model` | widen hook to `*model.Model` | −1 (contract) | H [DEF] |
| WINM-8 | plugin-template/provider.zig:174-199 | 10 | template claims sync resolves the occupant "through the registry INSTEAD of scanning the model" — live sync uses `model.coveringOccupantOnWs`; hook serves actions/workspaces | reword | 0 | H |
| WINM-9 | fullscreen.zig:172-176 | 1 | `isFullscreenOnWs` rec-gate redundant in-process (subsumed by `orelse return false`) | simplify after WINM-2 (changes pure-model behavior — model-authority-consistent) | −3 | L [DEF] |

## A.11 Cross-cutting / whole-codebase

**CC — interconnection agent (numbered CC-v4 to avoid collision with v3's CC-1..7).**

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| CC-v4-1 | check-layers.sh:144; xkbcommon.zig:60,69 | 9 | guard blind to `xcb_xkb_*` family (same as IN-11) | widen pat1 + allowlist entry | ~1..+2 | H [DEF] |
| CC-v4-2 | check-modularity.sh:80-90,249-252,293-294 | 10 | two scenarios `rm -rf` nonexistent flat paths (`layout.zig`/`variants.zig`); `remove_paths` silently no-ops on missing paths | point at real dirs; make `remove_paths` loud-fail on missing non-`!` path | ~4 (script) | H |
| CC-v4-3 | IMPROVEMENTS.md:278,287,289 | 10 | 3 OPEN rows already resolved in-tree | re-triage | 0 | H |
| CC-v4-4 | plugin.zig:136-202,256-257,296-297,301,233-239 | 9 | "at most one module binds this"/"SHOULD claim" single-binder contracts enforced only by prose | comptime uniqueness assert in generated registries | 15-25 (build) | M [DEF] |
| CC-v4-5 | build.zig:170-183 vs 438,482,856,984 | 8 | `tiling_seam` is the sole bespoke inline seam; all other generators share `makeGeneratedModule` | extract `buildEngineSeam` helper | ~20 (build) | H |
| CC-v4-6 | build.zig:248-282; check-modularity.sh:159-317; build.zig:85-98 | 9 | removable-file universe mirrored in 3 hand-synced lists; new module auto-joins registries but not gates/scenarios | scenario-existence assert (CC-v4-2b) at least | ~4 | M [DEF] |
| CC-v4-7 | config.zig:167,487; parser.zig:306,509 | 6 | leftover `(C1)`/`(Gap 2)` markers where v3 declared strip landed | strip | 0 | H |
| CC-v4-8 | config/types.zig:175,182; config.zig:1137,1238 | 8 | config workspace_idx bare `u8` duplicate of `ids.WorkspaceId` | type as `ids.WorkspaceId` (available via pure shelf) | ~6 | M |

---

# B. Ranked implementation order

**Phase 1 — zero-risk deletions, dead-param cuts, comment/header hygiene (no semantic risk):**
MOD-01..05; BARCR-01..05, 11-13, 17; BARMOD-01..09, 14; CFG-15..17, 22, 25, 33, 35;
COREH-01..08, 11; COREP-01, 02, 04, 05, 06, 11; IN-12; NEW-1..3, 13, 14; WINC-01..08;
WINM-3..6, 8; CC-v4-2, 3, 7.

**Phase 2 — consolidation (behavior-preserving, suite + plugin-template pinned):**
BARCR-06 (minimized API), BARCR-07 (RandR forwarders), BARCR-08 (tautology),
BARCR-10 (scoped-slot redraws); BARMOD-10 + COREP-03 (realtimeMs unification),
BARMOD-11 (subprocess-commit subset), BARMOD-12 (title clamp); CFG-18, 20, 21, 26,
27, 29, 30, 31; COREH-10 (double borderWidth); COREP-03, 08, 09, 12, 14; IN-13, 15;
MOD-06, 07 (taggedOn); NEW-5..11, 14 (docs/comments); WINC-10 (occupant cross-refs);
CC-v4-5, 8.

**Phase 3 — documentation & build/script fixes:**
CFG-23, 32, 34; COREH-09 (focus enum if desired); the deferred questions below;
impl of CC-v4-4/6 if authorized.

---

# C. Deferred items & questions (dedicated section — please decide)

1. **BARCR-09** — merge `force` into `dirty.flag` + dirty-set (−10..−14)? Three gate predicates change; behavioral but test-pinned. Fold or keep the explicit channels?
2. **BARCR-14** — delete `Segment.configurable` (dead) — touches the public plugin `Segment` contract (community template may set it).
3. **BARCR-16** — `.center` layout double-measures every non-center segment per frame; a claim-pass cache is a perf fix that costs lines — legal under the "algorithmic" axis but trade-heavy.
4. **BARCR-18 / IN-16 / IN-17 / NEW-12 / COREH-09** — bare-bool / long-param-helper readability conversions (each costs lines vs the win). The v3 WIN-9 precedent deferred these; recommend stet for most.
5. **BARMOD-11 full form** — hoisting `applyPct`/`previewPct`/`currentPct` twins onto a shared contract-level `Level` state object (touches the sealed slider `Sub` contract).
6. **CFG-24** — finish section-name single-sourcing; verbatim-identical strings — flagged conservative `[DEF]`.
7. **CFG-28** — `action_map` 54-line comptime block: fold to one table (−8) vs document-as-designed (binds tests pin).
8. **CFG-30** — break `types ↔ parser` circular import (move `ScalableValue` into types.zig; ~31 sites across 6 files): mechanical but wide.
9. **CFG-31 / CC-v4-1 / IN-11** — config purity body-guard + the `xcb_xkb_*` wire-family guard hole: widening `pat1` makes xkbcommon's setup request FAIL the build until allowlisted — the allowlist entry must say WHY. This is a guard-policy decision.
10. **COREP-07** — reconcileUnderGrab vs withServerGrab bracket dedup would move the profiler across the sync boundary; recommend keep+document (recorded).
11. **COREP-10** — drop the ledger's second id-index + IdMap + tombstone machinery for a sorted-ledger binary-search slot (−6 core / −60 tests). The public ledger API + two hash tests change.
12. **COREP-13** — single-variant `Stack` enum keep (documented).
13. **COREP-15 / NEW-15** — 146-line fused `reconcile` and the 8-param layout helpers: intentionally kept flat/flat.
14. **IN-11 / CC-v4-1** — bless the detectable-autorepeat wire request explicitly (allowlist entry) vs gate the family to fail-loud; decide the allowlist vocabulary.
15. **IN-14** — collapse the twin `map`/`seen` keybind maps (−6..−7): changes the conflict warn text from "first/current" to "previous/current".
16. **MOD-07** — add `taggedOn(e, ws)` (13 prod + 5 test mask sites) vs keep the explicit idiom (v3 deferred it; count materially revised upward).
17. **NEW-4** — unify master's dual row-stacking formulations (−8..−10): requires confirming the min_dim-floor corner (possible overlap in the closed form).
18. **NEW-6** — fibonacci "counter-clockwise" label is actually a clockwise trace on y-down screens: label fix vs "it's a spiral by convention".
19. **NEW-9 / NEW-10** — share the "can't fit two children" threshold and the `focusedElse` fallback convention across fib/leaf/monocle (topology decision counts as behavior).
20. **WINM-1 + WINM-2 + WINM-9** — fullscreen cluster: shrink `Rec.anchor` out and fix rec-less post-re-exec ghosts (→ also simplifies `isFullscreenOnWs`). Lands as ONE coordinated change with a restart-ghost test.
21. **WINM-7** — widen `moveCoveringTo` to `*model.Model` (contract signature; plugin-template + modularity matrix gates).
22. **WINC-09** — two owners of "last border width sent" (wincache + sync ledger): cross-ref comments now, merge later with parking-behavior tests.
23. **CC-v4-4 / CC-v4-6** — comptime single-binder asserts in generated registries + deriving `test_gates` by scanning `src/test/`: build-side, `[DEF]`.
24. **Deletion-modularity post-check** — after all changes, re-run the ~25-build matrix (`dev/scripts/check-modularity.sh`) to confirm no import coupling was introduced.
25. **v3 carry-forward** — the open items of SIMPLIFICATION_PLAN_v3 §C (CONFIG-13 `bar.text_color`, CONFIG-14 reload detectors, INPUT-6 verb merge, INPUT-10 has_input, CORE-10 OOM diagnostics, BAR-3 natural-width naming, BAR-4 metrics, CC-2 nullable property hook, CC-6 allowlist scoping, WIN-3 border-sweep cost, WIN-9 bools, WIN-7 test seams, TILING-10 cap binding, INPUT-3 sendWmDelete folding, CC-4/IMPROVEMENTS triage, MODEL-5 MAX_WS, MODEL-7 taggedOn) remain open decisions; this plan re-ranks the two whose counts changed (MODEL-7 → MOD-07).

## Execution status (2026-09-21, this pass)

(filled in per phase; each change verified with `zig fmt --check`, `zig build check`,
`dev/scripts/xtest.sh zig build test`, and the tokei delta)