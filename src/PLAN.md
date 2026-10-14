# src/config/ — Dynamic Config Registry Plan

This plan transforms the config system from a manually-maintained, hard-coded structure into a **fully dynamic, auto-generated registry** where optional subsystems contribute their config fragments via a standard interface, and the build system generates the composed config struct and parser. Deleting a module leaves **zero trace** in config.

---

## Current State Problems

| Issue | Impact |
|-------|--------|
| `config/types.zig` hard-codes `tiling: ?TilingConfig`, `fullscreen_enabled`, etc. | Delete module → manual cleanup in 3+ files |
| `config/parse/schema.zig` has explicit knobs for each optional feature | Add module → edit central schema |
| Runtime flags (`tiling.enabled`, `fullscreen_enabled`, etc.) duplicate comptime `build_options.has_*` | Redundant, inconsistent |
| Module deletion leaves config debris | Violates "true modularity" |

---

## Target Architecture

```
src/
├── config/
│   ├── composed.zig          # GENERATED: Composed Config struct + parser
│   ├── core.zig              # CoreConfig (always present)
│   ├── reload.zig            # Reload orchestration
│   ├── model_seeding.zig     # Config → model seeding
│   ├── reload.zig
│   ├── parse/
│   │   ├── schema.zig        # Toml schema helpers (shared)
│   │   └── parse.zig         # Dispatcher (delegates to modules)
│   ├── sections/
│   ├── source/
│   ├── persist/
│   ├── vocab/
│   └── modules/              # Module configs live here
│       ├── tiling.zig
│       ├── workspaces.zig
│       ├── bar.zig
│       ├── fullscreen.zig
│       ├── floating.zig
│       └── minimize.zig
├── core/
│   ├── architecture/
│   │   ├── tiling_contract.zig
│   │   ├── contract_dispatch.zig
│   │   └── domain.zig
│   └── ...
├── bar/
│   ├── bar_contract.zig
│   └── modules/
│       └── ... (bar modules)
├── tiling/
│   ├── tiling_config.zig
│   └── ...
├── window/
│   ├── modules/
│   │   ├── workspaces/
│   │   │   └── config.zig
│   │   ├── fullscreen/
│   │   │   └── config.zig
│   │   ├── floating/
│   │   │   └── config.zig
│   │   └── minimize/
│   │       └── config.zig
│   └── ...
└── build.zig                 # Generates config_registry.zig
```

---

## Module Config Interface

Each optional subsystem provides a **config fragment** via a standard interface:

```zig
// src/tiling/tiling_config.zig (example)
pub const Config = struct {
    layouts: []LayoutConfig,
    default_layout: []const u8,
    master_count: u8,
    variants: std.StringHashMap([]const u8),
};

pub const Module = struct {
    name: []const u8 = "tiling",
    parse: fn (alloc: Allocator, node: toml.Node) !Config,
    defaults: fn () Config,
    validate: fn (cfg: Config) !void,
};
```

**Required exports per module:**
| Export | Type | Purpose |
|--------|------|---------|
| `Config` | struct | Module's config fragment |
| `Module` | struct | Metadata + function pointers |

---

## Build-Time Registry Generation

### 1. Discovery (`build.zig`)

```zig
fn discoverConfigModules(b: *std.Build) []ConfigModuleSource {
    var modules = std.ArrayList(ConfigModuleSource).init(b.allocator);
    defer modules.deinit();
    
    const src_dir = std.fs.Dir.openDir("src", .{});
    var iter = src_dir.iterate();
    while (iter.next()) |entry| {
        if (entry.kind == .Dir) {
            const path = "src/" ++ entry.name ++ "/config.zig";
            if (std.fs.pathExists(path)) {
                modules.append(.{ .name = entry.name, .path = path });
            }
        }
    }
    return modules.toOwnedSlice();
}
```

### 2. Generated Registry (`config_registry.zig`)

```zig
// build.zig generates this at build time
pub const ConfigModules = [_]ConfigModule {
    .{ .name = "tiling", .parse = tiling.parse, .defaults = tiling.defaults, .validate = tiling.validate },
    .{ .name = "workspaces", .parse = workspaces.parse, .defaults = workspaces.defaults, .validate = workspaces.validate },
    // ... auto-discovered from src/*/config.zig
};

// Composed Config struct (comptime)
pub const Config = struct {
    core: CoreConfig,
    inline for (ConfigModules) |mod| {
        @fieldName(mod.name): ?mod.Config = null,
    }
};

// Parser: delegates to present modules
pub fn parseConfig(alloc: Allocator, doc: toml.Node) !Config {
    var cfg = Config{};
    inline for (ConfigModules) |mod| {
        if (doc.get(mod.name)) |node| {
            @field(cfg, mod.name) = mod.parse(allocator, node);
        }
    }
    return cfg;
}

// Defaults: compose from module defaults
pub fn defaults() Config {
    return .{
        .core = CoreConfig{},
        inline for (ConfigModules) |mod| {
            @fieldName(mod.name) = mod.defaults(),
        }
    };
}
```

---

## Migration Plan

### Phase 1: Module Config Extraction (No Behavior Change)

| Module | Source | Destination |
|--------|--------|-------------|
| Tiling | `config/types.zig:TilingConfig` | `src/tiling/tiling_config.zig` |
| Workspaces | `config/types.zig:WorkspacesConfig` | `src/window/modules/workspaces/config.zig` |
| Bar | `config/types.zig:BarConfig` | `src/bar/bar_config.zig` |
| Fullscreen | `config/types.zig:FullscreenConfig` | `src/window/modules/fullscreen/config.zig` |
| Floating | `config/types.zig:DragConfig` | `src/window/modules/floating/config.zig` |
| Minimize | (new) | `src/window/modules/minimize/config.zig` |

Each module gets:
```zig
// src/tiling/tiling_config.zig
pub const Config = struct { ... };

pub const Module = struct {
    name: []const u8 = "tiling",
    parse: fn (alloc: Allocator, node: toml.Node) !Config,
    defaults: fn () Config,
    validate: fn (cfg: Config) !void,
};
```

### Phase 2: Config Registry Generation (Build System)

1. **Add `buildConfigRegistryModule`** in `build.zig`
2. **Generate `config_registry.zig`** with `ConfigModules` array
3. **Update `build.zig`** to inject generated module
4. **Add carve-out** for generated `config_registry.zig` in `assertPureLayerImports`

### Phase 3: Config Composition & Parser Rewrite

1. **Create `config/composed.zig`** (generated) with:
   - `ConfigModules` registry array
   - Composed `Config` struct (inline for loop)
   - `parseConfig()` dispatcher
   - `defaults()` function

2. **Rewrite `config/parse/schema.zig`** → thin dispatcher:
   ```zig
   pub fn parseConfig(alloc: Allocator, doc: toml.Node) !Config {
       var cfg = Config{};
       inline for (ConfigModules) |mod| {
           if (doc.get(mod.name)) |node| {
               @field(cfg, mod.name) = mod.parse(allocator, node);
           }
       }
       return cfg;
   }
   ```

2. **Remove hard-coded knobs** from `config/parse/schema.zig`
3. **Update `config/types.zig`** → `config/composed.zig` (generated)

### Phase 4: Remove Runtime Feature Flags

| Flag | Replace With |
|------|--------------|
| `config.tiling.enabled` | `build_options.has_tiling` |
| `config.fullscreen_enabled` | `build_options.has_fullscreen` |
| `config.drag_enabled` | `build_options.has_floating` |
| `config.workspaces.enabled` | `build_options.has_workspaces` |

- Remove fields from `config/types.zig` (→ `composed.zig`)
- Remove knobs from `config/parse/schema.zig`
- Update call sites to use `build_options.has_*`

### Phase 5: Contract Split (Contract Split)

- Move `tiling_contract.zig` to `core/architecture/` (cross-engine)
- Create `window/window_contract.zig` (WindowModule hooks)
- Create `bar/bar_contract.zig` (Segment hooks)
- Update `build.zig` codegen/classifier for new contract stems
- Update plugin templates, tests, AGENTS.md

### Phase 6: Operation Migration (Option A)

Move mutations from `model.zig` to owning modules:

| Operation | Destination |
|-----------|-------------|
| `setFocus`, `clearFocus`, `fallbackFocusCandidate`, `collectCyclePool`, `focusedBorderColor` | `src/window/protocol/focus.zig` |
| `reorderTiled`, `stepTiled`, `swapPrimary`, `swapFocusedWithPrevious`, `adjustPrimaryWidth` | `src/tiling/` via `tiling_seam` |
| `register`, `unregister`, `applyParamsDelta` | `src/window/state/window_state_ops.zig` |
| `applyConfigReload` | `config/model_seeding.zig` |
| `capPrimaryCount` | Stays in `domain.zig` |

**Pure queries stay in `model.zig`**: `visibleOn`, `visibleEntry`, `tiledCountOnWs`, `coveringWsOf`, `isCovering`, `isCoveringOn`, `coveringOccupantOnWs`, `coveringOccupants`, `findHome`, `removeValue`, `detachTiledToFloating`

### Phase 6: Flag Removal (Behavior Change)

| Runtime Flag | Replace With |
|--------------|--------------|
| `config.tiling.enabled` | `build_options.has_tiling` |
| `config.fullscreen_enabled` | `build_options.has_fullscreen` |
| `config.drag_enabled` | `build_options.has_floating` |
| `config.workspaces.enabled` | `build_options.has_workspaces` |

- Update `config/parse/schema.zig` (remove knobs)
- Update `config/types.zig` (remove fields)
- Update call sites: `tilingEnabled()` → comptime `build_options.has_tiling`
- Update tests

### Phase 6: Cleanup & Verification

- Run `zig build check-modularity -j 4` after contract split and op migration
- Run full test suite with `--summary all`
- Update AGENTS.md, MESSAGE_BOARD.md, docs

---

## Verification Checklist

- [ ] `zig build check` passes (all layer guards)
- [ ] `dev/scripts/xtest.sh zig build test --summary all` passes
- [ ] `zig build modules` shows no duplicate stems
- [ ] `zig fmt --check .` passes
- [ ] `zig build check-modularity -j 4` passes
- [ ] `zig build check-plugin-template` passes
- [ ] Delete `src/tiling/` → `zig build check` passes, no config trace
- [ ] Delete `src/window/modules/workspaces/` → `zig build check` passes
- [ ] Delete `src/window/modules/fullscreen/` → `zig build check` passes
- [ ] `zig build check-plugin-template` passes
- [ ] All feature flags either removed or documented as breaking changes

---

## Cross-Cutting Requirements

- **Guard/scripts edited in lockstep**: `build.zig` (assertPureLayerImports + pureLayerAllows + **codegen/classifier**), `check-layers.sh`, `dev/plugin-template/*`, `AGENTS.md` (rule 6), `MESSAGE_BOARD.md`
- **Docs with `wm_state`**: `AGENTS.md:65,77`, `MESSAGE_BOARD.md`, `dev/actions-dissolution.md`, `dev/review-r2/*.md`, `src/window/PLAN.md`
- **Use `git mv`** for every rename/move
- **Verification**: Use `dev/scripts/xtest.sh zig build test --summary all` for counts; run `zig build check-modularity -j 4` after contract split and op migration; `zig build modules` after step 1
- **Documentation**: Refresh `AGENTS.md`/`src/PLAN.md` counts and diagrams after work lands

---

## Notes

- All changes are structural except flag removal (explicit behavior change)
- Each step independently verifiable with `zig build check`
- `core.zig` re-exports from `model` (not `wm_state`) after rename
- `config/` gains `model_seeding.zig`; `core/architecture/` loses `seed.zig` and `contract.zig`
- `pure/` may be removed if only `bounded.zig` + `idmap.zig` remain
- Contracts: engine contracts in `window/` + `bar/`; cross-engine in `core/architecture/tiling_contract.zig` + `contract_dispatch.zig`
- `core/architecture/` holds `domain.zig` + `contract_dispatch.zig` + `tiling_contract.zig`

---

## Execution Order

| Step | Action | Verification |
|------|--------|--------------|
| 1 | Extract module configs to `src/*/config.zig` | `zig build check` |
| 2 | Add build.zig config registry generator | `zig build check` |
| 3 | Generate `config_registry.zig` + `config/composed.zig` | `zig build check` |
| 4 | Rewrite `config/parse/schema.zig` as dispatcher | `zig build check` |
| 5 | Rename `types.zig` → `composed.zig` (generated) | `zig build check` |
| 6 | Remove runtime feature flags (9) | `zig build check` + tests |
| 7 | Split contracts (engine + cross-engine) | `zig build check` + modularity |
| 9 | Migrate ops from `model.zig` (Option A) | `zig build check` + modularity |
| 10 | Remove redundant runtime flags (opt-in) | `zig build check` + tests |
| 10 | Full suite with `--summary all` | All green |

---

## Notes

- All changes are structural except flag removal (explicit behavior change)
- Each step independently verifiable with `zig build check`
- `core.zig` re-exports from `model` (not `wm_state`) after rename
- `config/` gains `model_seeding.zig`; `core/architecture/` loses `seed.zig` and `contract.zig`
- `pure/` may be removed if only `bounded.zig` + `idmap.zig` remain
- Contracts: engine contracts in `window/` + `bar/`; cross-engine in `core/architecture/tiling_contract.zig` + `contract_dispatch.zig`
- `core/architecture/` holds `domain.zig` + `contract_dispatch.zig` + `tiling_contract.zig`