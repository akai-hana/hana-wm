# Merge pass 2026-10-10 — working checklist (step 53)

LIVE working notes for the 14-item same-goal merge/thin pass. Annotate the
plan file (structure-audit) when DONE; this file is the execution scratchpad.

## Global rules
- Throttling dropped by user (2026-10-10). Plain `zig build` / `zig build -j2`
  fine. Test steps are `test.<filestem>_test` (e.g. test.query_test).
- Per item: fmt → `zig build check` → dead-code → affected test stems.
  (check-dead-code only when removing pub APIs.)
- Free stems confirmed: `reply`. Taken (relevant): props (freed by T3 — do NOT
  reuse), dispatch (freed by T10), restart (freed by T5), identity/hints
  (freed by T11), timers (freed by T9), knobs/bar_properties (freed by T4),
  diff (freed by T14), cursor (T6), child_cache (T8), restore (T12),
  focus_commit (T13), defaults (T7), merge (T2).
- Zig gotchas: pointer auto-deref; local `var` never mutated = error;
  `testing.allocator` is a field; lazy analysis hides unused bad imports
  (grep for stale imports after every merge!); BSD sed -i broken → python.
- check-layers/check-modularity reference PATHS — update when files move.

## T1 — thin query.zig
- query.getWorkspaceCount → derive-on-read from core.getState().config.workspaces
  (gate core.isReady(), enabled→1, @min(count, max_workspaces)). Delete
  workspace_count var, latchWorkspaceCount, reLatchWorkspaceCount.
- reload.zig: drop `query.reLatchWorkspaceCount()` call (~line 114).
- clearFocusMru → pipeline.init (check pipeline.init/deinit + whether model
  zeroing already covers; if window deinit/init can cycle without pipeline
  re-init, keep clear callable from window discipline via pipeline). Then
  query.init/deinit deleted → window.zig drops those two calls.
- Verify: query_test, window init path tests (actions_test etc.), reload path.

## T2 — merge → document
- src/config/parse/merge.zig (50) body → document.zig (428→478), keep
  `pub fn mergeDocumentsInto`. Sole consumer: parser.zig (merge import → document).
- document imports: std, log, types. merge imports: std, document. One-way ✓.

## T3 — props → icccm
- props.zig (63) → protocol/icccm.zig (357→420): reset/evict/put/peek/
  max_window_cache + CachedProps. Consumers: window.zig (props.reset in init
  discipline), icccm.zig (already), tests: icccm_test (props.put/peek seams),
  wincache_test (max_window_cache). Retarget all → icccm.
- props stem freed; do NOT reuse.

## T4 — knobs + bar_properties → schema (DIRECTIVE 2)
- knobs.zig (284: Placement/Kind/Knob vocab, builders, 34-entry table) +
  bar_properties.zig (243: [bar.properties] segment decoder) → schema.zig.
- schema.zig target ~990: section 1 vocab+table, section 2 engine (unchanged),
  section 3 bar decoder (param `knobs` table now file-local — drop the param).
- schema.applyAll: call decoder after knob pass, pass nothing extra.
- Retarget: schema's knobs_mod/bar_properties imports → file-local; test files
  schema_test/bar_properties_test/parser_test — check what they import
  (schema.knobs re-export already public; bar_properties_test may import the
  stem directly → change to schema).
- config.zig imports schema only ✓.

## T5 — restart → lifecycle
- restart.zig (165) → proc/lifecycle.zig (84→249): init/requestReexec/
  consumeReexec/restorePathFromEnv/currentHandoff/execNext/Handoff.
- Consumers: main.zig, proc/signals.zig, input/dispatch.zig, loop/events.zig
  (restart.* → lifecycle.*; drop restart imports where lifecycle already imported).
- restart imports lifecycle one-way ✓. Check handoff_test (test/core) imports.
- ARCHITECTURE proc section + §2 tree mention restart.

## T6 — cursor → input
- x11/cursor.zig (51) → input/input.zig (265→316). Sole consumer input.zig.
- No check-layers entry for cursor ✓.

## T7 — defaults → types
- defaults.zig (28) → types.zig (700→728). Consts (default_focused_border etc.)
  become file-local in types (can use Color type directly if convenient — keep
  u32 signatures to avoid churn).
- Consumers: types.zig (self), config.zig, bar/render/drawing.zig,
  bar/modules/tags.zig, bar/modules/prompt/render.zig → defaults.X → types.X
  (all already import types — verify prompt/render).
- types→defaults edge dissolves.

## T8 — child_cache → window.zig
- state/child_cache.zig (61) → window.zig (492→~553). Sole consumer window.zig.
- Imports idmap only. Reset calls in window.init/deinit become file-local.

## T9 — timers → events
- loop/timers.zig (39) → loop/events.zig (666→705). Sole consumer events.zig.

## T10 — dispatch → input
- input/dispatch.zig (198) → input/input.zig (265→463). Consumers: input.zig,
  mouse.zig (dispatch.* → input.* or keep alias; mouse already imports input?).
- check-layers.sh:116 `src/input/dispatch.zig` Rule-1 entry → `src/input/input.zig`
  (comment already says input.zig carried it historically — restore).
- input_test may import dispatch — retarget.

## T11 — identity + hints → reply.zig
- NEW src/window/protocol/reply.zig = identity (33) + hints (93) ≈ 126.
  Pure ICCCM property-reply parsing (WM_CLASS split + size-hints derivation).
  No X imports (hints imports scaling; identity: std only).
- Consumers: admission.zig (identity+hints), window.zig (hints).
  Retarget → reply. Delete identity.zig + hints.zig.
- Tests: fold identity_test + hints_test → test/window/reply_test.zig
  (delete the two old test files; flat-per-subsystem policy).
- icccm.zig stays X-wired (purity preserved).

## T12 — restore → admission
- restore.zig (303) → admission.zig (419→722). Sole consumer main.zig
  (restore.adoptSession → admission.adoptSession).
- Check restore imports admission (one-way?) and window.zig header claims
  ("boot-time adoption ... live in admission.zig") — fix prose if stale.
- Check admission_test / restore coverage (none named restore_test).

## T13 — focus_commit → focus
- focus_commit.zig (128) → focus.zig (594→722). Sole consumer focus.zig
  (re-export line 590). DISSOLVES the focus↔focus_commit import cycle
  (Zig lazy-analysis cycle today).
- No other importers ✓.

## T14 — diff → config
- persist/diff.zig (35) → config/config.zig (468→503). Sole consumer config.zig
  (already re-exports detectChanges). diff imports types only.
- config_test: check whether it imports diff or config for detectChanges.

## Final
- Sliced battery: fmt, check, dead-code, ALL test stems in 6 batches (as
  previous pass), modularity Tier-5 + any scenario paths changed.
- ARCHITECTURE: §3 (schema description), §5 proc (restart), §7 (reply,
  admission, focus), §9 (dispatch), config parse description, §2 tree.
- structure-audit step 53 annotation with per-item outcomes + decl counts.
- git status review; do NOT commit unless asked (auto-sync may commit).
