# hana — Simplification Task List v6 (sixth audit campaign)

Date: 2026-09-23. Method: this campaign deployed **one analysis agent per `src/`
subsystem plus a whole-codebase interconnection agent** (11 research agents): `bar`
(split: bar-core engine vs bar-modules), `config`, `core` (split: hub/service vs
plumbing `sync`/`x11`/`utils`), `input`, `model`, `tiling`, `window` (split:
window-core vs window modules), plus one agent for the build/scripts/contracts/docs
interconnection view. Every finding was verified against the live tree (`rg` +
full-file reads) by its owning agent before listing; every v5 item was re-verified as
applied (or not) before being excluded from re-analysis.

Baseline (this campaign's start): clean tree at `64755cf fix focus_test no_input`;
`zig fmt --check .` clean; `zig build check` exit 0; headless `zig build test` exit 0;
`tokei src -f -s code --exclude src/test/` ≈ 16,972 code LOC.

Mandate (unchanged): reduce LOC while preserving identical behavior, or improve human
readability. Risk and effort are not constraints. Inviolable: the sync boundary (raw
wire sends stay behind `src/core/sync/` + `check-layers.sh` allowlist), pure
`model`/`tiling`/`config` layers (xcb-free), the core never naming an optional module
(deletion-modularity), no TODO/FIXME, `zig fmt` clean.

## Evaluation axes (every finding assessed on all of these)

1. DEAD CODE — unused exports, params, fields, imports, arms, branches (rg-verified).
2. DUPLICATION — near-identical functions, repeated literals/concepts, parallel truths.
3. OVER-ENGINEERING — comptime/generic/indirection net-negative at this scale.
4. READABILITY — bare bools, huge functions, dense hot loops, magic numbers.
5. NAMING — near-identical names for distinct roles, inverted-voice predicates.
6. COMMENT QUALITY — stale/contradictory headers, unresolvable markers, drift vs reality.
7. API ERGONOMICS — `!`-typed functions that cannot error, `null`/sentinel overload, dead params.
8. CONSOLIDATION — small files/functions that merge cleanly; single-source-of-truth.
9. STRUCTURAL / LAYERING — header truth vs guard script, seams, switchboards, contracts.
10. DOC DRIFT — planning/notes/README files that no longer match the tree.

## Verification gates (every change batch)

1. `zig fmt --check .` clean.
2. `zig build check` — exit 0 (check-layers + plugin-template).
3. `zig build test` — headless exit 0 (X-gated tests self-skip).
4. `tokei src -f -s code --exclude src/test/` — LOC delta reported per phase.
5. `dev/scripts/check-modularity.sh` where a contract/build surface changes.

---

# A. Findings by subsystem

## A.1 `src/bar/` — core engine (BAR-N, this campaign)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| BAR-N1 | bar.zig:797-818 | 1/7 | `drawSegmentSafe` `!u16`-swallowing wrapper; `drawSegment` has no other caller | merge the catch into `drawSegment` | −8 | H |
| BAR-N2 | drawing.zig:748-767, 826-847 | 2/8 | `drawPaddedSegment` / `drawPaddedSegmentCovering` ~85% identical | shared `drawPaddedSegmentImpl(…, cover_text: ?[]const u8)` + thin wrappers | −8 | M |
| BAR-N3 | bar.zig:836-847 | 6/10 | failure-path doc claims right-cluster gap handling matches center; code differs | doc fix | 0 | H |
| BAR-N4 | bar.zig:852-857 | 1/6 | `advancedX` sole caller only reaches `drew` branch; `else` runtime-dead; stale doc | inline into `drawRowSegment` | −8 | H |
| BAR-N5 | bar.zig:902 | 1 | `extendDirtySpan` immediately before `paintGap` = span union no-op | delete line | −1 | H |
| BAR-N6 | bar.zig:1373 | 1 | `s.dirty.flag = false` after `performDraw()` provably dead | delete line | −1 | H |
| BAR-N7 | bar.zig:1639-1641 | 1 | `s.dirty.flag = false` before `submitDraw()` redundant/defensive | delete (owner confirm) | −1 | L |
| BAR-N8 | bar.zig:1569-1576 | 2/8 | `hideBarForFullscreen` body == `applyVisibility(s, false, false)` | delegate | −4 | M |
| BAR-N9 | bar.zig:1557-1595 | 2/8 | `updateBarVisibilityForWorkspace` / `applyFullscreenVisibility` twins | shared `applyVisibilityDecision(ws, do_reconcile) bool` core | −5 | M |
| BAR-N10 | segdraw.zig:57,116; clock.zig:228 | 1 | `Opts.clickable` never set away from plugin default `true` | remove field + forwarding + `clock` explicit set | −3 | M |
| BAR-N11 | bar.zig:409 | 10 | `span_w` doc "0 means whole bar" wrong; 0 is unset sentinel | doc fix | 0 | H |
| BAR-N12 | bar.zig:1114-1116 | 5 | `submitDraw` one-line alias of `performDraw` | remove alias | −3 | L |
| BAR-N13 | win.zig:22,36; drawing.zig loadFonts/paintedSegment | 1 | de-pub members with no out-of-module consumers | de-pub | 0 | H |

## A.2 `src/bar/` — modules (BARMOD-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| BARMOD-T01 | vim.zig:197-202 | 1/4 | `commitMotion` never uses `vs` (`_ = vs;`); 4 call sites | drop param | −4 | H |
| BARMOD-T02 | prompt.zig:602-605 | 1 | `runPromptCommand` single-use 4-line wrapper | inline `.spawn` arm (keep `cmd.len > 0` guard) | −3 | MH |
| BARMOD-T03 | slider.zig:418-422 | 4 | infallible `bufPrint` if/else with empty `else` arm | `catch return x + slot` | −3 | H |
| BARMOD-T04 | prompt.zig:254 | 10 | `num_modes` doc cites vim.Mode; derives from prompt.Mode | reword | 0 | H |
| BARMOD-T05 | variants.zig:28 | 4 | `pipeline.model()` called twice | hoist const | 0 | M |
| BARMOD-T06 | prompt.zig:77,212 | 6 | Handler defaults style: named `onDeactivate` no-op vs anonymous siblings | inline | 0 | LM |

## A.3 `src/config/` (CFG-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| CFG-N1 | types.zig:441-469 | 2 | `freeSegmentColors`/`freeSegmentProps` identical bodies | comptime generic `freeSegmentMap(V)` | −12..−14 | H |
| CFG-N2 | parser.zig:104-114 | 1 | `Section.init` 4× identical map-init + `ensureTotalCapacity` | shared helper (keep 4 warn labels) | −8 | H |
| CFG-N3 | parser.zig:497-557 | 1 | `mixColors`/`resolveColorExpr` both scan weights | shared scan+validation step | −4..−6 | M |
| CFG-N4 | parser.zig:197-207 | 1 | `warnScalarDuplicate` two near-identical branches | one warn + comptime optional section slot | −4 | H |
| CFG-DA | config/config.toml:50,68-70,74,78,82 | 10 | stale `indicator` comment lines (knob removed) | delete | 0 | H |
| CFG-DB | config.toml:65,87-88; config/README.md:41; themes/akai.toml:14 | 10 | 'px'/'Npx' exact-pixel doc claims parser does not implement | [DEFERRED] implement px or fix docs | — | — |

## A.4 `src/core/` — hub/service (COREH-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| EVS-01 | contract.zig:61; events.zig:81-89 | 1 | `Surfaces.handlePropertyNotify` bound by no module; dead forward | delete field + forward | −6 | H |
| PIP-01 | pipeline.zig:69-79 | 2 | `getCurrentLayout` redundant `!has_tiling` guard (delegated fn guards already) | drop guard, delegate | −2 | H |
| EVS-02 | events.zig:548-558 | 1 | queued-drain `queued_pending` local dead-by-construction | comptime-gate drain's `pending` param | −1 | M |
| CR-01 | core.zig:62-73 | 6 | `State.facts` doc block restates `Facts` struct intro | shrink to one line | −2 | H |
| PS-01 | persist.zig:279-284 | 4 | reads `loaded_parsed.?.value` after `= parsed;` | `parsed.value` | 0 | H |
| SCR-01 | screen.zig:36; bar.zig:1203,1354 | 7 | `bar_id: ?u8` only for bar's `.?` in comptime-0 path | `pub const bar_id: u8 = 0`, drop `.?` | −2 | M |
| RS-01 | restart.zig:55; main.zig:79 | 7 | `init(alloc)` param unused-duplicated (module already uses c_allocator) | drop param | −2 | M |
| CR-02 | core.zig:150 | 3 | `dpi_info` write-once read-only, single-threaded; `std.atomic.Value(f32)` | plain `pub var f32` | 0 | M |

## A.5 `src/core/` — plumbing (COREP-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| C-01 | proc.zig:22-26; events.zig:620-626 | 10 | wake-byte doc claims byte dispatch; mechanism is bitmap + discard-only drain | rewrite doc | 0 | H |
| C-02 | sync.zig:150-226 | 2/8 | sent ledger re-invents `model.Store` sorted-keyed array + duplicated `.id` key | back `State.sent` with `model.Store(SentEntry, cap)`; drop `lowerBound`/`sentSlot`/`.id` | −34 | MH |
| C-03 | sync.zig:219-234 | 8 | `forget` one-line wrapper over private `sentSwapRemove` (only caller) | fold body into `forget` | −7 | H |
| C-04 | sync.zig:466-480 | 7/8 | `lastRectFor`/`lastBorderWidthFor` duplicate 3-line guard | private `visibleSent(win)` helper | −4 | H |
| C-05 | wire.zig:93 | 1 | `pub ungrabServer` zero consumers | de-pub; trim pairing note | 0 | H |
| C-06 | paths.zig:11 | 1 | `pub common_dirs` zero external consumers | de-pub | 0 | H |
| C-07 | bounded.zig:122,156 | 1/3 | `removeWhere`/`removeAllWhere` still pub, production only uses id-field wrappers | finish de-pub (COREP-23 bookkeeping); drop generic test block | 0 | M |
| C-08 | check-layers.sh:69-75; sink.zig:6 | 10 | Rule-1 prose names `pushWindowOffscreen*` (gone); sink "allowlist covers this file" imprecise | reword both | 0 | H |
| C-09 | wire.zig:6 | 10 | header claims "offscreen request shims live here"; park lives in sink | drop "offscreen" | 0 | H |
| C-10 | wire.zig:215-231,281-284 | 8 | `supported_atoms` parallel spelling of AtomCache fields; typo → silent NONE | comptime assert subset (owner) | +3 | M |
| C-11 | sync.zig:357-366 | 4 | 3-deep nested winner-seed `if` chain | braced blocks / named predicate | 0 | M |
| C-12 | sync.zig:404-406 | 4 | redundant `visibleEntry`/`visibleOn` recomputes per window | thread `on_current` through desire fns (owner) | 0 | M |
| C-13 | sync.zig:453 | 6 | ledger-full `debug.err` per window per pass | hoist one warn (owner) | 0 | L |

## A.6 `src/input/` (IN-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| ER-01 | xkbcommon.zig:215-296 | 3/8 | `retryPoll` generic + 3 closures over flat loops | 3 flat `for` loops; delete machinery | −15..−22 | H |
| ER-02 | input.zig:224,272,288 | 8 | bar-window predicate in 3 shapes (negated + positive) | local `inline fn onBarWindow(win)` | −1..−2 | H |
| ER-03 | keybind.zig:22-54 | 1/4/6 | `Entry.first_index` only feeds a misleading conflict warn ("second wins") | drop `Entry`, map value = `*const Action`, reword warn | −2..−4 | H |
| ER-05 | keysyms.zig:20,28 | 1/5 | private alias `xkb_keysym_case_insensitive` re-names imported const (single use) | inline | −1 | H |
| ER-06 | input.zig:303-334 | 2/1 | `sendWmDelete`/`forceDestroy` single-caller wrappers | fold into `closeWindow` | −4..−6 | M |
| ER-07 | input.zig:176 | 7 | redundant type annotation on `const matched` | drop | 0 | H |
| ER-08 | input.zig:244 | 1 | `clicked_window == 0` unreachable (child-or-event, both ≥ 1) | drop from guard | 0 | M |
| ER-09 | input.zig:303 vs 311 | 10 | ICCCM §4.1.2.7 vs §4.1.7 citation mismatch | unify | 0 | M |
| ER-10 | input.zig:517 | 5 | `screen.*.root` vs `screen.root` inconsistency | drop `.*` | 0 | H |
| ER-12 | input.zig:437-438 | 4 | `pipeline.model()` fetched twice in adjacent args | hoist | 0 | H |

## A.7 `src/model/` (MOD-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| MODAud-01 | model.zig:127-191 | 2/4 | `exactAt` + `lowerBound` two binary-search loops; `put` runs both; `register` on hot path | single search in `put`; `exactAt` = lowerBound + equality | −6..−8 | H |
| MODAud-02 | model.zig:161-167 | 6 | pointer-relocation contract self-contradictory | rewrite in 3 precise sentences | 0 | H |
| MODAud-05 | model.zig:498-507 | 1/6 | `swapPrimary` production-dead, unlabeled vs `swapFocusedWithPrevious` | label test-seam (or delete) | 0 | H |
| MODAud-06 | model.zig:19-21 | 6 | `bit()` documents no precondition on ws.index | doc the < 64 clamp contract | 0 | M |
| MODAud-07 | tracking.zig:142-149 vs model.zig:350-357 | 2/10 | two "count windows on ws" fns no cross-ref | one-line cross-ref each | +0..+1 | M |
| MODAud-08 | tracking.zig:146,167; window.zig:1355; bar.zig:768,776 | 2 | MOD-11: `mask & bit(ws)` re-derived at 4-5 sites | `model.maskedOn(mask, ws)` | −2..−6 | M |
| MODAud-10 | constants.zig:107-111 | 10 | `max_tiled_windows` "whole WM combined" doc stale (per-ws consumers) | reword | 0 | H |
| MODAud-11 | actions.zig:542 | 4/5 | primary-count clamp `store_capacity / 4` coupled to registry size | named const | 0 | L |
| MODAud-12 | model.zig:251-252 | 4 | `store_capacity`/`mru_capacity` magic numbers | rationale comments | +0..+1 | L |

## A.8 `src/tiling/` (TIL-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| TIL-01 | contract.zig:404-407 | 10 | `Layout.compute` doc names a `params` param that does not exist (stale; real preReconcile is by-value) | fix doc | −1 | H |
| TIL-02 | tiling.zig:231-233 | 6 | `layoutByName` doc self-contradicts (case-insensitive vs exact lowercased) | collapse to one sentence | 0 | H |
| TIL-03 | tiling.zig:263-265 | 3/7 | `defaultKind()` 3-line fn returning literal 0 | fold into `layoutKindOf` doc/fallback | −3 | M |
| TIL-04 | master.zig:304-311; grid.zig:45-51; fibonacci.zig:89-94; scroll.zig:82 | 2/8/9 | 5× hand-built `utils.Rect` + `satI16` + `emitView` (master-local emitRow) | shared `tiling.emitRect` helper | −10..−13 | M |
| TIL-05 | master.zig:40-43 | 4/8 | `blk:` labeled-block expression for one intermediate | inline | −2 | M |
| TIL-06 | fibonacci.zig:87-97 | 4/7 | `advance` 1-use intermediate; fn takes `(v, out)` not `ctx` | fold; pass ctx | −1..−3 | M |
| TIL-07 | master.zig:49,82 | 2 | `windows[master_n..]` re-sliced twice | hoist const | −1 | H |
| TIL-08 | tiling.zig:84-88 | 5/9 | `LayoutCtx` doc claims "every module needs" scalars half the modules never touch | reword doc | 0 | M |
| TIL-09 | tiling.zig:13-14; model.zig:27-29; window.zig:1285-1289 | 6/10 | "tiling ignores PMinSize" policy duplicated 3× | single-source in model SizeHints doc | 0 | M |

## A.9 `src/window/` — core (WINC-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| D1 | focus.zig:8 | 1 | dead `constants` import | delete | −1 | H |
| D2 | tracking.zig:8-10 | 1 | dead `build_options`/`wincache`/`utils` imports | delete | −3 | H |
| D3 | window.zig:89 | 1 | `pub` re-export `fireWMProtocolsQuery` zero external consumers | drop pub | 0 | H |
| D4 | window.zig:346,440 | 1 | `AdmissionRule`/`AdmissionDecision` pub zero references | drop pub | 0 | H |
| D5 | wincache.zig:26,36 | 1 | `pub WindowData`/`CacheMap` zero type-name references | drop pub | 0 | H |
| O1 | focus.zig:468-500,603 | 3 | single-use generic async-drain machinery (`PollResult`+`pollCookie`+`drainCookie`) | inline into `drainTilingOpSettle` | −20 | H |
| R1 | borders.zig:29-57; window.zig:1348-1370 | 4/2 | border sweep O(N²): `coveredByOccupant` full model scan per window per batch | precompute per-sweep occupied bit set; O(1) lookups | −6..−10 | M |
| R2 | focus.zig:625-651 | 2/4 | cycle pool re-derives window membership per keypress | consume `allWindows()` Entry fields directly | −7 | H |
| X1 | icccm.zig:320-330 | 2 | hand-declared 7-arg `xcb_get_property` vs module's own `firePropQuery` | delegate | −5 | H |
| X2 | window.zig:1259-1271 | 2 | `refreshSizeHints` re-declares `firePropQuery` request | delegate | −4 | H |
| N1 | borders.zig:29 | 5 | `coveredByOccupant` passive vs `coveringOccupantOnWs` active voice family | rename `isBehindCoveringWindow` | 0 | H |
| N2 | focus.zig:664 | 4/5 | `cycleTarget(forward: bool)` bare-bool public API | accept caller's direction enum | 0 | M |
| QA1 | focus.zig:371-377 | 4 | `shouldRaise` computed twice in dedup branch | hoist const | 0 | H |
| QG1 | tracking.zig:1-2 | 10 | header "Every query reads pipeline.model()" false for count store | amend | 0 | H |
| DG1 | wincache.zig:118-120 | 10 | `removeWindow` doc lists geometry among evicted entries | drop one word | 0 | H |

## A.10 `src/window/` — modules (WINM-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| FULL-01 | fullscreen.zig all | 1/2/8/9 | `g_recs` dual-store provably redundant with model (`e.anchor`==rec.anchor by gate analysis; `covering_ws` model-owned); persistence blob fully covered by `WindowRecord`; restart-ghost needs two toggle-offs today | **Model single authority**: pure store-order AND-scans; drop `Rec`/`MAX_FULLSCREEN`/`g_recs`/persistence seam + blob bindings; rewrite header; fixes ghost | **−143..−161** | H |
| MIN-01 | minimize.zig:236-245,308-316 | 1/2 | `collectMinimizedIntoSet` (`anyerror!void` swallowed) single consumer via adapter | merge into one infallible fn | −8..−10 | H |
| MIN-02 | minimize.zig:301-306,326 | 7 | `hideWindow` error-set-narrowing adapter for hook binding | try direct bind (Zig 0.16 coercion); drop adapter | −4..−5 | L (build-gated) |
| MIN-04 | minimize.zig:275-293 | 7 | scratch-buffer+memcpy decode | `std.mem.bytesToValue` | −2..−3 | M |
| WS-01 | workspaces.zig:76-83 | 2 | double `providerOf` (isCoveringMode then coveringWsOf) | one `coveringWsOf` lookup + nil test | −2..−3 | H |
| FLOAT-02 | floating.zig:249 | 5 | anonymous return struct for size hints | name `HintLimits` once | 0 | H |

## A.11 Cross-cutting / whole-codebase (CC-v6)

| ID | Location | Axis | Issue | Fix | Est. LOC | Conf. |
|----|----------|------|-------|------|----------|-------|
| CC-01 | build.zig:585,865,1058 | 2 | three byte-identical `std.mem.sort` comparators | shared `sortStrings` helper | −6 | H |
| CC-02 | check-modularity.sh:65-76 | 10 | rsync excludes omit `.opencode/` and `*.swp*` → 31 scenario copies re-copy ~34 MB junk | add excludes (junk deletion deferred) | 1-2 | H |
| CC-03 | IMPROVEMENTS.md:14; SIMPLIFICATION_PLAN_v5.md | 10 | scenario count drift (26 vs 31, "8 slice combos") | recount / define umbrella | 0 | H |
| CC-04 | README.md:184 vs check-layers.sh:214 | 10 | README says "whole tree fmt by check"; Rule 4 fmt-checks only `src/` | fix README claim | 1 | M |
| CC-05 | build.zig.zon / config tomls | 10 | `.links` mirror now real (verified); keep | — | 0 | H |

---

# B. Ranked implementation order (this session executes all green rows)

**Phase 1 — zero-risk deletions, de-pub, hygiene, comments (no semantic risk):**
BAR-N1..N13 (except N7); BARMOD-T01..T06 (except T06 optional); CFG-N1..N4 + CFG-DA;
EVS-01, PIP-01, CR-01, PS-01, SCR-01, RS-01, CR-02; C-01, C-03, C-04, C-05, C-06,
C-07, C-08, C-09, C-11; ER-01..ER-12 (except ER-11 optional); MODAud-02, -05, -06,
-07, -08, -10, -11, -12; TIL-01..TIL-09 (except TIL-10); D1..D5, O1, R2, X1, X2, N1,
N2, QA1, QG1, DG1; MIN-01, MIN-04, WS-01, FLOAT-02; CC-01..CC-05.

**Phase 2 — model-layer prereqs:** MODAud-01 (single-search `put`), MODAud-02 doc fix.

**Phase 3 — the two big consolidations:**
- C-02: sent ledger recomposed on `model.Store` (`getPtr`-then-`put`-only-on-miss;
  `SentEntry.id` dropped; tests pin sync/tracking/perf/pipeline).
- FULL-01: fullscreen `g_recs` + persistence-seam elimination (model-authority;
  `persist.applyModelLevel` verified to restore `covering_ws` independently).

**Phase 4 — documentation & plan maintenance:**
CFG-DA, MODAud-10, QG1, C-08/C-09, CC-02 script excludes, CC-03, CC-04, PG-01/C-01.

---

# C. Deferred items & questions (dedicated section)

> Items that touch a public contract, a build gate/guard policy, recorded behavior,
> a persisted format, or need a measured benchmark. Recorded for the next round.
>
> All 24 items disposed 2026-09-23 — see the "§C batch (2026-09-23) — COMPLETE"
> record in §D.

1. **CFG-DB (px doc drift)** — docs advertise `px`/`Npx` exact-pixel syntax the
   parser refuses. Fix = implement a trailing-`px` branch + tests, or correct the
   docs. The theme + config README read intentional → owner decides.
2. **CFG-46 disposition** — bare `RRGGBB` IS accepted except all-digit spellings
   (read as decimal `0x1B669` for `112233`). Make `colorFromValue` prefer hex for
   all-digit tokens, or keep decimal + doc caveat.
3. **FULL-01 test-churn / blob-format blessing** — the persistence blob drop is an
   internal re-exec format; `persist.WindowRecord.covering_ws`+`anchor` already
   covers every byte it encoded, and the ghost-restore single-toggle-off is a
   bugfix, but blessing the format change + the ~3 test-file edits is requested.
4. **C-02/`SentEntry.id` drop + ledger backing swap** — approved by the model agent
   with `getPtr`-then-`put` rules; sacred-file authorization requested for the
   record.
5. **C-10** — comptime `supported_atoms ⊆ AtomCache` assert (+3 LOC, guards a
   silent `XCB_ATOM_NONE` on typos): add, or keep the curated doc list?
6. **C-12** — thread the fast-path `on_current` into `computeDesire` to drop up to
   two redundant `visibleEntry`/`visibleOn` per window per pass (adds a param to a
   hot fn for 0 LOC).
7. **C-13** — ledger-full `debug.err` per window per pass: single warn per pass, or
   keep per-window loudness?
8. **EVS-02** — comptime-gate `drainEvents`' `pending` param (−1 LOC, touches the
   hair-trigger two-loop drain).
9. **BAR-N7** — remove the defensive `s.dirty.flag = false` in `updateIfDirty`?
10. **ER-11** — comptime-handler `barForward` consolidation (vs 6 labeled lines).
11. **ER-04 / CC-v5-10 (guard policy)** — widen `check-layers.sh` pat1 with
    `xcb_get_extension_data` + reword xkbfamily claim, or trim prose only.
12. **NEW-6 shipping scope** — check-layers Rule 4 whole-tree fmt vs README reword
    (fixed README already; widening the guard is optional).
13. **NEW-5** — merge the two comment-strippers in check-layers.sh.
14. **MOD-12** — focus-cycle pool ignores `all_view_active` while `visibleEntry`
    honors it: align, or document the divergence.
15. **MODAud-03** — relocate `model.Store` to `core/utils/bounded.zig` + alias
    (≈0 LOC, layer tidiness; deferred to avoid import churn mid-refactor).
16. **MODAud-04** — rename `Store.slotOf` → `indexOf` (subjective; touches tests).
17. **MODAud-09** — `Store.clear` zero consumers: annotate or delete.
18. **TIL-10** — boost-path pixel-diff readability split (+1, dense-register style
    may be deliberate).
19. **NEW-18 contract clause** — add the "non-empty canonical order" guarantee to
    `Layout.compute` doc + template.
20. **R1 correctness edge** — the home-ws covering quirk (multi-tagged window whose
    home ws has a covering occupant renders borderless even when visible
    elsewhere): preserve as-is (hoist keeps it) or "fix" semantics?
21. **ER-01 4th operation** — was `retryPoll`'s genericity for a planned 4th retried
    XKB op? Flattened per Phase 1; if expansion is real the generic returns.
22. **PIP-02** — bool-pair params of `reconcileUnderGrabNowFullscreen` → `kind`
    enum (naming; overlaps COREH-19 which stays unapplied).
23. **COREH-17/18/19/22, COREH-14, NEW-15b-extended** — prior v5 §C items remain
    open as recorded; re-listed for awareness, no action taken.
24. **Junk deletion** — the untracked `config/themes/.opencode/` (~34 MB),
    root `.opencode/`, and `src/core/*.swp` files: rsync excludes added (CC-02);
    actually deleting them is deferred to the owner (workspace files).

---

# D. Execution status (filled as this session proceeds)

- **Baseline**: clean tree `64755cf`; fmt clean; `zig build check` green; headless
  `zig build test` exit 0; 16,972 production LOC.
- **Phase 1 — DONE**
  - Core hub (CR-01/02, RS-01, SCR-01, PIP-01, PS-01), plumbing (C-01 proc half,
    C-03, C-04, C-05, C-06, C-07 partial, C-08, C-11), input (ER-01..03,
    ER-05..10, ER-12), model (MODAud-02, MODAud-05..08, MODAud-10..12),
    tiling (TIL-01..09), config (CFG-N1..N4, CFG-DA): **DONE**.
  - Window core (D1..D5, O1, R2, X1, X2, N1, N2, QA1, QG1, DG1), window
    modules (MIN-01, MIN-04, WS-01, FLOAT-02), cross-cutting (CC-01..05):
    **DONE**.
  - `bounded.removeWhere` re-pubbed (dev/plugin-template uses it);
    `removeAllWhere` stays private.
  - CFG-N3 owner ruling (2026-09-23): a bare operand list `[red, green]` with
    no `+`/weights is an EQUAL-WEIGHT mix (not an error); the array spelling of
    `extractMixOperands` now accepts it (test added), while the strict
    `+`/weight grammar is unchanged.
  - Fix while doing CFG-N3: `extractMixOperands` returned a slice into its own
    stack frame (use-after-return); refactored to fill a caller-provided buffer.
- **Phase 1 — DONE.** All §B batches landed through window/cross-cutting:
  window core D1..D5, O1, R2, X1, X2, N1, N2, QA1, QG1, DG1; window modules
  MIN-01, MIN-04, WS-01, FLOAT-02; cross-cutting CC-01, CC-02 (rsync excludes),
  CC-04 (README scoped to `src/`), CC-03 (the deletion-modularity matrix is
  **31 scenarios**: 26 `run_scenario` calls, the per-layout delete loop
  expanding to 6; IMPROVEMENTS.md:14/220 corrected from "26-scenario").
- **Phase 2 — DONE.** MODAud-01: `Store.put` runs a single `lowerBound`
  (in-place update or insertion from one search); `exactAt` = `lowerBound` +
  equality check.
- **Phase 3 — DONE.**
  - C-02: `State.sent` is now `model.Store(WindowId, SentEntry, cap)`; dropped
    `SentEntry.id`, `lowerBound`, `sentSlot`, `orderedRemove`; `forget` folds
    to a single store remove; `markSentVisible` dropped its `win` param (the
    doubled `forget` doc comment was also collapsed). Full test suite + bokeh
    (sync/tracking/perf shown above) green.
  - FULL-01: fullscreen has no module record store at all — the model entry IS
    the record. Dropped `Rec`/`MAX_FULLSCREEN`/`g_recs`, the persistence seam
    (`serialize/deserializeWindow` + blob consts/helpers), `coverageOn`, and
    the rec-based eviction/occupant scans. `toggleFullscreen`/`releaseCovering`
    drive `presence` + `covering_ws` directly (anchor needs no snapshot/replay:
    floating's `setFloatingRect` is gated on `presence != .covering`);
    `fullscreenOccupantOnWs` is a pure store-order AND scan; `persist`
    restores covering via `WindowRecord` (no blob), which also collapses the
    restart-ghost double-toggle. `.serializeWindow/.deserializeWindow`
    bindings removed (minimize alone claims the `ext` slot). Tests: model_test
    blob/coverageOn tests removed or repointed at the scan; fullscreen.zig
    went 464 → 283 lines.
- **Phase 4 — DONE.** §D updated; CC-04 README already fixed; tokei LOC delta
  in the closeout report.
- **§C batch (2026-09-23) — COMPLETE.** All items ruled/done. Gates green after
  the batch (fmt; `zig build check` incl. check-layers; `zig build test` exit 0).
  Dispositions:
  - 1 CFG-DB — **docs fixed** (owner ruling: the `px` label is never parsed, a
    bare number IS the pixel value). README table note + config.toml/theme
    comments reworded; no parser change.
  - 2 CFG-46 — **implemented** (owner ruling): `colorFromValue` reads a bare
    6-digit number as `#RRGGBB` hex and 8-digit as `#RRGGBBAA` hex; any other
    bare integral color is INVALID (warn+default, no silent decimal coerce);
    `0xRRGGBB` remains the numeric path. schema warn text + my README bullet
    updated; parser_test "colorFromValue: bare all-digit spellings are hex…".
  - 3 FULL-01 / 4 C-02 — already done/blessed above.
  - 5 C-10 — **added**: comptime `supported_atoms ⊆ AtomCache` assert in
    wire.zig (~+3 lines, `@setEvalBranchQuota` + plain `for` inside the
    comptime block to dodge the 1000-branch limit).
  - 6 C-12 — **done**: `on_current` threaded into `computeDesire` +
    `desireIsNonParked` (param, no inner `visibleEntry`/`visibleOn` re-scans;
    the fused pass and winner seed derive it once each).
  - 7 C-13 — **done**: single per-pass ledger-full warn (`ledger_overflow`
    flag) instead of one `debug.err` per window.
  - 8 EVS-02 — **kept as-is**: both `drainEvents` call sites read/write the
    `pending` slot; a comptime gate would duplicate the drain body for −1 LOC
    on the hair-trigger two-loop path — not worth it.
  - 9 BAR-N7 — **no-op**: the `s.dirty.flag = false` in question lives in
    `performDraw` (bar.zig), not `updateIfDirty`, and is load-bearing (kills
    full redraws after a bare poll wake).
  - 10 ER-11 — **already done**: no `barForward` survives; routing is the
    single comptime-gated `chromeHandleKeypress` call. The "6 labeled lines"
    are historical.
  - 11 ER-04 — **done**: `xcb_get_extension_data` added to pat1; xkbfamily
    allowlist comment reworded to name it explicitly.
  - 12 NEW-6 — **keep as-is**: Rule 4 stays `src/`-scoped; README reword fixed
    the doc side already.
  - 13 NEW-5 — **kept as-is**: the two comment-strippers are different tools
    (shell line-filter vs the Rule-3 awk inline-comment remover); merging
    risks the comment grammar for no guard benefit.
  - 14 MOD-12 — **aligned**: the cycle pool now honors `all_view_active`,
    mirroring `model.visibleEntry` exactly (parked skip + tag OR view-all);
    parent doc comment updated.
  - 15 MODAud-03 — **done**: `Store` factory relocated to
    core/utils/bounded.zig (next to BoundedList); model.zig re-exports
    `pub const Store = bounded.Store;`.
  - 16 MODAud-04 — **done**: `Store.slotOf` → `Store.indexOf` (sync + model).
  - 17 MODAud-09 — **done**: `Store.clear` deleted (zero consumers); pointer-
    relocation doc no longer names it.
  - 18 TIL-10 — **kept as-is**: dense-register style is deliberate.
  - 19 NEW-18 — **done**: "non-empty canonical order" clause added to
    `Layout.compute` doc (tiling.zig) + plugin-template/layout.zig.
  - 20 R1 — **preserved as-is** (hoist keeps the quirk; a semantic fix would
    change border rendering).
  - 21 ER-01 — **no action**: retrospective only; expansion never landed.
  - 22 PIP-02 — **done**: `reconcileUnderGrabNowFullscreen` takes
    `pipeline.FullscreenKind` (enter/exit/switch_) instead of the bool pair;
    the single caller (actions.zig) passes its pre-computed `kind`.
  - 23 COREH-17/18/19/22, COREH-14, NEW-15b — **no action** (as recorded).
  - 24 Junk deletion — **kept as-is** (owner ruling): root `.opencode/` and
    `config/themes/.opencode/` are opencode's ACTIVE runtime (node_modules +
    session/goals state), not junk; no `src/core/*.swp` files exist. CC-02
    rsync excludes remain the surface.
- **Report disclosures carried in**: `extractMixOperands` UAF fix; the wire.zig
  comptime assert; `src/core/events.zig` has +40 uncommitted lines from the
  config/events worker; config.zig earlier diagnostic edits superseded.