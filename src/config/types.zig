//! Config type definitions: the SHARED config vocabulary only.
//!
//! Everything here is cross-cutting vocabulary -- value types, section-name
//! constants, enum helpers, the always-present `CoreConfig`, and the generic
//! ownership helpers. The per-subsystem structs (`tiling_config.Config`,
//! `bar_config.Config`, `workspaces_config.Config`, `floating_config.Config`)
//! live BESIDE their subsystem as discovered `*_config.zig` fragments, and the
//! composed top-level Config is the build-generated `composed` module, so
//! deleting an optional subsystem leaves zero config trace.

const std = @import("std");
const action = @import("action");

/// Largest 1-based workspace number accepted when parsing a workspace
/// reference from config. 1-based values range 1..=255 (matching a u8
/// workspace index of 0..=254 in normal use); the parse helper is slightly
/// more lenient, tolerating 256 before subtracting 1 to reach index 255.
pub const max_workspace_number_1based: usize = 255;

/// Smallest on-screen width/height a tiled window (and floating drag
/// resize) is allowed to reach, in pixels. The default for the
/// `tiling.min_window_dim` config field and the floating drag resize
/// fallback when no tiling fragment is compiled in.
pub const default_min_window_dim: u16 = 50;

/// Default workspace count (the `workspaces.count` field initializer and the
/// bar's icon-padding self-seed). Shared here so the bar fragment can pad
/// without importing the optional workspaces fragment.
pub const default_workspace_count: u8 = 9;

/// A value that can be expressed as either an absolute pixel count or a
/// percentage of some reference dimension. Defined here (not in the parser)
/// so the config's field types and the scaling formulas need no parser
/// import (the parser, in turn, imports types for the section names).
pub const ScalableValue = struct {
    value: f32,
    is_percentage: bool,

    pub inline fn absolute(val: f32) ScalableValue {
        return .{ .value = val, .is_percentage = false };
    }
    pub inline fn percentage(val: f32) ScalableValue {
        return .{ .value = val, .is_percentage = true };
    }
};

/// X11 color value packed as 0x00RRGGBB into 32 bits.
/// The high byte is unused; values match what XCB expects for pixel/color fields.
pub const Color = u32;

/// Ceiling of a valid 24-bit color (0x000000-0xFFFFFF). Shared by the
/// in-range-integer color checks in the parser's single color decoder.
pub const max_color: u32 = 0xFF_FF_FF;

/// True when the 1-based workspace number lies inside 1..max (the caller's
/// workspace count or the `max_workspaces` ceiling). The absolute 1..255
/// syntax bound is folded in — no caller passes a `max` above it.
pub fn workspaceInRange(ws_1based: usize, max: usize) bool {
    return ws_1based >= 1 and
        ws_1based <= max_workspace_number_1based and
        ws_1based <= max;
}

/// Config-file section names shared by the parser, the knob tables, and the
/// config interpreter's sweeps. Single-sourced so a spelling change (and the
/// case-typo sweep that keys on these) updates one place. A fragment
/// references the names it owns from here (a local const is what a fork or
/// plugin fragment may use instead -- the section lists are per-fragment
/// exports); the mis-case lint's inventory is the union of the PRESENT
/// fragments' exports, so in a tree that deleted a module its sections drop
/// out of the mis-case table and fall back to the unconsumed-key warns.
pub const section_tiling = "tiling";
pub const section_bar = "bar";
pub const section_bar_properties = "bar.properties";
pub const section_rules = "rules";
pub const section_workspace_rules = "workspace.rules";
pub const section_core = "core";
pub const section_tiling_layouts_master_stack = "tiling.layouts.master-stack";
pub const section_binds = "binds";
pub const section_binds_alt = "Keybindings";
pub const section_drag = "drag";
pub const section_display = "display";
pub const section_fullscreen = "fullscreen";
pub const section_workspaces = "workspaces";
pub const section_bar_modules_workspaces = "bar.modules.workspaces";

/// Section-name prefixes for the family sweeps (inert-family warnings,
/// numbered-rule sections, tiling layout subtables).
pub const section_prefix_tiling = "tiling.";
pub const section_prefix_tiling_layouts = "tiling.layouts.";
pub const section_prefix_workspace_rules = "workspace.rules.";
pub const section_prefix_rules = "rules.";
pub const section_prefix_bar_layout = "bar.layout.";

/// A (section, key) pair on a fragment's duplicate-accumulate exemption
/// list: keys in this section accumulate duplicate declarations BY DESIGN
/// (bind tables, rule tables), so a scalar read of an accumulated array
/// must not warn "later wins" the way any other duplicated key does.
/// `key` = "" exempts every key in the section; a non-empty key exempts
/// just that key (e.g. `[tiling] layouts`).
pub const SectionKey = struct {
    section: []const u8,
    key: []const u8 = "",
};

/// A parent-gated section family on a fragment's `inert_families` list: a
/// child section present while its parent section is absent leaves those
/// knobs inert, which the load warns about (`warnInertSectionFamilies`).
/// Exactly one of the child fields is used per family (empty = unused).
pub const InertFamily = struct {
    parent: []const u8,
    /// Any section whose name starts with this prefix (family form).
    child_prefix: []const u8 = "",
    /// One exact child section name.
    child_exact: []const u8 = "",
};

/// Source label the config load stamps on the EMBEDDED fallback document
/// (`config.zig` parseFallbackDoc) so its entries carry it like any file
/// label. Shared vocabulary because a load-time check must RECOGNISE the
/// build-owned source: the bar's segment-name fail bar skips it (the boot
/// fallback path falls back to exactly this source, so rejecting its layout
/// would take the floor down in a build that deleted one of its segments)
/// while tests that load the same bytes under a file label keep it pinned.
pub const embedded_fallback_label = "<embedded fallback>";
/// Document-global color-palette variable names declared once and referenced
/// by any color knob (the color_from chains and the parser's collectPalette).
pub const palette_primary_color = "primary_color";
pub const palette_secondary_color = "secondary_color";
pub const palette_alternative_color = "alternative_color";
pub const palette_text_color = "text_color";

// Keybinding and action types

// The `Action` union and its payload vocabulary (`Dir`, `SwapMode`,
// `RestoreOrder`) moved to `action.zig` — a types-free module input
// consumes on its own stem. `Dir` and `Action` re-export here because
// `Keybind`/`MouseBind`, the contract, and the tests name them through this
// file; `needsTilingFocusScaffold` is generic (comptime tag) and cannot be
// const-aliased, so `input/dispatch` and the input tests import `action`.
pub const Dir = action.Dir;
pub const Action = action.Action;

pub const Keybind = struct {
    modifiers: u16, // u16 per XCB spec; xcb_grab_key rejects wider types
    keysym: u32, // xcb_keysym_t is u32 by X11 protocol spec; never narrowed
    // No keycode: it is derived from the live keyboard, not authored, and
    // storing it here made a config-reload's keycodes indistinguishable from
    // the config file's contents. `keybind.ResolvedBind` carries it instead.
    action: Action,
};

/// A binding triggered by a mouse button press with modifier keys held.
pub const MouseBind = struct {
    modifiers: u16,
    button: u8,
    action: Action,
};

// The (modifiers, keysym) -> Action dispatch map and its keysym->keycode
// resolution live in the input layer (`core/input/keybinds.zig`): resolving a
// keysym needs a live XkbState, which the pure config layer must not depend
// on. Keeping it out of this file also breaks the types -> keybinds -> core
// -> types import cycle.

// Layout-name vocabulary

/// Maximum bytes any lowered config name (layout names, string_map keys) may
/// occupy. Single home for the 32-byte buffers that config lookups lower into;
/// vocab/layout_names.zig derives its bound from this so the two can't drift.
pub const max_config_name = 32;

/// Lowercases `str` into a `max_len`-byte stack buffer if it fits; returns
/// null when `str` is too long. Shared by the layout-name and string_map
/// lookups; keyNameToKeysym bypasses it: the C API needs a verbatim
/// NUL-terminated copy.
pub inline fn lowerSlice(comptime max_len: usize, buf: *[max_len]u8, str: []const u8) ?[]const u8 {
    if (str.len > max_len) return null;
    _ = std.ascii.lowerString(buf[0..str.len], str);
    return buf[0..str.len];
}

/// Case-insensitive enum lookup shared by enums that expose a `string_map` decl.
/// Lowercases `str` into a stack buffer and probes the map.
/// Returns null when `str` exceeds the buffer or the key is not found.
pub fn enumFromString(comptime T: type, str: []const u8) ?T {
    const map = T.string_map;
    var buf: [max_config_name]u8 = undefined;
    return map.get(lowerSlice(max_config_name, &buf, str) orelse return null);
}

/// Canonical name of the master layout module. Every "master-stack"/
/// "master_stack" alias folds onto this at the config boundary. Shared
/// vocab: layout_names.zig (config layer) resolves names through it and must
/// not import the tiling layer.
pub const canon_master_layout = "master";

// Ownership helpers

/// Meanings for the free helpers' `retain_capacity` argument: `keep_capacity`
/// reuses backing storage (a config reload repopulates the same lists), while
/// `free_storage` deinits it (full teardown). A named spelling beats a bare
/// boolean at every call site.
pub const keep_capacity = true;
pub const free_storage = false;

/// Frees every owned string in `list`, then either deinits or clears the
/// list depending on `retain_capacity`. Shared by the fragment deinits
/// (full teardown) and config reload (reuse backing storage).
pub inline fn freeStrings(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    retain_capacity: bool,
) void {
    for (list.items) |s| allocator.free(s);
    if (retain_capacity) list.clearRetainingCapacity() else list.deinit(allocator);
}

/// Frees every heap-dup'd key/value in a variants-style string map, then
/// either deinits or clears it depending on `retain_capacity`.
pub fn freeStringMap(
    map: *std.StringHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    retain_capacity: bool,
) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    if (retain_capacity) map.clearRetainingCapacity() else map.deinit(allocator);
}

/// The always-present core config: keybindings, mouse bindings, DPI override.
pub const CoreConfig = struct {
    keybindings: std.ArrayList(Keybind) = .empty,
    mouse_bindings: std.ArrayList(MouseBind) = .empty,

    /// Overrides detected display DPI. null = detect (Xft.dpi, then geometry).
    ///
    /// An override exists because detection is a heuristic: a headless or
    /// nested-X server can report a screen size in millimetres that is a
    /// guess, and a HiDPI panel whose physical size the compositor has not
    /// told X about yields a DPI that is simply wrong. Both produce a bar
    /// whose text is the wrong size, with nothing in the config to correct it
    /// by. Validated for reasonableness on load, exactly like a detected one,
    /// so a typo cannot buy a font the size of a billboard.
    dpi: ?f32 = null,

    /// Allow held keybindings to re-fire at the X auto-repeat rate
    /// (universal repeat, the pre-0.x behavior). Default false: a bound
    /// combo fires exactly once per physical press (a false→true keycode
    /// transition), so side-effecting actions (exec / reload / close) cannot
    /// trigger at ~30 Hz while a combo is held.
    key_repeat: bool = false,

    pub fn deinit(self: *CoreConfig, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| kb.action.deinit(allocator);
        self.keybindings.deinit(allocator);

        for (self.mouse_bindings.items) |*mb| mb.action.deinit(allocator);
        self.mouse_bindings.deinit(allocator);
    }
};

/// Shared class-rule vocabulary: the workspace admission rules live with the
/// always-compiled admission layer's signatures (which take `[]const Rule`
/// even when the workspaces fragment is absent), while the LIST owner
/// (`WorkspaceConfig`) is the optional workspaces fragment.
pub const Rule = struct {
    class_name: []const u8,
    /// Target workspace (0-based) for workspace rules; unused when `float`.
    workspace: u8,
    /// "float" class rules: windows matching `class_name` are admitted
    /// floating on the current workspace instead of being tiled on `workspace`.
    float: bool = false,
};

/// Default colors (kept as shared literals: they seed fragment field
/// initializers and read-time fallbacks without coupling the fragments to
/// each other). Default color scheme for the focused/unfocused tiling borders.
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

/// Type-level defaults for optional string fields in the bar config.
/// When a field is `null`, the corresponding default is used at read time.
pub const default_clock_format: []const u8 = "%Y-%m-%d %H:%M:%S";
pub const default_run_prompt: []const u8 = "run: ";
pub const default_indicator_focused: []const u8 = "■";
pub const default_indicator_unfocused: []const u8 = "□";
