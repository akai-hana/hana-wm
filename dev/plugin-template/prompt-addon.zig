//! prompt-addon.zig — drop-in template for a hana prompt addon.
//!
//! COPY ME: the fastest way to start a new prompt addon is
//!
//!     cp dev/plugin-template/prompt-addon.zig src/bar/modules/prompt/myaddon.zig
//!
//! then edit the TODO markers. Nothing else needs to change:
//! build.zig's sub-registry generation (`prompt_subs`) picks the
//! file up from FILE PRESENCE plus the `pub const addon`
//! self-declaration.
//!
//! The prompt is the bar's chrome-surface overlay: an interactive
//! command line embedded in the title segment. An addon extends the
//! prompt's EDITOR — the vim modal-editing engine is the shipped
//! addon — by binding key handlers through the prompt core's
//! `registerHandlers` in `register` (a no-op addon registers
//! nothing and the basic editor stays in force), and by owning
//! per-activation state in `init`/`deinit` (the allocator is the
//! bar's; `max_input` bounds any input buffer you allocate, and
//! config slices are freed on reload, so copy anything you must
//! outlive into storage you own).
//!
//! The addon family is the one place the prompt's behavior is
//! open: the CLOSED CORE (`prompt.zig`) owns activation, key
//! routing, rendering and the editor contract it re-exports; the
//! OPEN MODULES are the siblings binding `pub const addon:
//! prompt.Addon`. Siblings WITHOUT the binding (completion,
//! editor, render) are private implementation files — importable
//! by stem, never bound.
//!
//! For the OTHER chrome-surface shape — a bar segment that binds
//! the prompt's keypress/redraw extras (`handleKeypress`,
//! `consumeRedrawRequest`, `invalidateReloadCaches`) and becomes
//! the chrome-surface input provider — see segment.zig, which
//! documents those bindings as commented-out lines.
//!
//! `check-plugin-template` compiles this file against the real
//! prompt module, so contract drift self-fails on `zig build check`.

const std = @import("std");
const prompt = @import("prompt");

/// Per-activation state setup. Called once per prompt activation
/// with the bar's allocator and the editor's input cap; return an
/// error to refuse the activation. Allocate your addon's state
/// here (a buffer bounded by `max_input`, say) and free it in
/// `deinit` — the reset discipline is what lets a test
/// init/deinit per fixture.
pub fn init(allocator: std.mem.Allocator, max_input: usize) anyerror!void {
    _ = max_input;
    _ = allocator;
    // TODO: allocate your addon's state here.
}

/// Per-activation teardown: free everything `init` allocated.
pub fn deinit(allocator: std.mem.Allocator) void {
    _ = allocator;
    // TODO: free your addon's state here.
}

/// Bind your key handlers through the prompt core
/// (`prompt.registerHandlers(.{ ... })` — see `prompt.Handlers`):
/// insert-mode keypress, normal-mode keypress, ctrl-key,
/// deactivate and the mode-label seam. Called once per activation;
/// a later addon's register REPLACES an earlier one's handlers, so
/// one addon owns the seam at a time.
pub fn register() void {
    // TODO: prompt.registerHandlers(.{ ... });
}

/// This module's prompt-addon binding. Membership in
/// `prompt_subs.addons` comes from file presence alone (build.zig's
/// sub-registry generation), so dropping this file reverts the
/// prompt to its basic editor with zero core edits.
pub const addon: prompt.Addon = .{
    .register = register,
    .init = init,
    .deinit = deinit,
};
