//! Config defaults: the scheme colors (tiling borders, accent, bar palette)
//! and the read-time fallback strings for optional `BarConfig` fields.
//!
//! The colors are typed `u32` — the value of `types.Color` — rather than
//! `Color` itself so this file needs no `types` import: `types.zig` imports
//! THIS file for its struct field initializers, and keeping that edge one
//! way (types -> defaults) is what keeps the two files from forming a cycle.

/// Default color scheme for the focused/unfocused tiling borders.
pub const default_focused_border: u32 = 0x5294E2;
pub const default_unfocused_border: u32 = 0x383C4A;

/// Default accent color; declared once so every referencing field has a single source of truth.
pub const default_accent: u32 = 0x61AFEF;

/// Default bar background/foreground scheme. Kept in one place so the bar's
/// color defaults read as a palette rather than scattered hex literals.
pub const default_bar_bg: u32 = 0x222222;
pub const default_bar_fg: u32 = 0xBBBBBB;
pub const default_bar_selected_bg: u32 = 0x005577;
pub const default_bar_selected_fg: u32 = 0xEEEEEE;

/// Type-level defaults for optional string fields in BarConfig.
/// When a field is `null`, the corresponding default is used at read time.
pub const default_clock_format: []const u8 = "%Y-%m-%d %H:%M:%S";
pub const default_run_prompt: []const u8 = "run: ";
pub const default_indicator_focused: []const u8 = "■";
pub const default_indicator_unfocused: []const u8 = "□";
