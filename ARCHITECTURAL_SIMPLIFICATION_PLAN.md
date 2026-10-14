# Hana Architectural Simplification - Master Plan

## Overview
Implement all architectural simplifications identified in the analysis in one continuous run.

## Phase 1: Quick Wins (Low Risk, High Value)
- [ ] 1.1 Remove `surfaces` generated module
- [ ] 1.2 Merge `contract_x11.zig` → `contract.zig`
- [ ] 1.3 Unify workspace ID names (WSId everywhere)
- [ ] 1.4 Move `actions/` to top-level `src/actions/`
- [ ] 1.5 Rename `reconcile.zig` → `plan.zig`, `sink.zig` → `dispatch.zig`

## Phase 2: Registry System Overhaul
- [ ] 2.1 Create generic registry generator in build.zig
- [ ] 2.2 Migrate all 8 registries to generic system
- [ ] 2.3 Convert sub-registries to nested `modules/` directories
- [ ] 2.4 Remove `sub_registry_specs` table

## Phase 3: Bar Subsystem Flattening
- [ ] 3.1 Merge state + repaint + paint + frame → `bar/render.zig`
- [ ] 3.2 Keep surface.zig, drawing.zig, fonts.zig, bindings.zig as-is
- [ ] 3.3 Unify segment binding to `scaffold.module()` only
- [ ] 3.4 Move title vocab to `title/vocab.zig` (verify done)
- [ ] 3.5 Clean up visibility.zig, win.zig, input_events.zig

## Phase 4: Config Subsystem Cycle Fix
- [ ] 4.1 Fix parse ⇄ sections mutual import
- [ ] 4.2 Ensure acyclic: parser → schema → sections → config

## Phase 5: Session/Process Consolidation
- [ ] 5.1 Merge handoff + persist → `session.zig`
- [ ] 5.2 Merge restart + lifecycle + signals → `process.zig`

## Phase 6: Cleanup & Verification
- [ ] 6.1 Remove dead code, unused imports
- [ ] 6.2 Run full verification suite
- [ ] 6.3 Update documentation

## Tracking
- Total files: 196
- Target: Reduce architectural complexity while preserving all behavior
- Verification after each phase: `zig fmt --check . && zig build check && dev/scripts/xtest.sh zig build test`

## Progress Log
$(date): Plan created, starting Phase 1