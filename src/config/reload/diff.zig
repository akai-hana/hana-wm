//! Reload change detection for handleConfigReload (reload.zig): whether the
//! key PAIR layout changed, so an unchanged reload can skip the regrab.
//! Bar and tiling deliberately have NO detector -- their rebuilds run on
//! every reload. A content compare that could skip them would leave
//! borrowed state (the rules map's config-sourced key slices) pointing at
//! the box the swap is about to release, and the rebuilds are idempotent.

const types = @import("types");

pub const ConfigChanges = struct {
    keys: bool = false,
};

/// Keys-subsystem content: the pair layout — (modifiers, keysym) per keyboard
/// binding and (modifiers, button) per mouse binding. Action is deliberately
/// excluded: two keybindings that differ only in their action (e.g. a changed
/// command string) still share a pair, so no regrab is needed.
fn keysChanged(old: *const types.Config, new: *const types.Config) bool {
    if (old.keybindings.items.len != new.keybindings.items.len) return true;
    for (old.keybindings.items, new.keybindings.items) |a, b| {
        if (a.modifiers != b.modifiers or a.keysym != b.keysym) return true;
    }
    if (old.mouse_bindings.items.len != new.mouse_bindings.items.len) return true;
    for (old.mouse_bindings.items, new.mouse_bindings.items) |a, b| {
        if (a.modifiers != b.modifiers or a.button != b.button) return true;
    }
    return false;
}

/// Compares old and new configs for the one subsystem whose rebuild is
/// skipped on an unchanged pair layout (the regrab). Gate the regrab on
/// `.keys`; everything else rebuilds unconditionally.
pub fn detectChanges(old: *const types.Config, new: *const types.Config) ConfigChanges {
    return .{ .keys = keysChanged(old, new) };
}
