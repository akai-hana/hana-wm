# Hana Phase 2-5 Remaining Work Plan

## Current State Summary

### What's Been Done (Phase 1 Complete)
- ✅ Removed `surfaces` generated module (replaced with static `src/core/surfaces.zig`)
- ✅ Merged `contract_x11.zig` into `contract.zig`
- ✅ Unified workspace ID names (`WorkspaceId` → `WSId` everywhere)
- ✅ Moved `actions/` to top-level `src/actions/`
- ✅ Renamed `reconcile.zig` → `plan.zig`, `sink.zig` → `dispatch.zig`
- ✅ Fixed numerous build errors during refactoring

### Current Build Status
- ✅ **Build green** (`zig build`, `zig fmt --check .`, `zig build check`)
- ✅ Full suite via `dev/scripts/xtest.sh`: 610/611 pass (1 pre-existing bench-gate skip)
- ✅ Modularity matrix: 31/31

---

## Phase 2: Generic Registry Generator — COMPLETE ✅

### Goal
Replace hardcoded `sub_registry_specs` table in `build.zig` with filesystem-based discovery.

### Delivered (as implemented)
1. **`sub_registry_specs` removed** — replaced by `SubRegistrySpec` + `discoverSubRegistrySpecs()`:
   a spec exists for every package some module imports as `@import("<package>_subs").<array>`
   (cores plus `slider/shell.zig`), scanned through the shared `SourceScanner`.
2. **All fields derived**: `array` from the import's field access; `binding` = array minus
   plural `s` (`subs`→`sub`, `addons`→`addon`); `contract` = `<package>.Binding` (each core
   exports that alias for its contract struct — `Sub`, `Addon`, `Scroller`); `bar_segments`
   from the core declaring `pub fn segmentFor`. Specs sort by package name (deterministic
   `bar_modules` order).
3. **`ownerModuleEntries` / `validateRegistryNames` / `boundSubStems` / registry generation**
   all consume the derived slice; configure-time errors for an undiscovered package, a core
   missing `pub const Binding`, a non-plural array, or conflicting arrays across consumers.
4. **New core decls**: `pub const Binding` in systatus/slider/prompt/title cores (the
   registry-facing contract alias).

### Verification
- `zig build`, `zig fmt --check .`, `zig build check` green
- `dev/scripts/xtest.sh zig build test --summary all`: 610/611 (1 bench-gate skip)
- `dev/scripts/check-modularity.sh -j 4`: 31/31 (incl. `-vim` and `-volume -brightness`
  empty-registry paths, and whole-package drops)

---

## Phase 3: Bar Subsystem Flattening

### Goal
Reduce 8 bar render files to ~3 coherent files.

### Current Structure (8 files)
```
src/bar/
├── bar.zig           (494 lines) - orchestrator
├── state.zig         (548 lines) - data + damage model + layout solver
├── render/
│   ├── repaint.zig   (656 lines) - WHEN to paint
│   ├── paint.zig     (450 lines) - WHERE to paint (layout solver)
│   ├── frame.zig     (145 lines) - live state collection
│   ├── drawing.zig   (468 lines) - text rendering
│   ├── surface.zig   (253 lines) - X surface/pixmap
│   ├── fonts.zig     (429 lines) - Pango font book
│   ├── bindings.zig  (199 lines) - Cairo/Pango externs
│   ├── center_row.zig (100 lines) - center row layout
│   └── metrics.zig   (165 lines) - derived metrics
├── segment.zig       (571 lines) - vocab + builder
├── visibility.zig    (324 lines) - policy + wire
├── win.zig           (200 lines) - window lifecycle
└── wire/visibility.zig, win.zig, input_events.zig
```

### Target Structure (3-4 files)
```
src/bar/
├── bar.zig           - orchestrator (imports render.*)
├── render.zig        - unified: when + where + text rendering
├── frame.zig         - live state collection (keep)
├── surface.zig       - X surface (keep)
├── segment.zig       - vocab + builder (keep)
├── visibility.zig    - policy + wire (keep)
├── win.zig           - window lifecycle (keep)
└── render/
    └── drawing.zig   - text rendering primitives (keep)
```

### Key Merges
1. **state.zig + repaint.zig + paint.zig + frame.zig → render.zig**
   - `state.zig` keeps only data structures
   - `paint.zig` + `repaint.zig` → unified `render.zig`
   - `frame.zig` functions move to `render.zig`

2. **Remove duplication**
   - `RightCluster` in `bar.zig` + `clock.zig` width tracking → unify
   - `drawPaddedSegmentValue` + `paintedSegment` duplication
   - Multiple `measureString` implementations

### Key Files to Modify
- `src/bar/bar.zig`
- `src/bar/render/repaint.zig`
- `src/bar/render/paint.zig`
- `src/bar/render/frame.zig`
- `src/bar/segment.zig`

---

## Phase 4: Config Subsystem Cycle Fix

### Problem
```
parse/parser.zig ←→ parse/schema.zig  (mutual import)
```

### Current Structure
```
src/config/
├── config.zig           (facade)
├── types.zig            (types + defaults)
├── parse/
│   ├── parser.zig       (tokenizer + parser)
│   ├── schema.zig       (comptime knob table)
│   ├── document.zig     (Value/Section/Document)
│   ├── color.zig        (color parsing)
│   ├── merge.zig        (mergeDocumentsInto)
│   ├── bar_properties.zig
│   └── knobs.zig        (deleted, merged into schema.zig)
├── sections/
│   ├── binds.zig
│   ├── rules.zig
│   ├── bar_sections.zig
│   └── tiling_sections.zig
├── vocab/
│   ├── action_names.zig
│   └── layout_names.zig
├── source/ (discover, fallback)
└── persist/ (snapshot)
```

### Required Changes
1. **Break parser ↔ schema cycle**
   - Move `Document`, `Section`, `Value` to `parse/document.zig` (done)
   - `parser.zig` exports `Document`, `Section`, `Value`, `ParseError`
   - `schema.zig` imports `parser` only for `Document` type
   - `parser.zig` imports `schema` only for `knobs` table

2. **Fix import directions**
   - `parse/` imports nothing from `sections/`
   - `sections/` imports from `parse/` and `schema/`
   - `config.zig` imports from all, re-exports public API

3. **Directory rename**
   - `parse/grammar/` → `sections/` (done)
   - `parse/parse/` → `parse/` (done)

### Key Files
- `src/config/parse/parser.zig`
- `src/config/parse/schema.zig`
- `src/config/sections/*.zig`
- `src/config/config.zig`

---

## Phase 5: Session/Process Consolidation

### Goal
Merge 5 files into 2:
```
src/core/proc/
├── handoff.zig      (serialize)
├── persist.zig      (save/load)
├── restart.zig      (re-exec)
├── lifecycle.zig    (reload flag)
└── signals.zig      (signals)
```

### Target
```
src/core/proc/
├── session.zig      ← handoff + persist
└── process.zig      ← lifecycle + restart + signals
```

### Current Coupling
- `handoff.zig` uses `model.Modal` for serialization
- `persist.zig` calls `handoff.serializeWindow`
- `restart.zig` calls `persist.save` then `execv`
- `lifecycle.zig` has reload flag + re-exec coordinator
- `signals.zig` signals `lifecycle.reload()` / `lifecycle.requestReexec()`

### Key Files
- `src/core/proc/handoff.zig`
- `src/core/proc/persist.zig`
- `src/core/proc/lifecycle.zig`
- `src/core/proc/restart.zig`
- `src/core/proc/signals.zig`

---

## Final Verification Protocol

After each phase, run **full battery**:
```bash
zig fmt --check .
zig build check
dev/scripts/xtest.sh zig build test
dev/scripts/check-before-commit.sh --test --modularity
```

### Modularity Matrix (31 scenarios)
```bash
dev/scripts/check-modularity.sh -j 4
```

### Test Gates
- All 286+ tests must pass
- X-gated tests via `dev/scripts/xtest.sh`
- Bench tests only under `-Dbench`

---

## Phase 2-5 Execution Order

```
1. Phase 2 (Registry)        → 2-3 days
2. Phase 3 (Bar flattening)  → 3-4 days
3. Phase 4 (Config cycle)    → 2-3 days
4. Phase 5 (Proc consolidation) → 2-3 days
5. Final verification        → 1 day
```

### Dependencies
- Phase 2 must complete before Phase 3 (bar uses registries)
- Phase 4 independent, can parallelize
- Phase 5 depends on Phase 4 (config types used in proc)

---

## Final Report Template

```
# Phase 1-5 Completion Report

## Phase 1 - Complete ✓
- [x] surfaces module removed
- [x] contract_x11 merged
- [x] WSId unified
- [x] actions/ moved
- [x] plan/dispatch renamed

## Phase 2 - Registry Generator — Complete ✅
- [x] sub_registry_specs removed (derived: `discoverSubRegistrySpecs()`)
- [x] contract via core `Binding` alias; `ownerModuleEntries` consumes derived specs
- [x] Tests pass (610/611, 1 bench-gate skip) + modularity 31/31

## Phase 3 - Bar Flattening
- [ ] state+repaint+paint+frame → render.zig
- [ ] Duplication removed
- [ ] Tests pass

## Phase 4 - Config Cycle — already satisfied in tree ✅
- [x] parser ↔ schema cycle broken (parser imports only `document`; schema imports `parser`)
- [x] Imports unidirectional (`parse/` imports nothing from `sections/`)
- [x] Tests pass (suite green)

## Phase 5 - Proc Consolidation
- [ ] handoff+persist → session.zig
- [ ] lifecycle+restart+signals → process.zig
- [ ] Tests pass

## Final Verification
- [ ] zig fmt --check .
- [ ] zig build check
- [ ] xtest.sh zig build test (286+ tests)
- [ ] check-modularity 31/31
- [ ] check-before-commit --test --modularity
```

---

## Key Technical Notes for Agent

### Build System Quirks
- `std.ArrayList(u8).init(b.allocator)` not `.init()` or `.empty`
- `defer src.deinit()` needs allocator: `defer src.deinit(b.allocator)`
- `std.ArrayListUnmanaged(T).empty` not `.init()`
- `std.mem.sort(T, items, {}, lessFn)` not `.sort()`
- `var buf: [512]u8 = undefined` for string building
- `@memcpy` for slice concatenation

### Test Patterns
```zig
// Headless test
test "name" {
    const m = helpers.makeModel();
    defer m.deinit();
    // test
}

// X-gated test
// build-gate: tiling, minimize
test "name" { ... }

// Bench test
test "name" {
    if (!build_options.bench) return;
    // full iterations
}
```

### Layer Rules (check-layers.sh)
- Rule 1: XCB calls only in `core/x11/` + allowlist
- Rule 2: Server grabs only in `core/x11/requests.zig` + allowlist
- Rule 3: `model/tiling/config` must be XCB-free (body sweep)
- Rule 4: `zig fmt --check .`

### Common Patterns
- `defer src.deinit(b.allocator)` for ArrayList
- `defer dir.close(b.graph.io)` for directories
- `try dir.iterate()` with `while (try iter.next(b.graph.io))`
- `b.build_root.handle.openDir(b.graph.io, path, .{})` for directories

---

## Files Modified in Phase 1 (Reference)

```
src/core/architecture/contract.zig      (merged contract_x11)
src/core/surfaces.zig                   (new, replaces generated)
src/core/architecture/contract_x11.zig  (deleted)
src/actions/                            (moved from window/)
src/core/loop/pipeline.zig              (reconcile→plan, sink→dispatch)
src/core/x11/plan.zig                   (was reconcile.zig)
src/core/x11/dispatch.zig               (was sink.zig)
build.zig                               (surfaces removed, registry changes)
src/window/actions/ → src/actions/      (moved)
src/core/architecture/contract_x11.zig  (deleted)
```

---

## Next Immediate Action

**Phase 2 and Phase 4 are done. Start Phase 3: Bar Subsystem Flattening** —
merge `state.zig` + `render/repaint.zig` + `render/paint.zig` + `render/frame.zig`
into `render.zig` (plan above), then remove the listed duplication, then run the
full battery. After that, Phase 5 (proc consolidation: `handoff.zig` → `session.zig`,
`lifecycle.zig` + `signals.zig` → `process.zig`; `spawn.zig` untouched).