//! drun — dwm-style command runner for the status bar.
//!
//! When active, the title segment area becomes a text input field. The user can
//! type a shell command and press Return to execute it via sh(1). A full
//! vim-style modal editing layer is built in; see vim.zig for details.
//!
//! ── Integration checklist ────────────────────────────────────────────────────
//!
//!  1. bar.zig  — In drawSegment(), replace the `.title` arm dispatch so that
//!                when drun.isActive() is true, drun.draw() is called instead
//!                of title_segment.draw(). Both share the same signature:
//!
//!                  .title => if (drun.isActive())
//!                      try drun.draw(self.dc, self.config, self.height, x,
//!                          width orelse 100, self.conn, snap.focused_window,
//!                          snap.current_ws_wins.items, snap.minimized.items,
//!                          &self.cached_title, &self.cached_title_window,
//!                          snap.title_invalidated, self.allocator)
//!                  else
//!                      try title_segment.draw(...)
//!
//!                Also guard drawTitleOnly() with `if (!drun.isActive())`.
//!
//!  2. event loop — Call drun.handleKeyPress() *before* normal keybind dispatch:
//!
//!                  const kp: *xcb.xcb_key_press_event_t = @ptrCast(event);
//!                  if (drun.handleKeyPress(kp, wm)) {
//!                      bar.submitDrawAsync(wm);
//!                      continue;
//!                  }
//!
//!  3. action dispatch — Add a "drun_toggle" action calling drun.toggle(wm).
//!
//!  4. bar init / deinit — drun.init(conn) / drun.deinit().
//!
//! ── config.toml ──────────────────────────────────────────────────────────────
//!
//!   Mod+Shift+Tab = "drun_toggle"
//!
//! ─────────────────────────────────────────────────────────────────────────────

const std     = @import("std");
const defs    = @import("defs");
const xcb     = defs.xcb;
const drawing = @import("drawing");
const title   = @import("title");
const debug   = @import("debug");
pub const vim = @import("vim");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
});

// ── xcb-keysyms bindings (link with -lxcb-keysyms) ───────────────────────────

const xcb_key_symbols_t = opaque {};

extern fn xcb_key_symbols_alloc(conn: *xcb.xcb_connection_t) ?*xcb_key_symbols_t;
extern fn xcb_key_symbols_free(syms: *xcb_key_symbols_t) void;
extern fn xcb_key_symbols_get_keysym(syms: *xcb_key_symbols_t, code: xcb.xcb_keycode_t, col: c_int) xcb.xcb_keysym_t;

// ── Constants ─────────────────────────────────────────────────────────────────

const MIN_CURSOR_PX  : u16   = 8;
const CURSOR_WIDTH   : u16   = 1;    // caret width in pixels (insert mode)
const CURSOR_BLINK_MS: u64   = 530;  // half-period: on for 530 ms, off for 530 ms
const CURSOR_V_PAD   : u16   = 2;
const MAX_COMPLETIONS: usize = 4096; // max executables stored
const MAX_COMP_LEN   : usize = 64;   // max length of a single executable name
const MAX_HIST       : usize = 512;  // history entries kept in memory
const MAX_HIST_LINE  : usize = vim.MAX_INPUT; // max chars per history entry

// ── Module state ──────────────────────────────────────────────────────────────

const DrunState = struct {
    active:   bool = false,
    vim:      vim.VimState = .{},

    key_syms:        ?*xcb_key_symbols_t = null,
    cached_prompt_w: ?u16                = null,
    cached_mode_w:   [4]?u16             = .{ null, null, null, null },

    // ── PATH completion ───────────────────────────────────────────────────────
    comp_names: [(MAX_COMP_LEN + 1) * MAX_COMPLETIONS]u8 = undefined,
    comp_count: usize = 0,

    // Ghost text (the completion suffix shown dimmed after the cursor).
    ghost_buf: [MAX_COMP_LEN]u8 = undefined,
    ghost_len: usize            = 0,

    // timerfd used to drive cursor blink redraws (-1 = not open).
    blink_fd:      i32  = -1,
    blink_visible: bool = true,

    // ── Command history (newest at index 0) ───────────────────────────────────
    hist_entries: [(MAX_HIST_LINE + 1) * MAX_HIST]u8 = undefined,
    hist_count:   usize = 0,
    hist_loaded:  bool  = false,
};

var g: DrunState = .{};

// ── Public API ────────────────────────────────────────────────────────────────

pub fn isActive() bool { return g.active; }

/// Returns true when drun is active in insert mode, signalling that the bar
/// should schedule a periodic redraw so the cursor blink animation runs.
pub fn needsRedraw() bool { return g.active and g.vim.mode == .insert; }

/// Returns the blink timerfd (or -1 if not active / not supported).
/// Add this fd to the main poll set.  When it becomes readable, call
/// blinkTick() and then redraw the bar (e.g. bar.submitDrawAsync(wm)).
/// The fd is opened in activate() and closed in deactivate().
pub fn blinkFd() i32 { return g.blink_fd; }

/// Toggle cursor visibility.  Call this from the main event loop each time
/// the timerfd returned by blinkFd() becomes readable, then trigger a redraw:
///
///   if (drun.blinkFd() >= 0 and poll says fd is readable) {
///       drun.blinkTick();
///       bar.submitDrawAsync(wm);
///   }
pub fn blinkTick() void {
    if (g.blink_fd >= 0) {
        var buf: u64 = 0;
        _ = c.read(g.blink_fd, &buf, @sizeOf(u64));
        g.blink_visible = !g.blink_visible;
    }
}

pub fn init(conn: *xcb.xcb_connection_t) void {
    if (g.key_syms != null) return;
    g.key_syms = xcb_key_symbols_alloc(conn);
    if (g.key_syms == null)
        debug.warn("drun: xcb_key_symbols_alloc failed — key input will not work", .{});
}

pub fn deinit() void {
    if (g.key_syms) |ks| {
        xcb_key_symbols_free(ks);
        g.key_syms = null;
    }
}

pub fn toggle(wm: *defs.WM) void {
    if (g.active) deactivate(wm) else activate(wm);
}

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *defs.WM) bool {
    if (!g.active) return false;

    const syms = g.key_syms orelse return false;

    const shift_held = event.state & xcb.XCB_MOD_MASK_SHIFT   != 0;
    const ctrl_held  = event.state & xcb.XCB_MOD_MASK_CONTROL != 0;
    const col: c_int = if (shift_held) 1 else 0;
    const sym        = xcb_key_symbols_get_keysym(syms, event.detail, col);

    // ── Ctrl-modified keys ────────────────────────────────────────────────────
    if (ctrl_held) {
        const action = vim.handleCtrl(&g.vim, sym);
        handleAction(action, wm);
        return true;
    }

    // ── Tab: accept ghost completion ──────────────────────────────────────────
    if (sym == vim.XK_Tab and g.vim.mode == .insert) {
        if (g.ghost_len > 0 and g.vim.cursor == g.vim.len) {
            const n = @min(g.ghost_len, vim.MAX_INPUT - 1 - g.vim.len);
            if (n > 0) {
                vim.insertSlice(&g.vim, g.ghost_buf[0..n]);
                g.ghost_len = 0;
            }
        }
        g.blink_visible = true;
        return true;
    }

    // ── Dispatch to mode handler ──────────────────────────────────────────────
    const action = switch (g.vim.mode) {
        .insert  => vim.handleInsert(&g.vim, sym),
        .normal  => vim.handleNormal(&g.vim, sym),
        .visual  => vim.handleVisual(&g.vim, sym),
        .replace => vim.handleReplace(&g.vim, sym),
    };
    handleAction(action, wm);
    updateGhost();
    g.blink_visible = true;
    return true;
}

pub fn draw(
    dc:                  *drawing.DrawContext,
    config:              defs.BarConfig,
    height:              u16,
    start_x:             u16,
    width:               u16,
    conn:                *xcb.xcb_connection_t,
    focused_window:      ?u32,
    current_ws_wins:     []const u32,
    minimized:           []const u32,
    cached_title:        *std.ArrayList(u8),
    cached_title_window: *?u32,
    title_invalidated:   bool,
    allocator:           std.mem.Allocator,
) !u16 {
    if (!g.active) {
        return title.draw(
            dc, config, height, start_x, width,
            conn, focused_window, current_ws_wins, minimized,
            cached_title, cached_title_window, title_invalidated, allocator,
        );
    }
    return drawActive(dc, config, height, start_x, width);
}

// ── Action handling ───────────────────────────────────────────────────────────

fn handleAction(action: vim.Action, wm: *defs.WM) void {
    switch (action) {
        .none       => {},
        .deactivate => deactivate(wm),
        .spawn      => {
            const cmd = g.vim.buf[0..g.vim.len];
            if (cmd.len > 0) spawnCommand(cmd);
            deactivate(wm);
        },
    }
}

// ── Activate / deactivate ─────────────────────────────────────────────────────

fn activate(wm: *defs.WM) void {
    g.vim              = .{};  // reset all vim state to defaults
    g.ghost_len        = 0;
    // Load completions and history on first activation.
    if (g.comp_count == 0) loadCompletions();
    if (!g.hist_loaded) loadHistory();
    g.active        = true;
    g.blink_visible = true;

    // Open a timerfd that fires every CURSOR_BLINK_MS so the caret blinks
    // even when no keystrokes arrive.
    if (g.blink_fd == -1) {
        if (std.posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true })) |fd| {
            const sec:  u64 = CURSOR_BLINK_MS / 1000;
            const nsec: u64 = (CURSOR_BLINK_MS % 1000) * 1_000_000;
            const ts = std.os.linux.timespec{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
            const spec = std.os.linux.itimerspec{ .it_interval = ts, .it_value = ts };
            std.posix.timerfd_settime(fd, .{}, &spec, null) catch {};
            g.blink_fd = fd;
        } else |_| {}
    }

    const cookie = xcb.xcb_grab_keyboard(
        wm.conn, 0, wm.root, xcb.XCB_CURRENT_TIME,
        xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
    );
    xcb.xcb_discard_reply(wm.conn, cookie.sequence);
    _ = xcb.xcb_flush(wm.conn);
}

fn deactivate(wm: *defs.WM) void {
    g.active               = false;
    g.vim.in_dot_replay    = false;
    g.vim.recording_insert = false;
    vim.resetNormalSub(&g.vim);
    if (g.blink_fd >= 0) {
        _ = c.close(g.blink_fd);
        g.blink_fd = -1;
    }
    _ = xcb.xcb_ungrab_keyboard(wm.conn, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(wm.conn);
}

// ── PATH completion ──────────────────────────────────────────────────────────

/// Scan every directory in $PATH and collect executable names into the static
/// comp_names table.  Called once on first activation.
fn loadCompletions() void {
    g.comp_count = 0;
    const path_env_ptr = c.getenv("PATH") orelse return;
    const path_env = std.mem.span(path_env_ptr);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;

    var dir_it = std.mem.splitScalar(u8, path_env, ':');
    outer: while (dir_it.next()) |dir_path| {
        if (dir_path.len == 0 or dir_path.len >= dir_buf.len) continue;
        @memcpy(dir_buf[0..dir_path.len], dir_path);
        dir_buf[dir_path.len] = 0;

        const dirp = c.opendir(&dir_buf) orelse continue;
        defer _ = c.closedir(dirp);

        while (c.readdir(dirp)) |entry| {
            const d_name: [*:0]const u8 = @ptrCast(&entry.*.d_name);
            const name = std.mem.span(d_name);
            if (name.len == 0 or name.len > MAX_COMP_LEN) continue;
            if (name[0] == '.') continue;

            const dt = entry.*.d_type;
            if (dt != 0 and dt != c.DT_REG and dt != c.DT_LNK) continue;

            const slot = g.comp_count * (MAX_COMP_LEN + 1);
            @memcpy(g.comp_names[slot .. slot + name.len], name);
            g.comp_names[slot + name.len] = 0;
            g.comp_count += 1;
            if (g.comp_count >= MAX_COMPLETIONS) break :outer;
        }
    }

    // Sort for O(log n) binary search in updateGhost.
    const SLOT = MAX_COMP_LEN + 1;
    const entries = @as([*][SLOT]u8, @ptrCast(&g.comp_names))[0..g.comp_count];
    std.sort.pdq([SLOT]u8, entries, {}, struct {
        fn lt(_: void, a: [SLOT]u8, b: [SLOT]u8) bool {
            return std.mem.order(u8, std.mem.sliceTo(&a, 0), std.mem.sliceTo(&b, 0)) == .lt;
        }
    }.lt);
}

/// Binary search comp_names (which must be sorted) for an exact match.
fn compExistsExact(name: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = g.comp_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const slot = mid * (MAX_COMP_LEN + 1);
        const entry = std.mem.sliceTo(g.comp_names[slot .. slot + MAX_COMP_LEN + 1], 0);
        switch (std.mem.order(u8, entry, name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}

/// Binary search for the first comp_names entry >= prefix.
/// Used as a starting point for prefix scanning.
fn compLowerBound(prefix: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = g.comp_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const slot = mid * (MAX_COMP_LEN + 1);
        const entry = std.mem.sliceTo(g.comp_names[slot .. slot + MAX_COMP_LEN + 1], 0);
        if (std.mem.order(u8, entry, prefix) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Recompute the ghost-text suggestion based on the current buffer.
/// Priority: history (newest first) → any executable match.
/// Only operates in INSERT mode with cursor at end and no spaces typed.
fn updateGhost() void {
    g.ghost_len = 0;

    if (g.vim.mode != .insert) return;
    if (g.vim.len == 0 or g.vim.cursor != g.vim.len) return;
    if (std.mem.indexOfScalar(u8, g.vim.buf[0..g.vim.len], ' ') != null) return;

    const prefix = g.vim.buf[0..g.vim.len];

    // ── 1. History-based suggestion (newest first) ──────────────────────────
    var hi: usize = 0;
    while (hi < g.hist_count) : (hi += 1) {
        const hslot = hi * (MAX_HIST_LINE + 1);
        const entry = std.mem.sliceTo(g.hist_entries[hslot .. hslot + MAX_HIST_LINE + 1], 0);
        if (entry.len == 0) continue;

        const cmd_end = std.mem.indexOfScalar(u8, entry, ' ') orelse entry.len;
        const cmd_tok = entry[0..cmd_end];

        if (cmd_tok.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, cmd_tok, prefix)) continue;
        if (!compExistsExact(cmd_tok)) continue;

        const suffix = cmd_tok[prefix.len..];
        const n = @min(suffix.len, MAX_COMP_LEN);
        @memcpy(g.ghost_buf[0..n], suffix[0..n]);
        g.ghost_len = n;
        return;
    }

    // ── 2. Fallback: shortest executable that starts with prefix ────────────
    //    comp_names is sorted, so the first entry past the lower bound that
    //    starts with prefix and is longer than prefix IS the shortest match.
    var i: usize = compLowerBound(prefix);
    while (i < g.comp_count) : (i += 1) {
        const slot = i * (MAX_COMP_LEN + 1);
        const name = std.mem.sliceTo(g.comp_names[slot .. slot + MAX_COMP_LEN + 1], 0);
        if (!std.mem.startsWith(u8, name, prefix)) return; // past all prefix matches
        if (name.len <= prefix.len) continue;              // exact match, not a completion
        const suffix = name[prefix.len..];
        const n = @min(suffix.len, MAX_COMP_LEN);
        @memcpy(g.ghost_buf[0..n], suffix[0..n]);
        g.ghost_len = n;
        return;
    }
}

// ── History ──────────────────────────────────────────────────────────────────

/// Prepend `cmd` to the in-memory history (newest at index 0).
fn histPrepend(cmd: []const u8) void {
    if (cmd.len == 0 or cmd.len > MAX_HIST_LINE) return;

    const keep = @min(g.hist_count, MAX_HIST - 1);
    var i: usize = keep;
    while (i > 0) : (i -= 1) {
        const src = (i - 1) * (MAX_HIST_LINE + 1);
        const dst =  i      * (MAX_HIST_LINE + 1);
        @memcpy(g.hist_entries[dst .. dst + MAX_HIST_LINE + 1],
                g.hist_entries[src .. src + MAX_HIST_LINE + 1]);
    }
    @memcpy(g.hist_entries[0..cmd.len], cmd);
    g.hist_entries[cmd.len] = 0;
    if (g.hist_count < MAX_HIST) g.hist_count += 1;
}

/// Append `cmd` to drun's own history file (~/.local/share/drun/history).
fn histAppendToDrunFile(cmd: []const u8) void {
    if (cmd.len == 0) return;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    var dir_buf:  [512:0]u8 = undefined;
    var file_buf: [512:0]u8 = undefined;

    _ = std.fmt.bufPrintZ(&dir_buf,  "{s}/.local/share/drun",         .{home}) catch return;
    _ = std.fmt.bufPrintZ(&file_buf, "{s}/.local/share/drun/history",  .{home}) catch return;

    _ = c.mkdir(&dir_buf, 0o700);

    const fd = c.open(&file_buf, c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_int, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.write(fd, cmd.ptr, cmd.len);
    _ = c.write(fd, "\n", 1);
}

/// Parse one line from a shell history file into `out`, returning its length.
/// Returns 0 to skip the line.
/// Formats understood:
///   fish   : "- cmd: <command>"   (YAML block)
///   zsh    : ": <ts>:<elapsed>;<command>"  OR bare line
///   bash   : bare line (may have "#<timestamp>" markers which are skipped)
///   drun   : bare line
fn histParseLine(line: []const u8, out: []u8) usize {
    if (line.len == 0) return 0;

    var cmd = line;

    if (std.mem.startsWith(u8, cmd, "- cmd: ")) {
        cmd = cmd["- cmd: ".len..];
    } else if (cmd.len > 2 and cmd[0] == ':' and cmd[1] == ' ') {
        if (std.mem.indexOfScalar(u8, cmd, ';')) |semi| {
            cmd = cmd[semi + 1..];
        }
    } else if (cmd[0] == '#') {
        return 0;
    }

    cmd = std.mem.trim(u8, cmd, " \t\r");

    if (cmd.len == 0 or cmd.len > MAX_HIST_LINE) return 0;
    // cmd.len <= MAX_HIST_LINE and out.len == MAX_HIST_LINE, so @min is always cmd.len
    @memcpy(out[0..cmd.len], cmd);
    return cmd.len;
}

/// Load history from a file, processing lines in reverse so newest ends up at 0.
fn histLoadFile(fp: *c.FILE) void {
    const FBUF_SIZE = 256 * 1024;
    const fbuf: []u8 = blk: {
        const ptr = c.malloc(FBUF_SIZE) orelse return;
        break :blk @as([*]u8, @ptrCast(ptr))[0..FBUF_SIZE];
    };
    defer c.free(fbuf.ptr);

    const n_read = c.fread(fbuf.ptr, 1, FBUF_SIZE - 1, fp);
    if (n_read == 0) return;
    const text = fbuf[0..n_read];

    const MAX_LINES = MAX_HIST * 2;
    const line_starts: []usize = blk: {
        const ptr = c.malloc(@sizeOf(usize) * MAX_LINES) orelse return;
        break :blk @as([*]usize, @ptrCast(@alignCast(ptr)))[0..MAX_LINES];
    };
    defer c.free(line_starts.ptr);
    const line_ends: []usize = blk: {
        const ptr = c.malloc(@sizeOf(usize) * MAX_LINES) orelse return;
        break :blk @as([*]usize, @ptrCast(@alignCast(ptr)))[0..MAX_LINES];
    };
    defer c.free(line_ends.ptr);

    var n_lines: usize = 0;
    var pos: usize = 0;
    while (pos < text.len and n_lines < MAX_LINES) {
        const line_start = pos;
        while (pos < text.len and text[pos] != '\n') : (pos += 1) {}
        const line_end = pos;
        if (pos < text.len) pos += 1;
        line_starts[n_lines] = line_start;
        line_ends[n_lines]   = line_end;
        n_lines += 1;
    }

    var out_line: [MAX_HIST_LINE]u8 = undefined;
    var li: usize = n_lines;
    while (li > 0) {
        li -= 1;
        if (g.hist_count >= MAX_HIST) break;
        const line = text[line_starts[li]..line_ends[li]];
        const len = histParseLine(line, &out_line);
        if (len == 0) continue;
        // Skip if this command already exists anywhere in history (not just at [0]).
        var dup = false;
        var di: usize = 0;
        while (di < g.hist_count) : (di += 1) {
            const dslot = di * (MAX_HIST_LINE + 1);
            const prev  = std.mem.sliceTo(g.hist_entries[dslot .. dslot + MAX_HIST_LINE + 1], 0);
            if (std.mem.eql(u8, prev, out_line[0..len])) { dup = true; break; }
        }
        if (dup) continue;
        histPrepend(out_line[0..len]);
    }
}

/// Load history from drun → bash → zsh → fish (load order).
/// Because histPrepend() inserts at index 0, fish ends up with the highest
/// suggestion priority in updateGhost.
fn loadHistory() void {
    g.hist_loaded = true;

    var path_buf: [512]u8 = undefined;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    const tryOpen = struct {
        fn f(buf: []u8, comptime fmt: []const u8, args: anytype) ?*c.FILE {
            const s = std.fmt.bufPrint(buf[0..buf.len-1], fmt, args) catch return null;
            buf[s.len] = 0;
            return c.fopen(@ptrCast(buf.ptr), "r");
        }
    }.f;

    if (tryOpen(&path_buf, "{s}/.local/share/drun/history", .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
    if (tryOpen(&path_buf, "{s}/.bash_history", .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
    if (tryOpen(&path_buf, "{s}/.zsh_history", .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
    if (tryOpen(&path_buf, "{s}/.local/share/fish/fish_history", .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
}

// ── Spawn ─────────────────────────────────────────────────────────────────────

fn spawnCommand(cmd: []const u8) void {
    histPrepend(cmd);
    histAppendToDrunFile(cmd);

    // cmd.len <= vim.MAX_INPUT - 1 (enforced by insertChar), so buf always has room.
    var buf: [vim.MAX_INPUT]u8 = undefined;
    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = buf[0..cmd.len :0];

    const pid = c.fork();
    if (pid == 0) {
        const pid2 = c.fork();
        if (pid2 == 0) {
            _ = c.setsid();
            _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

/// Binary search: first byte offset where textWidth(text[0..offset]) >= target_px.
/// That is: the index of the first character that begins at or past `target_px`
/// from the start of the string.  Returns text.len if the whole string is narrower.
fn textOffsetAtPx(dc: *drawing.DrawContext, text: []const u8, target_px: u16) usize {
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (dc.textWidth(text[0..mid]) < target_px) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Return the longest prefix of `text` whose pixel width is ≤ max_px.
/// Fast path: returns the full slice when the text already fits.
fn textPrefixFit(dc: *drawing.DrawContext, text: []const u8, max_px: u16) []const u8 {
    if (dc.textWidth(text) <= max_px) return text; // common case: no clipping needed
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2; // round up to avoid infinite loop
        if (dc.textWidth(text[0..mid]) <= max_px) lo = mid else hi = mid - 1;
    }
    return text[0..lo];
}

/// Draw `text` with hard pixel clipping to [text_left_x, scroll_end_x).
///
/// `px` is the virtual pen position (scroll-space, may be negative).  It is
/// always advanced by the full text width whether or not anything is drawn —
/// callers rely on this to keep the pen position consistent.
///
/// Both edges are clipped without ellipsis:
///   Left  — characters whose right edges fall before text_left_x are skipped.
///   Right — characters that would extend past scroll_end_x are dropped.
///
/// This is the correct behaviour for pre-cursor text in a scrolling field: the
/// cursor must appear immediately after the last visible character with no "…".
inline fn drawSpan(
    dc:           *drawing.DrawContext,
    px:           *i32,
    text_left_x:  u16,
    scroll_end_x: u16,
    baseline:     u16,
    text:         []const u8,
    color:        anytype,
) !void {
    const w = dc.textWidth(text);
    defer px.* += @intCast(w);
    if (w == 0) return;

    const tl: i32 = text_left_x;
    const se: i32 = scroll_end_x;

    // Fully off-screen to the left or right — nothing to draw.
    if (px.* + @as(i32, w) <= tl or px.* >= se) return;

    // Skip the prefix that lies off-screen to the left.
    const start: usize = if (px.* < tl)
        textOffsetAtPx(dc, text, @intCast(tl - px.*))
    else
        0;

    const draw_x: u16 = @intCast(@max(px.*, tl));
    const available: u16 = @intCast(se - @as(i32, draw_x));

    // Clip the visible suffix to the available width on the right.
    const visible = textPrefixFit(dc, text[start..], available);
    if (visible.len > 0)
        try dc.drawText(draw_x, baseline, visible, color);
}

/// Render the active input UI.
///
/// Layout:
///
///   [ pad | scrollable: PROMPT | pre | CURSOR/SELECTION | post | MODE_LABEL | pad ]
///
/// The mode label is pinned to the right edge (does not scroll).
/// The scrollable region keeps the cursor in view.
fn drawActive(
    dc:      *drawing.DrawContext,
    config:  defs.BarConfig,
    height:  u16,
    start_x: u16,
    width:   u16,
) !u16 {
    const end_x  = start_x + width;
    const pad    = config.scaledSegmentPadding(height);
    const accent = config.getDrunPromptColor();
    const bg     = config.getDrunBg();
    const fg     = config.getDrunFg();
    const prompt = config.drun_prompt;

    dc.fillRect(start_x, 0, width, height, bg);

    const baseline    = dc.baselineY(height);
    const text_left_x = start_x + pad;
    const text_end_x  = end_x   -| pad;
    if (text_left_x >= text_end_x) return end_x;

    // ── Mode label (pinned right) ─────────────────────────────────────────────
    const mode_label = g.vim.mode.label();
    const mode_idx: usize = @intFromEnum(g.vim.mode);

    const mode_w: u16 = g.cached_mode_w[mode_idx] orelse blk: {
        const w = dc.textWidth(mode_label);
        g.cached_mode_w[mode_idx] = w;
        break :blk w;
    };

    if (mode_w > 0 and text_end_x >= mode_w) {
        const label_x = text_end_x - mode_w;
        if (label_x >= text_left_x)
            try dc.drawText(label_x, baseline, mode_label, accent);
    }

    const scroll_end_x: u16 = if (text_end_x >= mode_w) text_end_x - mode_w else text_left_x;
    if (text_left_x >= scroll_end_x) return end_x;

    const max_scroll_px: u16 = scroll_end_x - text_left_x;

    // ── Measure prompt ────────────────────────────────────────────────────────
    const prompt_w: u16 = g.cached_prompt_w orelse blk: {
        const w = dc.textWidth(prompt);
        g.cached_prompt_w = w;
        break :blk w;
    };

    // ── Compute scroll offset (keep cursor visible) ───────────────────────────
    //
    // In INSERT mode the cursor is a thin 2-px caret; the character it sits on
    // is NOT consumed, so post_text starts at cursor (not cursor+1) and the
    // caret_w used for layout is CURSOR_WIDTH.
    // In all other modes we keep the traditional full-character block model.
    const pre_cur_text = g.vim.buf[0..g.vim.cursor];
    const pre_w_cur    = dc.textWidth(pre_cur_text);

    const caret_w: u16 = if (g.vim.mode == .insert) CURSOR_WIDTH
                         else @max(
                             dc.textWidth(if (g.vim.cursor < g.vim.len) g.vim.buf[g.vim.cursor..g.vim.cursor+1] else " "),
                             MIN_CURSOR_PX);

    const post_text: []const u8 = if (g.vim.mode == .insert)
        g.vim.buf[g.vim.cursor..g.vim.len]
    else
        (if (g.vim.cursor < g.vim.len) g.vim.buf[g.vim.cursor + 1 .. g.vim.len] else "");

    var scroll_x: u16 = 0;
    const cursor_right = prompt_w + pre_w_cur + caret_w;
    if (cursor_right > max_scroll_px)
        scroll_x = cursor_right -| max_scroll_px +| caret_w;

    // ── Draw prompt ───────────────────────────────────────────────────────────
    var px: i32 = @as(i32, text_left_x) - @as(i32, scroll_x);
    try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, prompt, accent);

    // ── Mode-specific text rendering ──────────────────────────────────────────
    if (g.vim.mode == .visual) {
        // Visual mode: split buffer into pre-selection, selection, post-selection.
        const sel      = vim.visualRange(&g.vim);
        const sel_lo   = sel[0];
        const sel_hi   = sel[1];

        const pre_sel  = g.vim.buf[0..sel_lo];
        const sel_text = g.vim.buf[sel_lo..sel_hi];
        const post_sel = g.vim.buf[sel_hi..g.vim.len];

        const sel_w      = @max(dc.textWidth(sel_text), MIN_CURSOR_PX);

        if (pre_sel.len > 0)
            try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, pre_sel, fg);

        if (px + @as(i32, sel_w) > @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const vis_w: u16 = @intCast(@min(
                @as(i32, sel_w),
                @as(i32, scroll_end_x) - px,
            ));
            if (vis_w > 0) {
                dc.fillRect(draw_x, CURSOR_V_PAD, vis_w, height -| CURSOR_V_PAD * 2, accent);
                if (sel_text.len > 0)
                    try dc.drawText(draw_x, baseline, sel_text, bg);
            }
        }
        px += @intCast(sel_w);

        if (post_sel.len > 0 and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, post_sel, remaining, fg);
        }

    } else if (g.vim.mode == .insert) {
        // ── INSERT mode: blinking 2-px caret, text NOT consumed by cursor ────
        const pre_text = g.vim.buf[0..g.vim.cursor];

        if (pre_text.len > 0)
            try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, pre_text, fg);

        // Blinking caret sized to actual font height.
        const asc, const desc = dc.getMetrics();
        const font_h: u16    = @intCast(@max(0, @as(i32, asc) + @as(i32, desc)));
        const caret_top: u16 = (height -| font_h) / 2;
        const caret_h: u16   = @min(font_h, height);

        if (g.blink_visible and px >= @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
            dc.fillRect(@intCast(px), caret_top, CURSOR_WIDTH, caret_h, accent);
        }

        // Ghost text (only when cursor is at end).
        if (g.ghost_len > 0 and g.vim.cursor == g.vim.len and px < @as(i32, scroll_end_x)) {
            const ghost = g.ghost_buf[0..g.ghost_len];
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, ghost, remaining, accent);
        }

        // Text from cursor onwards.
        if (post_text.len > 0 and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, post_text, remaining, fg);
        }

    } else {
        // ── NORMAL / REPLACE: full-character block cursor ─────────────────────
        const pre_text = g.vim.buf[0..g.vim.cursor];
        const cur_text = if (g.vim.cursor < g.vim.len) g.vim.buf[g.vim.cursor .. g.vim.cursor + 1] else " ";
        const cur_w    = @max(dc.textWidth(cur_text), MIN_CURSOR_PX);

        if (pre_text.len > 0)
            try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, pre_text, fg);

        if (px + @as(i32, cur_w) > @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const vis_w: u16  = @intCast(@min(
                @as(i32, cur_w),
                @as(i32, scroll_end_x) - px,
            ));
            if (vis_w > 0) {
                dc.fillRect(draw_x, CURSOR_V_PAD, vis_w, height -| CURSOR_V_PAD * 2, accent);
                if (g.vim.cursor < g.vim.len)
                    try dc.drawText(draw_x, baseline, cur_text, bg);
            }
        }
        px += @intCast(cur_w);

        if (post_text.len > 0 and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, post_text, remaining, fg);
        }
    }

    return end_x;
}
