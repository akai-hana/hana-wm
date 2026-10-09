//! ClientMessage: EWMH fullscreen requests from applications (the pager /
//! native-fullscreen side of the fullscreen protocol; the model transition
//! itself is actions/covering.zig).
//!
//! Split out of window.zig, which re-exports `handleClientMessage` as the
//! event dispatch surface events.zig's table binds. Owns the warn-once
//! latches: a looping pager would otherwise flood the log, and the latches
//! reset with the rest of the window layer's init discipline (window.init
//! calls `reset`).

const core = @import("core");
const xcb = core.xcb;
const log = @import("log");

const atoms = @import("atoms");
const actions = @import("actions");
const query = @import("query");

const State = struct {
    // Warn-once latches for client-message diagnostics (see
    // handleClientMessage): a looping pager would otherwise flood the log.
    // One latch per message class -- two unrelated warnings sharing a latch
    // meant whichever fired first silenced the other for the process's life.
    // Reset together via reset() so an init() re-arms every diagnostic.
    warned_unmanaged_fs_request: bool = false,
    warned_active_ignore: bool = false,
    warned_unmanaged_state: bool = false,
};

var state: State = .{};

/// Re-arm every warn latch (called from window.init's reset discipline).
pub fn reset() void {
    state = .{};
}

/// Logs `fmt` at warn level at most once per process, arming `latch` (a field
/// of `State`, so a reset() re-arms every diagnostic together). The
/// client-message handlers are fed by EWMH pagers that can loop forever, and
/// one shared latch between two message classes meant the second warning could
/// never fire after the first.
fn warnOnce(latch: *bool, comptime fmt: []const u8, args: anytype) void {
    if (latch.*) return;
    latch.* = true;
    log.warn(fmt, args);
}

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    // Unhonorable pager requests are dropped silently otherwise; each warn
    // fires once per process so a looping pager cannot flood the log.
    // `_NET_WM_FULLSCREEN_REQUEST` is a SEPARATE EWMH message from
    // `_NET_WM_STATE`, and it is the one browsers use for native video
    // fullscreen. Its layout is: window field = the window, data32[0] = the
    // intended end state (1 enter, 0 leave). Dropping it -- as the pre-fix
    // handler did, since the atom appeared nowhere in the tree -- is why F
    // did nothing in a YouTube player while hana's own Mod+F worked.
    const net_fs_request = atoms.getAtomOrZero("_NET_WM_FULLSCREEN_REQUEST");
    if (net_fs_request != 0 and event.type == net_fs_request) {
        const win = event.window;
        if (!query.isValidManagedWindow(win)) {
            warnOnce(
                &state.warned_unmanaged_fs_request,
                "Ignoring _NET_WM_FULLSCREEN_REQUEST for unmanaged window 0x{x}",
                .{win},
            );
            return;
        }
        // Only 0 and 1 are defined; anything else is dropped rather than
        // guessed at, since guessing means entering or leaving fullscreen on
        // a client that asked for neither.
        const target = switch (event.data.data32[0]) {
            0 => false,
            1 => true,
            else => return,
        };
        // PIPELINE: model-path transition; the transition stays on the single
        // source of truth.
        actions.fullscreenSetWindow(win, target);
        return;
    }

    const net_active = atoms.getAtomOrZero("_NET_ACTIVE_WINDOW");
    if (net_active != 0 and event.type == net_active) {
        warnOnce(
            &state.warned_active_ignore,
            "Ignoring _NET_ACTIVE_WINDOW request for 0x{x}: EWMH activation is not implemented",
            .{event.window},
        );
        return;
    }

    const net_wm_state = atoms.getAtomOrZero("_NET_WM_STATE");
    if (net_wm_state == 0 or event.type != net_wm_state) return;

    const fs_atom = atoms.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
    if (fs_atom == 0) return;
    const prop1 = event.data.data32[1];
    const prop2 = event.data.data32[2];
    if (prop1 != fs_atom and prop2 != fs_atom) return;

    const win = event.window;
    if (!query.isValidManagedWindow(win)) {
        warnOnce(
            &state.warned_unmanaged_state,
            "Ignoring _NET_WM_STATE request for unmanaged window 0x{x}",
            .{win},
        );
        return;
    }

    const action = event.data.data32[0];
    // EWMH _NET_WM_STATE action codes, carried in data32[0]. `want` is
    // the target state for the SET paths (add/remove); `toggle` is null
    // -- a genuine flip, the keybind path's meaning.
    const ewmh_state_add: u32 = 1;
    const ewmh_state_remove: u32 = 0;
    const ewmh_state_toggle: u32 = 2;
    const want: ?bool = switch (action) {
        ewmh_state_add => true,
        ewmh_state_remove => false,
        ewmh_state_toggle => null,
        else => return,
    };
    // PIPELINE: model-path transition; the transition stays on the single
    // source of truth. `fullscreenSetWindow` re-checks want-vs-current
    // itself and computes the covering state inside the same grab, so no
    // covering pre-scan or explicit guard is needed here -- one covering
    // scan per request instead of two.
    actions.fullscreenSetWindow(win, want);
}
