//! Session adoption: the re-exec-only path where a successor window manager
//! takes over the X clients a predecessor left behind.
//!
//! hana never reparents, so clients stay direct root children across an execv
//! and the successor can adopt them by scanning the root's children. main calls
//! adoptSession exactly once -- after surfaces.init() (bar up so bar-aware work
//! area is live) and before events.run() -- sequencing handoff, window adoption,
//! and focus against each other.
//!
//! The driver owns the ORDER (load the handoff, walk the root's children,
//! re-play the persisted level, hand focus to the restored winner); the
//! adoption loop below owns the walk itself: one pipelined
//! attribute+property fire over every root child, then the same
//! decision/register pipeline admission.zig runs for every MapRequest. The
//! cookie, rules-map, and registration helpers all live in admission.zig;
//! this file holds the restore-record side (lookup, float-bit resolution,
//! record application) and the loop that sequences them.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const log = @import("log");
const query = @import("query");
const handoff = @import("handoff");
const pipeline = @import("pipeline");
const actions = @import("actions");
const admission = @import("admission");
const model_mod = @import("model");
const usable_area_mod = @import("usable_area");
const window_mods = @import("window_modules").modules;
const registry = @import("registry");

/// Adopt the session described by `restore_path`, if there is one to adopt.
///
/// Called after the bar is up, so the bar-aware work area is already live and
/// the single reconcile that follows places windows against the same geometry a
/// normal boot would use. A missing or unreadable restore file is not an
/// error: that is an ordinary first boot.
pub fn adoptSession(restore_path: []const u8) void {
    if (!handoff.loadToGlobal(core.getState().alloc, restore_path)) return;

    const n = adoptRootWindows() catch |err| blk: {
        log.err("Window adoption failed: {}", .{err});
        break :blk 0;
    };
    // Nothing adopted: the file named windows the server no longer has, and
    // there is no level to re-apply and nothing to focus.
    if (n == 0) return;

    // Re-play the persisted level now that every window is registered; no
    // reconcile here — the single reconcile after adoptSession places every
    // adopted window exactly as it was.
    handoff.applyModelLevel(pipeline.mut());
    actions.focusAfterGeometry();
}

/// Linear scan for a window's restore record. Restore files are small
/// (bounded by the model's store_capacity), so a flat scan is cache-local and
/// avoids allocating a lookup map just for adoption.
fn findWindowRecord(windows: []const handoff.WindowRecord, win: u32) ?*const handoff.WindowRecord {
    for (windows) |*r| {
        if (r.win == win) return r;
    }
    return null;
}

/// Target workspace for an adopted window: the restore record's home
/// workspace (lowest set bit of its mask) when present, else the currently
/// active workspace. Deliberately NOT the spawn-queue/rules resolution, which
/// describes brand-new spawns rather than pre-existing windows.
fn restoredOrCurrent(record: ?*const handoff.WindowRecord) u8 {
    if (record) |r| {
        if (r.mask != 0) return @intCast((model_mod.lowestBit(r.mask) orelse unreachable).index);
    }
    return query.getCurrentWorkspace() orelse 0;
}

/// Re-applies a restore record's mask, anchor, and presence onto an
/// already-registered model entry. Registration (admitWindow ->
/// actions.mapRequest) creates the entry as a present tiled-anchored window on
/// its target workspace; this overwrites the per-window state that survived
/// the re-exec so the caller's reconcile can place it exactly as before.
/// Presence bookkeeping that would otherwise drift is routed through the owning
/// window module's deserialize hook rather than patched by hand.
fn applyRestoredRecord(win: u32, record: *const handoff.WindowRecord) void {
    const model = pipeline.mut();
    const e = model.store.getPtr(win) orelse return;

    e.mask = record.mask;

    switch (record.anchor) {
        .tiled => {},
        .floating => |rect| {
            // Mirror toggleFloating's floating storage: anchor + home_ws null
            // (a floating window has no tiled slot). The caller's reconcile
            // sizes the window from this rect.
            e.anchor = .{ .floating = rect };
            e.home_ws = null;
        },
    }

    // Presence that was non-present at save time is re-asserted through the
    // window-module registry's deserialize hook: the module that claims the
    // opaque ext blob re-parks the window / resumes its coverage and restores
    // its private record. Dispatch happens for ANY non-null ext (not only
    // parked records): a covering (fullscreen) window advertises presence
    // .covering + a fullscreen blob, and must route through the module in the
    // same dispatch. When no module claims the blob (the feature was stripped, or
    // the record carried no ext), the entry stays present and reconciles
    // on-screen -- the graceful degrade.
    //
    // Claim resolution: the blob is stamped with the claiming module's NAME at
    // save time (handoff.ext_format_version). Adoption fast-paths on the name;
    // when the name no longer resolves (the module was removed or renamed) or
    // its hook declines, the magic-byte scan over every module's
    // self-identifying format tag claims it instead. Blobs written by the
    // pre-name format still resolve through their registry ordinal.
    if (record.ext) |stored| {
        // A recognised header narrows WHICH module is asked first; it never
        // decides the outcome, because the payload's own magic bytes do that.
        // Anything unrecognised (a foreign version, a truncated header) is
        // passed through whole, exactly as an unstamped blob was.
        const header = handoff.decodeExt(stored);
        const payload: []const u8 = header.payload;
        if (header.claimed_name) |name| {
            for (window_mods) |mod| {
                if (!std.mem.eql(u8, mod.name, name)) continue;
                if (mod.deserializeWindow) |f| {
                    if (f(win, payload, model)) return;
                }
                break; // named claimant found; the scan below is the fallback
            }
        } else if (header.legacy_ordinal) |ordinal| {
            if (ordinal < window_mods.len) {
                if (window_mods[ordinal].deserializeWindow) |f| {
                    if (f(win, payload, model)) return;
                }
            }
        }
        // Uniform magic-byte claim scan: every module in registry order gets
        // a chance; the first hook to claim (return true) ends the scan, so
        // this is dispatchFirstTrue's stop-at-first-true shape rather than a
        // full fan-out. The function ends here either way -- the early
        // return this replaced just exited the same scope.
        _ = registry.dispatchFirstTrue(.deserializeWindow, .{ win, payload, model });
    }
}

const AdoptionEntry = struct {
    win: u32,
    attr_cookie: xcb.xcb_get_window_attributes_cookie_t,
    record: ?*const handoff.WindowRecord,
    cookies: admission.AdmissionCookies,
};

/// Adopts top-level windows that pre-existed the WM's (re)start as direct
/// root children (hana never reparents: clients are root children, borders
/// via the client's own X border), so after a re-exec the fresh process takes
/// over the old session's windows instead of waiting for new maps.
///
/// Per-window policy:
///   - skip already-managed windows, the WM's own bar window, and
///     override-redirect popups (never manage those);
///   - unmapped windows are adopted ONLY when the restore file records them
///     as parked (a surviving hidden window must stay hidden); other unmapped
///     windows are likely withdrawn toplevels and are skipped;
///   - each admitted window registers through the shared
///     admitWindow path on
///     its restored-or-current workspace;
///   - a restore record (if any) then re-applies the window's mask, mode, and
///     presence directly on the model entry.
///
/// CALLING CONTRACT: this does NOT reconcile. Placement derives from
/// tiled_order / focus_mru, which are rebuilt by handoff.applyModelLevel
/// AFTER this returns; a reconcile here would place pre-restore state.
/// adoptSession therefore sequences:
///     adoptRootWindows(); handoff.applyModelLevel(m); one reconcile.
/// Returns the number of windows admitted (restored-parked ones included).
///
/// PIPELINING: MapRequest pipelines one window's five property queries. Boot
/// restore pipelines the attribute + property query of every root child: fires
/// all cookies across all children into a single list, then drains each
/// batch in request order. The X server answers the whole batch back-to-back,
/// so the once per-window serial attribute-then-properties pattern collapses to
/// ~2 blocking reads total (the query_tree reply plus one drain that pulls the
/// entire batch off the wire).
fn adoptRootWindows() !usize {
    // Defensive boot-order guard: adoption runs the admission pipeline below
    // (spawn queue, rules maps, allocator). admission.init is called from
    // window.init AFTER the window module's own sub-systems are up, so a null
    // allocator means boot is too early and nothing is safe to touch yet.
    const alloc = admission.allocator() orelse return 0;

    const cs = core.getState();
    const conn = cs.conn;

    const tree_reply = xcb.xcb_query_tree_reply(
        conn,
        xcb.xcb_query_tree(conn, cs.root),
        null,
    ) orelse return 0;
    defer std.c.free(tree_reply);
    const children = xcb.xcb_query_tree_children(tree_reply);
    const child_count: usize = @intCast(xcb.xcb_query_tree_children_length(tree_reply));

    const loaded = handoff.loaded();

    // The per-window admission query used to be fired and drained inside this
    // loop (and the attribute query even earlier), costing one serial blocking
    // round trip for the attribute and one for the admission batch per child:
    // 1 + 2N total. Firing them all up-front lets the X server process every
    // child's attribute + property query in parallel; the replies then arrive
    // back-to-back and are drained in order below, so the batch costs a single
    // blocking read. Candidates that fail the attribute gate during the drain still
    // have their up-front property replies discarded, never leaked.
    var entries: std.ArrayListUnmanaged(AdoptionEntry) = .empty;
    defer entries.deinit(alloc);
    try entries.ensureTotalCapacity(alloc, child_count);

    for (children[0..child_count]) |win| {
        // Same guard as window.handleMapRequest: never re-admit a window another path
        // already manages.
        if (query.isManaged(win)) continue;

        // The WM's own bar window is a root child we created; leave it alone.
        if (usable_area_mod.surfaceWindow()) |bar_win| if (bar_win == win) continue;

        // The restore-record lookup is a local scan; carry the result into the
        // drain loop so it does no X work before consuming each batch.
        const record = if (loaded) |f| findWindowRecord(f.windows, win) else null;

        entries.appendAssumeCapacity(.{
            .win = win,
            .attr_cookie = xcb.xcb_get_window_attributes(conn, win),
            .record = record,
            .cookies = admission.fireAdmissionCookies(conn, win),
        });
    }

    var adopted: usize = 0;
    for (entries.items) |*entry| {
        const win = entry.win;

        const attr_reply = xcb.xcb_get_window_attributes_reply(conn, entry.attr_cookie, null);
        defer std.c.free(attr_reply);

        // Override-redirect windows are transient/popup, never manage.
        // Visibility gate: adopt mapped windows; adopt unmapped ONLY when
        // the restore file records them as parked (a surviving hidden
        // window must stay hidden). Other unmapped windows are likely
        // withdrawn toplevels and are skipped. A null reply means the
        // window vanished between the cookie fire and this drain; release its
        // up-front admission replies without parsing them.
        const adopt = if (attr_reply) |r|
            r.*.override_redirect == 0 and
                (r.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE or
                    (entry.record != null and entry.record.?.presence == .parked))
        else
            false;
        if (!adopt) {
            admission.discardAdmissionCookies(conn, entry.cookies);
            continue;
        }

        // Claim the management event mask so the adopted window delivers the
        // PropertyNotify/StructureNotify/FocusChange events managed windows
        // rely on (mirror of window.handleMapRequest's preamble).
        admission.claimManagedEventMask(conn, win);

        // Adoption never resolves the target workspace from these cookies
        // (restored-or-current wins, not spawn rules), so the two
        // conditionally-fired replies are discarded to keep the XCB queue
        // from accumulating unconsumed results. A persisted restore record
        // wins over the float rule too (it carries the window's exact
        // pre-restart anchor); record-less windows still honor a class float
        // rule, matching the MapRequest admission policy.
        const float = if (entry.record == null) admission.resolveClassFloat(entry.cookies.c_wm_class) else false;
        // resolveClassFloat already consumed the WM_CLASS reply, so draining it
        // again (drainAdmissionCookies with all=true) would double-dispose
        // the same XCB reply (a freed sequence wedged at the 16-bit wrap, plus
        // a leaked discard entry per adopted window). Null it out in the drain
        // copy: the spawn-queue cookie is still discarded below, and when a
        // restore record supplied the anchor resolveClassFloat never ran, so
        // c_wm_class stays live and is discarded here as before.
        var drain_cookies = entry.cookies;
        if (entry.record == null) drain_cookies.c_wm_class = null;
        const size_hints = admission.drainAdmissionCookies(conn, win, drain_cookies, true);

        // Register on the restored-or-current workspace. on_current=false so
        // actions.mapRequest does NOT reconcile per-window (the caller owns
        // the single end-of-adoption reconcile) or steal model focus before
        // applyModelLevel restores the session's focus.
        admission.admitWindow(win, restoredOrCurrent(entry.record), false, float, size_hints);

        if (entry.record) |r| applyRestoredRecord(win, r);

        adopted += 1;
    }

    log.info("Adopted {d} pre-existing windows", .{adopted});
    return adopted;
}
