//! Config → model seeding: stamps every workspace's tiling params from the
//! live config at boot and on reload. Owns the name/variant resolution
//! (layout registry ids, per-layout `variant_parse`), the primary-count
//! clamp, and the two-arg `applyConfigReload` stamping loop (config owns
//! seeding). The
//! reload reconcile is `pipeline.reconcileGrab`. Callers: `main` (boot, before
//! the first reconcile) and `config/reload` (post-swap re-seed via
//! `reloadAndReconcile`). The window-layer command half — layout cycling,
//! variant stepping, primary/swap — lives in `window/sync/reconcile_tails.zig`.

const core = @import("core");
const types = @import("types");
const tiling_config = @import("tiling_config");
const model_mod = @import("model");
const domain = @import("domain");
const pipeline = @import("pipeline");
const tiling = @import("tiling_seam").tiling;
const contract = @import("tiling_contract");
const log = @import("log");
const build_options = @import("build_options");

/// The global template resolved from `cfg`: the default layout's registry
/// kind, its default variant, and the clamped primary count. Pure — takes the
/// config explicitly instead of reading live state, so the boot/reload
/// wrapper below and `seed_test` exercise the identical resolution path.
///
/// `primary_width`/`secondary_balance` are runtime-only (no config
/// representation) and reset to their defaults here.
pub fn templateFrom(cfg: *const tiling_config.Config) model_mod.LayoutParams {
    // Config layout names resolve to registry ids here, once per seed;
    // unresolvable names fall back loudly to the neutral default.
    const default_kind: u8 = tiling.layoutKindFallingBack(cfg.defaultLayout(), contract.default_kind);
    // The config grammar lets master_count rise to its u8 ceiling; seeding
    // the raw u8 would slip those couple-dozen windows directly into
    // compute's master_n, where the master-column fit gate then has to
    // reject them; clamp at seed time instead.
    return .{
        .kind = default_kind,
        .variant_idx = resolveVariant(cfg, default_kind, null),
        .primary_count = domain.capPrimaryCount(cfg.master_count),
        .primary_width = 0.5, // runtime-only; reset to the model default (LayoutParams.primary_width)
        .secondary_balance = 0,
    };
}

/// The per-workspace override pass: re-stamps layout/variant/master-count
/// overrides on top of an already-`applyConfigReload`ed model, falling back to
/// `default_kind` for an out-of-range `layout_idx`. Pure (no live state), so
/// `seed_test` pins the last-wins lookups and the out-of-range carry-through
/// rule without a boot sequence.
pub fn applyOverrides(
    m: *model_mod.Model,
    cfg: *const tiling_config.Config,
    default_kind: u8,
) void {
    // Both lookups resolve ONCE: they build a fixed-size workspace table per
    // call, and this loop is their only consumer.
    const layout_overrides = cfg.workspaceLayoutLookup();
    const count_overrides = cfg.masterCountLookup();

    for (&m.ws, 0..) |*s, i| {
        const id: u8 = @intCast(i);
        if (layout_overrides[id]) |oi| {
            const o = cfg.workspace_layout_overrides.items[oi];
            const kind = if (o.layout_idx < cfg.layouts.items.len)
                tiling.layoutKindFallingBack(
                    cfg.layouts.items[o.layout_idx],
                    default_kind,
                )
            else
                default_kind;
            s.params.kind = kind;
            // A layout override always carries the variant override through,
            // even when its layout_idx resolved out of range (the override
            // string still applies to the active kind).
            s.params.variant_idx = resolveVariant(cfg, kind, o.variant);
        }
        if (count_overrides[id]) |mc| s.params.primary_count = domain.capPrimaryCount(mc);
    }
}

/// Seeds every workspace's model params from the CURRENT config, resolving
/// per-workspace overrides through the shared last-wins lookup rules on
/// TilingConfig. Shared by boot-time initialization (without this the config's
/// tiling params/workspace overrides stay inert until the first explicit
/// reload) and post-reload re-seeding. No reconcile: callers decide when to
/// push state to X.
///
/// The two state-touching steps only: stamp the pure `templateFrom` template
/// across every workspace (via `applyConfigReload` below, whose viewport-preserve
/// invariant gets its production caller here), then re-stamp per-workspace
/// overrides. The resolution itself lives in the two pure halves above.
pub fn seedParamsFromConfig() void {
    if (!build_options.has_tiling) return;
    const cfg = &core.getState().config.tiling;
    const tpl = templateFrom(cfg);

    const m = pipeline.mut();
    applyConfigReload(m, tpl);
    applyOverrides(m, cfg, tpl.kind);
}

/// Stamp one `LayoutParams` template across every workspace (the config
/// reload/seeding path — `templateFrom` supplies the template; at-zone tests
/// use it too). Config owns seeding, so the stamping loop lives beside the
/// resolution.
pub fn applyConfigReload(m: *model_mod.Model, tpl: model_mod.LayoutParams) void {
    for (&m.ws) |*s| {
        // Viewport state is RUNTIME state, not config: preserving it prevents
        // a spurious snap-right (n > prev_count fires when the counter resets)
        // on an unrelated reload while the viewport layout is active.
        const keep_offset = s.params.viewport_offset;
        const keep_prev_count = s.params.viewport_prev_count;
        s.params = tpl;
        s.params.viewport_offset = keep_offset;
        s.params.viewport_prev_count = keep_prev_count;
    }
}

/// Resolve the active variant index for `kind` from the registry-driven
/// value-string: `override_variant` when present, else the per-layout
/// variants map entry for the active module's canonical name. The module's
/// own variant_parse hook interprets the string; an unparseable/unknown
/// string warns (Stage-1 style) and uses 0.
fn resolveVariant(
    cfg: *const tiling_config.Config,
    kind: u8,
    override_variant: ?[]const u8,
) u8 {
    var value_string: ?[]const u8 = override_variant;
    const active_mod = contract.moduleOf(kind);
    var v_idx: u8 = 0;
    if (active_mod) |md| {
        if (value_string == null) value_string = cfg.variants.get(md.name);
        if (value_string) |vs| {
            if (md.variant_parse) |vp| {
                v_idx = vp(vs) orelse blk: {
                    if (override_variant != null)
                        log.warn("Config: workspace layout variant '{s}' ignored — not a variant of the active layout", .{vs})
                    else
                        log.warn("Unknown {s} variants '{s}', using default", .{ md.name, vs });
                    break :blk 0;
                };
            } else if (override_variant != null) {
                log.warn("Config: workspace layout variant ignored — not a variant of the active layout", .{});
            }
        }
    }
    return v_idx;
}

/// Boot/reload entry: re-seed the whole model from the live config, then
/// reconcile so the X side catches up. (Renamed from the no-arg
/// `applyConfigReload` to make room for the two-arg stamping loop above.)
pub fn reloadAndReconcile() void {
    seedParamsFromConfig();
    pipeline.reconcileGrab(.{});
}
