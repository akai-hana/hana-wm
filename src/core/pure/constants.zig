//! Core constants
//! Defines shared constants used across multiple modules.
//!
//! Layer note: this file is XCB-free. Modifier masks, event masks, and other
//! XCB-dependent values live in the core x11 masks module.

// Window constraints
pub const min_window_dim: u16 = 50;
pub const min_master_width: f32 = 0.05;
/// Primary-column width is capped at 95% so the secondary column always keeps
/// some screen. Single-sourced: config validation, the runtime pixel->ratio
/// conversion, and the primary-width adjustment action all clamp to this same
/// bound (tiling.zig's local `max_master_width_ratio` used to duplicate it).
pub const max_master_width: f32 = 0.95;

/// Primary-column width step per primary-width adjustment press.
pub const master_width_step: f32 = 0.025;
/// Secondary-column balance step per grow_stack press.
pub const stack_balance_step: f32 = 0.5;

/// Secondary-column balance swing cap for grow_stack adjustments (see
/// StackBoost.fromBalance).
pub const max_primary_swing: f32 = 6.0;

/// Maximum number of concurrently minimized windows. Hoisted from the minimize
/// module's `max_minimized` so the model layer (which may import only std +
/// utils + constants) can reach it without build_options. Distinct from
/// `max_tiled_windows`: this bounds the minimized-window buffer, not the
/// tiled-window pool.
pub const max_minimized: usize = 32;

// XKB retry parameters
// Short enough to be imperceptible, long enough to avoid busy-spinning while
// XKB initialises (~1 polling cycle at 50 Hz).
pub const xkb_retry_delay_ms: u64 = 20;

/// X11 reserves keycodes 0..7; the first real keycode is 8. The flat keysym
/// table therefore covers 8..255.
pub const x11_min_keycode: u8 = 8;
/// The keycode space is 0..255; tables and bitsets covering the full range are
/// sized from this.
pub const x11_max_keycode = 256;

// Offscreen positioning
// Windows on inactive workspaces are parked here so they are hidden without
// being unmapped (unmapping causes some apps to pause).
//
// X11's ConfigureWindow encodes x/y as INT16 on the wire (hence utils.Rect.x/y
// being i16), so -32768 is the hard floor. The old -4000 only cleared a single
// 3840px-wide display: on multi-monitor layouts with a display left of primary,
// ultrawides, or 5K/6K panels, -4000 can land back inside real screen estate.
// -30000 clears any realistic combined desktop while leaving headroom below
// the INT16 floor.
pub const offscreen_x_position: i32 = -30000;

/// Maximum depth when walking the X11 window tree in findManagedWindow.
pub const max_window_tree_depth: usize = 10;

/// Upper bound on live cache entries (focus-property cache in icccm.zig and
/// the border/hints/title cache in wincache.zig). Backing tables are fixed,
/// allocation-free, and O(1) at the cap; windows beyond the ceiling still
/// work, they just fall through to the live X11 path.
pub const max_window_cache: usize = 512;

/// Hard ceiling on the number of workspaces the WM can meaningfully support.
///
/// Not an arbitrary round number: tiling.zig's geometry-validity cache packs
/// one bit per workspace into a u64 (`workspace_geom_valid_bits`), and
/// workspaces.zig's per-workspace layout/master-count override tables are
/// fixed-size arrays sized to match. Raising this requires widening those
/// first; it is not just a config-side number. config.zig validates parsed
/// workspace numbers against it at parse time so oversized configs warn
/// immediately instead of silently no-oping once workspaces.init() builds its
/// lookup tables.
pub const max_workspaces: usize = 64;

/// Largest 1-based workspace number accepted when parsing a workspace
/// reference from config. 1-based values range 1..=255 (matching a u8
/// workspace index of 0..=254 in normal use); the parse helper is slightly
/// more lenient, tolerating 256 before subtracting 1 to reach index 255.
pub const max_workspace_number_1based: usize = 255;

/// Largest 1-based workspace number tolerated by the action/command parser
/// before subtracting 1. Command parsing is intentionally one more lenient
/// than max_workspace_number_1based: `workspace_N` verbs map cleanly onto the
/// top 1-based index (255 -> index 255 via 256 - 1).
pub const max_workspace_command_1based: usize = max_workspace_number_1based + 1;

// XCB property helpers
/// Maximum number of 32-bit words to request when fetching an XCB window property.
/// 256 words = 1 KiB, sufficient for all fixed-size properties the WM reads.
pub const property_max_length: u32 = 256;
/// Value for the `delete` argument to xcb_get_property that leaves the property intact.
pub const property_no_delete: u8 = 0;

// Mouse button codes (X11 button numbering)
pub const mouse_button_left: u8 = 1;
pub const mouse_button_middle: u8 = 2;
pub const mouse_button_right: u8 = 3;
pub const mouse_button_scroll_up: u8 = 4;
pub const mouse_button_scroll_down: u8 = 5;

// DPI / scaling
/// Standard DPI for a 1x display. All scale factors are computed relative to this value.
pub const baseline_dpi: f32 = 96.0;

/// Maximum tiled windows on a single workspace (per-workspace tiled_order
/// capacity, applied per ws). Buffers sized from this are indexed by
/// usize/u16, so raising it only costs memory; keep it a compile-time bound
/// so stack buffers stay stack buffers.
pub const max_tiled_windows = 64;
