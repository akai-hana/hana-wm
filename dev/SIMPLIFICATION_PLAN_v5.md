# hana — Simplification Task List v5 (fifth audit campaign)

Date: 2026-09-22. Method: this campaign deployed **one analysis agent per `src/`
subsystem plus a whole-codebase interconnection agent** (eleven research agents):
`bar` (split: bar-core engine vs bar-modules), `config`, `core` (split: hub/service
files vs plumbing `sync`/`x11`/`utils`), `input`, `model`, `tiling`, `window` (split:
window-core vs window modules), plus one agent for the build/scripts/contracts/docs
interconnection view. Every finding was verified against the live tree (`rg` +
full-file reads) by its owning agent before listing; every v4 item was re-verified as
applied (or not) before being excluded (`\[v5-NOT-APPLIED\]` marks v4-authorized items
that the tree still doesn't contain).

Baseline (this campaign's start): clean tree at `fc7a68af automated sync`;
`zig fmt --check .` clean; `zig build check` exit 0 (`check-layers: all layer rules
pass`); headless `zig build test` exit 0; `tokei src -f -s code --exclude src/test/`
≈ 17,046 code LOC. No TODO/FIXME in `src/` (verified).

Mandate (unchanged): reduce LOC while preserving identical behavior, or improve human
readability. Risk and effort are not constraints. Inviolable: the sync boundary (raw
wire sends stay behind `src/core/sync/` + `check-layers.sh` allowlist), pure
`model`/`tiling`/`config` layers (xcb-free), the core never naming an optional module
(deletion-modularity), no TODO/FIXME, `zig fmt` clean.

## Evaluation axes (every finding assessed on all of these)

1. DEAD CODE — unused exports, params, fields, imports, arms, branches (rg-verified, whole repo).
2. DUPLICATION — near-identical functions, repeated literals/concepts, parallel arrays of truth.
3. OVER-ENGINEERING — comptime/generic/间接 indirection net-negative at this scale.
4. READABILITY — bare bools, huge single functions, dense hot loops, abstruse flow, magic numbers.
5. NAMING — near-identical names for distinct roles, inverted-voice predicates.
6. COMMENT QUALITY — stale/contradictory headers, unresolvable markers, drift vs reality.
7. API ERGONOMICS — `!`-typed functions that cannot error, `null`/sentinel overload, dead params.
8. CONSOLIDATION — small files/functions that merge cleanly; single-source-of-truth violations.
9. STRUCTURAL / LAYERING — header truth vs guard script, seam surfaces, switchboards, contracts.
10. DOC DRIFT — planning/notes/README files that no longer match the tree.

## Verification gates (every change batch)

1. `zig fmt --check .` clean.
2. `zig build check` — exit 0 (check-layers + plugin-template).
3. `zig build test` — headless exit 0 (X-gated tests self-skip); `dev/scripts/xtest.sh zig build test` where X is available.
4. `tokei src -f -s code --exclude src/test/` — LOC delta reported per phase.
5. `dev/scripts/check-modularity.sh` where a contract/build surface changes.

---

# A. Findings by subsystem

## A.1 `src/bar/` — core engine (BARCR, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| BARCR-18 | drawing.zig:740-753 | 1 | `DrawContext.drawSegment` zero consumers | delete fn + bind comment | −14 | H |
| BARCR-19 | drawing.zig:779-794 | 1 | `DrawContext.drawSegmentMin` zero consumers | delete fn | −16 | H |
| BARCR-20 | drawing.zig:605-623 vs 674-695 | 2 | `drawTextImpl`/`drawTextImplStyled` identical except props wrapper | merge into one props-taking impl | −13 | H |
| BARCR-21 | drawing.zig:758,797 | 2/8 | `drawSegmentStyled`/`drawSegmentMinStyled` same fn modulo min-width | single `paintedSegment(…, min_w: ?u16, props)` | −24..−30 | H |
| BARCR-22 | drawing.zig:900-923 | 8 | `drawPaddedSegmentCovering` builds style attrs twice | drop outer wrapper after BARCR-21 | −3 | H |
| BARCR-23 | drawing.zig:473-474 | 6 | `paintText` doc lists deleted `drawSegment` variants | fix comment | 0 | H |
| BARCR-24 | segdraw.zig:65,67,68,70,123,125,126,128 | 1 | `Opts.center_slot`/`dirty_sources`/`needsRepaint`/`onPollWakeup` no callers | delete field + forwarding line each | −8 | H |
| BARCR-25 | segdraw.zig:21-28,130 | 3 | `widthState.invalidate` deliberate no-op + `opts.invalidate orelse W.invalidate` | bind `opts.invalidate` alone, keep rationale comment | −7 | M |
| BARCR-26 | bar.zig:1429,1438 | 2 | `redrawDraggedSegment`/`redrawScrolledSegment` twins (differ in State field) | shared `redrawScopedSegment(?usize)` | −4 | M |
| BARCR-27 | bar.zig:1368-1374,1387-1392 | 2 | `markDirty()` inside `if (pendingFullRedraw())` is a no-op | `if (s.pendingFullRedraw()) return;` | −4 | H |
| BARCR-28 | bar.zig:816-848 | 2 | `drawRowSegment` both branches `return advancedX(...)` | fold; single return | −2 | H |
| BARCR-29 | bar.zig:244,1745,1750 | 8 | chromeToggleOverlay + handleButtonPress duplicate click dispatch | extract `dispatchClick(id, dx, left, cmd) bool` | −6 | M |
| BARCR-30 | segment.zig:184,237,257; title.zig:350 | 7 | `gatherAndSortWindowInfos`/`GatherScratch.gather`/`hitTest` `!?` no error paths | drop `!`, drop `try` | −6 | H |
| BARCR-31 | layout.zig:37 | 7 | `.{ .with_collapse = false }` equals default | `.{}` | 0 | H |
| BARCR-32 | bar.zig:1368 | 7 | `redrawInsideGrab` de-pub (sole external ref is a doc comment) | de-pub | 0 | H |
| BARCR-33 | win.zig:19 | 1 | dead `types` import | delete | −1 | H |
| BARCR-34 | bar.zig:418-424 vs segment.zig:91-98 | 2/8 | `FrameState` 4-field mirror of `segmod.Frame` | hold one `segmod.Frame` | −8..−12 | M |
| BARCR-35 | bar.zig:154 | 4 | `trial_pt: u16 = 100` magic | named const | +1 | L |
| BARCR-36 | bar.zig:380 | 5 | `visibility` module vs `Visibility` struct name shadowing | rename struct or record settled | 0 | L |

## A.2 `src/bar/` — modules (BARMOD, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| BARMOD-21 | slider.zig:211-213 | 1 | `renderLine` zero consumers | delete fn; reword intro | −3 | H |
| BARMOD-22 | slider.zig:413-414,448 | 7 | `drawDragBar` dead `sub_name` param | drop param + arg | −1..−2 | H |
| BARMOD-23 | systatus.zig:82-84; native_pulse.zig:238-240 | 8 | two private `nowMs()` wrappers = `utils.realtimeMs()` | route via `utils.realtimeMs()`; delete | −6 | H |
| BARMOD-24 | clock.zig:25,46,112,127,138 | 7 | v4 skip-correction: 5 clock pub fns zero consumers (`clock_test` needs 5 others) | de-pub the 5 | 0 | H |
| BARMOD-25 | carousel.zig:35,39,132 | 7 | `inter_title_gap_px`/`cyclePx`/`resetForShow` zero out-of-file consumers | de-pub | 0 | H |
| BARMOD-26 | brightness.zig:114,121 | 7 | `pctFromRaw`/`rawFromPct` zero external consumers | de-pub | 0 | H |
| BARMOD-27 | native_pulse.zig:176,188,202,213,225 | 7 | 5 fn zero external consumers | de-pub | 0 | H |
| BARMOD-28 | native_alsa.zig:137,145 | 7 | `rawFromPct`/`pctFromRaw` zero external consumers | de-pub | 0 | H |
| BARMOD-29 | prompt.zig:38,77,345,365,373,388,396,402,411,433,444,475,580 | 7 | 13 registry-bound exports, zero out-of-file name consumers | de-pub the 13 | 0 | H |
| BARMOD-30 | tags.zig:159 | 7 | `pub fn draw` zero external consumers | de-pub | 0 | H |
| BARMOD-31 | prompt.zig:1223 | 6 | residual `(B2)` campaign marker | strip | 0 | H |
| BARMOD-32 | src/test/bar/carousel_test.zig:56 | 10 | comment uses pre-rename knob `gap_px` | reword | 0 | L |

## A.3 `src/config/` (CFG, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| CFG-36 [DEF] | parser.zig:189 | 2/8 | `warnScalarDuplicate` exemption spells `"binds"` raw + misses alias `section_binds_alt` (`[Keybindings]`) | swap to consts; add alt to exemption | 0 | M |
| CFG-37 | config.zig:91 | 5/2 | single-use alias `bar_layout_section_prefix` | use `types.section_prefix_bar_layout` | −1 | M |
| CFG-38 | config.zig:107 | 2 | `default_tiling_layout = (types.TilingConfig{}).layout` == `canon_master_layout` | use `types.canon_master_layout` | −1 | M |
| CFG-39 [DEF] | config.zig:573-576,579 | 2/8 | `known_sections` hand-spells bar.layout.\* + tiling.layouts.master_stack | prefix++suffix concat | 0 | M |
| CFG-40 [DEF] | config.zig:1209 | 9 | `layout_name_grammar` 8-name list mirrors disk registry (2 hand-synced lists) | comptime validate grammar ⊆ registry | +0..+1 | M |
| CFG-41 | config.zig:50,1166,1274 | 7 | `tryParseWsToken` still takes `ctx` + re-embeds ctx name in fmt | drop `ctx`, keep fmt-only warn | −3 | L |
| CFG-42 | parser.zig:496,339,345 | 1/7 | `mixColors`/`max_mix_operands`/`MixOperand` pub zero consumers | de-pub | 0 | H |
| CFG-43 | parser.zig:372,741 | 1/7 | `weightFromToken`/`parseColor` test-seam pub | annotate `/// test seam` | 0 | M |
| CFG-44 | schema.zig:89-214,302 | 7 | `knobs`/`value` pub test seams | header note | 0 | M |
| CFG-45 | config.zig:1626 | 6 | comment cites `types.schema.knobs`; knobs is top-level | reword | 0 | H |
| CFG-46 [DEF] | config/themes/akai.toml:7-8 | 10 | header claims bare `RRGGBB` valid; parser rejects | reword to `#RRGGBB`/`0xRRGGBB` | 0 | M |

## A.4 `src/core/` — hub/service (COREH, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| COREH-12 | main.zig:81-96 | 2 | two overlapping comment paragraphs restate the same config-quit defer | merge into one block | −5 | H |
| COREH-13 | restart.zig:86-88 | 10 | `selfPath` doc repeats "readLink of /proc/self/exe" | reword second clause | 0 | H |
| COREH-14 | restart.zig:90-93,114-116; events.zig:409 | 2/7 | `selfPath()` slice re-`mustDupeZ`s on one-shot re-exec path | `?[:0]const u8` threaded into execv | −3 | M |
| COREH-15 [DEF] | plugin.zig:61; events.zig:89 | 1 | `surfaces.handlePropertyNotify` bound by no surface (bar omits it) | delete field + guard | −6 | H |
| COREH-16 | src/core/logs/atlauncher.log | 1 | committed 94-line unrelated JVM log | `git rm` | −94 | H |
| COREH-17 | pipeline.zig:124-144,163-176 | 2 | `ctx()` + `preReconcileDuties()` recompute `screen.workArea` per cycle | fold once | 0-3 | L |
| COREH-18 | core.zig:87-101 | 3 | `factAccessors` comptime generator re-lists 4 field identities | optional plain accessors | 0-4 | L |
| COREH-19 | pipeline.zig:255-317 | 4 | `reconcileUnderGrabNowFullscreen` densest fn (~40-line closure) | hoist setEwmh/armBar loops | −8 | M |
| COREH-20 | events.zig:447 | 5 | `charge_tail` opaque bool name | rename e.g. `with_tail` | 0 | L |
| COREH-21 | window.zig:31-37; actions.zig:27; plugin.zig:197 | 8 | `providerOf` forwarder chain | keep (canonical scan home) | 0 | L |
| COREH-22 [DEF] | pipeline/events/persist | 8 | "for window_mods if (m.Hook) f" dispatch idiom inlined 4-5× | plugin.zig dispatch helpers | −6 | M |
| COREH-23 | events.zig:27-30; pipeline.zig:17-21; persist.zig:38-42 | 2 | "window_modules registry" intro repeated nearly verbatim 3× | collapse to one line each | −4 | M |
| COREH-24 | IMPROVEMENTS.md:278-292 | 10 | OPEN rows already resolved in-tree | re-triage | 0 | H |
| COREH-25 | pipeline.zig:102-118 | 7 | borderWidth fact split across core/metrics — keep documented | doc note only | 0 | L |

## A.5 `src/core/` — plumbing (COREP/UTIL/X11, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| COREP-16 | sync.zig:44, wire.zig:19, utils.zig:15 | 1 | dead `constants` import ×3 | delete | −3 | H |
| COREP-17 | sync.zig:29-40,364-365,388-391 | 6 | ledger docs omit fast-path `parked` read + `bw`/`pixel` members | enumerate in docs | 0 | H |
| COREP-18 | sync.zig:502-515 | 2/4 | `desireIsNonParked` re-fetches entry via `visibleOn` → `store.get` twice | `model.visibleEntry(m, e, ws)` | 0 | H |
| COREP-19 | sync.zig:345-353,596-604 | 2/4 | winner seed double-binary-searches (`store.get` then `slotOf`) | `slotOf` once, `at(slot)` | −3 | L |
| COREP-20 | sync.zig:206-214,220-222 | 1/7 | `sentSwapRemove` pub, only `forget` caller | de-pub | 0 | H |
| COREP-21 [DEF→v4-authorized] | sync.zig:157-164,174-222; sync_test.zig:410-496 | 3/8 | v4 COREP-10 authorized but NOT applied: 2nd id-index + tombstone machinery; ledger sorted by construction | binary-search sorted insert + `orderedRemove`; drop index + 2 tests | −6 core / −60..−84 tests | M |
| COREP-22 [DEF] | wincache.zig:34,128-133; window.zig:1054-1056,1078-1082; sync.zig markSentBorderWidth | 8/9 | v4 WINC-09 authorized but NOT applied: two owners of "last border width sent" | sync ledger sole owner; drop `applied_border_width` | −6..−10 | M |
| X11-01 [DEF] | check-layers.sh:156; xkbcommon.zig:49 | 9/10 | guard widening incomplete: `xcb_get_extension_data` named in prose, not in pat1 | add to pat1 or trim prose | 0..+1 | M |
| COREP-23 | bounded.zig:37-46,122-132 | 1 | `indexOf`/`removeWhere`/`removeAllWhere` generic forms zero consumers | de-pub the trio | 0 | L |
| COREP-24 | idmap.zig:64-66,107-109 | 1 | `IdMap.contains`/`count` zero consumers (after COREP-21 only icccm user) | drop or annotate | 0 | L |
| COREP-25 | masks.zig | 1 | re-verified RESOLVED | — | 0 | H |
| COREP-26 | sync.zig:60,71-81,94-105 | 3/5 | `stack_only` vtable entry carries single-variant `Stack` (bool in disguise) | keep; de-param later | 0 | L |
| UTIL-01 | utils.zig:20 ↔ wire.zig:20 | 9 | utils↔wire import cycle benign by design | keep; note only | 0 | — |
| UTIL-02 | utils/paths.zig vs config SearchPaths | 5 | two unrelated namespaces both imported as `paths` | ignore or rename core's to `pathscan` | 0 | L |

## A.6 `src/input/` (IN, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| IN-18 | xkbcommon.zig:190 | 1 | private alias `xkb_retry_delay_ms` re-names imported const | use `constants.xkb_retry_delay_ms` | −1 | H |
| IN-19 | xkbcommon.zig:196-257 | 3/8 | `retryPoll` generic + 3 closures over flat retry loops | 3 flat `for` loops; delete machinery | −15..−22 | M |
| IN-20 | input.zig:342-348 | 2/8 | `dirSign`/`dirSignF` one-line twins | single inline fn; delete `dirSignF` | −3 | M |
| IN-21 | input.zig:94 | 6 | `handleMappingNotify` doc opens with `//` not `///` | unify | 0 | H |
| IN-22 [DEF] | check-layers.sh:52-62,156; v4:393 | 6/9 | allowlist prose claims `xcb_xkb_` family; pat1 has single symbol | widen token or reword | 0..+1 | M |
| IN-23 | input.zig:225-226,274,290 | 8 | bar-window predicate recurs in 3 shapes | local `onBarWindow(win)` inline fn | 0 | L |
| IN-24 [DEF] | keybind.zig:24-27,47-51 | 4/6 | `first_index` survives only for warn; "second wins" mislabels triple conflict | drop `first_index`; reword warn | −1..−3 | M |
| IN-25 | input.zig:117-120,125; main.zig:56 | 7/8 | `setup` root param duplicates `screen.*.root` | `setup(conn, screen)` | −1..−2 | L |
| IN-26 [DEF] | check-layers.sh:156-175 | 9 | grab/allow family pattern-invisible (Rule 2 covers server grabs only) | informational | 0 | — |
| IN-27 | input.zig:198-205 | 6 | `handleKeyRelease` 6-line doc re-explains autorepeat | cross-ref xkbcommon; trim | −3..−4 | L |

## A.7 `src/model/` (MOD, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| MOD-08 | model.zig:99 | 1 | `pub const WsState` zero consumers | drop `pub` | 0 | H |
| MOD-09 | model.zig:500-506 | 1 | `swapPrimary` production-dead (test seam) | keep labeled | −17 or 0 | H |
| MOD-10 | borders.zig:32 | 7 | `_ = m.store.get(win) orelse return false` full copy for membership | `m.store.has(win)` | −1 | H |
| MOD-11 | tracking.zig:146,167; window.zig:1358; bar.zig:760,768 | 2 | `mask & bit(ws)` re-derived at 5 sites | add `maskedOn(mask, ws)` | −2..−6 | M |
| MOD-12 [DEF] | tracking.zig:183-190; focus.zig:626 | 8 | focus-cycle pool omits all-view-visible ws-unrelated windows | align with `visibleEntry` or document | −1 | M |
| MOD-13 | tracking.zig:35-36 | 2/5 | `tracking.Entry` re-spells `win: u32, mask: u64` | alias `model.WindowId`/`model.Mask` | −1 | L |
| MOD-14 | workspaces.zig:33-36 | 1/7 | `workspaces.switchTo` test-only seam (8 test refs) | keep labeled | 0 | H |

## A.8 `src/tiling/` (NEW/TILI, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| NEW-15 [DEF] | master.zig:114-120 vs 282-285 | 2/4 | v4 NEW-4 authorized but NOT applied; full merge NOT behavior-preserving (min_dim floor) | safe subset: shared `emitRow`; keep both height sources | −6..−9 | M |
| NEW-16 | leaf.zig:41-42 | 6 | spliced double sentence (NEW-9 patch residue) | rewrite one coherent comment | 0 | H |
| NEW-17 | tiling_test.zig:276 | 6 | test comment cites gone `algo_scroll` header | reword | 0 | M |
| NEW-18 [DEF] | plugin.zig:392; tiling.zig:300-303 | 6/9 | Layout contract never states engine guarantees non-empty order | one clause on `Layout.compute` doc | 0 | M |
| NEW-19 | tiling_test.zig:14 | 1/9 | `else struct {}` arm unreachable (ungated unless has_tiling) | plain `@import("tiling")` | −2 | M |
| NEW-20 | fib.zig:58-59 | 8/4 | fib builds `LayoutCtx.init` inline; master/leaf hoist | hoist `const ctx` | −1 | L |
| NEW-21 | grid.zig:30-35,43 | 5 | `cell_w_here` holds spacing stride; near-identical names | rename `spacing_w` | 0 | L |
| TILI-22 | tiling.zig:182-184 | 1/8 | `paneCell` single-consumer engine helper | keep (layout vocabulary); note only | 0 | L |
| TILI-23 | scroll.zig:90-98 | 2 | preReconcileHook re-clamps already-clamped value | keep (documented) | 0 | L |

## A.9 `src/window/` — core (WINC, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| WINC-13 | window.zig:324 | 1 | `isValidManagedWindow` zero out-of-file consumers | drop `pub` | 0 | H |
| WINC-14 [DEF] | window.zig:1082 | correctness | `.ignored` ConfigureRequest writes wincache bw but not sync ledger (transient diverge) | fold into WINC-09 merge | 1 | H |
| WINC-15 | sync.zig:356 | 6 | "Send order: map -> pixel -> bw -> geometry" stale vs folded geom_bordered emission | rephrase to folded order | 0 | H |
| WINC-16 | window/actions/focus/tracking headers | 6 | "read-only model gate" prose duplicated 4× | single-source in model doc (or accept house style) | 0 | H |

## A.10 `src/window/` — modules (WINM, wave 2)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| WINM-10 [DEF] | fullscreen.zig:38-47,101-142,172-243,282-326,435-462 | 1/2/8/9 | `g_recs` store duplicates model truth; rec⇔presence only diverges post-restart where presence is the correct discriminator | eliminate `Rec` store, model-authority (subsumes WINM-1+2+9 cluster) | −90..−110 | M |
| WINM-11 | fullscreen.zig:234-243 | 1/2 | `coverageOn` third OR-semantics occupant scan (model_test only) | fold into WINM-10 or pin as seam | −9 or 0 | M |
| WINM-12 | minimize.zig:165-179 | 3 | `bestSeq` comptime `skip_covering` for 2 sites | plain bool | −1 | H |
| WINM-13 | minimize.zig:304-316 | 7/2 | `hideWindow` adapter removable if Zig coerces error sets (build-locked) | test then drop | −3 | L |
| WINM-14 | floating.zig:250 | 4 | `sizeHintLimits` `store.get(win).?` panics on withdraw-mid-drag | `orelse` fallback | 0+ | M |
| WINM-15 | fullscreen.zig:282-288 | 7 | `serializePreamble` copies whole Entry | return only needed fields | −1 | H |
| WINM-16 | fullscreen.zig:219-243 | 8/9 | AND/OR occupant split is documented | keep hook; no change | 0 | H |
| WINM-17 | minimize.zig:236 | 6 | min doc drift: "called by bar.zig" — actually via adapter | reword | 0 | H |
| WINM-18 | fullscreen.zig:1-4 | 6 | header overstates isolation | amend wording | 0 | H |
| WINM-19 | — | 1 | test-seam pub (`switchTo`/`count`/`coverageOn`) required by tests | keep | 0 | H |

## A.11 Cross-cutting / whole-codebase (CC-v5)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|-----|----------|-------|
| CC-v5-1 | model.zig:10; core.zig:31 | 9 | `WindowId = u32` redeclared in two layers (WorkspaceId precedent: one ids.zig authority) | `ids.WindowId`, alias in both layers | ~4 | H |
| CC-v5-2 | window.zig:39-78 vs bar.zig:111-118 | 2 | two dispatch-helper families (enum-tag vs comptime-string) | cross-ref comments; optional later unify | 10 docs | MED |
| CC-v5-3 | src/core/logs/atlauncher.log | 1 | committed unrelated ATLauncher JVM log | `git rm`; ignore logs/ | 1 file | H |
| CC-v5-4 [DEF] | build.zig:239-273 | 9 | `test_gates` hand-written; adding a test file needs 2nd site edit; stale rows silent | derive table keys from discovered `*_test` stems + assert | ~30 | HIGH |
| CC-v5-5 [DEF] | plugin.zig:135-190 | 9 | single-binder hooks enforced by prose only; 2 binders silently first-match | comptime `countTrue(non-null)<=1` asserts in registry generation | ~25-40 | HIGH |
| CC-v5-6 | prompt.zig:1223 | 6 | `(B2)` production marker (CC-v4-7 residue) | delete | 0 | HIGH |
| CC-v5-7 | IMPROVEMENTS.md:278,362,363 | 10 | stale OPEN rows (3 workspace-id types / S01-21 recapture / CI non-gating / borders) | re-triage | docs | HIGH |
| CC-v5-8 | plugin.zig:330; segdraw.zig:78; slider.zig:313,404 | 2 | natural-width in 3 spellings | rename slider fn `naturalWidth` (3 sites) | ~5 | HIGH |
| CC-v5-9 | model.zig:370; fullscreen.zig:219; actions.zig:39-41; borders.zig:25 | 2 | occupant-query 4 spellings 2 semantics | doc cross-ref now; unify later | 1 doc | HIGH |
| CC-v5-10 [DEF] | check-layers.sh:60,156 | 9 | "Rides pat-wide via xcb_xkb_ family" half-false | add `xcb_get_extension_data` to pat1 or tighten comment | 1-2 | HIGH |

---

# B. Ranked implementation order (this session executes the green rows)

**Phase 1 — zero-risk deletions, de-pub, hygiene, comments/header fixes (no semantic risk):**
BARCR-18, 19, 23, 24, 25, 30, 32, 33, 35, 36; BARMOD-21..32; CFG-37, 38, 41, 42, 43, 44, 45;
COREH-12, 13, 16, 20, 23, 24; COREP-16, 17, 18, 19, 20, 23, 24; IN-18, 20, 21, 25, 27;
MOD-08, 10, 13; NEW-16, 17, 19, 20, 21; WINC-13, 15, 16; WINM-12, 14, 15, 17, 18;
CC-v5-1, 3, 6, 7, 8, 9.

**Phase 2 — consolidation (behavior-preserving, suite-pinned):**
BARCR-20, 21, 22, 26, 27, 28, 29; BARCR-34 (FrameState→segmod.Frame, careful);
NEW-15 safe subset (shared `emitRow`); NEW-15b (NEW-4 resolved: unify where safe, corner documented).

**Phase 3 — v4-authorized-but-not-applied (owner already answered; tree lacks it):**
COREP-21 (COREP-10 sorted ledger); CC-v5-4/5 halves per owner yes-if → see §C.

**Phase 4 — documentation & plan maintenance:**
CFG-46 reword (after owner answer); IMPROVEMENTS.md triage; README/config README as flagged.

---

# C. Deferred items & questions (dedicated section — decisions recorded)

> Items that touch a public contract, a build gate/guard policy, recorded behavior,
> a current in-flight seam, or need a measured benchmark. The owner is away; these
> are recorded for the next round. Where v4 already answered, the answer is quoted.

1. **BARCR-31** — keep `.{ .with_collapse = false }` vs `.{}` (0 LOC, deliberate mirror of variants' `true`). → do `.{}` (white-noise; recorded).
2. **COREP-21 (v4 COREP-10)** — [v4 §C: "→ do the sorted-ledger rewrite (drop 2nd id-index / IdMap / tombstone)"]. Tree lacks it. Proceed unless the auth window has lapsed; sync-vault rewrite, tests pin (sync_test/tracking_test/perf_test).
3. **COREP-22 (v4 WINC-09)** — [v4 §C: "→ merge now (fold the border-width/border-size owner structs)"]. Tree lacks it. Interacts with the newly-landed `geom_bordered` sink slot.
4. **X11-01 / CC-v5-10 (guard policy)** — widen pat1 with `xcb_get_extension_data` (fail-loud) vs trim the prose. v4 pre-owned IN-11/CC-v4-1 allowed same pattern-based entries with a documented warrant; recommend widen + warrant.
5. **WINM-10 / WINM-1+2+9** — the agent recommends re-opening §C.20 in favor of FULL `g_recs` elimination (model-authority, no seam, fixes restart ghost by construction, −90..−110). Founder earlier answered "do the cluster"; full elimination is a superset — owner confirm.
6. **CC-v5-4/5 (build gates)** — comptime single-binder asserts + deriving `test_gates` from discovered test stems. v4 answered "do both" but not applied. Build-side `[DEF]`.
7. **CFG-36** — `[Keybindings]` alias exemption (parser warning behavior), vs treat as legacy.
8. **CFG-39/40** — `known_sections` comptime concat vs literal greppability; grammar⊆registry assert.
9. **CFG-46** — akai.toml/README bare-`RRGGBB` claim vs accepting bare hex in parser.
10. **MOD-12** — focus-cycle pool all-view exclusion: align with `visibleEntry` vs document.
11. **MOD-09 / MOD-14** — `swapPrimary`/`switchTo` keep-as-labeled-test-seam.
12. **NEW-15 beyond-safe-subset** — accumulator-everywhere (geometry change in min_dim-floor corner) vs shared `emitRow` only.
13. **NEW-18** — contract clause (non-empty order guarantee) on `Layout.compute` doc + template.
14. **IN-22/24/26** — pat token family widening; warn-text wording + `first_index` drop; grab/allow family pattern-invisible policy.
15. **COREH-15/22** — `surfaces.handlePropertyNotify` dead-seam cut; plugin.zig dispatch helpers.
16. **BARCR-16 (v4)** — center double-measure: measure → cache → re-measure → decide (bench-pinned; owner criteria: keep iff commensurate).
17. **WINM-13** — `hideWindow` adapter removal needs a build to test error-set coercion (headless build available next session).
18. **CC-v5-2** — dispatch-helper unify is optional phase-2-lite; cross-ref docs only.

---

# D. Execution status (filled as this session proceeds)

- **Baseline**: clean tree `fc7a68af`; fmt clean; `zig build check` green; headless `zig build test` exit 0.
- **Phase 1 — DONE (all items, gates green)**: 1a bar core (BARCR-18/19/20/21/22/23/24/25/26/27/28/29/30/32/33/35), 1b bar modules (BARMOD-21..32), 1c config (CFG-37/38/41/42/43/44/45), 1d core hub (COREH-12/13/16/20/23/24), 1e core plumbing (COREP-16/17/18/19/20/23), 1f input (IN-18/20/21/25/27), 1g model/window/tiling/modules (MOD-08/10/13, WINC-13/15/16, NEW-16/17/19/20/21, WINM-12/14/15/17/18), 1h contract (CC-v5-1/3/6/7/8/9).
- **Phase 2 — DONE**: BARCR-34 (FrameState now holds one `segmod.Frame`; ws_has_windows is the bar-local backing array it slices), NEW-15 (shared `emitRow` in master.zig, height sources kept separate), NEW-15b (corner documented on `emitRow`).
- **Phase 3 — DONE**: COREP-21 (ledger sorted by construction — binary-search `lowerBound`, `orderedRemove`, `sent_index`/IdMap dropped, 2 ledger-index tests removed), COREP-22 (wincache `applied_border_width`/`cacheBorderWidth` removed; sync ledger is the sole "last border width" owner; `borders.applyWidth` dedups via `sync.sentGet`).
- **Build gates — DONE**: CC-v5-4 (`test_gates` keys asserted against discovered `*_test` stems; stale rows fail the build), CC-v5-5 (`plugin.single_binder_hooks` comptime asserted <= 1 binder by the generated `window_modules` registry).
- **Verification**: `zig fmt --check .` 0; `zig build test` 0; `zig build check` 0; `zig build` 0 — final state after all phases.
- **§C decisions taken this session**: #1 (BARCR-31 recorded `.{}` preferred), #2/#3 (COREP-21/22 done per v4 auth), #4 (X11-01/pat1 — NOT taken, deferred; needs owner), #7/#8 (CFG-36/39/40 — NOT taken, deferred), #13 (NEW-18 contract clause — NOT applied, deferred; template v5 still lacks it), #14 (IN-22/24/26 — deferred), #17 (WINM-13 — not tested/headless), others as recorded/kept per ownership.
- **Promoted to NOTED**: CC-v5-8 slider natural-width unification adopted the coherent form (camelCase `probeNaturalWidth` field rename, 4 sites) because renaming the slider fn itself to `naturalWidth` collides with the adapter hook of the same name in the generated Hooks struct; net effect (single camelCase spelling family) matches intent.

Commits: the campaign is uncommitted; tree carries the full diff (see `git status`).