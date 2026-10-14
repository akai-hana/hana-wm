# Implementation Plan for src/core/TODO.md

This plan addresses all 13 concerns listed in `src/core/TODO.md`. Each item is broken into concrete steps with file-level changes, import updates, and verification commands.

---

## Item 1: Fold `time.zig` and `paths.zig` into their importers

**Rationale:** Both files are tiny (38 and 115 lines) and their contents are pure utilities better inlined at call sites.

### `time.zig` → fold into importers
- **Importers:** `src/input/input.zig`, `src/core/x11/reconcile.zig` (via xtrace), `src/core/loop/events.zig`, `src/core/proc/spawn.zig`, `src/actions/ws.zig`, `src/actions/covering.zig`
- **Action:** Inline `monotonicNs()`, `monotonicMs()`, `realtimeNs()`, `realtimeMs()` at each call site. Replace `@import("time").monotonicNs()` with direct `clockNs(.MONOTONIC)` etc.
- **Delete:** `src/core/pure/time.zig`

### `paths.zig` → fold into importers
- **Importers:** `src/config/discover.zig`, `src/config/fallback.zig`, `src/bar/modules/prompt/completion.zig`, `src/core/proc/session.zig`
- **Action:** Inline `runtimeFile()`, `dirIterator()`, `probe_order`, `probe_set`, `exeInDir()`, `configHome()`, `restricted_file_mode` at each call site.
- **Delete:** `src/core/pure/paths.zig`

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test -Dtest-filter=config
dev/scripts/xtest.sh zig build test -Dtest-filter=prompt
```

---

## Item 2: Make `log.zig` a module, detach latency profiling to `profile.zig`

**Rationale:** `log.zig` contains both logging utilities and `WindowedProfiler` (latency profiling). These are separate concerns.

### Steps
1. **Create `src/core/pure/profile.zig`** with `WindowedProfiler` (lines 144-180 of log.zig)
2. **Update `log.zig`** to import `profile` and re-export `WindowedProfiler` if needed, or let importers import `profile` directly
3. **Update importers** of `WindowedProfiler`: `src/input/input.zig` (key_profile), any others found via grep
4. **Make `log.zig` a proper module** (it already is, but ensure it's cleanly separated)

### File changes
- **New:** `src/core/pure/profile.zig` — `WindowedProfiler` comptime function
- **Edit:** `src/core/pure/log.zig` — remove `WindowedProfiler`, keep `Collector`, `log`, `err`, `warn`, `info`, `debug`, `warnOnErr`
- **Edit:** `src/input/input.zig` — change `@import("log").WindowedProfiler` to `@import("profile").WindowedProfiler`

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test
```

---

## Item 3: Rename `xtrace.zig` to `trace.zig`, create `debug/` directory

**Rationale:** Group all debug-related modules (`log`, `profile`, `trace`) under `src/core/debug/`.

### Steps
1. **Create directory:** `src/core/debug/`
2. **Move and rename:**
   - `src/core/pure/log.zig` → `src/core/debug/log.zig`
   - `src/core/pure/profile.zig` (new) → `src/core/debug/profile.zig`
   - `src/core/pure/xtrace.zig` → `src/core/debug/trace.zig`
3. **Update all imports** across the codebase:
   - `@import("log")` → `@import("debug/log")`
   - `@import("profile")` → `@import("debug/profile")`
   - `@import("xtrace")` → `@import("debug/trace")`
4. **Update `build.zig`** module discovery if needed (should auto-discover by stem)

### Files to update (grep for imports):
- `src/input/input.zig` — log, xtrace
- `src/core/x11/reconcile.zig` — xtrace
- `src/core/loop/events.zig` — log, xtrace
- `src/core/loop/reload.zig` — log
- `src/core/loop/seed.zig` — log
- `src/core/proc/process.zig` — log
- `src/core/proc/session.zig` — log
- `src/core/proc/spawn.zig` — log, time
- `src/actions/*.zig` — log
- `src/window/*.zig` — log
- `src/bar/*.zig` — log
- `src/config/*.zig` — log
- `src/test/**/*.zig` — log, xtrace

### Verification
```bash
zig build modules  # confirm new stems: debug/log, debug/profile, debug/trace
zig build check
dev/scripts/xtest.sh zig build test
```

---

## Item 4: Fold `masks.zig` into `input.zig`

**Rationale:** `masks.zig` (167 lines) defines modifier masks, event masks, and binding helpers used primarily by `input.zig`.

### Steps
1. **Move all contents** of `masks.zig` into `src/input/input.zig` (or a new `src/input/masks.zig` if preferred, but TODO says "fold into input.zig")
2. **Update imports:** Replace `@import("masks")` with `@import("input")` or inline
3. **Importers to update:**
   - `src/input/input.zig` (already imports)
   - `src/core/loop/events.zig` — uses `masks.core_event_code_mask`
   - `src/core/pure/ids.zig` — does NOT import masks (good)
   - `src/bar/modules/prompt/prompt.zig` — uses `masks.isModifierKeysym`, `masks.core_event_code_mask`
   - `src/window/protocol/client_events.zig` — may use event masks
   - `src/test/core/masks_test.zig` — tests the constants

### Note
Keep `mod_*` constants, `lock_modifiers`, `EventMasks`, `BindingMods`, `normalizeModifiers`, `toMask`, `isModifierKeysym`, `core_event_code_mask` — all used by input and prompt.

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test -Dtest-filter=masks
dev/scripts/xtest.sh zig build test -Dtest-filter=input
```

---

## Item 5: Fold `ids.zig` into `workspaces.zig`

**Rationale:** `ids.zig` defines `WorkspaceId`, `WindowId`, and `isValidWorkspaceIndex`. `workspaces.zig` (in `src/window/modules/workspaces.zig`) is the natural home.

### Steps
1. **Move contents** of `ids.zig` into `src/window/modules/workspaces.zig`
2. **Update imports:** Replace `@import("ids")` with `@import("workspaces")`
3. **Importers to update:**
   - `src/core/architecture/model.zig` — uses `WorkspaceId`, `WindowId`, `isValidWorkspaceIndex`
   - `src/core/pure/constants.zig` — uses `isValidWorkspaceIndex` (via ids import)
   - `src/core/loop/events.zig` — may use WindowId
   - `src/core/proc/session.zig` — uses `WorkspaceId`
   - `src/actions/ws.zig` — uses `model_mod.WSId` (aliased from ids)
   - `src/window/modules/workspaces.zig` — will now own the types
   - `src/test/core/ids_test.zig` — tests

### Note
`model.zig` already has `pub const WSId = ids.WorkspaceId;` and `pub const WindowId = ids.WindowId;`. After the move, `model.zig` should import from `workspaces` or re-export.

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test -Dtest-filter=workspaces
dev/scripts/xtest.sh zig build test -Dtest-filter=model
```

---

## Item 6: Fold every constant in `constants.zig` into its respective importers

**Rationale:** `constants.zig` (108 lines) is a catch-all. Each constant should live with the code that semantically owns it.

### Constant → Owner mapping
| Constant | Owner Module |
|----------|--------------|
| `min_window_dim`, `min_master_width`, `max_master_width`, `master_width_step`, `stack_balance_step`, `max_primary_swing` | `src/tiling/` or `src/actions/layout_params.zig` |
| `max_minimized` | `src/window/modules/minimize.zig` (or `parked.zig`) |
| `xkb_retry_delay_ms` | `src/input/xkbcommon.zig` |
| `x11_min_keycode`, `x11_max_keycode` | `src/input/keybind.zig` or `src/input/xkbcommon.zig` |
| `offscreen_x_position` | `src/core/x11/reconcile.zig` (uses `contract.parked_rect`) |
| `max_window_tree_depth` | `src/window/admission.zig` or `src/window/protocol/client_events.zig` |
| `max_window_cache` | `src/window/wincache.zig` |
| `max_workspaces`, `max_workspace_number_1based`, `max_workspace_command_1based` | `src/window/modules/workspaces.zig` (with Item 5) |
| `property_max_length`, `property_no_delete` | `src/window/protocol/icccm.zig` or `src/core/x11/atoms.zig` |
| `mouse_button_*` | `src/input/mouse.zig` |
| `baseline_dpi` | `src/core/display/dpi.zig` (with Item 7) |
| `max_tiled_windows` | `src/core/architecture/model.zig` |

### Steps
1. For each constant, move definition to owner module
2. Update all importers to import from new location
3. Delete `src/core/pure/constants.zig`

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test
```

---

## Item 7: Fold `dpi_math.zig` into `dpi.zig`

**Rationale:** Both in `src/core/display/`. `dpi_math` is pure math used only by `dpi.zig`.

### Steps
1. **Move** `min_reasonable_dpi`, `max_reasonable_dpi`, `mm_per_inch`, `Geometry`, `lineStartOf`, `parseXftDpi`, `calcDpiFromGeometry`, `isReasonableDpi` from `dpi_math.zig` into `dpi.zig`
2. **Remove** `@import("dpi_math")` from `dpi.zig`
3. **Delete** `src/core/display/dpi_math.zig`

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test -Dtest-filter=dpi
```

---

## Item 8: Fix `contract_x11.zig` workaround

**Rationale:** `contract_x11.zig` exists only to satisfy `check-layers.sh` Rule 3 (no xcb in pure layers). It splits the contract into two files.

### Current state
- `contract.zig` — pure, xcb-free, defines opaque `KeyPressEvent`, `Surfaces` hook set
- `contract_x11.zig` — XCB-typed, defines concrete `KeyPressEvent = xcb.xcb_key_press_event_t`, concrete `Surfaces` with xcb event pointers

### Solution
**Option A (preferred):** Use `@typeInfo` and comptime to keep contract pure while allowing XCB-typed implementations. Define `KeyPressEvent` as `anytype` or opaque in contract, with a comptime-known concrete type in the X11 layer.

**Option B:** Move the XCB-typed definitions into `src/core/x11/` (e.g., `src/core/x11/contract.zig`) and have `contract.zig` only declare the abstract interface. The `surfaces` composition root in `build.zig` would bind the concrete XCB types.

**Recommended approach (Option B):**
1. Create `src/core/x11/contract.zig` with concrete XCB types
2. Update `build.zig` to generate `surfaces` using `src/core/x11/contract` when bar is enabled
3. Keep `contract.zig` pure (opaque types only)
4. Delete `contract_x11.zig`
5. Update `check-layers.sh` Rule 3 allowlist if needed

### Files to update
- `src/core/architecture/contract.zig` — keep pure
- **New:** `src/core/x11/contract.zig` — concrete types
- `src/bar/bar.zig` / `src/bar/modules/prompt/prompt.zig` — import concrete types from x11/contract
- `build.zig` — surfaces generation

### Verification
```bash
zig build check  # must pass Rule 3 without contract_x11
dev/scripts/xtest.sh zig build test
```

---

## Item 9: Move `reload.zig` to `src/config/`

**Rationale:** `reload.zig` handles config reload logic, belongs with config subsystem.

### Steps
1. **Move** `src/core/loop/reload.zig` → `src/config/reload.zig`
2. **Update imports** in:
   - `src/core/loop/events.zig` — imports `reload`
   - `src/core/loop/seed.zig` — imports `reload` (via `seed.applyConfigReload()`)
   - `src/core/loop/pipeline.zig` — may import
3. **Update module stem** — `reload` stays same stem, just different directory

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test -Dtest-filter=reload
dev/scripts/xtest.sh zig build test -Dtest-filter=config
```

---

## Item 10: Move `seed.zig` next to `model.zig` or into `src/config/`

**Rationale:** `seed.zig` seeds model params from config. Best home is next to `model.zig` in `src/core/architecture/`.

### Steps
1. **Move** `src/core/loop/seed.zig` → `src/core/architecture/seed.zig`
2. **Update imports** in:
   - `src/core/loop/events.zig` — imports `seed`
   - `src/core/loop/reload.zig` (now in config) — imports `seed`
   - `src/core/loop/pipeline.zig` — imports `seed`
   - `src/core/architecture/model.zig` — may import
3. **Update module stem** — `seed` stays same

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test -Dtest-filter=seed
```

---

## Item 11: Consolidate `reload.zig`, `seed.zig`, `handoff.zig`

**Rationale:** These three handle related concerns: config reload, model seeding, and session hand-off (re-exec).

### Analysis
- **`reload.zig`** — loads/validates new config, swaps pointer, rebuilds subsystems
- **`seed.zig`** — stamps tiling params from config into model (boot + reload)
- **`handoff`** (in `src/core/proc/process.zig` and `src/core/proc/session.zig`) — saves/restores session state across re-exec

### Consolidation strategy
**Phase 1 (this plan):** Keep files separate but clarify boundaries:
- `config/reload.zig` — config loading + subsystem rebuild orchestration
- `core/architecture/seed.zig` — pure config→model param stamping
- `proc/session.zig` — serialize/deserialize model state (handoff)
- `proc/process.zig` — process lifecycle flags + re-exec coordination

**Phase 2 (future):** Consider merging `reload` + `seed` into a single `config/apply.zig` that handles "config changed → update model". The handoff (session save/restore) is distinct — it's about process continuity, not config.

### For this plan: No structural merge, but:
1. Ensure `reload.zig` calls `seed.applyConfigReload()` (already does)
2. Ensure `seed.zig` has no knowledge of reload/handoff (already pure)
3. Ensure `session.zig` is the single authority for session persistence
4. Document the boundaries in each file header

### Verification
```bash
zig build check
dev/scripts/xtest.sh zig build test -Dtest-filter=reload
dev/scripts/xtest.sh zig build test -Dtest-filter=seed
dev/scripts/xtest.sh zig build test -Dtest-filter=session
```

---
 
 ## Item 12: Fold `spawn.zig` into `prompt.zig`
 
 **Rationale:** TODO says fold `spawn.zig` into `prompt.zig`. However, `spawn.zig` (core/proc/spawn.zig) is used globally by `input.zig` for `.exec` and `.parallel` actions, not just by prompt.
 
 ### Re-evaluation
 Looking at `prompt.zig`:
 - `handleAction(.spawn)` calls `completion.spawnCommand(cmd)`
 - `completion.zig` likely calls `spawn.executeShellCommand()`
 
 **The TODO may mean:** Move the *prompt-specific* spawn logic (completion.spawnCommand) into prompt, or make prompt self-contained. But `spawn.zig` is a general facility.
 
 **Alternative interpretation:** The `spawn` module in `core/proc/` and the prompt's spawn usage are separate. Perhaps the TODO is outdated or means something else.
 
 **Recommended action:** 
 1. Keep `spawn.zig` as global facility (used by keybinds, sequences, parallel batches)
 2. If `prompt.zig` has duplicate spawn logic, remove it and use `spawn.executeShellCommand()`
 3. Verify `completion.spawnCommand` delegates to `spawn.executeShellCommand`
 
 ### Check `completion.zig`:
 ```bash
 grep -n "spawnCommand" src/bar/modules/prompt/completion.zig
 ```
 
 If it already uses `spawn.executeShellCommand`, no action needed. If it has its own fork/exec, fold it.
 
 ### Verification
 ```bash
 zig build check
 dev/scripts/xtest.sh zig build test -Dtest-filter=prompt
 dev/scripts/xtest.sh zig build test -Dtest-filter=spawn
 ```
 
 ---
 
 ## Item 13: `plan.zig` and `reconcile.zig` seem duplicated — **RESOLVED**
 
 **Confirmed:** No `plan.zig` exists in the codebase (`find src -name "plan.zig"` returns nothing). The `Plan` struct is defined locally inside `src/core/x11/reconcile.zig:133` and is appropriately scoped. No action needed.

## Execution Order (Dependency-Aware)
 
 | Phase | Items | Rationale |
 |-------|-------|-----------|
 | 1 | 7, 1 | Independent, small folds |
 | 2 | 2, 3 | Debug module restructuring (log→profile, xtrace→trace, debug dir) |
 | 3 | 4, 5, 6 | Fold pure utilities into owners (masks→input, ids→workspaces, constants→owners) |
 | 4 | 9, 10 | Move loop files to config/architecture |
 | 5 | 8 | Contract fix (depends on clean imports from phases 2-3) |
 | 6 | 11 | Boundary documentation (no structural change) |
 | 7 | 12 | Verify/cleanup (item 13 resolved — no plan.zig exists) |

---

## Global Verification After All Changes

```bash
# Formatting
zig fmt --check .

# Layer checks + plugin template gate
zig build check

# Full test suite (isolated Xvfb)
dev/scripts/xtest.sh zig build test

# Module registry check
zig build modules
```

---

## Notes for Implementer

1. **File stems are global namespace** — renaming `xtrace.zig` to `trace.zig` changes the module stem. All `@import("xtrace")` must become `@import("trace")` (or `@import("debug/trace")` after Item 3).

2. **Run `zig build modules` after each phase** to verify stem uniqueness.

3. **`check-layers.sh` Rule 3** sweeps `src/core/architecture/model.zig`, `contract.zig`, `src/tiling`, `src/config` for `xcb` tokens. Item 8 must pass this.

4. **No `TODO`/`FIXME` in src/** — this plan is the tracking document.

5. **Test after each phase** using `dev/scripts/xtest.sh zig build test -Dtest-filter=<area>` for fast feedback.

6. **Preserve `zig fmt` style** — run `zig fmt` on every touched file.