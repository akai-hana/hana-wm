# Input Module Refactoring & Relocation Plan

## Overview
Refactor `src/input/` from 7 files (~1,730 lines) to 7 focused modules, eliminate the `input.zig` ↔ `mouse.zig` circular dependency, then move the entire subsystem to `src/core/input/` where it belongs architecturally.

---

## Current State

### Files
| File | Lines | Responsibility |
|------|-------|----------------|
| `input.zig` | 486 | God module: XKB lifecycle, keybind building, dispatch map, action dispatch (200-line switch), key events, cursor setup, mouse re-exports |
| `mouse.zig` | 311 | Button/motion handling, press classification, drag routing, config mouse bind lookup |
| `keybind.zig` | 251 | Keybind resolution (keysym→keycode), dispatch map (`KeybindResolver`), conflict reporting |
| `xkbcommon.zig` | 268 | Live XKB state (`XkbState`), retry init, rebuild on mapping change, detectable auto-repeat |
| `grabs.zig` | 227 | Root-window grab installation (keybinds + Super+Button), failure reporting |
| `keymap.zig` | 148 | Pure: keycode→keysym table + reverse index from `xkb_keymap` |
| `keysyms.zig` | 39 | Pure: keysym↔name parsing (borrows `@cImport` from `keymap.zig`) |

### Dependency Graph (Current)
```
main.zig → input.zig ←→ mouse.zig (CIRCULAR)
                ↓
            grabs.zig (called by main.zig, events.zig)
                ↓
            keybind.zig → keymap.zig ← keysyms.zig
                ↓
            xkbcommon.zig → keymap.zig
```

### Importers of `input` (4 files)
| File | Uses |
|------|------|
| `src/main.zig` | `initXkb`, `deinitXkb`, `setup`, `buildKeybinds`, `deinitKeybinds`, `resolvedKeybinds` |
| `src/core/loop/reload.zig` | `buildKeybinds`, `resolvedKeybinds` |
| `src/core/loop/events.zig` | `handleMappingNotify`, `resolvedKeybinds`, `handleKeyPress`, `handleKeyRelease`, `handleButtonPress`, `handleButtonRelease`, `handleMotionNotify` |
| `src/input/mouse.zig` | `executeAction`, `grafted` (via `dispatch` alias) |

---

## Target Architecture

### Final File Structure (`src/core/input/`)
```
src/core/input/
├── xkb.zig         # XKB state + init/deinit/rebuild + handleMappingNotify (~200 lines)
├── keybinds.zig    # Keybind resolution + dispatch map + grab installation (~400 lines)
├── dispatch.zig    # executeAction + grafted (~250 lines)  ← breaks cycle
├── events.zig      # handleKeyPress/Release only (~80 lines)
├── cursor.zig      # Root cursor theming (~50 lines)
├── mouse.zig       # Mouse handlers + drag (~310 lines, updated imports)
└── keymap.zig      # Pure keymap tables + keysym parsing (~190 lines)
```

### New Dependency Graph (Acyclic)
```
main.zig → xkb.zig
         → keybinds.zig
         → dispatch.zig ← mouse.zig (NO CYCLE)
         → events.zig
         → cursor.zig
```

### Top-Level Structure After Move
```
src/
├── core/
│   ├── input/        # Foundation: X11 input handling
│   ├── loop/         # Event loop, pipeline, reload
│   ├── x11/          # XCB primitives, atoms
│   ├── display/      # RandR
│   └── architecture/ # model, contract
├── bar/              # Engine
├── tiling/           # Engine
├── window/           # Engine
├── config/           # Engine
├── test/
└── actions/
```

---

## Implementation Phases

### Phase 1: Trivial Merges (Zero Risk, Do First)

#### 1.1 Merge `keysyms.zig` → `keymap.zig`
**File**: `keymap.zig`
- Move `keysymFromName` and `keysymGetName` from `keysyms.zig` into `keymap.zig` (append at end)
- Remove `keysyms.zig` file
- `keymap.zig` already imports `keymap.xkb` — no import changes needed

**Verification**:
```bash
zig build check
dev/scripts/xtest.sh zig build test -Dtest-filter=keymap
```

#### 1.2 Merge `grabs.zig` → `keybinds.zig` (new file, created in Phase 3)
**Note**: `grabs.zig` will be inlined into `keybinds.zig` during Phase 3. Skip separate merge step.

---

### Phase 2: Extract `dispatch.zig` (Breaks Cycle, High Value)

#### 2.1 Create `src/input/dispatch.zig` (new file)
```zig
//! Action dispatch: executeAction + grafted. Shared by key and mouse paths.

const std = @import("std");
const core = @import("core");
const types = @import("types");
const masks = @import("masks");
const log = @import("log");
const actions = @import("actions");
const pipeline = @import("pipeline");
const window = @import("window");
const query = @import("query");
const focus = @import("focus");
const spawn = @import("spawn");
const atoms = @import("atoms");
const lifecycle = @import("lifecycle");
const surfaces = @import("surfaces").Surfaces;
const constants = @import("constants");
const action_mod = @import("action");

// --- COPY FROM input.zig (lines 319-486) ---
// dirSign, toggleBarPosition, closeWindow, executeAction, grafted
// Everything from "// ---------------------------------------------------------------------------
// // Action dispatch (former dispatch.zig, merged 2026-10-10)" to end of file

// Key exports:
// pub fn executeAction(action: *const types.Action) void
// pub inline fn grafted(comptime tag: std.meta.Tag(types.Action), comptime op: anytype, arg: anytype) void
```

#### 2.2 Update `src/input/mouse.zig`
```zig
// Line 26: Change
// const dispatch = @import("input");
// To:
const dispatch = @import("dispatch");
```
**Cycle is now broken** — `mouse.zig` no longer imports `input.zig`.

#### 2.3 Update `src/input/input.zig`
- Remove all action dispatch code (from `toggleBarPosition` to end of file, lines 319-486)
- Add near top: `const dispatch = @import("dispatch");`
- Add re-exports for backward compat during transition:
  ```zig
  pub const executeAction = dispatch.executeAction;
  pub const grafted = dispatch.grafted;
  ```

**Verification**:
```bash
zig build check
dev/scripts/xtest.sh zig build test
# Verify no circular import:
grep -r "import.*input" src/input/mouse.zig  # Should show only "dispatch"
```

---

### Phase 3: Split `input.zig` into Focused Modules

#### 3.1 Create `src/input/xkb.zig` (new)
```zig
//! XKB keyboard state management: init, deinit, rebuild on mapping change.

const std = @import("std");
const core = @import("core");
const constants = @import("constants");
const log = @import("log");
const keymap = @import("keymap");
const xkb = keymap.xkb;

// --- MOVE from input.zig ---
// var xkb_state: ?XkbState = null;
// getXkbState(), getXkbStateMut()

// --- MOVE from xkbcommon.zig (ENTIRE FILE) ---
// XkbState struct + all its methods
// enableDetectableAutoRepeat, retry logic, keymapOnce, etc.
// XkbState.init, XkbState.deinit, XkbState.rebuild
// keycodeToKeysym, keysymToKeycode
// handleMappingNotify (from input.zig, but uses XkbState.rebuild)
```

**Exports**:
- `pub fn initXkb(conn: core.Connection) !void`
- `pub fn deinitXkb() void`
- `pub fn handleMappingNotify(keyboard: bool) bool`
- `pub fn getXkbState() ?*const XkbState`
- `pub const XkbState = struct { ... }` (if needed externally)

**Delete**: `src/input/xkbcommon.zig` after verification.

#### 3.2 Create `src/input/keybinds.zig` (new)
```zig
//! Keybind resolution, dispatch map building, and grab installation.

const std = @import("std");
const log = @import("log");
const types = @import("types");
const masks = @import("masks");
const keymap = @import("keymap");
const xkb = @import("xkb");
const grabs = @import("grabs");  // Temporary, will inline below
const core = @import("core");

// --- MOVE from input.zig ---
// var keybind_resolver: keybind.KeybindResolver
// var resolved_binds: []keybind.ResolvedBind
// buildKeybinds(), resolvedKeybinds(), deinitKeybinds()

// --- MOVE from keybind.zig (ENTIRE FILE) ---
// KeybindResolver, DispatchEntry, resolveKeycodes, reportUnresolved
// logShadowConflict, entryLessThan, byKey, ResolvedBind

// --- INLINE from grabs.zig (ENTIRE FILE) ---
// grabKeybindings, grabMouseButtons, fillGrabCookies, checkGrabCookies
// undeliverableMouseBindReason, MouseGrabSpec, mouse_grab_buttons
// FailureReporter, CookieEntry, MouseGrabLabel, MouseGrab
// Update calls to use xkb.keysymToKeycode instead of keybind.state.keysymToKeycode
```

**Exports**:
- `pub fn buildKeybinds(keybindings: []types.Keybind) void`
- `pub fn resolvedKeybinds() []const keybind.ResolvedBind`
- `pub fn deinitKeybinds() void`
- `pub fn grabKeybindings(resolved: []const keybind.ResolvedBind) void`
- `pub fn grabMouseButtons() void`
- `pub const KeybindResolver = ...`
- `pub const ResolvedBind = ...`
- `pub const MouseGrabSpec = ...`
- `pub const mouse_grab_buttons = ...`
- `pub fn undeliverableMouseBindReason(mb: types.MouseBind, grab: MouseGrabSpec) ?[]const u8`

**Delete**: `src/input/keybind.zig` and `src/input/grabs.zig` after verification.

#### 3.3 Create `src/input/events.zig` (new)
```zig
//! Key event handlers.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const masks = @import("masks");
const log = @import("log");
const focus = @import("focus");
const xkb = @import("xkb");
const keybinds = @import("keybinds");
const surfaces = @import("surfaces").Surfaces;
const dispatch = @import("dispatch");
const build_options = @import("build_options");
const time = @import("time");
const constants = @import("constants");
const action_mod = @import("action");

// --- MOVE from input.zig ---
// key_profile (profiler)
// handleKeyPress, handleKeyRelease
// (handleMappingNotify MOVED to xkb.zig)
```

**Exports**:
- `pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) void`
- `pub fn handleKeyRelease(event: *const xcb.xcb_key_release_event_t) void`

#### 3.4 Create `src/input/cursor.zig` (new)
```zig
//! Root window cursor theming.

const core = @import("core");
const xcb = core.xcb;
const log = @import("log");
const constants = @import("constants");
const mouse = @import("mouse");

// --- MOVE from input.zig ---
// Context, extern fn declarations
// setupRoot()
// setup() // calls setupRoot + mouse.reportUndeliverableMouseBinds()
```

**Exports**:
- `pub fn setup(conn: core.Connection, screen: core.Screen) void`

#### 3.5 Update `src/input/mouse.zig` Imports
```zig
// Remove: const dispatch = @import("dispatch");  // Already done in Phase 2
// Add imports for types it uses directly:
const types = @import("types");
const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const masks = @import("masks");
const log = @import("log");
const window = @import("window");
const query = @import("query");
const focus = @import("focus");
const keybind = @import("keybind");  // For logShadowConflict
const grabs = @import("grabs");       // For undeliverableMouseBindReason, MouseGrabSpec
const actions = @import("actions");
const surfaces = @import("surfaces").Surfaces;

// dispatch is already imported as @import("dispatch")
```

**Note**: `mouse.zig` still uses `grabs.MouseGrabSpec` and `grabs.undeliverableMouseBindReason` — these are now in `keybinds.zig`. Update:
```zig
// Change:
const grabs = @import("grabs");
// To:
const keybinds = @import("keybinds");
// And update references: grabs.MouseGrabSpec → keybinds.MouseGrabSpec, etc.
```

#### 3.6 Delete `src/input/input.zig`
After all code moved and verified, delete the file.

**Verification after Phase 3**:
```bash
zig fmt --check .
zig build check
dev/scripts/xtest.sh zig build test
# Verify all 4 importers still work (they use facade re-exports for now)
```

---

### Phase 4: Move `src/input/` → `src/core/input/`

#### 4.1 Move Directory
```bash
mv src/input src/core/input
```

#### 4.2 Update Imports in 4 Caller Files

**`src/main.zig`**:
```zig
// Change:
const input = @import("input");
// To individual imports:
const xkb = @import("core/input/xkb");
const keybinds = @import("core/input/keybinds");
const cursor = @import("core/input/cursor");

// Update calls:
// input.initXkb → xkb.initXkb
// input.deinitXkb → xkb.deinitXkb
// input.setup → cursor.setup
// input.buildKeybinds → keybinds.buildKeybinds
// input.deinitKeybinds → keybinds.deinitKeybinds
// input.resolvedKeybinds → keybinds.resolvedKeybinds
```

**`src/core/loop/reload.zig`**:
```zig
// Change:
const input = @import("input");
// To:
const keybinds = @import("core/input/keybinds");

// Update calls:
// input.buildKeybinds → keybinds.buildKeybinds
// input.resolvedKeybinds → keybinds.resolvedKeybinds
```

**`src/core/loop/events.zig`**:
```zig
// Change:
const input = @import("input");
// To:
const xkb = @import("core/input/xkb");
const keybinds = @import("core/input/keybinds");
const events = @import("core/input/events");
const mouse = @import("core/input/mouse");

// Update calls:
// input.handleMappingNotify → xkb.handleMappingNotify
// input.resolvedKeybinds → keybinds.resolvedKeybinds
// input.handleKeyPress → events.handleKeyPress
// input.handleKeyRelease → events.handleKeyRelease
// input.handleButtonPress → mouse.handleButtonPress
// input.handleButtonRelease → mouse.handleButtonRelease
// input.handleMotionNotify → mouse.handleMotionNotify
```

**`src/core/input/mouse.zig`** (already in new location):
```zig
// Update internal imports from relative to absolute:
// @import("dispatch") → @import("core/input/dispatch")
// @import("keybinds") → @import("core/input/keybinds")
// @import("xkb") → @import("core/input/xkb")
// etc.
```

#### 4.3 Update `dev/scripts/check-layers.sh` Allowlist
Replace 4 entries:
```bash
# OLD (lines ~180, 210, 215, 220):
src/input/xkbcommon.zig
src/input/input.zig
src/input/mouse.zig
src/input/grabs.zig

# NEW:
src/core/input/xkb.zig
src/core/input/dispatch.zig
src/core/input/mouse.zig
src/core/input/keybinds.zig
```

#### 4.4 Update Test Files
```bash
# Find and update test imports:
grep -r "@import.*input" src/test/ --include="*.zig"
```
Likely files:
- `src/test/input/` → move to `src/test/core/input/` or update imports
- Any test using `keybind.KeybindResolver` → `keybinds.KeybindResolver`
- Any test using `xkbcommon.XkbState` → `xkb.XkbState`

---

### Phase 5: Cleanup & Verification

#### 5.1 Verify No Stale References
```bash
# Should return nothing:
grep -r "src/input" src/ --include="*.zig" | grep -v test | grep -v PLAN
grep -r "@import(\"input\")" src/ --include="*.zig"
```

#### 5.2 Run Full Verification Suite
```bash
# Format
zig fmt --check .

# Layer checks (critical)
zig build check

# Unit tests (with Xvfb)
dev/scripts/xtest.sh zig build test

# Modularity check (optional, heavy)
dev/scripts/check-modularity.sh -j 4
```

#### 5.3 Verify Module Stems
```bash
zig build modules
# Should show unique stems: xkb, keybinds, dispatch, events, cursor, mouse, keymap
# (No "input" stem — that was the facade, now gone)
```

---

## Detailed Function Migration Map

| Function/Type | From | To |
|---------------|------|----|
| `keysymFromName`, `keysymGetName` | `keysyms.zig` | `keymap.zig` |
| `XkbState`, `initXkb`, `deinitXkb`, `handleMappingNotify`, `getXkbState`, `enableDetectableAutoRepeat`, retry logic | `xkbcommon.zig` + `input.zig` | `xkb.zig` |
| `KeybindResolver`, `resolveKeycodes`, `reportUnresolved`, `ResolvedBind`, `DispatchEntry`, `buildKeybinds`, `resolvedKeybinds`, `deinitKeybinds` | `keybind.zig` + `input.zig` | `keybinds.zig` |
| `grabKeybindings`, `grabMouseButtons`, `fillGrabCookies`, `checkGrabCookies`, `undeliverableMouseBindReason`, `MouseGrabSpec`, `mouse_grab_buttons`, `FailureReporter` | `grabs.zig` | `keybinds.zig` |
| `executeAction`, `grafted`, `toggleBarPosition`, `closeWindow`, `dirSign` | `input.zig` | `dispatch.zig` |
| `handleKeyPress`, `handleKeyRelease`, `key_profile` | `input.zig` | `events.zig` |
| `setupRoot`, `setup` | `input.zig` | `cursor.zig` |
| (mouse handlers unchanged) | `mouse.zig` | `mouse.zig` (relocated) |

---

## Layer Compliance Notes

After move, `check-layers.sh` allowlist entries:

| File | Allowlist Entry | Reason |
|------|-----------------|--------|
| `src/core/input/xkb.zig` | One-shot XKB setup | `enableDetectableAutoRepeat`, retry init |
| `src/core/input/dispatch.zig` | Action dispatch + root cursor | `executeAction`, `toggleBarPosition`, `setupRoot` |
| `src/core/input/mouse.zig` | Grab-unwind flushes | `finishGrab` (allow_events + flush) |
| `src/core/input/keybinds.zig` | Grab-installation flushes | `grabKeybindings`, `grabMouseButtons` flush cookies |
| `src/core/input/keymap.zig` | (none needed) | Pure, X-free |
| `src/core/input/events.zig` | (none needed) | Event handlers, no wire mutations |
| `src/core/input/cursor.zig` | (part of dispatch) | Root cursor theming (startup) |

---

## Test Files to Update

Search:
```bash
grep -rn "input" src/test/ --include="*.zig" | grep -E "import|@import"
```

Expected updates:
- `src/test/input/*` → move to `src/test/core/input/` OR update imports to `core/input/...`
- `keybind.KeybindResolver` → `keybinds.KeybindResolver`
- `xkbcommon.XkbState` → `xkb.XkbState`
- `input.buildKeybinds` → `keybinds.buildKeybinds`
- `input.resolvedKeybinds` → `keybinds.resolvedKeybinds`
- `input.handleKeyPress` → `events.handleKeyPress`
- `input.handleButtonPress` → `mouse.handleButtonPress`

---

## Rollback Plan

If something breaks at any phase:
```bash
# Phase 1-3: Revert input/ changes
git checkout -- src/input/

# Phase 4: Revert move
mv src/core/input src/input
git checkout -- src/main.zig src/core/loop/reload.zig src/core/loop/events.zig dev/scripts/check-layers.sh
```

Each phase is independently verifiable with `zig build check` + tests.

---

## Success Criteria

- [ ] `zig fmt --check .` passes
- [ ] `zig build check` passes (no layer violations)
- [ ] `dev/scripts/xtest.sh zig build test` passes (full suite)
- [ ] No circular imports (`grep -r "import.*core/input" src/core/input/mouse.zig` shows only `dispatch`)
- [ ] `zig build modules` shows unique stems (no "input" stem)
- [ ] `src/input/` directory **deleted**
- [ ] `src/core/input/` exists with 7 files
- [ ] All 4 callers updated to direct imports (no facade)
- [ ] Each module < 450 lines, single responsibility

---

## Estimated Effort

| Phase | Effort | Risk |
|-------|--------|------|
| 1.1 Merge keysyms | 15 min | None |
| 2 Extract dispatch | 1-2 hrs | Medium (cycle break) |
| 3 Split input.zig | 2-3 hrs | Medium (large moves) |
| 4 Move to core/input | 1 hr | Low (mechanical) |
| 5 Cleanup & test | 1 hr | Low |

**Total: ~5-7 hours** for complete refactor + relocation.

---

## Agent Handoff Notes

1. **Start with Phase 1.1** — trivial, builds confidence
2. **Phase 2 is the critical path** — breaks the cycle, enables clean split
3. **Use `zig build check` constantly** — catches layer violations early
4. **Run tests after each phase** — `dev/scripts/xtest.sh zig build test -Dtest-filter=<module>`
5. **`mouse.zig` is the canary** — if it compiles after Phase 2, the cycle is broken
6. **Check `dev/scripts/check-layers.sh`** — update allowlist entries for renamed/moved files
7. **No facade** — callers import exactly what they need (4 files to update)
8. **Module stems are global** — moving directories doesn't change stems; imports use full path `core/input/...`

The codebase is well-structured; the refactor follows existing patterns (see `dispatch.zig` merge history in `input.zig` comments, and the `core/` subsystem organization).

Good luck!