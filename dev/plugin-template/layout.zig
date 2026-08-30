//! layout.zig — drop-in template for a hana tiling-layout module.
//!
//! COPY ME: the fastest way to start a new layout is
//!
//!     cp dev/plugin-template/layout.zig src/tiling/modules/mylayout.zig
//!
//! then edit the TODO markers. Nothing else needs to change: build.zig's
//! directory scan picks the file up, wires your `pub const module` into the
//! generated `tiling_modules.modules` array, and the engine dispatches to it
//! the moment a config layout-name resolves to your module's registry index.
//!
//! This file is INTENTIONALLY inert: its name ("template") is not in any
//! config `[tiling] layouts` list, so the engine never activates it — the
//! hooks are real, copy-pasteable code that builds and tests identically
//! (110/110) with or without the file. That is the contract's litmus test.
//!
//! The full contract + onboarding guide lives in PLUGIN_PROVIDER.md (§1.8
//! and §7). The placement machinery (View/List/emit helpers) lives in
//! src/tiling/engine.zig — import it with `@import("engine")`; the engine
//! never imports your module (the registry dispatch is the one edge).

const utils = @import("utils");
const model = @import("model");
const engine = @import("engine");

/// Compute this layout into `out` (already cleared by the engine). MUST
/// append exactly one placement per window in `v.order` — either a real
/// placement (`engine.emitView`) or a parked one (`engine.emitHidden`).
/// Origin top-left, y-down; use the engine's `outerArea`/`shrinkClamped`/
/// `waY` helpers (see monocle.zig, the least complex shipped layout).
pub fn compute(v: engine.View, out: *engine.List) void {
    // TODO: your placement algorithm. This template stacks every window at
    // the full work area inset by twice the border (a minimal "stack").
    if (v.order.len == 0) return;

    const m = v.env.margins; // TODO: border/gap + your per-layout config.
    const margin = utils.doubledBorder(m);
    const rect = utils.Rect{
        .x = @intCast(engine.waY(&v) +| m.gap),
        .y = @intCast(m.gap),
        .width = engine.shrinkClamped(v.workarea.width, margin + m.gap * 2, v.env.min_dim),
        .height = engine.shrinkClamped(v.workarea.height, margin + m.gap * 2, v.env.min_dim),
    };

    // Every window visible at the same rect: the stack order (last wins the
    // stack top) is the placement order. A real layout usually shows one and
    // parks the rest, or splits the area across windows.
    for (v.order) |win| {
        engine.emitView(&v, out, win, rect, true);
    }
}

/// Cast shim: the plugin contract's type-free seam (`*anyopaque`) -> the
/// engine's typed params. Keep this exact shape; it is what the registry
/// dispatches through.
fn computeHook(view: *const anyopaque, out: *anyopaque) void {
    const v: *const engine.View = @ptrCast(@alignCast(view));
    const o: *engine.List = @ptrCast(@alignCast(out));
    compute(v.*, o);
}

// ---------------------------------------------------------------------------
// Scroll viewport addon hooks. ONLY the scroll layout registers these; the
// engine/actions treat "the active layout provides slotWidth/maxOffset/
// preReconcile" as the definition of a scroll layout (no name matching). If
// your layout is a viewport over a longer strip, mirror scroll.zig; leave
// them out otherwise. A preReconcile hook receives `*anyopaque` params (the
// active `*model.LayoutParams`) plus the tiled window count and screen width.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// This layout's registry contribution: metadata + the dispatch hook. The
// name is the config identity and the cycle-order key; icon/indicators are
// rendered by the bar's layout/variants segments (no core switch over
// layouts). variant_count must match the variants your compute actually
// branches on; fifo_variant marks the variant index that toggles fifo spawn.
// ---------------------------------------------------------------------------
pub const module: @import("plugin").Layout = .{
    .name = "template", // TODO: unique config identity, e.g. "master"
    .compute = computeHook,
    .variant_count = 1, // TODO: number of cycle_variant steps this layout has
    // .has_variants = true,          // when config may declare variants
    // .fifo_variant = 1,             // variant index that toggles fifo spawn
    // .variant_parse = variantParse, // maps config value-strings to variant idx
    // .gap_mode = 1,                 // variant idx that honours gaps
    // .relax_mode = 1,               // variant idx that switches to relaxed
    // .slotWidth = slotWidth,        // scroll viewport addon (scroll.zig)
    // .maxOffset = maxOffset,        // scroll viewport addon
    // .preReconcile = preReconcile,  // scroll viewport addon
    // .icon = "[T]",                 // bar layout-segment glyph
    // .indicators = &.{ ... },       // bar variants-segment strings
};
