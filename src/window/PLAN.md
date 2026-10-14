# src/window — Final Corrected Plan (B1-B6 + R1-R10 Applied)

This plan addresses the three concerns in `src/window/TODO.md`, fixing all 6
blockers (B1-B6) from the round-2/3 surveys and all 10 residual defects
(R1-R10) from the round-4 survey (patched in place by the survey agent).

---

## Blocker Fixes Summary

| Blocker | Root Cause | Fix |
|---------|------------|-----|
| **B1** | Methods at file scope; `ws()` collides with `ws` field | Methods **inside** `Model` struct; drop `ws()` accessor (callers use `m.ws[i]` directly); export `WsState` `pub` |
| **B2** | `Store` concrete instance breaks generic users | Keep `pub const Store = bounded.Store;` (generic); name concrete `StoreT` (as model.zig:321 does) |
| **B3** | Shim installed too late (step 5 vs steps 1-4) | **Same step**: create `domain.zig` + `wm_state.zig` + install `model.zig` shim atomically |
| **B4** | File moves separated from rewrites | **Bundle each move + all rewrites in one step**; keep `query.zig` name (stem free, no churn) |
| **B5** | Title-seam: null deref, missing `discardTitleCookies`, circular init/deinit, missing `TitleCookies` | **Keep wincache in window layer** (renamed `title_cache.zig`); bar importers keep their **direct import**, renamed (`@import("wincache")` → `@import("title_cache")`, the pattern bar/state.zig:22 and render.zig:29 already use) — no seam, no providerOf, no registry change |
| **B6** | Module subdir moves: no steps, no purpose | **Drop subdir restructure**; modules stay flat; `check-layers.sh`/`check-modularity.sh` unchanged |

---

## Corrected Architecture

### Core Files (Stem-Safe)

```
core/
├── wm_state.zig                      # PUBLIC FACADE: Model + methods inside + re-exports of domain
└── architecture/
    └── domain.zig                    # PRIVATE pure vocabulary + constants + Store generic (no Model)

src/window/
└── title_cache.zig                   # window-side title cache (stem rename of wincache)
```

### `core/architecture/domain.zig` — Pure Vocabulary + Generic Store (PRIVATE)

Only `wm_state.zig` imports this file. No forward-declares, no Model.

```zig
// Rect, Margins, SizeHints, Mask, WSId (= WorkspaceId), WindowId
// LayoutParams, BaseMode, Presence, RestoreOrder, ConfigureReq, HonorDecision
// Constants: max_workspaces, max_tiled_windows, store_capacity, mru_capacity,
//            max_primary_count, min_master_width, max_master_width, max_layouts, ALL_MASK
// Pure helpers: satI16, toXcbCoord, wrapIndex, bit, maskedOn, lowestBit,
//               doubledBorder, isValidWorkspaceIndex, capPrimaryCount

// Generic Store (re-exported from bounded.zig) — MUST stay the generic:
// ledger.zig:69 and model_test.zig:37 instantiate it with other parameters.
pub const Store = bounded.Store;
```

### `core/wm_state.zig` — Public Facade (Model + Methods Inside)

The single import surface: re-exports all of `domain` plus
`Entry`/`WsState`/`Model` and every free function, so the mass sed has ONE
target — `@import("model")` → `@import("wm_state")`.

```zig
const domain = @import("domain");
const bounded = @import("bounded");

// Re-export vocabulary — EVERY decl of domain, one line each.
// The sketch shows the types; the constants (max_workspaces, store_capacity,
// mru_capacity, max_tiled_windows, max_tiled_per_ws, max_primary_count,
// min/max_master_width, max_layouts, ALL_MASK, WorkspaceId, Margins, ...) and
// pure helpers (bit, satI16, ...) follow the same `pub const X = domain.X;`
// pattern — the shim re-exports them THROUGH wm_state.
pub const WindowId = domain.WindowId;
pub const WSId = domain.WSId;
pub const Mask = domain.Mask;
pub const Rect = domain.Rect;
pub const SizeHints = domain.SizeHints;
pub const LayoutParams = domain.LayoutParams;
pub const BaseMode = domain.BaseMode;
pub const Presence = domain.Presence;

// Concrete Store type
pub const StoreT = bounded.Store(WindowId, Entry, domain.store_capacity);
pub const Store = domain.Store;  // generic re-export

// WsState MUST be pub (used by reconcile, bar, etc.)
pub const WsState = struct {
    tiled_order: bounded.BoundedList(WindowId, domain.max_tiled_windows) = .{},
    focus_mru: bounded.BoundedList(WindowId, domain.mru_capacity) = .{},
    params: LayoutParams = .{},
};

pub const Entry = struct {
    mask: Mask,
    anchor: BaseMode,
    size_hints: SizeHints = .{},
    home_ws: ?WSId = null,
    presence: Presence = .present,
    covering_ws: ?WSId = null,
};

// THE single runtime state struct — methods LIVE INSIDE
pub const Model = struct {
    store: StoreT = .{},
    ws: [domain.max_workspaces]WsState = [_]WsState{.{}} ** domain.max_workspaces,
    current: WSId = WSId.fromIndex(0),
    focused: ?WindowId = null,
    all_view_active: bool = false,

    // ---- Inline query methods (inside struct) ----
    pub inline fn isManaged(self: *Model, win: WindowId) bool {
        return self.store.has(win);
    }
    pub inline fn getFocused(self: *Model) ?WindowId {
        return self.focused;
    }
    pub inline fn getCurrentWorkspace(self: *Model) WSId {
        return self.current;
    }
    pub inline fn isAllViewActive(self: *Model) bool {
        return self.all_view_active;
    }
    pub inline fn entry(self: *Model, win: WindowId) ?*Entry {
        return self.store.getPtr(win);
    }
    // NO ws() accessor — callers use m.ws[i] directly
};

// Free functions — signatures copied VERBATIM from model.zig:344-771.
// Note the *const Model group (findHome, visibleOn, visibleEntry, tiledCountOnWs,
// coveringWsOf, isCovering, isCoveringOn, collectCyclePool, focusedBorderColor):
// do NOT retype them as *Model.
pub fn removeValue(list: anytype, win: WindowId) void { ... }
pub fn findHome(m: *const Model, win: WindowId) ?WSId { ... }
pub fn detachTiledToFloating(m: *Model, e: *Entry, win: WindowId, rect: Rect) void { ... }
pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) error{CapacityFull}!void { ... }
pub fn unregister(m: *Model, win: WindowId) void { ... }
pub fn visibleOn(m: *const Model, win: WindowId, ws: WSId) bool { ... }
pub inline fn visibleEntry(m: *const Model, e: *const Entry, ws: WSId) bool { ... }
pub inline fn isPinned(e: Entry) bool { ... }
pub inline fn taggedOn(e: Entry, ws: WSId) bool { ... }
pub fn tiledCountOnWs(m: *const Model, ws: WSId) usize { ... }
pub fn coveringWsOf(m: *const Model, win: WindowId) ?WSId { ... }
pub inline fn isCovering(m: *const Model, win: WindowId) bool { ... }
pub fn isCoveringOn(m: *const Model, win: WindowId, ws: WSId) bool { ... }
pub fn coveringOccupantOnWs(m: *Model, ws: WSId) ?WindowId { ... }
pub fn coveringOccupants(m: *Model, buf: []?WindowId) void { ... }
pub const RestoreOrder = domain.RestoreOrder;
pub const ConfigureReq = domain.ConfigureReq;
pub const HonorDecision = domain.HonorDecision;
pub fn setFocus(m: *Model, win: WindowId) void { ... }
pub inline fn focusedBorderColor(m: *const Model, win: WindowId, focused_px: u32, unfocused_px: u32) u32 { ... }
pub fn applyParamsDelta(m: *Model, ws: WSId, delta: LayoutParams) void { ... }
pub fn clearFocus(m: *Model) void { ... }
pub fn fallbackFocusCandidate(m: *Model, ws: WSId, excluded: ?WindowId) ?WindowId { ... }
pub fn collectCyclePool(m: *const Model, ws: WSId, buf: []WindowId) usize { ... }
pub fn reorderTiled(m: *Model, win: WindowId, idx_in: usize) void { ... }
pub fn stepTiled(m: *Model, win: WindowId, dir: i32) void { ... }
pub fn swapPrimary(m: *Model) void { ... }
pub fn swapFocusedWithPrevious(m: *Model) void { ... }
pub fn adjustPrimaryWidth(m: *Model, delta: f32) void { ... }
pub fn applyConfigReload(m: *Model, tpl: LayoutParams) void { ... }
```

---

## Module-Local State Stays in Modules (No Core Slots)

- `minimize.zig` → `var g_recs: bounded.BoundedList(...)`
- `fullscreen.zig` → `var g_pending_bars: PendingBarTable`
- `floating.zig` → drag state vars
- Core knows nothing about them. Modules access their own vars directly.

---

## Query Facade — Keep `query.zig` (Stem Free, No Churn)

**Do NOT rename/move `query.zig`.** It stays at `src/window/state/query.zig` (stem `query` is free and uniquely owned). It reads from `pipeline.state()` → `*Model`.

```zig
// query.zig — import barrier for core/loop, core/proc, input, bar
pub fn isManaged(win: u32) bool {
    const m = m() orelse return false;
    return m.isManaged(win);
}

pub inline fn isInvalidWindow(win: u32) bool {
    return win == 0 or win == core.getState().root or usable_area.isSurfaceWindow(win);
}

pub inline fn getWorkspaceCount() usize {
    if (!core.isReady()) return 1;
    const cs = core.getState().config.workspaces;
    return if (cs.enabled) @min(@as(usize, cs.count), wm_state.max_workspaces) else 1;
}
// ... other hub-dependent predicates
```

### `workspace_labels` → Inline in `src/bar/modules/tags.zig` (Flat File)

```zig
// tags.zig (flat, no tags/ directory)
pub const workspace_labels: [wm_state.max_workspaces][]const u8 = blk: { ... };
```

### `src/window/state/wincache.zig` → Renamed `src/window/title_cache.zig` (B5 Fix)

**Stay in window layer.** Rename stem `wincache` → `title_cache`; logic unchanged. Bar readers keep their direct import (see below).

```zig
// title_cache.zig — window-side title cache (unchanged logic, stem rename)
pub const TitleCookies = struct { ... };
pub fn fireTitleCookies(conn: core.Connection, win: u32) TitleCookies { ... }
pub fn discardTitleCookies(conn: core.Connection, cookies: TitleCookies) void { ... }
pub fn collectTitleCookies(conn: core.Connection, win: u32, cookies: TitleCookies) void { ... }
pub fn refreshTitle(conn: core.Connection, win: u32) bool { ... }
pub fn peekTitle(win: u32) []const u8 { ... }
pub fn removeWindow(win: u32) void { ... }
pub fn init(alloc: std.mem.Allocator) void { ... }
pub fn deinit() void { ... }
```

### Bar Reads via Direct Import (Renamed)

Bar already imports the cache directly today (`bar/state.zig:22` and
`render/render.zig:29` do `@import("wincache")`). After the rename they do
`@import("title_cache")` — no contract hook, no registry entry, no
`providerOf` (a non-`modules/` file cannot bind `window_modules`, so a
provider lookup would always be null).

```zig
// bar/render/render.zig (pattern unchanged, import renamed)
const title_cache = @import("title_cache");
const title = title_cache.peekTitle(e.window);
```

**No seam, no build generation, no registry change, no null-deref risk.**
Window owns the cache; bar reads it (sanctioned direction).

---

## Focus Protocol — Merge ICCCM + Single File ~750 Lines

### Merge ICCCM Focus Bits into `focus.zig`

- Move `InputModel`, `InputModelResolution`, `peekInputModelResolved`, `provisionalResolution`, `sendWMTakeFocusKnown` → `focus.zig`
- Move focus-property cache (`CachedProps`, `cache_slots`, `put`/`peek`/`evict`/`reset`) → `focus.zig`
- `fireWMProtocolsQuery`/`drainWMProtocolsReply`/`populateFocusCacheFromCookies` stay in `icccm.zig` (admission) but delegate to `focus.zig` for cache write
- `refreshCachedPropHalf` → `focus.zig`

### Clean Up `focus.zig` Internal Structure (Single File, Clear Sections)

1. State + init/deinit + pure accessors
2. Etiquette table (pure data)
3. Resolve predicates (`resolveFocusTarget`, `isWindowMapped`)
4. Two-phase: `prepareFocus`/`prepareClearFocus`/`yieldsModelFocus`
5. Two-phase: `applyPendingFocus`/`clearTail`/`grabButtons`/`focusNow`/`advertiseActiveWindow`
6. Settle: `beginTilingOpSettle`/`drainTilingOpSettle`
7. Grab-wrapped API: `grabFocus`/`grabFocusWithDuty`/`cycleFocus`/`cycleTarget`

### Move Suppression Policy from `client_events.zig` → `focus.zig`

- `suppressSpawnCrossing`/`crossingShouldDrop` → `focus.zig`
- `maybeFocusWindow` → `focus.zig` (hover focus policy)

---

## Client Events — Clean Up In Place (No Split)

**Keep `src/window/protocol/client_events.zig` as single file (~250 lines):**
- Each handler: validates event shape, extracts data, calls **one** `actions.*`/`focus.*`/`registry.*` function
- No `pipeline.*` imports
- Clear section comments for three event classes

---

## Borders — Relocate Sweeps

- `updateWorkspaceBorders` / `updateFloatingWindowBorders` / `reloadBorders` → `src/window/sync/border_sweeps.zig` (new file, stem `border_sweeps`)
- `protocol/borders.zig` keeps only pure helpers: `isBehindCoveringWindowWith`, `resolveBorderColorWith`, `applyWidth`, `applyWith`

---

## Contract.zig Migration — Explicit Steps

### Update `contract.zig` Hook Signatures

```zig
// WindowModule.init is fn () anyerror!void (NOT taking Model/Config/Allocator)
// Mutations use *Model from wm_state.zig (the public facade)
pub const WindowModule = struct {
    init: ?*const fn () anyerror!void = null,
    deinit: ?*const fn () void = null,
    
    // Mutations — use *wm_state.Model
    sendToWs: ?*const fn (*wm_state.Model, WindowId, WSId) void = null,
    // ... etc.
    
    // Serialization — unchanged (*const Model)
    serializeWindow: ?*const fn (*const wm_state.Model, WindowId, Allocator) ?[]const u8 = null,
    deserializeWindow: ?*const fn (WindowId, []const u8, *wm_state.Model) bool = null,
    
    // ... rest unchanged
};
```

### Migration Steps (Atomic with Shim Install)
1. Add `wm_state` import to `contract.zig` (the vocab types it already needs — `model.Rect`, `model.store_capacity`, `model.SizeHints` at :794-813 — come through wm_state's re-exports)
2. Update hook signatures from `*model.Model` → `*wm_state.Model`
3. Update 4 module implementations (import `wm_state`, use `*wm_state.Model`)
4. `registry.zig` dispatch is generic (`@field`+`@call`) — likely no edit
5. Run `zig build check`

---

## Layer Guards — Explicit Updates

### `dev/scripts/check-layers.sh`
- Line 81: unchanged (modules stay flat)
- Rule 3 allowed imports: `core/architecture/model.zig` → `core/architecture/domain.zig` + `core/wm_state.zig`

### `build.zig`
- `assertPureLayerImports`: remove `model`, add `domain`, `wm_state`
- Plugin-template check: update paths

---

## Plugin-Template Migration — Explicit Steps

### `dev/plugin-template/provider.zig` + `layout.zig`
- `@import("model")` → `@import("wm_state")`
- `*model.Model` → `*wm_state.Model` (and `*const model.Model` → `*const wm_state.Model`)
- `model.LayoutParams`/`model.WindowId`/`model.WSId` → `wm_state.*`, etc.

### Verification
- `zig build check-plugin-template` passes

---

## Check-Modularity Script — No Changes Needed (B6 Fix)

Modules stay flat. `check-modularity.sh` lines 212-253 remain valid.

---

## Protocol Directory — Kept (5 Files)

```
src/window/protocol/
├── focus.zig              # ~750 lines (merged ICCCM, clear sections)
├── client_events.zig      # ~250 lines (cleaned up)
├── icccm.zig              # Admission queries only (trimmed)
├── borders.zig            # Pure helpers only
└── reply.zig              # Pure parsing
```

---

## Import Rewrite Strategy — Bundled with Moves

### Step 1 (Atomic): Create `domain.zig` + `wm_state.zig` + Install `model.zig` Shim

The shim is **generated mechanically from the old model.zig, not hand-picked**:
enumerate EVERY `pub` decl of model.zig:29-773 (≈70 of them) and re-export
each from its new home — wm_state for Model/Entry/WsState/free functions,
domain (via wm_state) for the vocabulary. Real code uses the decls the old
sketch omitted: `session.zig:23` `model.max_workspaces`, `:506`
`model.max_tiled_per_ws`, `contract.zig:794-813` `model.Rect` /
`model.store_capacity` / `model.SizeHints`, plus `WorkspaceId`,
`isValidWorkspaceIndex`, `doubledBorder`, `max_layouts`, `capPrimaryCount`,
`lowestBit`, `ALL_MASK`, `bit`, `satI16`, `toXcbCoord`, `wrapIndex`,
`maskedOn`, `min_master_width`, `max_master_width`, and the rest. Copy every
signature verbatim (the `*const Model` group especially).

```zig
// model.zig — FULL RE-EXPORT SHIM (deleted at step 18)
// Shape (one line per pub decl of the old file — ~70 lines total):
pub const WindowId = @import("wm_state").WindowId;       // re-export chain: wm_state → domain
pub const WSId = @import("wm_state").WSId;
pub const Entry = @import("wm_state").Entry;             // owned by wm_state
pub const WsState = @import("wm_state").WsState;         // owned by wm_state
pub const Store = @import("wm_state").Store;             // the GENERIC (bounded.Store)
pub const Model = @import("wm_state").Model;             // owned by wm_state
pub const max_workspaces = @import("wm_state").max_workspaces;
pub const store_capacity = @import("wm_state").store_capacity;
// ... every remaining pub const/fn/inline fn, likewise
pub const removeValue = @import("wm_state").removeValue;
pub const findHome = @import("wm_state").findHome;
// ...
```

### Step 16: Mass Import Rewrite (After All Moves)

```bash
# 1. model → wm_state. ONE target: wm_state re-exports all of domain, so
#    vocabulary and Model/function users are both covered.
sed -i 's/@import("model")/@import("wm_state")/g' $(grep -rl '@import("model")' src/ --include="*.zig")

# 2. Pipeline state accessor (run BEFORE any identifier-rename pass so
#    pipeline.model is never touched by it)
sed -i 's/pipeline\.model()/pipeline.state()/g' $(grep -rl 'pipeline\.[a-zA-Z]*model' src/ --include="*.zig")

# 3. wincache → title_cache (already run inside step 14; harmless if repeated)
sed -i 's/@import("wincache")/@import("title_cache")/g' $(grep -rl '@import("wincache")' src/ --include="*.zig")
sed -i 's/wincache\./title_cache./g' $(grep -rl 'wincache\.' src/ --include="*.zig")

# NOTES:
# - query.zig is NOT renamed — never touch @import("query").
# - sed rewrites import STRINGS only; identifiers stay bound via alias
#   (const model = @import("wm_state") keeps `model.` spellings working).
#   Optional follow-up, reviewed via git diff: rename those aliases
#   (`const model =` → `const wm_state =` + the call sites), running AFTER
#   the pipeline.model sed above.
```

---

## Execution Order (Each Step Verifiable)

| Step | Action | Verification |
|------|--------|--------------|
| 1 | **ATOMIC**: Create `core/architecture/domain.zig` + `core/wm_state.zig` + install `model.zig` shim | `zig build check` |
| 2 | Move hub-dependent predicates to `query.zig` (stays); pure predicates as `Model` methods | `dev/scripts/xtest.sh zig build test` |
| 3 | Move `workspace_labels` inline to `src/bar/modules/tags.zig` | `zig build check` |
| 4 | Update `contract.zig` hook signatures to `*wm_state.Model` | `zig build check` |
| 5 | Update 4 modules to use `*wm_state.Model` + own local vars (no `exts`) | `zig build check` |
| 6 | Update `registry.zig` dispatch (likely no edit) | `zig build check` |
| 7 | Verify `session.zig`/`seed.zig` need no manual edit (shim covers their `model.*` usage; sed at step 16 rewrites their imports) | `dev/scripts/xtest.sh zig build test` |
| 8 | Update layer guards (`check-layers.sh`, `build.zig`) | `zig build check` |
| 9 | Merge ICCCM focus bits into `focus.zig` | `dev/scripts/xtest.sh zig build test -Dtest-filter=focus` |
| 10 | Clean up `focus.zig` internal sections | `dev/scripts/xtest.sh zig build test -Dtest-filter=focus` |
| 11 | Move suppression policy from `client_events.zig` → `focus.zig` | `dev/scripts/xtest.sh zig build test -Dtest-filter=client_events` |
| 12 | Clean up `client_events.zig` in place | `dev/scripts/xtest.sh zig build test -Dtest-filter=client_events` |
| 13 | Relocate border sweeps → `src/window/sync/border_sweeps.zig` | `zig build check` |
| 14 | Rename `wincache.zig` → `src/window/title_cache.zig` (+ optional `wincache_test.zig` → `title_cache_test.zig`); run the two `wincache`→`title_cache` seds in the SAME step (window.zig, admission.zig, actions/manage.zig, bar/state.zig, render.zig, tests) | `dev/scripts/xtest.sh zig build test -Dtest-filter=bar` |
| 15 | Verify admission/PropertyNotify/title paths use `title_cache` (bar readers keep their direct import, renamed — no providerOf) | `dev/scripts/xtest.sh zig build test` |
| 16 | Run mass import rewrite (`model` → `wm_state` seds; see Import Rewrite section) | `zig build check` |
| 17 | Update `check-plugin-template`; migrate `dev/plugin-template/` | `zig build check-plugin-template` |
| 18 | Delete `src/core/architecture/model.zig` (shim) | `zig build check` |
| 19 | Verify `src/window/state/` contains only `query.zig` (wincache renamed out at step 14) | `zig build check` |

---

## Final Structure

```
core/
├── wm_state.zig                      # PUBLIC FACADE: Model + methods inside + re-exports of domain
└── architecture/
    └── domain.zig                    # PRIVATE pure vocabulary + constants + Store generic (no Model)

src/window/
├── modules/                          # FLAT (no subdirs)
│   ├── workspaces.zig                # Mutations (sendToWs, tagAdd, etc.)
│   ├── tiling.zig                    # Mutations (reorderTiled, etc.)
│   ├── fullscreen.zig                # Mutations + protocol hooks + g_pending_bars
│   ├── minimize.zig                  # Mutations + g_recs
│   └── floating.zig                  # Floating mutations + drag state
├── protocol/                         # KEPT (5 files)
│   ├── focus.zig                     # ~750 lines (merged ICCCM)
│   ├── client_events.zig             # ~250 lines (cleaned)
│   ├── icccm.zig                     # Admission queries only
│   ├── borders.zig                   # Pure helpers only
│   └── reply.zig                     # Pure parsing
├── sync/
│   └── border_sweeps.zig             # Border sweeps (stem border_sweeps)
├── state/
│   └── query.zig                     # Import barrier (stem query kept)
├── title_cache.zig                   # Window-side title cache (stem title_cache; bar imports directly)
├── actions/                          # Transitions (use *wm_state.Model)
├── admission.zig                     # Spawn pipeline (use *wm_state.Model)
├── registry.zig                      # Dispatch
└── window.zig                        # Facade (updated)

src/bar/modules/
├── title/
│   ├── title.zig                     # Render + TitleSnapshot from title_cache
│   ├── carousel.zig
│   ├── geom.zig
│   └── vocab.zig
└── tags.zig                          # Flat file, includes workspace_labels inline
```

---

## Verification Checklist

- [x] `zig build check` passes (all layer guards updated)
- [x] `dev/scripts/xtest.sh zig build test` passes (full suite: 598/598, 0 fail)
- [x] `zig build modules` shows **no duplicate stems**
- [x] Delete `src/bar/` → tree compiles, runs without title queries (window layer no-ops) [via check-modularity Tier 4/5]
- [x] Delete any single window module → tree compiles, zero residue [via check-modularity]
- [x] `grep -r '@import("model")' src/ dev/` returns nothing
- [x] `grep -r '@import("query")' src/` still resolves (`state/query.zig` kept)
- [x] `grep -r "title_cache\." src/` shows title cache usage
- [x] `protocol/` directory exists with 5 files
- [x] `window/state/` contains only `query.zig` (wincache renamed out)
- [x] Session save/restore works (`Model` serialization unchanged; session tests in suite)
- [x] Config reload works (`seed.zig` uses `wm_state.Model`)
- [x] `zig build check-plugin-template` passes
- [x] `zig build check-modularity` passes (31/31, flat modules)

---

## Out of Scope
- Changing focus protocol semantics
- Changing title cache capacity/eviction
- Changing bar title rendering/carousel
- Any config/user-facing changes

**This plan resolves B1-B6 and R1-R10. Every step is independently verifiable; the tree compiles at every step boundary.**

---

## Execution Status (2026-10-12)

All 19 steps executed. Full suite 598/598 through `xtest.sh`; `zig build check`,
`check-plugin-template`, and `check-modularity` (31/31) green; `zig fmt --check .`
clean. Deviations from the plan text, recorded for the record:

- **Step 8 folded into steps 1/18.** The build.zig pure-layer guard had to
  accept `wm_state`/`domain` at step 1 (the shim imports `wm_state`, which the
  old allowlist rejected), and check-layers.sh Rule 3's find list gained both
  pure roots at step 1; both lost the `model.zig` entries at step 18 with the
  shim.
- **Step 16 identifier-rename pass skipped (optional per plan).** Only import
  strings were rewritten; `const model = @import("wm_state")` aliases remain
  tree-wide and compile. The plugin-template got the full `wm_state.` rename
  (teaching material should show the real spelling).
- **Step 12 residual:** client_events.zig's ConfigureRequest path still calls
  `pipeline.state()`/`pipeline.mut()` to supply the `*Model` the honor hook
  takes; the crossing section — the suppression-policy subject of steps 11-12
  — is pipeline-free.
- `icccm_test.zig` kept its stem but was retargeted to `focus.*` (the moved
  cache/resolution API).
- AGENTS.md/README still name `model.zig` in prose (doc debt outside this
  plan's scope).