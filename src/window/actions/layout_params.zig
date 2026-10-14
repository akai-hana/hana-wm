//! The layout-parameter actions (cycle/variant/primary/swap)
//! and the config-reload seeding that stamps every
//! workspace's params from the live config. Each action is
//! one model transition + one sync entry. The shared
//! transition tails (retile, prepareAndSetFocus) live in
//! `actions.zig`, the hub this file imports: the two files
//! form the window layer's intentional runtime-only import
//! cycle (the same hub-and-spoke shape check-layers.sh
//! documents for core<->window).

const std = @import("std");
const core = @import("core");
const constants = @import("constants");
const types = @import("types");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const build_options = @import("build_options");
const tiling = @import("tiling_seam").tiling;
const contract = @import("contract");
const log = @import("log");

const actions = @import("actions");

/// Primary-column capacity: a sane handful of slots, capped at a quarter of
/// the managed-window ceiling so one workspace can't statically claim the
/// store. The config grammar lets master_count rise to its u8 ceiling; every
/// path that stamps primary_count funnels through `capPrimaryCount`.
const max_primary_count = model_mod.store_capacity / 4;

/// Clamps a configured/adjusted primary count into [1, max_primary_count].
fn capPrimaryCount(count: u8) u8 {
    return @min(count, @as(u8, @intCast(max_primary_count)));
}

pub fn cycleLayoutKind(dir: i32) void {
    const m = pipeline.mut();
    cycleActiveLayout(m, dir);
    actions.retile(.{ .full_redraw = true }, null);
}

/// Step the active layout within the config layout-name list (config order
/// is the cycle order), reproducing the old model.cycleLayout
/// wrap-around while resetting the variant index. Defaults/overrides always
/// come from config names, so the active kind is always resolvable.
fn cycleActiveLayout(m: *model_mod.Model, dir: i32) void {
    if (!build_options.has_tiling) return;
    const cfg = &core.getState().config.tiling;
    const p = &m.ws[m.current.index].params;
    p.kind = tiling.cycleKind(p.kind, dir, cfg.layouts.items);
    p.variant_idx = 0;
}

pub fn stepVariantDir(dir: i32) void {
    if (!build_options.has_tiling) return;
    const m = pipeline.mut();
    const p = &m.ws[m.current.index].params;
    const n = tiling.variantCount(p.kind);
    p.variant_idx = @intCast(model_mod.wrapIndex(p.variant_idx, dir, n));
    actions.retile(.{ .full_redraw = true }, null);
}

pub fn adjustPrimaryWidthAction(delta: f32) void {
    const m = pipeline.mut();
    model_mod.adjustPrimaryWidth(m, delta);
    pipeline.reconcileGrab(.{});
}

pub fn adjustPrimaryCount(delta: i32) void {
    const m = pipeline.mut();
    const p = &m.ws[m.current.index].params;
    const next = std.math.clamp(@as(i32, p.primary_count) + delta, 1, max_primary_count);
    p.primary_count = @intCast(next);
    pipeline.reconcileGrab(.{});
}

pub fn adjustSecondaryBalance(delta: f32) void {
    const m = pipeline.mut();
    const p = &m.ws[m.current.index].params;
    p.secondary_balance = std.math.clamp(p.secondary_balance + delta, -constants.max_primary_swing, constants.max_primary_swing);
    pipeline.reconcileGrab(.{});
}

/// swap_master: exchanges the focused window's tiled slot with the previously
/// focused window's (focus MRU), not the list head -- a slot in the middle of
/// a 3+ window workspace still swaps the pair the user expects. focus_swap
/// variant moves focus to the previously focused window BEFORE the reconcile
/// so the swapped-in window is focused on the first reconcile.
pub fn swapPrimaryAction(focus_swap: bool) void {
    const m = pipeline.mut();
    const focused = m.focused orelse return;
    const mru = m.ws[m.current.index].focus_mru.constSlice();
    if (mru.len < 2 or mru[1] == focused) return;
    const displaced = mru[1];
    model_mod.swapFocusedWithPrevious(m);
    var ft: focus.FocusTransition = .none;
    if (focus_swap) {
        // A no_input displaced window must not take model focus.
        ft = actions.prepareAndSetFocus(m, displaced, .tiling_operation);
    }
    pipeline.reconcileGrabFocus(.{}, ft, .before, null);
}

// config reload

/// Seeds every workspace's model params from the CURRENT config, resolving
/// per-workspace overrides through the shared last-wins lookup rules on
/// TilingConfig. Shared by
/// boot-time initialization (without this the config's tiling
/// params/workspace overrides stay inert until the first explicit reload)
/// and post-reload re-seeding; mirrors the per-workspace override model:
/// per-workspace layout/variant/master-count overrides, global defaults
/// otherwise; primary_width/secondary_balance are runtime-only (no config
/// representation) and reset to their defaults.
/// No reconcile: callers decide when to push state to X.
///
/// The stamping loop lives in model.applyConfigReload (whose viewport-preserve
/// invariant gets its production caller here); this fn supplies the template.
pub fn seedParamsFromConfig() void {
    if (!build_options.has_tiling) return;
    const cs = core.getState();
    const cfg = &cs.config.tiling;

    // Config layout names resolve to registry ids here, once per seed;
    // unresolvable names fall back loudly to the neutral default.
    const default_kind: u8 = tiling.layoutKindFallingBack(cfg.defaultLayout(), contract.default_kind);

    const m = pipeline.mut();
    // The config grammar lets master_count rise to its u8 ceiling; seeding
    // the raw u8 would slip those couple-dozen windows directly into
    // compute's master_n, where the master-column fit gate then has to
    // reject them; clamp at seed time instead.
    const primary_count = capPrimaryCount(cfg.master_count);
    // Global default template, stamped across every workspace by
    // applyConfigReload (preserves viewport runtime state). Per-workspace
    // overrides are re-stamped in the loop below.
    model_mod.applyConfigReload(m, .{
        .kind = default_kind,
        .variant_idx = resolveVariant(cfg, default_kind, null),
        .primary_count = primary_count,
        .primary_width = 0.5, // runtime-only; reset to the model default (LayoutParams.primary_width)
        .secondary_balance = 0,
    });

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
        if (count_overrides[id]) |mc| s.params.primary_count = capPrimaryCount(mc);
    }
}

/// Resolve the active variant index for `kind` from the registry-driven
/// value-string: `override_variant` when present, else the per-layout
/// variants map entry for the active module's canonical name. The module's
/// own variant_parse hook interprets the string; an unparseable/unknown
/// string warns (Stage-1 style) and uses 0.
fn resolveVariant(
    cfg: *const types.TilingConfig,
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

pub fn applyConfigReload() void {
    seedParamsFromConfig();
    pipeline.reconcileGrab(.{});
}
