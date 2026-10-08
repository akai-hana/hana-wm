# KISS audit — PASS 2 (2026-10-08)

Second decisive pass over the hana tree, run after PASS 1 (`kiss-audit-2026-10-07.md`,
~110 findings implemented, 7 cancelled). PASS 1's dispositions are binding: nothing
cancelled/rejected there is re-raised here. New mandate this pass: **strip devlog codes
and tags from comments** (session/changelog refs like `(28.6)`, `14.9`, `from 21.7`),
plus everything six fresh audits found below.

Method: 6 parallel area audits (CORE, WIN, CFG, TILINP, BARK, XS/REPO), each with
PASS 1's file + README ideals + a devlog-sweep mandate. Baseline green at audit time.

## Findings & dispositions

Risk: A = behavior bug · A* = likely bug/needs in-file eval (escape clause given) ·
B = false/self-contradicting documentation · C = dead code/style/cosmetic.

### CORE2 (src/core/** + main.zig) — 14 findings + 41 devlog sites
- [ ] CORE2-01 A — core.zig:304-306 dpi() doc describes a nonexistent global (both halves false); :317 "only writer" ignores init. Delete paragraph; "only writer after init". −3.
- [ ] CORE2-02 A — dpi.zig:27-28 claims caller validation nobody performs; :176-178 names deleted consts bar_min/max_height_px. Rewrite both. Comment-only.
- [ ] CORE2-03 A — comments name nonexistent symbols: handoff.zig:429 `tiling.defaultKind`; spawn.zig:306-307 `spawn_is_closed`. Fix both.
- [ ] CORE2-04 A — main.zig:184 `restart_env` → `restart.restore_env` (constant name).
- [ ] CORE2-05 A — xcb.zig:9 credits randr to dpi.zig; real consumer is display/hz.zig. Fix.
- [ ] CORE2-06 A — core.zig:35-37 eventCast caller list wrong (no bar caller; hz.zig:230 is one). Fix.
- [ ] CORE2-07 A — restart.zig:86-118 33 lines of docs on wrong decls (restore_env carries execNext+Handoff docs; execNext/Handoff undocumented). Re-block: :105-112→:129.
- [ ] CORE2-08 A — contract_segment.zig:67-95 ClickCtx+Frame docs attach to Painted; Frame/ClickCtx undocumented. Re-block.
- [ ] CORE2-09 A — handoff.zig:178-181 save's doc orphaned above Snapshot, duplicates atomicWrite/save docs. Delete. −4.
- [ ] CORE2-10 A* — core.zig:145-147 `Phase.core_ready` write-only; doc over-claims. Collapse enum to {uninit, model_ready}; init asserts state==null; fold markCoreReady. A* escape: keep enum, fix doc only. −4..−6.
- [ ] CORE2-11 A — handoff.zig:489/:500 moduleOf imported+called twice in one loop; hoist `restored`. −1..−2.
- [ ] CORE2-12 C — residual deleted-symbol narration: reconcile.zig:198 (removed findPlacement), :537-538 (removed linear scan), main.zig:130-133 (grabMouseButtons incident). Rewrite to live invariant. −7..−9.
- [ ] CORE2-13 A* — de-pub sink.zig:85 `VTable` + log.zig:122 `test_emit` (zero external users). Escape: if check names Sink.VTable, keep it.
- [ ] CORE2-DEVLOG — 41 sites/15 files (dpi ×3, usable_area, sink, pipeline ×5, core, ledger ×4, contract_window ×3, spawn ×7, ids ×2, seams, reconcile ×2, events ×2, contract, model ×4, handoff ×3). Strip/rewrite per table (fold rows: pipeline:312, spawn:124, seams:66, handoff:49). Excluded legit: 0.16 toolchain, 96.0, floats.

### WIN2 (src/window/**) — 8 findings + 26 devlog sites
- [ ] WIN2-01 A* — borders.zig: production ships table-form (resolveBorderColorWith/…With), only tests use scan-form (isBehindCoveringWindow/resolveBorderColor); model.zig:378-380 claims exact equivalence but anchored-vs-visible diverges (reachable via workspaces.tagAdd writing mask only). Change: delete scan-form wrappers (−28), port borders_pure_test 7 + borders_test 8 asserts to With-forms (+~10), rewrite model claim, fix reconcile.zig:84 cite. A* escape: add anchored-but-visible regression case; if forms disagree → fix coveringOccupants first or CANCEL.
- [ ] WIN2-02 B — window.zig:125-127/:269-271 claim spawn-cursor snapshot lives in admission.zig (moved to focus.zig in WIN-15). Drop from both lists. −2.
- [ ] WIN2-03 B — admission.zig:634-635 names nonexistent `discardAdmissionCookies`. Keep mechanism, drop wrong call spelling.
- [ ] WIN2-04 B — floating.zig:26-30 comment sentence severed across 3 imports + duplicated from fullscreen.zig:15-17/contract.zig:127. Delete interleaved copy. −3.
- [ ] WIN2-05 B — five byte-identical `providerOf` doc comments (actions/manage/ws/geometry/parked) + undocumented alias in workspaces.zig. Delete 5 dups (−10); manage.zig:39 → window.providerOf. Net −9.
- [ ] WIN2-06 C — tombstones: fullscreen.zig:160-167 (12.4 GONE block), :254-255, ws.zig:163-164, layout_params.zig:106-107 (dead store + `C12` code), window.zig:878-879. Rewrite to live invariants. −7.
- [ ] WIN2-07 C — stacked duplicate doc paragraphs: focus.zig:125-133, fullscreen.zig:168-175. Fold. −4.
- [ ] WIN2-08 C — test headers cite pre-PASS-1 paths: tracking_test:1, focus_test:2, actions_test:1; wincache_test:6 deleted `sendBorderColorIfChanged`; borders_pure_test:99 (post-WIN2-01). (Same as XS2-01; apply once.)
- [ ] WIN2-DEVLOG — 26 sites/15 files (12.4 ×6, 10.10/11.4/11.9/12.7/12.8/28.3 ×2, rest ×1). 6 need reword not just strip (fullscreen:160,174; wincache:63; borders:79; focus:646,657; window:780 — see transcript table).

### CFG2 (src/config/** + test/config) — 21 findings + 12 devlog sites
- [ ] CFG2-01 B — discover.zig:34-36 ReadSet doc names parseAndMerge as choke point; pass-1 CFG-13 made mergeAndRecord the choke point. Fix name.
- [ ] CFG2-02 B — types.zig:367/:374 mangled split docs on defaultLayout/workspaceLayoutLookup. Re-block.
- [ ] CFG2-03 B — snapshot.zig:70-72 states "never move in step" (backwards; they can never move OUT of step). Fix.
- [ ] CFG2-04 C — phantom symbols: schema.zig:264 `types.bar_owned_str_fields`; layout_names.zig:49 `parseLayoutVariant`; types.zig:264 wrong parser cite. Fix ×3.
- [ ] CFG2-05 C — parser.zig:179-180 cites deleted `pairs` hashmap. Rewrite.
- [ ] CFG2-06 C — snapshot_test.zig:190 stale file:line cite (parser.zig:230). Cite behavior.
- [ ] CFG2-07 C — parseTiling tombstones ×4 (schema:108-109, :427-428, tiling_sections:47-48, schema_test:98-100). State gates directly.
- [ ] CFG2-08 C — schema.zig:638-641 lists 5 deleted interpreters. Drop list.
- [ ] CFG2-09 C — schema.zig:447-450 narrates deleted accessor pair. Drop/compress.
- [ ] CFG2-10 C — schema.zig:89-91 attributes icon-padding to config.zig; real: bar_sections.padWorkspaceIcons. Fix cite.
- [ ] CFG2-11 C — snapshot.zig tombstones of deleted files/stamps arrays :44-47, :204-205, :211-213, :323-325. Present tense ×4.
- [ ] CFG2-12 C — snapshot.zig:1-8 module doc duplicated by :26-31 GoodSource doc. Shrink GoodSource.
- [ ] CFG2-13 C — color.zig:16-17 future-tense about completed split. Past/present fix.
- [ ] CFG2-14 C — types.zig:298-303 Stage-3 narration + context split. Present tense; move context.
- [ ] CFG2-15 C — types.zig:572-573 accent_color rename tombstone. Rewrite.
- [ ] CFG2-16 C — parser.zig:129-137 inventories 5 deleted parallel structures. Keep live facts only.
- [ ] CFG2-17 C — discover.zig:274-276 "previous spelling" narration. Present tense.
- [ ] CFG2-18 C — bar_sections.zig:65/67 duplicated warn literal in comptime arms. Warn once after loop.
- [ ] CFG2-19 C — de-pub ×4 (zero external users): discover:30 max_total_config_bytes (CFG-20's stated exception), config.zig:45 loadConfigFromDir, parser:534 ParseError, schema:382 Kind. Verify: 4 config tests.
- [ ] CFG2-20 C — test/config/scratch.zig:3-17 rewrite-narrative module doc. Present tense 2-3 lines.
- [ ] CFG2-21 C — schema_test:526-527 "now any-case" narration. Drop "now".
- [ ] CFG2-DEVLOG — 12 sites (3 src/config, 9 test/config). Test-name tags `15.1:`/`15.6:`/`15.12:` are code → strip only if repo-grep proves no consumer (verify).

### TILINP2 (src/tiling/** + src/input/**) — 11 findings + 9 devlog sites
- [ ] TILINP2-01 A — keybind.zig:14-22 resolver doc attached to entryLessThan; KeybindResolver (:72) undocumented. Move :14-18 above :72; drop wrong "keycode-resolution step" clause.
- [ ] TILINP2-02 A — masks.zig:41 doc cites input.zig's undeliverableMouseBindReason (now grabs.zig); unenforced OR-of-lock_modifiers invariant. Fix doc + add `expectEqual(all_locks, masks.lock_bits)` to masks_test.
- [ ] TILINP2-03 A — mouse.zig:97-99/:126-127 scroll predicate spelled twice. Add `isScrollButton` helper, use ×2. −2+3.
- [ ] TILINP2-04 A — keymap.zig dead exports: BuiltTable, ReverseEntry (pub → private; zero outside users). Optionally reverse_capacity/XKB_KEY_NoSymbol (needs keymap_test edits; tautological assert re-pin).
- [ ] TILINP2-05 A — stale grab-install pointers: input.zig:6-7 (says setup installs; real: main.zig:137 via grabs), main.zig:131 narrates nonexistent `events.grabMouseButtons()`. Fix ×2.
- [ ] TILINP2-06 A* — workarea.x has no shared floor while y has waY: 4 inline spellings + outerArea's deliberate @max(0,wa.x). Add `waX` next to waY (one home with outerArea), use at grid:63/master:334/scroll:90/monocle:34. Byte-identical for wa.x≥0. Escape: revert if goldens/tiling_test move.
- [ ] TILINP2-07 C — tiling.zig:206-208 dead `if (!out.append) return;` both fall through void. → `_ = out.append(...)`. −1.
- [ ] TILINP2-08 C — tiling.zig:282/:317 no-op u8→u8 @intCast. Drop casts.
- [ ] TILINP2-09 C — `pub fn compute` ×6 (+dev/plugin-template/layout.zig) exports nothing callable; registry keys on `pub const module`. Do BOTH or neither → drop pub ×7.
- [ ] TILINP2-10 C — input_test:107-111 re-types grab button table (4th copy). → `&grabs.mouse_grab_buttons`.
- [ ] TILINP2-11 C — tiling_test:616 grammar "the 120x120 hostile keep" → "hostile one keeps".
- [ ] TILINP2-DEVLOG — 9 sites (tiling ×3, scroll, keybind, keysyms, xkbcommon, dispatch ×2). All reword-strip on live sentences; dispatch:148 `10.10's cycleFocus` → `focus.cycleFocus`.

### BARK2 (src/bar/**) — 11 findings + 94 devlog sites
- [ ] BARK2-01 C — five dead top-level bindings: state.zig:18 xcb, metrics.zig:18 constants, win.zig:13 std, title.zig:17 drawing, prompt.zig:43 pub Handlers re-export. Delete ×5.
- [ ] BARK2-02 B — brightness.zig:136-142 writeU32File doc on WriteResult + wrong "returns false" claim. Re-block + fix contract.
- [ ] BARK2-03 B — visibility.zig:42-50 desiredVisibility doc parked on Reason + contradicts own mechanism. Move above :71, fix clause.
- [ ] BARK2-04 B — cpu.zig:1-6 cites nonexistent `boot_priming_ns`; real bootAverage. Rewrite.
- [ ] BARK2-05 B — 6 dangling refs: input_events:118 + state:465 `redrawScrolledSegment`→redrawScopedSegment; repaint:171 drawn_end→drawn_w; clock:14 dead docs/clock-plan.md; brightness:379 + volume:459 stale "below" → point at test files.
- [ ] BARK2-06 C — volume.zig:378-380 commitCost rationale stated twice. Delete 3 lines.
- [ ] BARK2-07 B — ram.zig:28-31 + batt.zig:24 read() docs attached to scratch buffer. Move onto read().
- [ ] BARK2-08 C — 40 file-local decls carry pub (full list in transcript: drawing ×4, completion, prompt, native_alsa, systatus ×2, geom ×3, repaint, scaffold ×2, segment, state ×20, visibility ×2, win, bar). Excluded on purpose: bindings C-ABI mirrors, build-registry `module/sub/addon`, generated-glue (vim.*). Drop pub ×40; check is backstop.
- [ ] BARK2-09 C — segmentFor hook-adapter duplication systatus vs slider — **CANCEL: accepted duplication** (builder would cost more than the 12 saved lines; re-evaluate at third sub-package).
- [ ] BARK2-10 C — tags.zig 7 fn-docs use `//` not `///` (:51,:58,:63,:109,:144-146,:178-179,:185-190). Convert.
- [ ] BARK2-11 C — geom.zig zero coverage. NEW src/test/bar/geom_test.zig: tiling exactness, segmentIndexOfX inverse, hitTest cases.
- [ ] BARK2-DEVLOG — 94 sites/21 files (drawing ×29, volume ×9, brightness, systatus, slider…). 86 strip, 8 wording repairs (drawing:74-75, :504, :1011; scaffold:114; completion:240; brightness:379; volume:460, :518-519). Excluded legit: 1.0, 3.1 KiB, libpulse 16.0.

### XS2 (tests/README/build/scripts/repo) — 18 findings + 133 devlog sites
- [ ] XS2-01 C — 3 test headers cite pre-pass-1 paths (tracking/focus/actions). [same as WIN2-08 — apply once]
- [ ] XS2-02 C — handoff_test:21 cites deleted debug.zig → core/pure/log.zig.
- [ ] XS2-03 C — test_sink:265-269 expectStackOp doc: dead `reconcile/pipeline.zig` path + verbless + 14.8 tag. Rewrite.
- [ ] XS2-04 C — window.zig:125/:268 spawn-cursor in admission list. [same as WIN2-02 — apply once]
- [ ] XS2-05 B — build.zig:1904-1908 "cycles structurally impossible" over-claims (1-hop guard; keysyms→keymap edge unscanned). **This is PASS-1's never-applied XS-15-P comment-only disposition**: qualify the claim + name the keysyms exception.
- [ ] XS2-06 C — README:20 promises per-subsystem md files that don't exist. Drop/reword.
- [ ] XS2-07 C — README:163 puts Surfaces in contract.zig; it's seams.zig:20. Fix.
- [ ] XS2-08 C — README:264 "~33 fewer tests" → ~44 (6 X-gated files, 45 tests, 1 runs headless).
- [ ] XS2-09 C — README:272 "~25 configurations" → ~31 (matrix reports 31/31).
- [ ] XS2-10 C — README:273-276 bench paragraph: timings go to `.zig-cache/bench/timings.txt`, perf_test also benches, `zig build bench` step undocumented. Rewrite sentence.
- [ ] XS2-11 C — build.zig:272-273 category list omits input/; :277 cites nonexistent `utils` module. Fix ×2.
- [ ] XS2-12 C — build.zig:88-91 -Dbench says "print timings" → file destination. Fix.
- [ ] XS2-13 C — perf_test:3-5 header says stdout/stderr timing; contradicts helpers.benchLog + own pin test :330. Rewrite.
- [ ] XS2-14 C — comment sentence interrupted by imports: focus_latency:31-35, tiling_latency:31-36. Move below imports.
- [ ] XS2-15 B/A* — perf_test: 11 bench tests assert nothing (:77,:94,:111,:130,:151,:174,:186,:249,:261,:278,:293). XS-19 precedent: add only provable-deterministic assertions (focused id, window counts, ledger after op); else mark test explicitly timing-only in doc. Escape: no flaky goldens — state reason per skipped test.
- [ ] XS2-16 C — font_probe_test:29,:36 discard results; sibling asserts non-null. Bind + assert ×2.
- [ ] XS2-17 C — helpers.zig: `testReset` pub, sole caller in-file → drop pub; `std_golden` one external caller (reconcile_test:26) → move next to caller (or keep + note).
- [ ] XS2-18 C — build.zig:320-326 test_gates `x_gated` always true → drop bool (presence = X-gated). ~−8.
- [ ] XS2-DEVLOG — 126 in-scope (build.zig 11, src/test 115) + 7 test-name/string codes. Strip-tag 100, bare-prefix 22, narrative rewrites 18 (full rows in transcript). README/dev/scripts: 0 sites. Excluded: 28 numeric false positives (floats, Zig 0.16, libpulse 16.0, ICCCM §4.1.2.7, sleep 0.1).

## Devlog sweep — global rules
1. Comment lines only (`//`, `///`, `//!`, trailing `// ...`), never code.
2. Strip `(N.N)` / `(N.N/N.N)` tags; strip leading `N.N: ` prefixes (uppercase the sentence);
   apply listed narrative rewrites where a tag carries a dead path/verb/tombstone.
3. NEVER touch: floats (0.05, 1.0), toolchain versions (0.16), protocol/version numbers
   (libpulse 16.0, 3.1 KiB), ICCCM §-numbers, golden test math.
4. Test-name tags (`test "15.1: …"`) and debug-print tags: strip too, after grepping that
   nothing consumes the name (scripts/README).
5. Leftover sweep after applying: `rg '\(\d{1,2}\.\d{1,2}\)' src build.zig` on comments →
   review each survivor manually.

## Phases (implementation order)
- **Phase A — comments/stale refs (mechanical):** CORE2-01..09,11,12 · WIN2-02..08 ·
  CFG2-01..17,20,21 · TILINP2-01,05,07,08,11 · BARK2-02..07,10 · XS2-01..04,06..14,16.
- **Phase B — dead code/de-pub:** CORE2-13 · TILINP2-04 (,+test re-pin) · CFG2-19 ·
  BARK2-01,08 · XS2-17,18 · TILINP2-03,10 · CFG2-18 · BARK2-11 (new tests) · CORE2-10 (A*).
- **Phase C — evaluative A*:** WIN2-01 (borders scan-form deletion) · TILINP2-06 (waX) ·
  XS2-05 (build.zig guard doc + keysyms exception) · XS2-15 (perf assertions).
- **Phase D — devlog sweep:** all CORE2/WIN2/CFG2/TILINP2/BARK2/XS2 devlog rows + global rules.
- **Phase E — battery + summary:** fmt, check, xtest full suite, check-before-commit --test --modularity.

## Verification battery (unthrottled, full speed)
```
zig fmt --check .
zig build check
dev/scripts/xtest.sh zig build test
dev/scripts/check-before-commit.sh --test --modularity
```

## Live progress checklist
