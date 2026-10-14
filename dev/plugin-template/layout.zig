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
//! with or without the file. That is the contract's litmus test. `zig build
//! check` additionally compiles every file here against the real modules
//! (the `check-plugin-template` step in build.zig), so contract drift
//! self-fails.
//!
//! The placement machinery (View/List/emit helpers) lives in the tiling
//! engine — import it with `@import("tiling")`; the engine never imports
//! your module (the registry dispatch is the one edge). Mirror the shipped
//! modules, not this template alone: monocle.zig is the least complex real
//! layout, master.zig the reference one — the template below must always
//! compile against the same `tiling` API they use.

const tiling = @import("tiling");
const model = @import("model");

/// Compute this layout into `out` (already cleared by the engine). MUST
/// append exactly one placement per window in `v.order` — either a real
/// placement (`tiling.emitView`) or a parked one (`tiling.emitHidden`).
/// Contract: `v.order` is non-empty and canonical — the engine always calls
/// compute with the FULL ordered workspace set, so a module sees every
/// window at once and must not assume sliced input.
/// Origin top-left, y-down; use the engine's `outerArea`/`shrinkClamped`/
/// `waY` helpers (see monocle.zig, the smallest shipped layout).
fn compute(v: *const tiling.View, out: *tiling.List) void {
    if (v.order.len == 0) return;

    // TODO: your placement algorithm. This template stacks every window at
    // the full work area inset by the outer gap plus the border (a minimal
    // "stack"); grid.zig/master.zig show real cell/column math.
    const m = v.env.margins;
    const area = tiling.outerArea(v.workarea, m.gap);
    const inset = tiling.totalInset(m.gap, m);
    const rect = model.Rect{
        .x = @intCast(area.x),
        .y = @intCast(tiling.waY(v)),
        .width = tiling.shrinkClamped(area.w, inset, v.env.min_dim),
        .height = tiling.shrinkClamped(area.h, inset, v.env.min_dim),
    };

    // Every window visible at the same rect: the stack order (last wins the
    // stack top) is the placement order. A real layout usually shows one and
    // parks the rest (`tiling.emitHidden(out, win)`), or splits the area
    // across windows.
    for (v.order) |win| {
        tiling.emitView(v, out, win, rect);
    }
}

// Scroll viewport addon hooks. ONLY the scroll layout registers these; the
// engine/actions treat "the active layout provides slotWidth/maxOffset/
// preReconcile" as the definition of a scroll layout (no name matching). If
// your layout is a viewport over a longer strip, mirror scroll.zig; leave
// them out otherwise. `preReconcile` takes the workspace's LayoutParams BY
// VALUE and returns the updated params (pure; a layout module never receives
// a mutable pointer into the model).

// This layout's registry contribution: metadata + the dispatch hook. The
// name is the config identity and the cycle-order key; icon/indicators are
// rendered by the bar's layout/variants segments (no core switch over
// layouts). Your variants go in the `variants` table below: one row per
// cycle_variant step, each with its config value-string and its bar
// indicator. `tiling.layoutModule` derives `variant_count`, `variant_parse`,
// `indicators` and `fifo_variant` FROM THAT TABLE, so the four cannot drift
// apart and there is no count to keep in sync by hand. To read your own
// variant's ordinal inside `compute`, use
// `tiling.variantIndex(&variants, "name")` rather than a literal index
// (mirror grid.zig / monocle.zig). `tiling.layoutModule` also fills
// name/icon/compute (typed `*const fn(*const View, *List)`, no opaque cast).
const variants = [_]tiling.Variant{
    // TODO: one row per cycle_variant step, e.g.
    // .{ .name = "rigid", .indicator = "[^]" },
    // .{ .name = "relaxed", .indicator = "=^=" },
};

pub const module = tiling.layoutModule("template", "[T]", compute, &variants, .{
    // .slotWidth = slotWidth,        // scroll viewport addon (scroll.zig)
    // .maxOffset = maxOffset,        // scroll viewport addon
    // .preReconcile = preReconcile,  // scroll viewport addon
});
