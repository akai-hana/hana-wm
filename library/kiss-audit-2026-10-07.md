# hana KISS Audit — 2026-10-07 (ALL findings, ALL dispositions)

Single source of truth across compactions. Compiled from 6 sub-agent audits
(core, window, config, tiling+input, bar, cross-cutting) + my own review.
Baseline at start: `zig fmt --check .` = clean, `zig build check` = pass.

## Project ideals (from README.md) that constrain every change
- **Modularity #1**: optional subsystems (bar, tiling, window/modules/*) deleted by
  removing directories; core NEVER imports optional modules by name — only contracts
  (`src/core/architecture/contract*.zig`) + build-generated registries.
- **Layering** (`dev/scripts/check-layers.sh`, run by `zig build check`): wire-mutating
  XCB + server grabs behind `sync`; `model`/`tiling`/`config` xcb-free; src/ fmt-clean.
- No TODO/FIXME markers in src/. Tests organized under `src/test/` by area.
- Prior audits recorded rejections in comments — do not re-propose rejected items.
- Test command: `dev/scripts/xtest.sh zig build test` (Xvfb). Also
  `dev/scripts/check-before-commit.sh --test --modularity`.

## Disposition legend
A = accept · A* = accept after in-file evaluation · P = partial · C = cancel · DONE = implemented+verified

## Live progress checklist (update as batches land; verified = fmt+check+tests green)

Phase 1 — zero-risk
- [x] CORE-01,02,03,04,05,06,07,08,09,10,14,15,16,17,18,19,20,21 — DONE (incl. 15-decl de-pub sweep; INP-04 masks.zig half done here)
- [x] CORE-11 — DONE (key rows in Phase 1 + repo-wide sweep now: 167 grep matches classified KEEP 146 / REWRITE 13 / DROP 6 → 19 edits, ~77 comment lines of tombstone narration removed [state.zig clock-store tombstone, pipeline.zig Gate + triple-duties paragraphs, drawing.zig subslice + cairo-order, bounded.zig removeById, window.zig double-unregister, scaffold.zig two-knobs, types.zig Stage-3 enums + field-name list, tracking.zig global-scratch + facade-spellings, focus.zig deleted-assert crash story, minimize/clock/scroll/slider/usable_area spot-fixes]; live invariants kept or reworded [window.zig "actions.unmanage owns the unregister" kept; scroll's TIL-06 equivalence note dropped — the early-out it compared against is gone]; present-tense "used to [verb]" idioms and toolchain rationales untouched; fmt + check green)
- [x] WIN-10,11,12,14,16,17 — DONE. **WIN-17 guard sub-item CANCELLED**: `len > buf.len` guard in takePropertyReply STAYS (X GetProperty long_length is in 32-bit units → up to 4×buf.len bytes can arrive; guard protects the memcpy).
- [x] CFG-03,08,09,11,12,14,15,19,20 — DONE (verified fmt+check+tests; also de-pub'd discover.silent_missing, removed dead config.zig alias)
- [x] TIL-01,02,03,05 — DONE
- [x] INP-02,03,04,08,09 — DONE (resolveKeycodes→void, xkbcommon/keymap doc merges, setupGrabs refs fixed, DispatchEntry/xkb_keymap de-pub'd, no_fullscreen inline)
- [x] BARK-04,07,08,09,10,11,12,13,14,15 — DONE (DirtySourcesSource = FieldEnum; hasSource needs `inline else` — @field requires comptime tag)
- [x] XS-06,07,20,22 — DONE
- [x] **PHASE 1 COMPLETE** — fmt+check+tests all green after full phase.

Phase 2 — mechanical: CORE-13 · WIN-01,08,09,13 · CFG-04,05,06,07,10,16,17,18,21,23 · TIL-04,07,08,09,11,12 · INP-01,06 · BARK-01,02,03,05,06 · XS-09,10,12
- [x] CORE-13 — DONE (upsertById + removeAllById + private removeAllWhere deleted; removeWhere/removeById/removeValue/pushFrontEvictingTail/indexOfByIdField kept — live consumers; bounded_test trimmed; removeValue doc's stale "remove all" paragraph replaced)
- [x] WIN-01 — DONE (setIntent/shouldRaise/suppressionFor inlined into prepareFocus, etiquetteFor read once; orphan doc moved onto prepareFocus; 2 referencing docs reworded)
- [x] WIN-08 — DONE (de-pub discardAdmissionCookies, findWindowRecord, resolveClassFloat, restoredOrCurrent, applyRestoredRecord; AdmissionCookies STAYS pub — in fire/drain signatures used by window.zig)
- [x] WIN-09 — DONE (applyRestoredLevel body moved into restore.zig, forward+re-export deleted, dead handoff import dropped from layout_params.zig)
- [x] WIN-13 — DONE (occupantsInto helper extracted in window.zig; both sweeps + reloadBorders use it)
- [x] CFG-04 — DONE (types.workspaceInRange shared by sections.tryParseWsToken + rules.checkWorkspaceBound; rules' two messages merged to one; dead constants import dropped from rules.zig)
- [x] CFG-05 — DONE (4 raw literals derived via types.section_prefix_bar_layout/section_prefix_tiling_layouts ++; assert loop skipped per audit)
- [x] CFG-06 — DONE (collectPalette: names array+cap+sort gone; per-var name-max selection, root last; test "palette: same var in two sections takes the alphabetically later section" added)
- [x] CFG-07 — DONE (18-entry internal alias block deleted, call sites qualified; pub re-export block + validate_mod/diff kept; paths.zig comment updated)
- [x] CFG-16 — DONE (splitParallel returns n_sep; resolveElement single scan; no-sep path keeps untrimmed cmd)
- [x] CFG-17 — DONE (ints_are_percent arm collapsed to range-check + i==1 + /100; schema_test getRatio suites green)
- [x] CFG-18 — DONE (read_files: one optional struct {arena, paths}; publish installs/tears down atomically; snapshot_test green)
- [x] CFG-21 — DONE (loaded_freed flag + errdefer deleted: validate is the block's last fallible step, InvalidConfig arm is sole owner; config_test green)
- [x] CFG-23 — DONE (appendDupedStrings gains comptime ints_as_numbers arm; parseWorkspaceIcons 6-line loop → one call; fonts/segments pass false)
- [x] TIL-04 — DONE (Placement/Env/HintsView/parked_rect re-exports deleted → tests use contract.*; variantParse de-pub'd; internal parked_rect unified on contract.parked_rect)
- [x] TIL-07 — DONE (guards dropped in monocle/leaf/master; invariant noted in each compute doc; [n=0] path covered by engine guard; tiling_test green)
- [x] TIL-08 — DONE (row_fit computed once in compute, passed to tileStack/tileStackExtra; local formula + blk deleted; floor rationale folded)
- [x] TIL-09 — DONE (grid/scroll/monocle now build LayoutCtx, read ctx.m/ctx.min_dim; master primary_on_right via ctx.v)
- [x] TIL-11 — DONE (tiling.shrinkCapped added; grid ×3 + fibonacci ×2 converted; per-site rationale comments folded; net +1 line)
- [x] TIL-12 — DONE (OPTION a: m.compute.? panic; null-fallback park block deleted; layoutModule:506 assigns unconditionally)
- [x] INP-01 — DONE (option a: getXkbState de-pub'd in input.zig; const-mut pair kept)
- [x] INP-06 — DONE (FailureReporter struct + cap_detail=4 extracted in grabs.zig; checkGrabCookies returns void; shared tail "N further keybinding grab failed"; mouse path uses same helper)
- [x] BARK-01 — DONE (single pub clampPct in slider.zig beside rawFromPct/pctFromRaw; volume/brightness copies + their docs deleted; call sites qualified slider.clampPct; inline @min spellings converted at brightness ×2, native_alsa ×1, slider rawFromPct; slider pctFromRaw left (i128 context) + level.zig:53 left (u32 context) — type mismatches, not spellings)
- [x] BARK-02 — DONE (center_slot_ids/self_ticking_ids/roleIndexOf/isRole/naturalWidthOf hoisted into segment.zig as single home; state keeps pub self_ticking_ids alias [repaint,bar] + file-local center_slot alias; state.measureSegmentWidth delegates; center_row local copies/isCenterSlot/naturalWidthOf deleted)
- [x] BARK-03 — DONE (drawDragBar: fill_w = level.offsetFromPct(0, inner_w, pct); nearest-rounding inverse now live, fill/pointer agree)
- [x] BARK-05 — DONE (drawSingleWindow passes ctx.config.title_unfocused_accent instead of bg; both accent paths now agree; defaults equal → no visual change)
- [x] BARK-06 — DONE (option b: prompt segment-contribution comment corrected — `prompt` IS a valid [bar] segments entry, SEGMENT draw hook bound for that path)
- [x] XS-09 — DONE (addFloating/expectOrder/registerRange moved into test/helpers.zig; 4 files alias like regCur precedent; single definitions confirmed)
- [x] XS-10 — DONE (loadToml into test/config/scratch.zig, one .toml suffix policy via bufPrint; config_test local copy + schema_test scratchFile shim + local copy deleted)
- [x] XS-12 — DONE (perf_test reconcile bench → helpers.benchReconcile(&m, if (bench) 1_000 else 1); ledger.init pattern kept; local fill + testColor kept — testColor also used by drag bench)
- [x] **PHASE 2 COMPLETE** — fmt+check+tests+check-before-commit --test --modularity all green after full phase (31/31 modularity).
Phase 3 — structural: CORE-12 + diag-move · WIN-02,03,05+06,07,15 · CFG-01,02,13,22,24,25 · TIL-06 · INP-05,07 · XS-11,13,14,16,17,19,23
- [x] CORE-12 — DONE (decodeExt single-pass: one length check + one version switch via private extHeaderLen [writer :304 shares it]; extPayload/extClaimantName/extLegacyOrdinal deleted, ExtHeader file-local; handoff_test rewritten to assert decodeExt directly — 2 "agrees with accessors" cross-check tests deleted)
- [x] diag-move — DONE (git mv src/core/loop/diag.zig → src/window/actions/diag.zig; core→window edge confirmed — imports tracking/focus; sole importer input/dispatch.zig:23 `@import("diag")` unchanged, auto-discovery re-wires; check + input_test green)
- [x] WIN-02 — DONE (borders_flushed_this_batch + markBordersFlushed + updateWorkspaceBordersIfNeeded deleted; events.zig:541 calls updateWorkspaceBorders() directly; 2 dispatch mark calls dropped — ledger dedup makes the sweep zero-wire)
- [x] WIN-03 — DONE (actions.Ctx deleted; manage.unmanage(win) reads was_fs_current/was_focused before unregister ["facts read before unregister" comment]; window.zig actx capture deleted)
- [x] WIN-05+06 — DONE (single rules_map: StringHashMapUnmanaged(?u8), null=float, float_rules deleted; pure buildRulesMapFrom + matchRule(map param) testable without server; gotcha: putNoClobber asserts no-existing → ReleaseFast inserted dupes, fixed via getOrPut first-wins; NEW src/test/window/admission_test.zig 2 tests green)
- [x] WIN-07 — DONE (cache_ready deleted; setCacheArmed→reset() clear-only; guards dropped in put/peekCachedProps; window.init/deinit verified only at main.zig:165-166 — no reachable put between, not cancellable)
- [x] WIN-15 — DONE (SpawnCursor + spawn_cursor field + spawnCursor()/snapshotSpawnCursor moved admission→focus.zig; window.zig 3 refs repointed; focus.init's `state = .{}` resets it — coupling concern resolved, not cancelled)
- [x] CFG-01 — DONE (option b: bar/tiling detectors deleted from diff.zig with cmpFor/fieldEql/isArrayList/BarCmp/eqlBarLayouts/eqlStringMap — std.meta.eql on slices is ptr+len so both flags were true on EVERY reload; ConfigChanges = {keys} only; reload.zig: surfaces.onReload/applyConfigReload/reloadBorders/buildRulesMap now unconditional, regrab stays gated on changes.keys, log → "Reload complete (keys={})"; 3 bar/tiling tests deleted + keys tests trimmed. Rejected (a): a deep-eql skip would leave buildRulesMap's config-borrowed key slices pointing at the box the swap frees; behavior-identical either way since the bug meant these paths already ran unconditionally. config_test green)
- [x] CFG-02 — DONE (types.TilingConfig.layout field deleted → defaultLayout() accessor [first layouts entry or canon_master_layout]; readers fixed: pipeline:69, handoff:437, schema_test:66, layout_params:128 — last caught by check)
- [x] CFG-22 — DONE (sections.seedDefaultLayout helper used by config.zig getDefaultConfig + single-layout parse path; hazard comment + guard-assign deleted; schema.zig bespoke_fields "tiling.layout" entry removed)
- [x] CFG-13 — DONE (evaluated A*: naive routing through parseAndMerge would swallow read errors via tryParseTomlFile — FileNotFound → had_errors + ConfigEmpty, breaking search-order fallthrough (silent_missing) and reload keep-live; instead extracted discover.mergeAndRecord as the ReadSet choke point [byte ceiling, tally, merge, log, path record — both counters one place], parseAndMerge keeps pre-read count ceiling + swallow, parseFileDoc keeps raw parseTomlFile + fresh Document.init dst with includes resolved into it [mergeIncludes same-doc comment updated]; byte ceiling now covers main file (harmless), "Merged: {s}" log line added per dir precedent. config/snapshot/parser/schema tests green)
- [x] CFG-24 — DONE (parse/validate.zig deleted; invalid/validate/warnOnly + docs folded into config.zig beside loadFor; validate_mod import + re-export removed — external config.validate surface unchanged [reload.zig, tests]; scaling/constants imports added to config.zig; check-layers xcb dir-sweep green)
- [x] CFG-25 — DONE (grammar/sections.zig 410 lines split → tiling_sections.zig [tryParseWsToken, seedDefaultLayout, parseTilingStructures + variant/layout subtables family; imports std/constants/ids/log/model/parser/types/layout_names — schema unused, dropped] + bar_sections.zig [BarAnchorInfo/bar_anchors, initDefaultBarLayout, appendDupedStrings/dupeNum, parseBar/padWorkspaceIcons/parseWorkspaceIcons/parseBarLayout; imports std/log/parser/schema/types]; config.zig repointed [5 call sites + 1 comment]; anchors/seed helpers land with their only consumers — no cross-file sharing; sections stem gone, auto-discovery rewires. config/schema/parser/snapshot tests green)
- [x] TIL-06 — DONE (scroll.zig early-out `x >= sw or right <= 0` + `const right` + stale i16 comment deleted after in-file equivalence proof: early-out true ⇒ clip always yields clipped_w<=0 ⇒ same emitHidden; early-out false ⇒ clip emits for sw>=1, hidden only for sw<=0 where early-out also never fired; equivalence note folded into kept visibility-cutoff comment. tiling_test scroll strip/parking + orphan keep-last green)
- [x] INP-05 — DONE (keymapOnce now returns health-checked ?[max_keycode]u32 instead of BuiltTable; retryKeymap returns the table; tableForDevice forwarder deleted [init calls retryKeymap directly]; keymapForRebuild deleted [rebuild inlines keymapOnce], its no-retry rationale folded into rebuild's doc; identity-preserving refactor — same health gate, retry count, values — input_test + check green; no manual Xephyr run needed since transformation is provably behavior-identical)
- [x] INP-07 — DONE (step 1: fillGrabCookies/grabKeybindings take `resolved: []const keybind.ResolvedBind`, grabs drops @import("input"), 3 call sites [main:164, events:125, reload:136 — all already import input] pass input.resolvedKeybinds(), reload ordering comment updated; step 2: MouseGrabSpec + mouse_grab_buttons + undeliverableMouseBindReason moved keybind→grabs with rewritten cycle-rationale docs, grabs gains constants+types imports, keybind drops now-unused constants import, mouse gains @import("grabs") [keeps keybind for logShadowConflict], input.zig setup doc's stale would-be-a-cycle claim fixed, input_test repointed + grabs import. Final edges cycle-free: input→mouse→grabs→{keybind,core,masks,log,types,constants}; check-before-commit --test --modularity 31/31 green)
- [x] XS-11 — DONE (paths.runtimeFile(alloc, base, ext) = the one XDG-/tmp-uid policy; snapshotDirPath → runtimeFile("hana-config", ""), defaultStatePath → runtimeFile("hana-restore", ".json") — byte-identical paths, wrappers keep external API [events.zig untouched]; native_pulse keeps its /run/user/{uid} PulseAudio convention + cross-ref comment; snapshot_test + handoff_test green)
- [x] XS-13 — DONE (SinkMode count/category/none/record → category/record/none — category's total+per-op fields supersede flat count [readers migrated: focus probe.count→total, helpers ×2 TestSink(.count)→(.category); tiling's .total/.configure/.map reads unchanged]; all 4 bypass shims [ewmh/flush/grab/ungrab] now route through bump — ewmhShim 20→2 lines, 3 unit shims via unitShim comptime factory with @unionInit; category mode now counts flush/grab/ungrab/ewmh via 4 new fields [old count field deleted]; one OOM policy: named @panic in bump. reconcile/tracking/both latency/perf tests green)
- [x] XS-14 — DONE (git mv src/core/x11/masks.zig → src/core/pure/masks.zig; xcb import deleted — 7 mod_* + both EventMasks consts spelled as X protocol values [audit's "8 XCB_MOD_MASK_*" undercounted: EventMasks had 15 more xcb refs]; masks_test extended: 2 new tests pin EVERY literal against xcb.XCB_* names — earned its keep immediately: first run caught Exposure=1<<15 omitted, so StructureNotify/SubstructureNotify/SubstructureRedirect/FocusChange/PropertyChange were all off-by-one → corrected to 1<<17/19/20/21/22; constants.zig stale cross-ref updated. Audit's "remove masks exception from pureLayerAllows" NOT taken: shelf entry stays and is now legitimate [masks IS in core/pure and xcb-free; removing it would break config→binds→masks] — the real exception was Rule 1's src/core/x11/ directory exemption, which the move removes automatically. check + masks_test 6/6 + check-modularity 31/31 green)
- [x] XS-16 — DONE (engine/ catch-all rehomed: model/reconcile/pipeline/handoff → src/test/core/, tracking → src/test/window/, tiling → src/test/tiling/ [new dir], engine/ removed; 3 live path refs repointed [check-layers.sh Rule-1 allowlist ×2 for pipeline_test test-double, fixture.zig:3 comment] + build.zig discovery-grouping comment updated; stem-keyed discovery/test_gates/build-gate make moves transparent; dev/ audit docs keep old paths as history; fmt + check + all 6 moved tests green [pipeline via xtest])
- [x] XS-19 — DONE (provable assertions added, timings stay bench-gated. focus: steady probe==0 after warm per n [reconcile never flushes itself]; Mod+k s1 total==pixel==1 [focus was null → exactly win2's color flips; setFocus is model-only] + s2==0 [the folded path's premise]. tiling: flip delta decomposes EXACTLY with no golden count — park==stack==flush==ewmh==0, map==pixel [first-show/unpark replays both], total==configure+map+pixel; probe-after each flip ==0 [full-resend regression caught here]; spread-10ws probe==0 [parked windows in ledger too]; placements.len==nn [same invariant compute's own std.debug.assert guards, live under ReleaseFast]; grab==ungrab==1 + bracket in total. First attempt `total==configure` failed at n=20: master hides overflow windows (warm parks them: park+zeroed bw/pixel), monocle flip unparks → 10 map+10 pixel pairs — diagnostic print justified replacing the golden count with the decomposition. focus_latency + tiling_latency 6/6 green)
- [x] XS-17 — DONE (README: `model` now stated as living at `src/core/architecture/model.zig` in the subsystem paragraph — no file move, per audit: would churn check-layers.sh:26 path + build.zig layer-guard endsWith + modularity matrix for org-only gain)
- [x] XS-23 — DONE (README "Unit tests live in `src/test/` alongside the code they cover" → "Unit tests live in `src/test/`" — drops the phrase contradicting :185 "organized under `src/test/` by area")
- [x] **PHASE 3 COMPLETE** — full battery green: `zig fmt --check .` + `zig build check` (check-layers) + `check-modularity` 31/31 + full isolated test suite, one unthrottled `dev/scripts/check-before-commit.sh --test --modularity` run.
- [x] **FINAL BATTERY COMPLETE** — same command, exit 0.
- [x] **SUMMARY COMPLETE** — high-level change summary with highlights delivered to the user at end of session (see closing message).

---

## Disposition summary (checkmarks for the TO-DO pass)

| ID | Disposition | Notes |
|---|---|---|
| CORE-01..21 | A / A* | 12=A, 11 A*(keep live-invariant sentences), 12 A*(don't break cross-check doc), 15 A*(trace fix), 21 A* (verify precedence) |
| WIN-01 | A | inline 3 single-caller helpers in focus.zig |
| WIN-02 | A* | delete borders_flushed_this_batch double-gate if ledger dedup confirmed |
| WIN-03 | A* | delete actions.Ctx if hooks truly model-blind |
| WIN-04/XS-04/XS-05 | A* | ONE task: verify prod usage of border wrappers, delete test-only twins, port tests, fix model.zig:378 claim |
| WIN-05+06 | A | merge rule maps + new admission test |
| WIN-07 | A* | cache_ready flag; cancel if belt-and-braces justified |
| WIN-08..14,16,17 | A | de-pub, move applyRestoredLevel, ws range helpers, dead alloc, void return, occupants helper, cap helper, stale docs, title_fetch_len |
| WIN-15 | A* | SpawnCursor→focus; cancel if admission reset coupling messy |
| CFG-01 | A* | diff.zig pointer-eql bug: decide targeted deep-eql fix+test vs delete bar/tiling detectors after reading reload.zig gates |
| CFG-02 | A | delete tiling.layout field → defaultLayout() accessor |
| CFG-03,04,06,07,08,09,10,11,12,14,15,16,17,19,20,23 | A | local simplifications |
| CFG-05 | P | derive 4 literals from types.section_*; skip comptime assert unless trivial |
| CFG-13 | A* | route parseFileDoc through parseAndMerge |
| CFG-18 | A* | snapshot read_files pair → one struct |
| CFG-21 | A* | loaded_freed flag removal if restructure clean |
| CFG-22 | A* | default-layout seeding dedup (after CFG-02) |
| CFG-24 | A* | fold validate.zig into config.zig |
| CFG-25 | A* | split sections.zig → tiling_sections/bar_sections (house style: one family per file) |
| CFG-26 | **C** | Action/Keybind/MouseBind ARE Config-schema types (fields of Config); moving them scatters the schema + wide import churn for org-only gain |
| TIL-01..05,08,09 | A | |
| TIL-06 | A* | scroll early-out removal; verify clipped_w equivalence in-file |
| TIL-07 | A | option A: drop 3 module empty-order guards (engine guards; modules unreachable directly) |
| TIL-11 | A* | add shrinkCapped helper if net lines ≤ +2 |
| TIL-12 | A | option (a): `m.compute.?` (subsumes TIL-03 std.log branch) |
| INP-01 | P | (a) de-pub only; keep const-mut pair (review-r2 ★) |
| INP-02,03,04,08,09 | A | |
| INP-05 | A* | keymap ladder: only if refactor stays compile-safe; else C |
| INP-06 | P | unify grab-failure log policy helper; skip index rewrite if awkward |
| INP-07 | A* | remove grabs→input edge (step1+2) unless cycle/churn balloons |
| BARK-01..05,07..15 | A | BARK-03 = wire offsetFromPct; BARK-05 = one-token behavior fix |
| BARK-06 | P | option (b): fix comment only (behavior for user-listed prompt unclear) |
| XS-06,07,09,10,11,12,13,20,22 | A* | XS-11/13 evaluate in-file |
| XS-14 | A* | move masks.zig → core/pure/ + xcb literals, update allowlists |
| XS-15 | P | comment-only (document 1-hop guard); **cancel the keysyms move** (keymap is input's cImport owner; can't move) |
| XS-16 | A | rehome test/engine files (glob discovery = transparent) |
| XS-17,23 | A | README fixes (model location; tests wording) |
| XS-18 | C | explicitly "no code change" recommendation |
| XS-19 | A* | add only provably-deterministic assertions; else C (no flaky tests) |
| CORE-struct: diag.zig move | A* | accept only if it removes a core→optional-module import edge |
| CORE-struct: handleReexec→proc, handoff→persist | **C** | churn; many doc/script path references; directories are decorative per README |

---

# AREA 1 — src/core/ (36 files, 8451 lines)

### CORE-01 A — dead `xtrace.announce()`
`src/core/loop/xtrace.zig:139-146`. 1 occurrence repo-wide (definition). Delete fn + doc. −8. Verify: grep + build.

### CORE-02 A — dead `core.currentPhase()`; over-pub `Phase`/`markCoreReady`
`src/core/core.zig:162-165` (currentPhase: 0 callers), `:149-158` (Phase: never named outside core.zig), `:170-173` (markCoreReady: 1 internal call). Delete currentPhase; drop pub on Phase + markCoreReady. Keep isModelReady/markModelReady (16/4 real users). −7.

### CORE-03 A — 19 `pub` symbols with zero external users
Verified 0 external refs: `restart.selfPathZ`, `restart.Handoff`, `handoff.ExtHeader`, `handoff.max_stamped_name_len`, `handoff.WsRecord`, `handoff.StateFile`, `pipeline.tilingEnv`, `dpi_math.min_reasonable_dpi/max_reasonable_dpi/mm_per_inch`, `log.Diagnostic`, `paths.probe_order`, `paths.DirIterator`, `core.markCoreReady`, `sink.ConfigureWire`, `dpi.BarHeightPolicy`, `hz.publishDetectedRate`, `xtrace.announce`, `core.currentPhase`. De-pub each (Zig allows pub fn returning non-pub type; callers use inferred types). Borderline type-of-exported-value ones (BarHeightPolicy/ConfigureWire/DirIterator): de-pub only if compile stays clean. 0 lines; surface reduction.

### CORE-04 A — `tilingEnv` doc claims a test-fixture consumer that doesn't exist
`src/core/loop/pipeline.zig:110-113`; only 3 hits all inside pipeline.zig. Fix doc + de-pub.

### CORE-05 A — dead field `Claim.monitor`
`src/core/display/usable_area.zig:41-51`; doc admits "nothing reads the field"; grep confirms. Delete field + doc (move any live intent to setClaim doc). −10.

### CORE-06 A — `claimInsets()[4]` read by raw indices, consumer ignores enum order
`usable_area.zig:130-138` producer, `:155-163` consumer reads insets[2]/[0]/[1]/[3] with no enum. With one ?Claim it's multi-slot scaffolding. Change: hoist named locals top/bottom/left/right via @intFromEnum(Edge.*) OR drop claimInsets and switch on claim.edge in workAreaFrom. Test: `src/test/core/usable_area_test.zig` covers all edges + saturation. −6..−9.

### CORE-07 A — Sink doc attached to wrong declaration
`src/core/x11/sink.zig:35-38` (vtable description) sits above `ConfigureWire` (:44); `Sink` (:81) has no doc. Move lines 35-38 above :81. Comment-only.

### CORE-08 A — byte-identical duplicated doc line
`src/core/loop/pipeline.zig:99-100`. Delete line 100. −1.

### CORE-09 A — comment sentence split by an import
`src/core/loop/events.zig:29-31`: comment / `const lifecycle = @import(...)` / comment. Move import below both comment lines (same sentence intact in reload.zig:16-17 confirms accident).

### CORE-10 A — false comment vs its own retraction
`src/core/x11/masks.zig:54-55` claims raw-type-byte comparison "see isRandrEvent"; `events.zig:169-178` retracts it ("It was wrong") + 5 lines of meta-commentary. Delete trailing clause in masks.zig; delete events.zig:174-178. −6.

### CORE-11 A* — tombstone/change-log comments narrating deleted code (~47 matches)
Key rows: `pipeline.zig:24-28` (initialized()/modelReady() facades, sits between imports), `pipeline.zig:406-417` (grabCtx seam), `events.zig:549-558` (tuple-of-closures stage), `signals.zig:211-220` (two removed Plan fields, inside struct body), `core.zig:141-148` ("two independent latches this used to have"), `events.zig:403-404`, plus hz.zig:240-248/:300-305, reload.zig:29-36, ids.zig:1-19. RULE: keep sentences stating live invariants; drop "used to be/was deleted" narration. −45..−60.

### CORE-12 A* — handoff ext-header: 3 accessors re-parse same bytes; decodeExt not "one pass"
`src/core/proc/handoff.zig:48-77` (extHeaderLen/extPayload), `:79-103` (ExtHeader/decodeExt), `:105-120` (extClaimantName/extLegacyOrdinal). Production reads ONLY decodeExt (admission.zig:518); other accessors test-only. decodeExt claims one-pass, makes 3 passes; ExtHeader doc admits re-parsing. Change: decodeExt = single parse (one length check + one version switch); make accessors private or delete; de-pub ExtHeader; rewrite handoff_test.zig:240-266 to assert decodeExt directly. Risk MEDIUM (reworks 9.10 cross-check block — cross-check only meaningful while both spellings exist). −25..−30. Verify: zig build test + save/load round-trip.

### CORE-13 A — two BoundedList members production-dead
`src/core/pure/bounded.zig:88-99` upsertById, `:166-168` removeAllById (+ private removeAllWhere :170-186 if no other caller): only bounded_test.zig references. Old audit claim cited dead `persist.zig`. KEEP removeWhere (re-published for dev/plugin-template/provider.zig:94), removeById, removeValue, pushFrontEvictingTail. Update fieldEq doc "three id-keyed" → two. −15. Verify greps first.

### CORE-14 A — 180-char condition in seedWinner
`src/core/x11/reconcile.zig:245`. Hoist `const placement = placementOfSlot(...)`, `const on_cur = model.visibleEntry(...)`; two-line condition. Readability only.

### CORE-15 A* — xtrace claims bw in a request that didn't send it
`reconcile.zig:381-390`: doc says trace guarded by SAME condition as send; `true` arm prints `bw={d}` unconditionally while configure gets `.bw = if (need_bw) bw else null`. Fix: build message from same need_geom/need_bw predicates (or drop bw from geom-only format). Trace-only, opt-in HANA_XTRACE, no test → manual verify note.

### CORE-16 A — `applyParamsDelta` anytype for concrete type
`src/core/architecture/model.zig:462`: body is `m.ws[ws.index].params = delta;` → `delta: LayoutParams`. Trivial.

### CORE-17 A — Cursor = namespace wrapper around static fns
`src/core/x11/cursor.zig:17-53` (3 extern + 1 fn, no state); sole caller `src/input/input.zig:201`. Hoist externs to file scope, `pub fn setupRoot`, call `cursor.setupRoot(...)`. −2.

### CORE-18 A — signals.Plan need not be exported + tombstone comment
`src/core/proc/signals.zig:204-221`: only install(plan()) internal; tests use `const p = signals.plan();` (never name Plan). `const Plan`; drop removed-flags narration (:211-220). −10.

### CORE-19 A — `eventWindow()` computed twice on its only path
`src/core/loop/events.zig:274`: `eventWindow(event)` called twice; `t` already computed. → `const win = eventWindowFor(t, event);` then use. Delete eventWindow + doc (eventWindowFor stays; events_test covers it). −4.

### CORE-20 A — naming inversion `event_dispatch_table` (size) vs `dispatch_table`
`events.zig:49-52` const is the SIZE (one use :139); real table :138. Rename to `dispatch_table_len` or inline 36. 0..−4.

### CORE-21 A* — @compileError message precedence may truncate in the both-classified case
`src/core/architecture/contract.zig:233-237`: `"(single=" ++ if (s) "yes" else "no" ++ ", multi=" ...` — else operand may swallow the ++ tail. Parenthesize both ifs (or two consts). LOW confidence; verify by reading Zig parsing rules — fix costs nothing.

### CORE structure (from agent):
- `loop/diag.zig` (48 lines): dump-state action body, only importer input/dispatch.zig:23; imports tracking/focus/pipeline/tiling_seam → potentially core→optional edge. **A* move to src/window/actions/ if edge confirmed.**
- `loop/events.zig` handleReexec (:372-394) → proc/: **C** (churn).
- `proc/handoff.zig` → persist/: **C** (churn; doc/script refs).

---

# AREA 2 — src/window/ (20 files, 6172 lines)

### WIN-01 A — 3 single-caller helpers + anonymous struct around one focus transition
`src/window/protocol/focus.zig:368-389` setIntent (inline opts struct pass-through), `:543-545` shouldRaise, `:549-554` suppressionFor; sole consumer prepareFocus :436-445; re-reads etiquetteFor(reason) 3×. Change: read `const et = etiquetteFor(reason);` once, build `.set` in place; delete 3 helpers. All file-private. ~35 net lines. Verify: focus_test, actions_test, focus_latency_test.

### WIN-02 A* — border-sweep double gate (cross-module flag to skip one local walk)
`src/window/window.zig:155-158` State field borders_flushed_this_batch, `:178-180` markBordersFlushed, `:822-832` updateWorkspaceBordersIfNeeded; writers input/dispatch.zig:47-48,62-63; real gate core/loop/events.zig:576 (`facts_before != facts`). Sweep is ledger-dedup'd (window.zig:809 markSentBorderPixelIfChanged) → zero wire either way. Change: delete flag + setter + wrapper; events.zig:576 calls window.updateWorkspaceBorders() directly; drop 2 dispatch.zig calls. ~40 lines. Risk LOW (one extra colorless local sweep on bar toggle). Verify: build+test+check-layers; manual bar toggle watching X traffic.

### WIN-03 A* — actions.Ctx 2-field struct threaded one-to-one
struct `src/window/actions/actions.zig:53-67`; capture `window.zig:412-427`; consume `actions/manage.zig:317-325` (does `const m = pipeline.mut()` FIRST, then reads ctx — model already in hand); tests actions_test.zig:287,297. unmanage caller guard `core.isModelReady()` (:419) dead (reachable only via isValidManagedWindow→isManaged). Hooks `fn (u32) void` (fullscreen.zig:340-347, minimize.zig:328-330 touch module-local stores only). Change: delete Ctx; in unmanage compute was_fs_current=coveringWsOf(m,win), was_focused=m.focused==win at top before unregister; add comment "facts must be read before unregister; an onWindowGone binder mutating model focus/covering would break this". ~30 lines. Verify: actions_test unmanage case, focus_test.

### WIN-04 + XS-04 + XS-05 A* — test-only border wrappers + claimed scan/table divergence
`src/window/protocol/borders.zig:27-37` isBehindCoveringWindow (live store scan; headless tests borders_pure_test.zig:41-93), `:56-61` resolveBorderColor (X-gated tests borders_test.zig:68-99, 8 sites); production forms :40-52 isBehindCoveringWindowWith + :66-82 resolveBorderColorWith. Claimed divergence: `model.coveringOccupants` (model.zig:381-396) assigns anchored covering only to slot[cws] + continue, while `coveringOccupantOnWs` (:360-368) ORs visibleEntry → anchored-but-visible window = occupant under scan, not under table. **FIRST verify** who calls which form in production (agent claims prod sweeps use table; ws.zig:187 & fullscreen.zig:151 use "scan/hook" — resolve contradiction myself). Plan: delete wrappers, port both test files to the `With` forms with local table builds, fix/annotate model.zig:378-380 "matching exactly" claim, add regression case for anchored-but-visible shape. Net ~−10..−35. Verify: borders_pure_test (headless) + borders_test (X-gated).

### WIN-05 + WIN-06 A — two parallel rule maps → one; admission has zero tests
`src/window/admission.zig:81` rules_map, `:87` float_rules, cross-contains :152,:159, probes :204-209 (4 lookups per match). Change: one `StringHashMapUnmanaged(?u8)` (null = float, ?u8 = workspace), putNoClobber first-wins survives; matchRule one lookup/key. Add `src/test/window/admission_test.zig` FIRST (matchRule must become pub — makes its :198-201 "testable without a server" doc true). Reload caller core/loop/reload.zig:138 untouched. ~−12 prod + ~40 test. Verify: new test + manual WM_CLASS rules.

### WIN-07 A* — `cache_ready` guards a state that cannot occur
`src/window/protocol/icccm.zig:31` field, setCacheArmed :61-64, guards :143,:156; callers window.zig:280,:298. Flag false only between window.deinit/init when map just cleared; writers: populateFocusCacheFromCookies (post-init), refreshCachedPropHalf (PropertyNotify, managed only), supportsWMDeleteCached (input close). Change: `pub fn reset() { cache_slots.clear(); }` from init/deinit; drop flag + both guards. ~−8. Risk: loses belt-and-braces vs put between deinit/init → **verify no reachable put in that window; else CANCEL**.

### WIN-08 A — `pub` with no naming site outside admission.zig
:318 AdmissionCookies, :401 discardAdmissionCookies, :446 findWindowRecord, :456 resolveClassFloat, :466 restoredOrCurrent, :480 applyRestoredRecord (only ext mention: comment handoff.zig:39). Drop pub on the four functions; check type-in-pub-signature rule for the two types first. Compile-verified.

### WIN-09 A — applyRestoredLevel parked in layout_params.zig
`src/window/actions/layout_params.zig:99-107` = `handoff.applyModelLevel(pipeline.mut());` one line, sole caller restore.zig:35; hub re-export actions.zig:83. Move body into restore.zig (its pipeline import at :14 is currently unused — reuse), delete forward + re-export. ~−10. Verify: build + check-layers + re-exec adopt.

### WIN-10 A — 4 spellings of workspace-index range check
ws.zig:40,:78,:148 (`ws_idx >= constants.max_workspaces`), workspaces.zig:23 (`ws.index >= m.ws.len`) vs the ONE notion ids.zig:37-40 isValidWorkspaceIndex. → `if (!core.WorkspaceId.isValidWorkspaceIndex(ws_idx)) return;`. admission.zig:167-172 (configured count) stays different question. ~−4 + drift-proof.

### WIN-11 A — dead field `window.State.alloc`
window.zig:130-131 decl, :270 write; zero readers (admission.State.alloc IS read). Delete field+assignment; keep init(alloc) param. ~−4.

### WIN-12 A — dead bool return `snapViewportParamsToFocused`
actions/geometry.zig:198 returns bool; old_offset/old_count comparison :219,:226,:228; sole caller :235-27 discards `_ =`; caller doc says change signal unneeded (reconcile always runs). → void; drop old-*, 5× `return false`→`return`, trim doc. ~−7.

### WIN-13 A — two copies of border-sweep skeleton in one file
window.zig:786-812 sweepWorkspaceBorders vs :922-932 reloadBorders: byte-identical `var occupants: [max_workspaces]?model.WindowId = @splat(null)` + coveringOccupants + tracking.allWindowsInto(&state.?.snapshot) blocks; filters/actions differ. Extract 4-line `fn occupantsInto(buf: *[constants.max_workspaces]?model.WindowId)`. KEEP distinct filters (reload must visit off-workspace windows). ~−8.

### WIN-14 A — primary-count cap re-spelled 3×
layout_params.zig:63,:139 (`max_primary_count = store_capacity/4`), clamp forms :66,:140,:175. → one file-scope const + `fn capPrimaryCount(mc: u8) u8`. ~−5.

### WIN-15 A* — SpawnCursor suppression split across 3 files
admission.zig:60-65 SpawnCursor, :89-92 field, :133-137 getter, :412-428 query; reason focus.zig:35,:109-111; predicate window.zig:645-676; focus already does X round-trips (isWindowMapped :526). Change: move SpawnCursor + spawn_cursor + snapshot into focus.State; focus.snapshotSpawnCursor(conn) called from handleMapRequest (window.zig:354); suppressSpawnCrossing (window.zig:662) reads from focus. ~−30 in admission. Risk MEDIUM (moves xcb_query_pointer across files; admission State resets). Verify: build+test + manual spawn-under-cursor. **CANCEL if reset coupling is messy.**

### WIN-16 A — stale docs contradicting other files
hints.zig:8 ("actions.mapRequest bridges it") vs manage.zig:217 (bridge deleted); tracking.zig:145 orphan heading; check-layers.sh:124 cites wincache cacheBorderWidth dedup vs borders.zig:86-87 ("ledger sole owner; wincache no longer mirrors"). Rewrite/delete all three.

### WIN-17 A — fetch 4× buffer stored + unreachable guard
wincache.zig:105 title_fetch_len=1024 vs :32 max_title_len=256 (+6-line rationale :25-30); setTitle truncates → bytes 257-1024 fetched/copied/discarded; guard :219 `if (len > buf.len) return null` unreachable after format==8 check with long_length=buf.len. Change: title_fetch_len = max_title_len (delete constant + rationale; setTitle still truncates byte-identical), drop guard or assert. ~−8.

### Window structure (agent): shape healthy; window.zig 6 concerns noted but extraction NOT recommended (State reset discipline); restore.zig keep (ordering contract). armPendingBarHide/Show merge = C (contract edit for less clarity).

---

# AREA 3 — src/config/ (15 files, 5213 lines)

### CFG-01 A* — diff.zig compares by pointer identity, contradicting its header
`src/config/reload/diff.zig:1-6` header claims "never pointer identity"; `:106` .meta/.lists→`std.meta.eql` which on slices = ptr+len (std meta.zig:662); `:124,:129,:19` sites. getDefaultConfig dupes tiling.layout (config.zig:243-245), initDefaultBarLayout dupes 3 names (sections.zig:55-61) → `tilingChanged` (:153) + `barChanged` (:136) true on EVERY reload; only keysChanged (:169) can report unchanged. Test gap: config_test.zig:266 compares trivially-equal defaults; :592-594 claims content test but tests different lengths only. Production effect: reload.zig:129-141 always runs onReload/applyConfigReload/reloadBorders/buildRulesMap.
**Decision needed in-file:** (a) targeted deep-eql for slices/optionals/ArrayLists in cmpFor (+~10-18) + test "load same TOML twice → no changes" — makes reload SKIP work (behavior change, medium risk); or (b) delete bar/tiling detectors + always rebuild those two (−~150, behavior exactly as today, KISS: delete machinery that never worked). Read reload.zig gates first.

### CFG-02 A — `tiling.layout` stores derived value aliasing freed memory (UAF hazard)
types.zig:315-319 field; deinit :380-383 frees only layouts; sections.zig:77 frees strings, :80-83 hazard comment, :88 guard `layouts.items.len > 0` then assign [0]; config.zig:243-245 second writer; schema.zig:279 bespoke_fields entry. Dangling path: `[tiling]` with empty/invalid layouts → line 77 frees string layout points at → guard false → layout keeps freed ptr → readers pipeline.zig:74, handoff.zig:465 byte-compare freed memory. Change: DELETE field; `pub fn defaultLayout(self: *const TilingConfig) []const u8 { return if (self.layouts.items.len > 0) self.layouts.items[0] else canon_master_layout; }`; delete 2 writers, :80-83 comment, schema entry; edit pipeline.zig:74, handoff.zig:465, schema_test.zig:83. Verify diff.zig field walk (inline-for adapts automatically). ~−6.

### CFG-03 A — warnOnly carries 3 schema-unreachable checks
validate.zig:56-59 (count==0/master_count==0 unreachable: schema.zig:105/.min=1 rejects below-min via getInRange :543 → default), :60-62 stale comment ("negative pixel" impossible: barScalable min 0), :66 `<= 0.0` → `== 0.0`. Keep warnOnly (2 reachable warnings). ~−6.

### CFG-04 A — workspace-bound predicate exists twice with one unreachable arm each
sections.zig:25-38 tryParseWsToken (callers :153,:205 pass max_workspaces) vs rules.zig:17-30 checkWorkspaceBound (callers :79,:105,:147 pass cfg.workspaces.count); `>255` arm never fires (both capped at 64). → one shared `types.workspaceInRange(ws, max) bool` next to types constants; each site keeps own message/parse. ~−10.

### CFG-05 P — known_sections hand-maintains grammar spellings
config.zig:294-304: 13 entries use types.section_* but :300,:301,:303 raw literals ("bar.layout.left/center/right") + "tiling.layouts.master_stack" alias. PARTIAL: derive via `types.section_prefix_bar_layout ++ "left"` etc. (dual-source removal). SKIP the +6 comptime assertion loop unless trivial to add.

### CFG-06 A — collectPalette sorts [64]-slot array, silently drops sections past cap
color.zig:300-302 lessThanStr, :316-324 `var names: [64][]const u8` + `if (n_names == names.len) break;` (seed-dependent which sections kept → false "scan is still stable") + std.mem.sort. Change: delete array/cap/sort; fold precedence into loop — per palette var keep (best_section, best_value), replace when section name sorts strictly greater; apply doc.root last. Deterministic, no alloc. Add test: 2 sections declaring one palette var → later name wins. ~−10.

### CFG-07 A — config.zig 20-entry internal alias block is pure forwarding
config.zig:35-54: 16 aliases appear exactly twice (defined + called once): parseTomlFile, mergeIncludes, searchPaths, SearchAttempt, silent_missing, tryLoadOrWarn, discoverDirNames, parseDirDoc, DirInput, parseKeybindings, parseTilingStructures, parseRules, padWorkspaceIcons, initDefaultBarLayout, validate_mod, diff. Non-pub → tests can't use them. Delete block, qualify call sites. KEEP pub re-export block :22-33 (documented single import surface). ~−16.

### CFG-08 A — three vestigial shapes in parser.zig
:184-187 lineOfKey (0 call sites; doc mention :45); :179-181 Section.init returns .{} (2 calls :363,:1016 where .{} works); :482-499 insertOrAccumulate `line: ?usize` + `line orelse 0` (:497) — both callers pass plain usize (:512 e.line, :952 self.line). Delete/inline/non-opt. ~−8.

### CFG-09 A — stale comments
parser.zig:926-928 (paragraph describing loop parsePairs doesn't do — real one at :929-932); :325-327 (`OrderedIterator` values "looked up live from pairs" — field is entries, struct doc :129-130 records rename); validate.zig:60-62 (folded into CFG-03). ~−6.

### CFG-10 A — parseKeyValuePair/parsePairs split + last_key field bridging them
parser.zig:910-924 (1 caller :934), :933-956 (1 caller :1024), last_key field :581-586 written :913-915 read :936-937,:966 — both inside merge. Inline key/value parse into parsePairs; keep 2 diagnostics; demote last_key to local (pass to advanceAfterPair if message needs it); delete stale :926-928 paragraph. ~−10. Verify parser_test failure cases (:131,:166,:188,:206).

### CFG-11 A — typeLabel missing two arms real call sites instantiate
parser.zig:304-312 handles i64/bool/[]const u8/Scalable else "a different type". Callers: schema.zig:709 getAsOrWarn(f32) (dpi) → "expects a different type, got a string" instead of "a number"; sections.zig:84,:337 getAsOrWarn([]const Value) → should be "an array" (and sibling icons :381-387 accepts scalar-string → message actively misleading). asScalar supports f32 (:99-103); valueTypeLabel has `.array => "an array"` (:319). Add `f32 => "a number"`, `[]const Value => "an array"`. No test asserts warning strings.

### CFG-12 A — parseAndMerge sets dst.had_errors on 2 paths where never read
discover.zig:154,:161 immediately followed by `return error.TooMany*`; callers try-propagate → buildConfigFromDoc unreachable, config.zig:256 never sees them. Contrast :118 sets flag + returns null (flag IS the mechanism, doc :107-111). Delete 2 assignments. config_test.zig:502 asserts only error propagation. −2.

### CFG-13 A* — parseFileDoc reimplements parseAndMerge bookkeeping, contradicting ReadSet contract
config.zig:164-174 (manual read.bytes += :170, read.paths.append :171 + justification comment :166-169) vs discover.zig:144-172 + contract "Both counters move in one place (parseAndMerge), the single choke point". Change: route single-file path through parseAndMerge with fresh `parser.Document.init(a)` as dst; let mergeIncludes resolve includes on result. Ceilings then cover main file (harmless: 1 file ≤ max_file_bytes < max_total). ~−4. Verify config_test dir/file/ceiling + snapshot_test.

### CFG-14 A — tryLoadOrWarn `silent` param has one value
discover.zig:291 param, :300 use; sole caller config.zig:133 always &silent_missing. Drop param, reference silent_missing inside. ~−3.

### CFG-15 A — writeSnapshot takes `snap` and discards it
snapshot.zig:336-343 (`_ = snap;` :343); sole caller :316 (caller builds staging path :314). Delete param + `_ = snap;`. −2.

### CFG-16 A — resolveElement scans separator twice
binds.zig:234-239 pre-scan predicate byte-identical to splitParallel's :216 loop; fallback :244-245 `frags.items.len <= 1`. Change: splitParallel returns separator count; early return on n_sep==0 with untrimmed cmd (preserves documented byte-for-byte behavior :226-227); keep frags.len<=1 branch for n_sep>0. ~−5.

### CFG-17 A — getRatio bare-integer branch = 3 special cases where 1 test suffices
schema.zig:583-597 ints_are_percent arm. Collapse: `if (i < 0 or i > 100) { warn invalid; return default; } if (i == 1) { warn ambiguous; return 0.01; } return @floatFromInt(i)/100.0;` — identical outcomes. Leave ratio_strict :598-603. ~−6. Verify schema_test "both getRatio policies".

### CFG-18 A* — snapshot read-file set = two module globals that must move in step
snapshot.zig:71 read_files_arena, :75 load_read_files, :78-93 publishReadFiles resets both, :126-132. → one optional struct `var read_files: ?struct { arena: ArenaAllocator, paths: []const []const u8 }`; publishReadFiles installs/tears down atomically. ~−6.

### CFG-19 A — grammar policy hard-coded inside generic parser
parser.zig:239-243 warnScalarDuplicate exemption list encodes grammar facts ("binds" literal while siblings use types.section_*; parser already imports types :38; types.section_binds exists :56). MINIMAL: replace literal with types.section_binds. (Full move to types = optional, +0.)

### CFG-20 A — `pub` on same-file-only symbols
binds.zig:104 expandGlobKeys (sole caller :284); schema.zig: resolveTarget (:292), walkVal, Placement (external hits are tiling.Placement), EnumRead, bespoke_fields (:278; ext hit is error string :334). Drop pub ×6. KEEP: discover's (config.zig uses them), schema.knobs/value (test seams), schema.assignStr (sections.zig:350).

### CFG-21 A* — loadFor loaded_freed flag guards a prevented double-free
config.zig:415-419 flag + errdefer, :423-424 only set (InvalidConfig arm frees then break :blk). Restructure so validate arm is last before break (or arm errdefer after validate scope) → drop bool. ~−4. Risk: error-path ownership, no direct unit test → verify config_test validation-failure :454-461 + --check-config.

### CFG-22 A* — default layout seeding duplicated across 2 files
config.zig:243-245 vs sections.zig:85-88 (same 3-line idiom; 3rd line disappears with CFG-02). Fold seed into helper used by both, e.g. sections.seedDefaultLayout(allocator, &cfg). ~−3. schema_test :75/:83 pin result.

### CFG-23 A — parseWorkspaceIcons reimplements appendDupedStrings 3 lines at a time
sections.zig:374-378 (manual dupe + i64→dupeNum arm) vs :317-330 appendDupedStrings (same item.asScalar→dupe path). Give appendDupedStrings optional int arm (or appendIconValue both use). ~−4.

### CFG-24 A* — parse/validate.zig: 69-line one-function file that doesn't parse
File: validate :17-35, warnOnly :55-69, invalid :12-15; header says "Pure by construction". Only importer config.zig:10 + re-export :22; external callers use config.validate (reload.zig:90, tests). Fold into config.zig (add imports scaling + constants), delete file + import alias + re-export. MUST stay under src/config (check-layers.sh:264 sweeps dir for xcb). build.zig auto-discovers → no build edit. ~−6.

### CFG-25 A* — grammar/sections.zig covers two families (only such sibling)
409 lines: tiling :71-316, bar :332-409, shared anchors :40-61 (consumed only by bar: initDefaultBarLayout:55, parseBarLayout). All other grammar files = one family. Split → tiling_sections.zig (~265) + bar_sections.zig (~145, anchors included). Do AFTER CFG-07 (aliases already gone). Importers: config.zig only. Auto-discovery → no build edit.

### CFG-26 C — extract action.zig from types.zig
**CANCELLED.** Action/Keybind/MouseBind are fields of the Config schema (binds parse into them; Keybind.action is config data) — types.zig owning the config data model is coherent; the "input vocabulary" framing is wrong (input CONSUMES config types). Wide import churn across core/input/test for organizational gain only; README says directories are decorative.

### Config structure notes: layering reads bottom-up (source→parse→grammar→reload→config.zig); external surface = config.zig:22-33 re-exports (documented, keep); check-layers.sh:264 dir-sweep constrains where files may live; no test asserts warning strings (message edits free); schema.zig comptime machinery :284-360 is load-bearing (keep).

---

# AREA 4 — src/tiling/ + src/input/

### TIL-01 A — unused `std` import
tiling/modules/scroll.zig:4 (only mention is comment :105). Delete. −1.

### TIL-02 A — stale comments naming removed function
grid.zig:7, monocle.zig:6: "must match variantParse order below" — index now DERIVED via tiling.variantIndex (:15/:14), variantParse lives in tiling.zig:426 (not "below"). Delete both lines. −2.

### TIL-03 A — only std.log in tiling tree bypasses facade
tiling.zig:346 std.log.warn vs :278 log.warn (facade feeds test collector). → log.warn. **Subsumed by TIL-12(a)** if null-branch deleted. Δ0.

### TIL-04 A — over-broad pub in tiling engine (test-only re-exports)
tiling.zig:85 Placement, :87 Env, :88 HintsView (external users only tiling_test.zig:33,:66,:625 → switch tests to contract.* which they import), :426 variantParse (external: none; internal :510), parked_rect two spellings (:224 unqualified vs :419 contract.parked_rect → unify). KEEP View/List re-exports (header :84 justifies; widely used). −3 + test edits.

### TIL-05 A — fibonacci min_region hand-re-derives totalInset
fibonacci.zig:47 border2 (single use :54), :54 `m.gap *| 2 +| border2` == tiling.zig:119-121 totalInset(gap, m). → `const min_region = tiling.totalInset(m.gap, m);` delete :47. Expression-identical.

### TIL-06 A* — scroll off-viewport early-out subsumed by clip check
scroll.zig:75 + :77-83 park when `x >= sw or right <= 0`; clip block :85-98 re-derives: x≥sw→clipped_w=sw−x≤0; x<0→clipped_w=content_w+x≤0 ⟺ x+content_w≤0. Same action (emitHidden+continue), no side effects between, content_w≥1 always (:69 floors avail). Comment :77-79 ("before casting") stale — emitRect takes i32. Change: delete :75,:77-83; keep :71-74 comment. **Verify equivalence in-file before deleting.** −8. Tests: tiling_test scroll strip/parking + orphan keep-last.

### TIL-07 A — empty-order contract enforced in 2 styles (OPTION A)
Engine tiling.zig:328-339 documents non-empty contract + guards (:339) "for direct/test callers"; ALL module computes only reachable via engine (verified: 20 tests go via engine). monocle.zig:22, leaf.zig:28, master.zig:43 re-guard; grid/scroll/fibonacci don't. OPTION A: drop 3 module guards, note invariant in each compute doc. −3..−6. Verify [A][T][M] (n=0 test exercises engine path).

### TIL-08 A — master computes row-fit count twice
master.zig:44 `fits` vs :265-267 `max_fit` (same formula; tileStack :92 sole caller gets screen_h==h → identical). → compute once in compute, pass row_fit into tileStack/tileStackExtra; delete :265-267; fold floor-at-1 rationale into :36-41 comment. −1..−3 + single-sourcing.

### TIL-09 A — LayoutCtx adopted by 3/6 modules, others read v.env directly
grid.zig:29,42,43,52; scroll.zig:33,47; monocle.zig:23,41; master.zig:59 (`v.env.primary_on_right` past ctx) vs fibonacci.zig:42-44 rationale ("two homes for one fact"). Route through ctx (ctx.m, ctx.min_dim, ctx.v.env.primary_on_right). Δ≈0 spelling swap. (Requested by review-r2 nit, not applied.)

### TIL-11 A* — shrink+clamp+floor idiom ×5
grid.zig:42,43,52; fibonacci.zig:103,104 all `@max(@min(tiling.shrinkClamped(D,M,min), D-|M), 1)`; rationale re-explained at grid:40-41 + fibonacci:98-99. House precedent: cellStride/totalInset/seamGap created for 2-4 uses. → `pub inline fn shrinkCapped(dim, margin, min_dim)` beside shrinkClamped (tiling.zig:131), one comment on helper. Optional: +5 lines for one spelling — ACCEPT only if net ≤ +2 after folding per-site rationale comments.

### TIL-12 A — null-compute defended at runtime (OPTION a)
tiling.zig:340-349: fallback logs std.log.warn + parks everything; layoutModule :497-516 always assigns m.compute (:507) → null unreachable for any tree entry. OPTION (a): `m.compute.?(v, out);` (panic loudly any build mode; −9, removes the std.log → closes TIL-03). [r2 recommended comptime assert (b): +3 validation −4 — choose (a) for KISS unless trivial.] Verify plugin-template can't produce null (layoutModule assigns unconditionally).

### INP-01 P — getXkbState pub + one-use pair (conservative)
input.zig:92-106 (15-line doc, 0 external callers; internal :118,:181,:224), getXkbStateMut :108-112. OPTION (a): de-pub getXkbState only (0 lines; keeps review-r2 ★ const/mut story). **Cancels option (b)** collapse (−13 but drops documented defense-in-depth for first future consumer).

### INP-02 A — resolveKeycodes return value vestigial
keybind.zig:215-235 returns out[0..len]; sole caller input.zig:132 reassigns slice just passed (1 line after realloc :124); own comment :221-226 says caller sizes correctly; no test calls it. → return void; caller plain call; trim doc :214. −3.

### INP-03 A — four stacked/orphaned doc blocks
xkbcommon.zig:74-76 (orphan reverse_capacity doc on XkbState; real one keymap.zig:22); :124-130 (two stacked docs on rebuild → merge, keep 2nd's unique facts); :239-242 (orphan min_keymap_symbols doc above tableForDevice's own :243-245); keymap.zig:45-48 (two docs on buildKeysymTable → merge); keymap.zig:6 (dangling fragment). −11.

### INP-04 A — comments naming functions that no longer exist
keybind.zig:237-240 ("input.zig builds this... setupGrabs" — mouse.zig:217-221 builds it; setupGrabs doesn't exist, it's grabs.grabMouseButtons); input.zig:5-6 (header claims grab setup stays here vs body :196-197 says caller installs it); masks.zig:72 (names input.setupGrabs). Rewrite all three.

### INP-05 A* — keymap acquisition: 77-line ladder around a boolean read once
xkbcommon.zig: tableForDevice :245-246 (one-line forwarder, sole caller init), keymapOnceArgs/keymapOnce/retryKeymap/keymapForRebuild; BuiltTable.healthy (keymap.zig:53) read at ONE place xkbcommon.zig:265 `return if (built.healthy) built else null;` → flag true by construction, threaded as .table plumbing. Change: keymapOnce returns `?[max_keycode]u32` (health-checked table only); inline tableForDevice into init; fold keymapForRebuild forwarding into rebuild. −8..−12. Risk MEDIUM: cold paths (MappingNotify), no tests → manual Xephyr + xmodmap/setxkbmap verify needed. **If refactor feels less than clearly safe → CANCEL.**

### INP-06 P — one file, two grab-failure log policies
grabs.zig:64-75 (key: log every failure uncapped + summary :155) vs :128-140 (mouse: cap at 4 `if (failed <= 4)` + tail :140). Extract one "first 4 then N further" helper for both. Also `var n` :103/:106/:123/:129 provably == grabs.len (loops exhaustive) → optional index rewrite `grabs[bi * lock_modifiers.len + li]`; skip if reads worse. −2 + one policy.

### INP-07 A* — keybind.zig hosts mouse-grab policy because of grabs→input import edge
keybind.zig:252-273 (MouseGrabSpec, mouse_grab_buttons) live there only to avoid grabs→input second cycle (comment :265-268); grabs.zig:18,:32 imports input for ONE call input.resolvedKeybinds() whose 3 callers (events.zig:125, reload.zig:141, main.zig:164) already import input; mouse.zig:217-221 reconstructs the grab spec + re-spells masks.mod_super.
Step 1: `grabKeybindings(resolved: []const ResolvedBind)` / fillGrabCookies(cookies, resolved); drop grabs→input; 3 call sites pass list.
Step 2: move MouseGrabSpec + mouse_grab_buttons (+ undeliverableMouseBindReason) into grabs.zig; mouse imports grabs not keybind. Resulting edges: input→mouse→grabs, keybind→grabs, grabs→{core,masks,log} — no cycle.
−8..−12. Touches main/events/reload/input_test. Verify [A][T]. **CANCEL if a cycle or unexpected churn appears.**

### INP-08 A — pub over-reach
keymap.zig:18 `pub const xkb_keymap` (xkbcommon uses `keymap.xkb` namespace, not the const); keybind.zig `pub const DispatchEntry` (unqualified internal use only). Drop pub ×2.

### INP-09 A — one-use negated intermediate
dispatch.zig:60-61 `const no_fullscreen = !forced_hidden;` → single if next line. `if (!forced_hidden) grab.reconcileNow(.{});` −1.

### Tiling/input structure: tiling/modules = model shape (no module imports module; registry-owned) — no change. input.zig facade re-exports rated ★ by review-r2 — keep. keysyms/keymap split — do NOT merge (review-r2 ★; build allowlist). INP-07 = the one structural asymmetry worth acting on.

---

# AREA 5 — src/bar/ (35 files, 11,626 lines)

### BARK-01 + XS-08 A — clampPct spelled 7× (two byte-identical copies)
volume.zig:388-396 clampPct, brightness.zig:309-315 clampPct (identical `return @min(v,100);`, no external/test callers); inline `@min(pct,100)` at brightness.zig:181,:291, native_alsa.zig:235, slider.zig:170,:180. brightness.zig:309-312 doc claims "one clamp every level passes". → `pub fn clampPct(v: u8) u8` in slider.zig beside rawFromPct/pctFromRaw; delete both copies; replace 3 inline spellings. No new import edge (both already @import slider). −10..−14. Verify: one definition via rg; slider tests.

### BARK-02 A — registry-role vocabulary has three homes
state.zig:50-51 + center_row.zig:20-21 (identical findAllByCapability pairs); center_row.zig:25-31 isCenterSlot == state.isRole(id, center_slot_ids) :90-92; center_row.zig:48-54 naturalWidthOf == state.measureSegmentWidth :690-699 (same doc + 5-line body). Copy is structural (state imports center_row :33) but segment.zig already owns this vocabulary (bar_mods :217, segId :224, hasRegisteredSegments :236, findAllByCapability :248; comment :211-216 records prior absorption). → hoist into segment.zig: `pub const center_slot_ids/self_ticking_ids`, roleIndexOf/isRole (from state :81-92), naturalWidthOf(modules, id, frame, clock_width). state keeps pub aliases for repaint.zig:19 / bar.zig:76. −15..−22. Verify: build (comptime set guards) + center_row_test.

### BARK-03 + XS-03 A — offsetFromPct has no production caller; drawDragBar hand-rolls inverse with truncating rounding
level.zig:51-56 def (0 prod callers; 16 refs in level_test.zig; doc :40-43 says nearest-rounding so 50% fill lines up with pointer); slider.zig:545 `@intCast(@as(u32, inner_w) * pct / 100)` truncating while pointer→pct uses level.pctFromSlot (rounding). Round-trip: inner_w=3, press px2 → pct=67 → fill=1. Change: `const fill_w = level.offsetFromPct(0, inner_w, pct);` (slider already imports level :59). Kills u32/@intCast dance, makes inverse live, fill/pointer agree. Visual ≤1px in correct direction. (Alternative = delete fn + 16 test refs, precedent 84cb3ef — **chose wiring**.) −1 + dead fn live.

### BARK-04 A — SlotMode.fixed dead enum case ≡ .self_measured
scaffold.zig:133-135 case+doc, :231 arm; only users: layout/variants.zig:54, layout/layout.zig:46, clock.zig:266-278 using the other 3 modes. In module(): only wiring diff is consumeRedrawRequest :219-222 (measured_relayout vs else null) + onPainted :229-232 (measured_* → W.store; fixed/self_measured → null) → fixed/self_measured produce byte-identical Segments. Delete case + doc; arm → `.self_measured => null`. −4. Compile-proven (exhaustive switch).

### BARK-05 A — bar.title_unfocused ignored in single-window title path
title.zig:135 drawSingleWindow passes ctx.config.bg as unfocused_fallback vs :299-304 drawSegmentedTitles passes title_unfocused_accent (schema.zig:188 → types.zig:583; defaults equal → hides divergence). → pass ctx.config.title_unfocused_accent at :135 (one token). Default configs visually unchanged; verify with key set: 1-window vs 2-window.

### BARK-06 P — prompt .draw hook bound but documented unreachable → OPTION (b) comment fix
prompt.zig:412-414 doc says never in config segments list, yet :418-421 drawHook bound :438; real path overlay.draw :445 (title.zig:331). **OPTION (b): correct the comment** (listing `prompt` renders it inline; deletion would change user-visible behavior for a reachable config path — unclear intent). Comment-only.

### BARK-07 A — dead re-export prompt.WordAtCursor
prompt.zig:54; 3 hits total (completion.zig:187 def, :193 return type, this line). Delete. −1.

### BARK-08 A — clampPct carries commitPct's orphaned doc
brightness.zig:303-308 (block describes commitPct: "Applies a level to whatever backend..." scheduled by throttle) sits above clampPct :309-312 (own doc); commitPct :317 undocumented. Move block down above commitPct. (If BARK-01 lands first, clampPct gone from file → block just moves.) 0.

### BARK-09 A — two stacked docs on pub const Frame
segment.zig:39-41 + :42-45 both on Frame :46. Merge: keep B's alias explanation (definition lives in contract.zig) + fold A's "only segment-visible slice of WM state" sentence. −3..−4.

### BARK-10 A — drawTextEllipsis documents a reset that cannot happen
drawing.zig:705 doc claims "Resets Pango width/ellipsize to defaults after rendering" — body :706-713 → drawTextImpl :721-739 uses one-shot TextRun with defer deinit; nothing persists. Replace with accurate one-liner. 0.

### BARK-11 A — segmentIndexOfX doc states false inverse + cites nonexistent fn
title/geom.zig:116-118: `partitionPoint` appears nowhere else; predicate off-by-one (count=2,total=100,offset=40 → fn returns 0, stated rule yields 1). Real rule: `floor(offset_x * count / total_width)` = index whose tile contains offset_x. Rewrite 3 lines. 0.

### BARK-12 A — import inserted mid-comment
title.zig:21-23: comment → `const time = @import("time");` → comment. Move import below comment block (imports grouped :14-19).

### BARK-13 A — pollTimeoutMs doc twice, 14 lines apart
bar.zig:149-153 doc vs :164-169 inline (inline strictly more informative: null vs -1 reduce-priority story). Trim doc to the fact body doesn't repeat. −2..−3.

### BARK-14 A — typo
scaffold.zig:202 "wiress" → "wires".

### BARK-15 A — DirtySourcesSource hand-mirrors contract.DirtySources
segment.zig:190-202 enum{focus,frame} + switch re-reading bools vs contract_segment.zig:28-33 packed struct(u2); single caller state.zig:600-604; contract regime demands rename=compile error, mirror doesn't. → `pub const DirtySourcesSource = std.meta.FieldEnum(contract.DirtySources);` + `hasSource` → `@field(sources, @tagName(source))`. −4..−5. Verify: commit_test (dirty-source protocol).

### Bar structure notes: two clean layers, registry-driven; state.zig/repaint.zig new Oct-7 (single review pass only); zero inline tests in production; coverage holes noted (geom.zig notably untested — BARK-11 survived because nothing runs it); wire allowlist still exactly 4 files (state/repaint clean); no TODO; rejections live in commit messages 905cdad/d6dfd14/a4be2b5.

---

# AREA 6 — cross-cutting (main.zig, test/, structure)

### XS-01 = CORE-01 · XS-02 = CORE-02 · XS-03 = BARK-03 · XS-08 = BARK-01 · XS-04/05 = WIN-04 (dedup)

### XS-06 A — unused private const in Pulse parser
native_pulse.zig:58 `sink_info_volume_values` (1 occurrence repo-wide; siblings sink_info_index/channel_bytes/muted all referenced). Delete. −1. Verify grep myself.

### XS-07 A — two inert rows in build.zig test_gates
build.zig:327-328 (focus_latency_test, tiling_latency_test both x_gated:false), consumer :404 `if (spec != null and spec.?.x_gated)` — false row ≡ absence; comment :376-380 says absence is normal. Drop 2 rows (or reshape to x_gated list of 6 names, removing always-true bool). Staleness check :341-349 unaffected. −2..−6. Verify zig build check.

### XS-09 A — test fixture helpers copied verbatim ×4/×3/×2
addFloating identical 5-line bodies: model_test.zig:58, floating_test.zig:37, fullscreen_test.zig:43, minimize_test.zig:52; expectOrder ×3: model_test.zig:51, fullscreen_test.zig:36, minimize_test.zig:45; registerRange ×2: model_test.zig:67, minimize_test.zig:61 (calls regCur which already lives helpers.zig:71; all 4 files import helpers). → move 3 helpers into src/test/helpers.zig. ~−29 + removes 4 drift points.

### XS-10 A — loadToml defined twice
config_test.zig:91-96 + schema_test.zig:43-48 (+ local scratchFile shim :34-39); same shape, differ by suffix. → put loadToml in src/test/config/scratch.zig (one suffix policy), delete local copies + shim. ~−13.

### XS-11 A* — XDG runtime-dir path policy written twice (+ third variant)
snapshot.zig:170-178 snapshotDirPath vs handoff.zig:174-183 defaultStatePath: structurally identical (getenv XDG_RUNTIME_DIR → "{s}/leaf" else "/tmp/leaf-{uid}"); snapshot comment says "mirroring handoff.zig". native_pulse.zig:150-164 = different fallback (/run/user/uid) → leave alone + cross-ref comment. → `pub fn runtimeFile(...)` in core/pure/paths.zig (declared home for shared path utils; core/proc→core/pure and config→core/pure are sanctioned edges; no optional module named). Paths must stay byte-identical (uid suffix load-bearing). Verify snapshot_test (sets XDG_RUNTIME_DIR) + handoff restore test. ~−2 + one policy.

### XS-12 A — perf_test re-implements helpers.benchReconcile
perf_test.zig:174-191 (test "bench: reconcile pass (50 windows)") vs helpers.zig:103-115 (used by focus_latency :63,:96, tiling_latency :59,:102,:175). → call helpers.benchReconcile(&m, if (bench) 1_000 else 1); keep local fill. ~−12.

### XS-13 A* — TestSink: .count subset of .category.total; 4 shims bypass bump with different OOM policy
test_sink.zig:44-67 bump (catch unreachable) vs :98-138 ewmhShim/flushShim/grabShim/ungrabShim (inline mode==.record + catch @panic); .category/.count can't count flush ops (bypass bump); 3 unit-payload shims ~18 lines copy-paste. Change: keep ONE of .count/.category (verify readers: focus_latency:45 .count; tiling_latency:77,191 .total → pick .count or .total and migrate the other); route all shims through bump (payload param); comptime factory for the 3 unit shims; one OOM policy. ~−20. Verify: reconcile_test, tracking_test, both latency files. A* — if mode unification churns more than −20, do only the shim dedup.

### XS-14 A* — "pure shelf" contains masks.zig which imports xcb, contradicting shelf doc
build.zig:1957-1961 pureLayerAllows shelf (constants, log, ids, masks, paths, bounded, idmap, scaling, time, lifecycle, dpi_math) doc "xcb-free by construction" vs masks.zig:1-5 `@import("xcb")` + mod_shift = xcb.XCB_MOD_MASK_SHIFT. Consequence: config layer reaches xcb transitively (binds.zig:17 imports masks); check-layers Rule 3 sweeps config bodies for token "xcb" → passes while closure isn't xcb-free. masks consumers: input(5), config/grammar/binds, bar/prompt, core/loop/events, core/x11/requests, 2 tests.
Change (combined): move file → src/core/pure/masks.zig AND replace 8 `xcb.XCB_MOD_MASK_*` with protocol literals (Shift=1<<0, Lock=1<<1, Control=1<<2, Mod1..5=1<<3..1<<7), remove masks exception from pureLayerAllows. Verify: extend src/test/core/masks_test.zig to pin literals against protocol numbers; zig build check (Rule 3 + assertPureLayerImports) + check-modularity. 0 lines; removes documented carve-out. A* — if allowlist/Rule-1 wiring fights back (filename allowlists in check-layers), keep the xcb import and only move+document, or CANCEL.

### XS-15 P — keysyms "config sibling" + 1-hop guard claim
build.zig:1971-1975 siblings include keysyms (lives src/input/, imports keymap.xkb → cImport xkbcommon); assertPureLayerImports (build.zig:1903-1948) only checks direct edges → comment claims "cycles structurally impossible" is 1-hop only; directory-level config⇄input cycle exists. **PARTIAL: comment-only** — name the exception + state the guard is 1-hop. **CANCEL the file move**: keymap.zig is input's @cImport owner (xkbcommon), can't relocate to config/pure without dragging xkbcommon into config.

### XS-16 A — src/test/engine/ catch-all with no source counterpart
Files: model_test (→core/architecture/model), reconcile_test (→core/x11), pipeline_test (→core/loop), handoff_test (→core/proc), tracking_test (→window/state), tiling_test (→tiling). src/test/core/ already has 11 files. Discovery is `*_test.zig` glob (build.zig:274) → pure moves transparent; -Dtest-filter uses stems.
Rehome: model_test, reconcile_test, pipeline_test, handoff_test → src/test/core/; tracking_test → src/test/window/; tiling_test → src/test/tiling/ (new). First grep dev/ + build.zig for path refs ("test/engine") to confirm none. 0 lines + README accuracy.

### XS-17 A — README names `model` a top-level subsystem; no src/model/ exists
README.md:185 vs src/core/architecture/model.zig + check-layers.sh:26 hardcodes the file path. → README wording: "`model` — the single source of truth for window state, at `src/core/architecture/model.zig`" (no file move: would churn check-layers.sh:26 + build.zig:1931 endsWith check + modularity matrix for org-only gain).

### XS-18 C — Rule 1 allowlist outrules the rule: explicitly "no code change", monitoring recommendation only. CANCELLED (nothing to implement).

### XS-19 A* — latency tests contain ZERO assertions but claim regression protection
focus_latency_test.zig (126 lines, 2 tests), tiling_latency_test.zig (194 lines, 4 tests): grep assert|expect|panic → no matches; numbers only consumed in `if (bench) helpers.benchLog`. Claims: focus :79-81 "any regression to two reconciles shows up"; tiling :164 "XCB request count". Constraint: silent default (Zig test protocol) — documented at tiling header :30-32, deliberate.
Change: add only provably-deterministic assertions (e.g. steady-state post-warm reconcile request count == 0; assert shapes like `configure == n` rather than raw totals where possible); keep timings bench-gated. **If golden counts can't be justified by reading the code → CANCEL (no flaky/brittle tests).**

### XS-20 A — helpers.zig doc interleaved with imports
helpers.zig:5-10: std_wa doc split across `const sinkmod = @import("sink");` (line 6) etc. Reorder so both doc lines sit above std_wa.

### XS-22 A — main.zig stale comment contradicts registry architecture
main.zig:176-177 "only the bar ever registered hooks (no plugin registry anymore)" vs 3 build-generated registries + main.zig:19-21 (correct). Reword: surfaces composition root for chrome; window/tiling/bar hooks dispatch through generated registries.

### XS-23 A — README contradicts itself on test location
README.md:185 "organized under src/test/ by area" vs :282 "alongside the code they cover". Drop the latter phrase.

### XS verified-clean (do not re-raise): all contract hooks have binder+dispatcher; zero core→bar and zero core→tiling/module import edges (comment-stripped graph); no orphan tests; labelled test seams (swapPrimary, protocolParityHooks, resetForTesting, cachedWindowCount, clearValueForTest, clearNativeBackendForTest) stay; check-layers Rule 1 entries stay; usable_area placement stays.

---

# Implementation order (updated as I go)
1. Zero-risk: CORE-01,02,04,05,07,08,09,10,11,16,17,18,19,20,21 · WIN-10,11,12,14,16,17 · CFG-03,08,09,11,12,14,15,19,20 · TIL-01,02,03,05 · INP-02,03,04,08,09 · BARK-04,07,08,09,10,11,12,13,14,15 · XS-06,07,20,22
2. Mechanical: CORE-03,06,14,15,17 · WIN-01,08,09,13 · CFG-04,05,06,07,10,16,17,18,21,23 · TIL-04,07,08,09,11,12 · INP-01,06 · BARK-01,02,03,05,06 · XS-09,10,12
3. Structural/medium: CORE-12,13,diag-move · WIN-02,03,05+06,07,15 · CFG-01,02,13,22,24,25 · TIL-06 · INP-05,07 · XS-11,13,14,16,17,19,23
4. Cancelled (do NOT implement): CFG-26, XS-15-move, XS-18, CORE handoff/handleReexec moves, WIN armPending merge, INP-01b, CFG-05 assertion (unless trivial), BARK-06a.

# Verification battery (run frequently + at end)
```
zig fmt --check .                      # must stay clean
zig build check                        # layer rules + compile
dev/scripts/xtest.sh zig build test    # THE test suite (Xvfb, HANA_REQUIRE_X=1)
dev/scripts/check-modularity.sh        # feature-deletion matrix (before finish)
```
