# src/ — Core Architecture Improvement Plan (Final — All Steps Executed)

This plan addresses naming and organizational issues in `src/core/` and related areas. **All changes maintain `zig build check` at every step.** Items marked **BLOCKER** were re-scoped based on three rounds of review.

**Status: STEPS 1-11 COMPLETE.** Final gates: `zig build check` green, `zig fmt --check .` clean, `xtest.sh zig build test --summary all` → 144/144 steps, 600/601 tests (1 skipped), `check-modularity.sh -j 16` → 31/31, `zig build check-plugin-template` green. See "Execution Results" and "Preserved Knowledge" at the end.

---

## Critical Blockers (Resolved)

| Item | Issue | Resolution |
|------|-------|------------|
| **1. `wm_state.zig` → `model.zig`** | `build.zig` pure-layer allowlist, `assertPureLayerImports`, `check-layers.sh`, plugin templates, AGENTS.md | All updated in scope |
| **2. `seed.zig` → `config/model_seeding.zig`** | `config/` is pure-layer scanned; needs carve-out in `build.zig` | Carve-out added; import list corrected |
| **5. `toggleBarScreenPosition()`** | `bar/bar.zig` calls it; core is single writer of `config.bar.bar_position` | Mutation moved to `bar.zig` BEFORE core function deleted |
| **8. Contract split** | `tiling_contract.zig` cannot live in `src/tiling/` (deleted by modularity matrix); cross-engine decls must stay in core | Cross-engine decls stay in `core/architecture/tiling_contract.zig`; engine-local hooks go to engine dirs; allowlist entry is `tiling_contract` |
| **10. Operation migration** | Moving ops to deletable modules breaks callers; re-exporting from `model.zig` violates pure-layer guard | **Option A**: Keep pure queries in `model.zig`; move mutations only; no re-exports of migrated ops |

---

## 1. Rename `wm_state.zig` → `model.zig` (High Value, Low Effort) **BLOCKER** — DONE

**File**: `src/core/wm_state.zig` → `src/core/model.zig`

**Scope**:
- Rename file (`git mv`)
- Update all imports: ~68 files + plugin templates (2) + `check-layers.sh` + `build.zig` pure-layer allowlist (`"wm_state"` → `"model"`) + `assertPureLayerImports` (path to `src/core/model.zig`) + AGENTS.md + doc comments
- Update `core.zig` re-exports (`pub const WindowId = @import("model").WindowId` etc.)

---

## 2. Move `seed.zig` → `config/model_seeding.zig` (Medium Value, Medium Effort) **BLOCKER** — DONE

**File**: `src/core/architecture/seed.zig` → `src/config/model_seeding.zig`

**Scope**:
- Move file (`git mv`)
- **Add carve-out in `build.zig`** for `src/config/model_seeding.zig` (like `config/reload.zig`) to exempt from pure-layer imports check
- Update **actual importers**: `main.zig`, `config/reload.zig`, `test/core/seed_test.zig` (NOT `pipeline.zig`, `window.zig`, `admission.zig`)
- Update comment refs

---

## 3. Move `scaling.zig` → `display/scaling.zig` (Medium Value, Low Effort) — DONE

**File**: `src/core/pure/scaling.zig` → `src/core/display/scaling.zig`

**Scope**:
- `git mv` — **stem unchanged → zero import updates**
- Fix comments: `config/types.zig` cites `core/pure/scaling`; `build.zig` shelf comments

---

## 4. Rename `proc/` → `process/` (Low Value, Low Effort) — DONE

**Directory**: `src/core/proc/` → `src/core/process/`

**Scope**:
- `git mv` directory — **stems unchanged → zero import updates**
- Fix 4 comment references

---

## 5. Move Bar Position Toggle to `bar/` (High Value, Low Effort) **BLOCKER** — DONE

**Current (at plan time)**: `core.zig` `toggleBarScreenPosition()` mutated `config.bar.bar_position`; `bar/bar.zig` called it.

**Fix**:
1. Move the config mutation into `bar/bar.zig` (inside `toggleBarSegmentAnchor`)
2. Keep `surfaces.toggleBarSegmentAnchor()` as the public hook
3. Update `core.zig` doc comment and `bar.zig` comment
4. Delete `toggleBarScreenPosition()` from `core.zig`

---

## 6. `title_cache` Re-export — **Already Done (Dropped)**

**Status**: `window.zig` has private `const title_cache = @import("title_cache")`; no public re-exports exist. `bar/render/render.zig` imports `title_cache` directly. `title_seam` does not exist.
**Action**: Dropped item; "bar titles render" kept as regression check.

---

## 7. Move `dumpState()` to `core/diagnostic.zig` (Low Value, Low Effort) — DONE

**Fix**:
1. Created `src/core/diagnostic.zig` with `dumpState()`
2. Uses `tiling_seam` (not direct `tiling` import) with `build_options.has_tiling` guard
3. Added `@import("diagnostic")` in `dispatch.zig` — kept `@import("window")` (used elsewhere)
4. Deleted `dumpState()` from `window.zig`

---

## 8. Split Contracts by Engine — **REVISED (Cross-Engine Stays in Core)** **BLOCKER** — DONE

**Target Structure** (landed):
```
src/
├── window/
│   └── window_contract.zig      # WindowModule hooks (engine-local)
├── bar/
│   └── bar_contract.zig         # Segment, BarOverlay, Frame, ClickCtx, Painted, DirtySources, KeyPressEvent
├── core/architecture/
│   ├── contract_dispatch.zig    # providerOf, callAll (shared primitives)
│   └── tiling_contract.zig      # Layout, View, Env, Placement, List, HintsView, moduleOf, activeLayoutKind, activeLayoutMeta, default_kind, parked_rect, tiling_mods
```

**Why**: Cross-engine tiling vocabulary used by core/reconcile/bar **must stay in core** — cannot live in deletable `src/tiling/`.

**Scope (all done)**:
- Created 3 engine contracts + `tiling_contract.zig` in `core/architecture/`
- Moved `providerOf`/`callAll` to `contract_dispatch.zig`; deleted `contract.zig`
- Updated `build.zig` classifier/codegen (4 sites that hardcoded the `"contract"` stem) to accept all four contract stems
- Added `tiling_contract` to tiling allowlist in `pureLayerAllows` — **NOT `contract_dispatch`**
- Updated `check-layers.sh`, plugin templates, `AGENTS.md` rule 6, test imports
- Repointed ~32 `@import("contract")` sites to owning engine contract / `contract_dispatch`

---

## 9. Migrate Operations from `model.zig` (Option A — Keep Pure Queries) **BLOCKER** — DONE

**Goal**: `model.zig` keeps `Model` struct + minimal queries + struct helpers. **No re-exports of migrated ops.**

| Operation(s) | Destination | Reason |
|--------------|-------------|--------|
| `setFocus`, `clearFocus`, `fallbackFocusCandidate`, `collectCyclePool`, `focusedBorderColor` | `src/window/protocol/focus.zig` | Focus protocol owns focus |
| `reorderTiled`, `stepTiled`, `swapPrimary`, `swapFocusedWithPrevious`, `adjustPrimaryWidth` | `src/tiling/tiling.zig` (via `tiling_seam` stubs) | Tiling module owns layout |
| `register`, `unregister`, `applyParamsDelta` | `src/window/state/window_state_ops.zig` (new) | Window state owns admission |
| `applyConfigReload` | `src/config/model_seeding.zig` (two-arg form; no-arg wrapper renamed `reloadAndReconcile`) | Config owns seeding |
| `capPrimaryCount` | `domain.zig` (already there) | Pure vocabulary |

**Pure Queries (Stay in `model.zig`)**: `isManaged`, `getFocused`, `getCurrentWorkspace`, `isAllViewActive`, `entry`, `visibleOn`, `visibleEntry`, `tiledCountOnWs`, `coveringWsOf`, `isCovering`, `isCoveringOn`, `coveringOccupantOnWs`, `coveringOccupants`, `findHome`, `removeValue`, `detachTiledToFloating`, `OrderList`/`MruList` type aliases

**Landed details**:
- `buildTilingSeamModule` extended: seam source has `const model = @import("model")` plus `has_tiling`-gated top-level stubs for the five tiling ops, so window-side callers (`admission.zig`, `reconcile_tails.zig`) never import `tiling` directly
- `model.zig` reduced to pure queries only (~264 lines); header comment documents where ops live
- `reloadAndReconcile()` in `model_seeding.zig` wraps the two-arg `applyConfigReload(m, tpl)`; `config/reload.zig` calls the new name

---

## 10. Remove Redundant Runtime Feature Flags (Behavior Change — Opt-In) — DONE

Runtime flags duplicated comptime module presence; all four removed:

| Runtime Flag | Replaced With |
|--------------|---------------|
| `config.tiling.enabled` | `build_options.has_tiling` (`core.tilingEnabled()`, `border_sweeps.tilingActive()`) |
| `config.fullscreen_enabled` | `build_options.has_fullscreen` (`fullscreen.zig`) |
| `config.drag_enabled` | `build_options.has_floating` (`floating.zig`) |
| `config.workspaces.enabled` | `build_options.has_workspaces` (`query.getWorkspaceCount()`) |

**⚠️ BREAKING CHANGE (opt-in)**: A tree with `src/tiling/` present can no longer run floating-only via config; to disable a feature, delete its module (or build without it). Existing user TOMLs setting these keys still load (the parser is knob-driven; unmatched keys are ignored).

**Scope (all done)**: fields removed from `config/types.zig` (`TilingConfig.enabled`, `WorkspaceConfig.enabled`, `Config.fullscreen_enabled`, `Config.drag_enabled`); knobs removed from `config/parse/schema.zig`; call sites updated; shipped `config/config.toml`, `config/fallback.toml`, `config/README.md` updated; tests updated (`config_test`, `schema_test`).

**Note**: The plan's call-site table claimed `workspaces.enabled` had zero production readers — it had one: `query.getWorkspaceCount()` collapsed the count to 1 when false. That reader now uses `has_workspaces`, which also fixes phantom multi-workspace counts in module-deletion builds.

---

## 11. Full Suite — DONE

All gates green (see Status line).

---

## 12. Incremental Refactors (Post-Plan — Do When Touching Files) — NOT DONE (future)

### `core.zig` — Targeted Moves (Keep Facts Here)
| Move | Destination | Rationale |
|------|-------------|-----------|
| Time functions | **Keep in `core.zig`** | `bar/modules/clock.zig` is a bar segment; core time wrappers are system utilities |
| DPI (`dpi()`, `setDpi()`, `baseline_dpi`) | `display/dpi.zig` | Display metrics belong in display/ |
| Config accessor (`borderWidth()`) | `config/` (new `config_access.zig` or `config.zig`) | Config reads belong in config/ |
| `Facts` struct + fact accessors | **Keep in `core.zig`** | Core's single source of truth |

(`tilingEnabled()` already comptime via step 10.)

### `core/input/dispatch.zig` — Reduce Coupling
- Replace `process.reload()` / `process.requestReexec()` with `process` contract hook

### `window.zig` — Slim Facade
- Move child cache → `src/window/protocol/child_cache.zig`
- Move geometry queries → `src/window/protocol/geometry.zig`

### `config/` — Consolidate
- Add `config_access.zig` for `borderWidth()`

---

## Execution Order (as executed)

| Step | Action | Result |
|------|--------|--------|
| 1 | `wm_state.zig` → `model.zig` + build.zig/check-layers/plugin-templates/AGENTS.md | green |
| 2 | `proc/` → `process/` (pure `git mv` + comments) | green |
| 3 | `scaling.zig` → `display/scaling.zig` (`git mv` + comments) | green |
| 4 | `seed.zig` → `config/model_seeding.zig` + build.zig carve-out | green |
| 5 | Bar position toggle → mutation in `bar.zig`, core function deleted | green |
| 6 | Verify `title_cache` re-export already gone | green (no-op) |
| 7 | `dumpState()` → `core/diagnostic.zig` | green |
| 8 | Split contracts (engine contracts + `tiling_contract.zig` in `core/architecture/`) | green |
| 9 | Migrate ops from `model.zig` to non-deletable homes (Option A) | green |
| 10 | Remove redundant feature flags (opt-in, behavior change) | green |
| 11 | Full suite with `--summary all` | green |

---

## Verification Checklist (final state)

- [x] `zig build check` passes (all layer guards)
- [x] `dev/scripts/xtest.sh zig build test --summary all` passes — 144/144 steps, 600/601 tests (1 skipped; Zig 0.16 prints failures-only, grep the log line 1)
- [x] `zig build modules` shows no duplicate stems
- [x] `zig fmt --check .` passes
- [x] `dev/scripts/check-modularity.sh -j 16` passes (31/31)
- [x] `zig build check-plugin-template` passes
- [x] Bar position toggle works (`.toggle_bar_position` action)
- [x] Bar titles render correctly
- [x] `.dump_state` action works
- [x] All feature flags removed; breaking change documented above

---

## Cross-Cutting Requirements (Apply to All Steps)

- **Guard/scripts edited in lockstep**: `build.zig` (assertPureLayerImports + pureLayerAllows + codegen/classifier), `check-layers.sh` (Rule 3 find list + comments), `dev/plugin-template/*`, `AGENTS.md` (rule 6)
- **Docs with `wm_state`**: historical archives (`MESSAGE_BOARD.md`, `dev/actions-dissolution.md`, `dev/review-r2/*.md`, `src/window/PLAN.md`) intentionally NOT edited — they are records of past rounds
- **Use `git mv`** for every rename/move
- **Verification**: `dev/scripts/xtest.sh zig build test --summary all` for counts; `dev/scripts/check-modularity.sh -j 16` after contract/ops/flag steps; `zig build modules` after renames

---

## Final `src/core/` Structure (as landed)

```
src/core/
├── model.zig              # Model struct + pure queries + vocab re-exports
├── core.zig               # XCB state, config, facts, time, DPI (no bar position toggle)
├── architecture/
│   ├── domain.zig         # Pure vocabulary (Rect, Mask, WSId, Entry, WsState...)
│   ├── contract_dispatch.zig  # providerOf, callAll (shared primitives)
│   └── tiling_contract.zig    # Layout, View, Env, Placement, List, HintsView, moduleOf, activeLayoutKind, activeLayoutMeta, default_kind, parked_rect, tiling_mods
├── pure/
│   ├── bounded.zig        # BoundedList, Store
│   └── idmap.zig          # Fixed-capacity IdMap
├── display/
│   ├── dpi.zig            # DPI detection/override
│   ├── usable_area.zig    # Work area (screen minus bar)
│   ├── hz.zig             # Refresh rate detection
│   └── scaling.zig        # (moved from pure/) — DPI-aware scaling math
├── input/                 # Key/mouse dispatch
├── x11/                   # XCB primitives (atoms, ledger, reconcile, requests, sink, xcb)
├── loop/
│   ├── events.zig
│   └── pipeline.zig       # Model instance + reconcile entry points
├── process/               # (was proc/)
│   ├── process.zig        # Process utilities
│   ├── spawn.zig          # Command execution
│   └── session.zig        # Session save/restore
├── diagnostic.zig         # dumpState() and future diagnostics
└── debug/
    ├── log.zig
    ├── trace.zig
    └── profile.zig
```

---

## Execution Results (final counts)

| Gate | Command | Result |
|------|---------|--------|
| Type-check + layers | `zig build check` | green ("check-layers: all layer rules pass") |
| Format | `zig fmt --check .` | clean |
| Full test suite | `dev/scripts/xtest.sh zig build test --summary all` | 144/144 steps, 600/601 tests (1 skipped) |
| Modularity matrix | `dev/scripts/check-modularity.sh -j 16` | 31/31 passed |
| Plugin template | `zig build check-plugin-template` | green (via `zig build check`) |

---

## Preserved Knowledge (annotations for future maintainers)

- **Historical archives left unedited by design**: `MESSAGE_BOARD.md`, `src/window/PLAN.md`, `src/core/PLAN.md`, `src/core/TODO.md`, `dev/review*/`, `dev/SIMPLIFICATION_PLAN*`, `.swm`. They describe past rounds; do not "fix" stale names there. X-atom name strings (`net_wm_state`, `"wm_state"`) are wire protocol, not file references.
- **Contract split mechanics**: the build-generated registries keep a local alias `const contract = @import("<owner>_contract")` so module code can stay unchanged. `classifyFile` matches three needles: `pub const module: @import("<owner>_contract").`. `pureLayerAllows` shelf includes `tiling_contract` (allowed for tiling layer only); `contract_dispatch` is hub-only (core/window/input/bar).
- **Modularity matrix scope**: deletes only `src/bar`, `src/tiling`, `src/window/modules/*`. `src/window/protocol/`, `src/window/state/`, `src/config/` are NEVER deleted — so tests may import `focus`, `window_state_ops`, `model_seeding` ungated. `src/tiling/` IS deleted, so test imports of `tiling` need a `// build-gate: tiling` line; gated-off tests are excluded from compilation (`if (!gate.on) continue;` in build.zig). The matrix runs only `zig build` (never tests).
- **Test build-gates**: a `// build-gate: ...` line anywhere in a test file gates the whole file; the gate list is the file's required module stems (comma-separated).
- **Tiling seam design**: `buildTilingSeamModule` in build.zig emits a generated `tiling_seam.zig` that re-exports `tiling` when present and provides `has_tiling`-gated op stubs otherwise, importing `model` for signatures. Window-side callers (`admission.zig`, `reconcile_tails.zig`) call `tiling_seam.*`, never `tiling` directly.
- **`applyConfigReload` rename**: the no-arg `model.applyConfigReload()` became `seed.reloadAndReconcile()`; a two-arg `seed.applyConfigReload(m, tpl)` holds the stamping body (viewport-preserve loop). Callers: `config/reload.zig` → `reloadAndReconcile()`; tests → two-arg form.
- **`workspaces.enabled` correction**: the plan claimed zero production readers; `query.getWorkspaceCount()` read it. Removal replaced it with `has_workspaces`, which also collapses the count to 1 in module-deletion builds (fixing phantom workspaces).
- **This environment's `sed` is BSD-style** — use `perl -pi -e` for in-place edits. In perl patterns escape `@` as `\@` (bare `@import` interpolates empty and corrupts the file).
- **`borders.zig` xcb import**: an earlier perl rename pass accidentally dropped `const xcb = core.xcb;`; restored during flag removal when `zig build check` caught `use of undeclared identifier 'xcb'`. Lesson: run `zig build check` after bulk perl passes.
- **Parser is knob-driven**: TOML keys with no matching knob are silently ignored (no unknown-key errors), so removing flags/knobs never breaks existing user configs — stale keys just do nothing.
- **Schema dead-field guard**: `config/parse/schema.zig` has a comptime coverage pass — every scalar Config field must be a knob target or listed in `bespoke_fields`; every knob target must name a real field. Removing a flag requires removing BOTH the field and its knob in the same change.
