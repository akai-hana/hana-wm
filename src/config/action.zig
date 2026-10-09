//! Action vocabulary: the `Action` union (what a binding, bar segment, or
//! IPC line can ask the WM to do), the payload vocabulary it names (`Dir`,
//! `SwapMode`, `RestoreOrder`), and the `needsTilingFocusScaffold` gate that
//! declares which actions must run with the tiling focus scaffold wrapped
//! around them.
//!
//! Deliberately types-free: `types.zig` re-exports `Dir` and `Action` for
//! its `Keybind`/`MouseBind`, the contract, and the tests, so the edge
//! between the two files runs one way (types -> action) and never forms a
//! cycle. `needsTilingFocusScaffold` is a generic function and cannot be
//! const-aliased, so its two consumers (`input/dispatch`, the input tests)
//! import this module directly.
//!
//! Its own stem (`action`, consumed by input) is why this union is not just
//! a section of types.zig.

const std = @import("std");
const model = @import("model");

pub const Dir = enum { forward, reverse };
pub const SwapMode = enum { normal, focus_swap };
/// Single source: the model owns the restore-order vocabulary (its enum is
/// what minimize/actions dispatch on); this file aliases it so the Action
/// union's payload and the runtime share one type and one definition.
pub const RestoreOrder = model.RestoreOrder;

pub const Action = union(enum) {
    exec: []const u8,
    close_window,
    /// In-place config reload: re-reads config.toml and applies the diff to
    /// the live model, without restarting the process (proc.reload flag).
    /// On success the live config is also frozen into the re-exec snapshot.
    reload_config,
    /// Unconditional in-place re-exec of the current binary at the resolved
    /// executable path (restart.requestReexec): reloads the whole process,
    /// no binary-change check. BINARY-ONLY: the successor boots from the
    /// frozen last-good config snapshot (HANA_CONFIG_DIR), never re-reading
    /// the config files; chain with reload_config for a full reload.
    reload_hana,
    cycle_layout: Dir,
    toggle_bar_visibility,
    toggle_bar_position,
    set_master_width: Dir,
    set_master_count: Dir,
    /// Grow the topmost/bottommost stack slave's share of the column (mod+n/o).
    grow_stack: Dir,
    toggle_floating_window,
    toggle_fullscreen,
    swap_master: SwapMode,
    switch_workspace: u8,
    move_to_workspace: u8,
    toggle_tag: u8,
    /// Ordered list of actions executed left-to-right (owned slice).
    /// A `+`-linked group in a config list becomes a `.parallel` step (see
    /// below); the enclosing `.sequence` runs steps in order, so a mixed list
    /// like `[a, b + c, d]` is a, then b+c, then d.
    sequence: []Action,
    /// One batch of sub-actions launched together: every member is dispatched
    /// before the enclosing sequence proceeds to its next step, and no member
    /// waits on another (owned slice). The WM is single-threaded, so this is
    /// the same-batch form of parallelism: sync actions complete back-to-back
    /// and `exec` children run as concurrent processes.
    parallel: []Action,
    dump_state,
    minimize_window,
    unminimize: RestoreOrder,
    unminimize_all,
    cycle_variants: Dir,
    toggle_prompt,
    /// Shows all windows from every workspace at once; toggled on/off.
    all_workspaces,
    /// Pin/unpin focused window to every workspace.
    pin_window,
    /// Cycle focus forward/right or backward/left.
    cycle_focus: Dir,
    /// Move focused window forward.
    move_window_next,
    /// Move focused window backward.
    move_window_prev,
    /// Shift scroll-layout viewport left/right by one slot.
    scroll_view: Dir,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exec => |cmd| allocator.free(cmd),
            .sequence, .parallel => |acts| {
                for (acts) |*a| a.deinit(allocator);
                allocator.free(acts);
            },
            // Payload-free variants.
            .all_workspaces, .close_window, .dump_state, .grow_stack, .minimize_window, .move_to_workspace, .move_window_next, .move_window_prev, .pin_window, .reload_config, .reload_hana, .swap_master, .switch_workspace, .toggle_bar_position, .toggle_bar_visibility, .toggle_floating_window, .toggle_fullscreen, .toggle_prompt, .toggle_tag, .unminimize, .unminimize_all => {},
            // Copy payloads (Dir, u8): nothing to free.
            .set_master_width, .set_master_count, .cycle_focus, .cycle_layout, .cycle_variants, .scroll_view => {},
            // Deliberately no `else`: a new Action variant carrying an owned
            // allocation has to name its free here, at compile time. A
            // catch-all would make every future payload leak by default.
        }
    }
};

/// Actions that need the tiling-op focus scaffold: transient focus noise
/// suppressed, then a settle grab, wrapped around the mutation.
///
/// This is a property OF THE ACTION, so it is declared here beside the union
/// rather than left implicit in whichever switch arm happens to call the
/// helper. The failure mode that motivated it: the graft lived at three
/// dispatch arms, so a new mutating tag was scaffolded or not by which arm
/// somebody wrote, and the answer was invisible at the type. The `switch` below
/// has no `else` on purpose -- adding a variant is a compile error naming
/// this decision, not a silent default.
///
/// Why only these three, when `set_master_width`, `swap_master`,
/// `move_window_*` and `scroll_view` also mutate the layout: those reconcile
/// inside the action itself (`actions.adjustPrimaryWidthAction` and friends
/// each end in `pipeline.reconcileGrab`) and never move focus, so there is no
/// transient focus event to suppress and no settle grab owed. The three
/// grafted tags DO move focus as a side effect -- toggling float and cycling
/// layout/variants re-derive the focused window -- so they take one grab for
/// the whole operation instead of paying focus-then-reconcile's two.
pub fn needsTilingFocusScaffold(comptime tag: std.meta.Tag(Action)) bool {
    return switch (tag) {
        // Re-derives focus as a side effect of the mutation.
        .toggle_floating_window, .cycle_layout, .cycle_variants => true,
        // Pure layout mutations: self-reconciling, focus-preserving.
        .set_master_width,
        .set_master_count,
        .grow_stack,
        .swap_master,
        .move_window_next,
        .move_window_prev,
        .scroll_view,
        .toggle_fullscreen,
        // Everything else (lifecycle, bar chrome, workspaces/tags, exec,
        // diagnostics, min/unminimize, sequence/parallel) touches neither the
        // layout nor focus: each has its own focus transition where it needs
        // one, and grafting here would suppress focus changes users asked for.
        .close_window,
        .reload_config,
        .reload_hana,
        .exec,
        .sequence,
        .parallel,
        .dump_state,
        .cycle_focus,
        .switch_workspace,
        .move_to_workspace,
        .toggle_tag,
        .all_workspaces,
        .pin_window,
        .toggle_bar_visibility,
        .toggle_bar_position,
        .toggle_prompt,
        .minimize_window,
        .unminimize,
        .unminimize_all,
        => false,
    };
}
