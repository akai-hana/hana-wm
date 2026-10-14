//! readout.zig — drop-in template for a hana systatus readout.
//!
//! COPY ME: the fastest way to start a new readout is
//!
//!     cp dev/plugin-template/readout.zig src/bar/modules/systatus/myreadout.zig
//!
//! then edit the TODO markers. Nothing else needs to change:
//! build.zig's sub-registry generation (`systatus_subs`) picks the
//! file up from FILE PRESENCE plus the `pub const sub` self-declaration,
//! and the systatus core turns every bound readout into one
//! standalone bar segment named `.name`, selectable in
//! `[bar.layout.*]`.
//!
//! This file is INTENTIONALLY inert: its `.name` never appears in
//! any shipped config, so the bar never renders it, and its `read`
//! is real, copy-pasteable code that reports a value. The systatus
//! surface is a closed-core / open-module system: the CLOSED CORE
//! (`systatus.zig`) owns the poll/render machinery and the `Sub`
//! contract; the OPEN MODULES are the sibling files binding
//! `pub const sub: systatus.Sub`. A sibling WITHOUT the binding is
//! a private implementation file (importable by stem, never bound).
//!
//! `check-plugin-template` compiles this file against the real
//! systatus module, so contract drift self-fails on `zig build check`.

const systatus = @import("systatus");

/// Scratch for the formatted reading. The core COPIES the sample's
/// text into its render buffer, so the storage only has to outlive
/// the `read` call — a module-level buffer is the established shape
/// (see the shipped readouts).
var g_num: [16]u8 = undefined;

/// The readout itself: the current value as display text, or null
/// when unreadable / not present this tick (the segment then renders
/// nothing, zero width). The common case is `systatus.percentSample`
/// into your scratch; any text you format yourself is equally valid —
/// the presentation is yours, the core just paints it.
fn read() ?systatus.Sample {
    // TODO: your measurement here (a /proc or sysfs read, a
    // command's output, ...). Return null on failure; the core
    // tolerates consecutive failures before collapsing the slot.
    const value: u8 = 0;
    return systatus.percentSample(&g_num, value);
}

/// This readout's binding to the systatus surface (`systatus.Sub`):
/// the config identity, the label prefix rendered before the value,
/// and the readout function. Membership in `systatus_subs` — and
/// therefore a bar segment named after this readout — comes from
/// file presence alone, so dropping this file removes the segment
/// with zero core edits.
pub const sub: systatus.Sub = .{
    .name = "readout", // TODO: unique config identity, e.g. "cpu"
    .label = "READOUT", // TODO: the label prefix rendered before the value
    .read = read,
};
