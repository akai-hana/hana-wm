//! control.zig — drop-in template for a hana slider control.
//!
//! COPY ME: the fastest way to start a new control is
//!
//!     cp dev/plugin-template/control.zig src/bar/modules/slider/mycontrol.zig
//!
//! then edit the TODO markers. Nothing else needs to change:
//! build.zig's sub-registry generation (`slider_subs`) picks the
//! file up from FILE PRESENCE plus the `pub const sub` self-declaration,
//! and the slider core turns every bound control into one standalone
//! bar segment named `.name`, selectable in `[bar.layout.*]`.
//!
//! This file is INTENTIONALLY inert: its `.name` never appears in
//! any shipped config, so the bar never renders it, and its hooks
//! are real, copy-pasteable code that neither claims a level nor
//! writes a backend. The slider surface is a closed-core /
//! open-module system: the CLOSED CORE (`slider.zig`) owns the
//! contract, the pct map and the `segmentFor` binding (the render
//! shell, click/drag interaction, poll cadence and commit throttle
//! live in `slider/shell.zig`); the OPEN MODULES are the siblings binding
//! `pub const sub: slider.Sub`, each owning its backend's truth
//! (device discovery, reads, writes, display format). A sibling
//! WITHOUT the binding is a private implementation file
//! (native_alsa.zig beside the slider package is the shipped
//! example: importable by stem, never bound).
//!
//! `check-plugin-template` compiles this file against the real
//! slider module, so contract drift self-fails on `zig build check`.

const types = @import("types");
const slider = @import("slider");
const drawing = @import("drawing");

/// Default display format. `{pct}` is the value region (the core
/// records its span so the segment paints the number in its value
/// colour; a literal `%` directly after the placeholder joins the
/// span), `{state}` the writable-state word your `write` hook can
/// pass through. Any other text is literal.
const default_format = "CTL {pct}%";

/// Scratch for the rendered label: valid until the next `label`
/// call (the core copies it into its own render buffer).
var g_scratch: [128]u8 = undefined;

/// The control's live state. `g_has_value` false = the control has
/// no answer this tick and renders nothing (zero-width slot,
/// unclickable) — the absence lives in the type via the optional
/// `level` hook, so it cannot disagree with the value.
var g_pct: u8 = 0;
var g_has_value: bool = false;

/// The control's current 0-100 level, or null while it has no
/// answer. Leave the `level` binding null entirely for a control
/// that is always present (the hook then never runs).
fn level() ?u8 {
    if (!g_has_value) return null;
    return g_pct;
}

/// Whether the backend can write. While false, interactions no-op
/// but the level still displays.
fn writable() bool {
    return true; // TODO: false while your backend can't write.
}

/// Refresh the control's live state (attach/probe is cached inside
/// the control). Returns true when the displayed state changed this
/// call, so the core knows to repaint.
fn read() bool {
    // TODO: refresh g_pct / g_has_value from your backend.
    return false;
}

/// What the core wants a write to do (see `slider.Write`):
/// `preview` advances the display only (drag/scroll motion — the
/// write is deferred anyway), `commit`/`apply` write the backend
/// (a press set, or the authoritative end of a scrub — never
/// throttled, it is the release of the gesture).
fn write(mode: slider.Write, pct: u8) void {
    // TODO: clamp to your backend's range here if it is not 0-100;
    // preview updates g_pct only, commit/apply also write the device.
    _ = mode;
    g_pct = pct;
    g_has_value = true;
}

/// The latency class of one commit on this control: `immediate`
/// commits are cheap in-process writes and are never coalesced;
/// `rate_limited` ones pass through the core's throttle window
/// (spawn-per-commit controls — volume/brightness subprocesses).
fn commitCost() slider.CommitCost {
    return .rate_limited; // or .immediate for a cheap in-process write
}

/// Renders the idle label into `buf` (control-scoped scratch) from
/// the control's own state and config, plus the label's numeric
/// region; valid until the next call. `renderLineValue` is the
/// shared `{pct}`/`{state}` substitution walker — use it unless
/// your display format is genuinely bespoke.
fn label(config: types.BarConfig, buf: []u8) drawing.Label {
    _ = config; // TODO: your config-driven format string, if any.
    return drawing.renderLineValue(default_format, g_pct, null, buf);
}

/// This control's binding to the slider surface (`slider.Sub`). The
/// hooks you don't override keep their defaults: `read_interval_ms`
/// (per-control poll cadence), `secondary` (right-click action —
/// volume's mute toggle is the shipped example), `commit_window_ms`
/// (share the core throttle window) and `probeNaturalWidth` (the
/// idle-width natural reserve). Membership in `slider_subs` — and
/// therefore a bar segment named after this control — comes from
/// file presence alone, so dropping this file removes the segment
/// with zero core edits.
pub const sub: slider.Sub = .{
    .name = "control", // TODO: unique config identity, e.g. "volume"
    .level = level,
    .writable = writable,
    .read = read,
    .write = write,
    .commit_cost = commitCost,
    .label = label,
};
