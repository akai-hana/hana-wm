//! The prompt's completion provider seam: the sorted `$PATH`
//! executable table, the ghost-completion suffix, and the
//! run-history ring (newest first, persisted append-only under
//! `$HOME`). State lives in this module's global so no allocation
//! or partial-OOM bookkeeping exists; the package core
//! (`prompt.zig`) owns activation and key routing and reaches the
//! tables through the accessors below.

const std = @import("std");

const paths = @import("paths");
const editor = @import("editor");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
});

const max_completions: usize = 1024;
const max_completion_len: usize = 64;
const max_history: usize = 128;
const max_history_line: usize = editor.default_max_input;
// History-file path scratch size (HOME + suffix); shared by the append and
// load paths so the two buffers can't drift apart.
const history_path_buf_len = 512;

/// drun history path relative to $HOME; shared by the append and the
/// load-order list so both spell the same file.
const run_history_suffix = ".local/share/drun/history";

const CompState = struct {
    // Completion table: `max_completions` fixed 65-byte zero-terminated slots,
    // embedded in the global so no allocation/partial-OOM bookkeeping exists.
    // `comp_count` is the live length; slots beyond it are stale.
    comp_names: [max_completions][max_completion_len + 1:0]u8 = .{.{0} ** (max_completion_len + 1)} ** max_completions,
    comp_count: usize = 0,

    // Ghost text: the completion suffix shown dimmed after the cursor.
    ghost_buf: [max_completion_len:0]u8 = .{0} ** max_completion_len,
    ghost_len: usize = 0,

    hist_entries: [max_history][max_history_line + 1:0]u8 = .{.{0} ** (max_history_line + 1)} ** max_history,
    hist_count: usize = 0,
    hist_head: usize = 0,
    is_hist_loaded: bool = false,
    // Tracks whether the $PATH scan has run at all, separate from comp_count:
    // a legitimately empty result leaves comp_count at 0, and gating on that
    // would re-scan $PATH on every activation.
    is_completions_loaded: bool = false,
};

var g: CompState = .{};

/// The current ghost-completion suffix (empty when none). The slice
/// aliases this module's storage and is valid until the next
/// completion-table or history rebuild -- the same lifetime the
/// caller's buffer already had.
pub fn ghost() []const u8 {
    return g.ghost_buf[0..g.ghost_len];
}

/// Clears the ghost suffix (prompt activation resets it).
pub fn clearGhost() void {
    g.ghost_len = 0;
}

/// True once the `$PATH` scan has been ATTEMPTED (a legitimately
/// empty result still counts), so activation never re-scans.
pub fn isCompletionsLoaded() bool {
    return g.is_completions_loaded;
}

/// True once the history files have been loaded, so activation
/// never re-reads them.
pub fn isHistLoaded() bool {
    return g.is_hist_loaded;
}

/// Scan every directory in $PATH and collect executable names into the static
/// completion table.  Called once on first activation.
pub fn loadCompletions() void {
    g.comp_count = 0;
    // Mark attempted up front: a missing $PATH or an empty result must not
    // re-trigger the scan on the next activation.
    g.is_completions_loaded = true;
    const path_env_ptr = c.getenv("PATH") orelse return;
    const path_env = std.mem.span(path_env_ptr);

    var dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;

    var dir_it = paths.dirIterator(path_env);
    outer: while (dir_it.next()) |dir_path| {
        if (dir_path.len >= dir_buf.len) continue;
        @memcpy(dir_buf[0..dir_path.len], dir_path);
        dir_buf[dir_path.len] = 0;

        const dirp = c.opendir(&dir_buf) orelse continue;
        defer _ = c.closedir(dirp);

        while (c.readdir(dirp)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            // d_type 0 (DT_UNKNOWN on filesystems with no type) counts as a
            // candidate: it rules out only "obviously not a plain file"; the
            // X_OK probe inside isRunnableFile is the real test.
            const dt = entry.*.d_type;
            if (dt != 0 and dt != c.DT_REG and dt != c.DT_LNK) continue;
            if (!isRunnableFile(dir_path, name)) continue;
            if (offerCompletion(name)) break :outer;
        }
    }

    // Sort for O(log n) binary search in updateGhost.
    const entries = g.comp_names[0..g.comp_count];
    std.sort.pdq([max_completion_len + 1:0]u8, entries, {}, struct {
        fn lt(_: void, a: [max_completion_len + 1:0]u8, b: [max_completion_len + 1:0]u8) bool {
            return std.mem.order(u8, std.mem.sliceTo(&a, 0), std.mem.sliceTo(&b, 0)) == .lt;
        }
    }.lt);
}

/// True when `name` under `dir_path` is executable, so it can be offered as a
/// command completion.  Filters empty/oversized/dot-prefixed names and probes
/// the executable bit on the joined path.
fn isRunnableFile(dir_path: []const u8, name: []const u8) bool {
    if (name.len == 0 or name.len > max_completion_len) return false;
    if (name[0] == '.') return false;

    var full_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    return paths.exeInDir(&full_path_buf, dir_path, name);
}

/// Stores `name` into the next completion slot.  Returns true when the table is
/// full and the $PATH scan should stop.
fn offerCompletion(name: []const u8) bool {
    const slot = &g.comp_names[g.comp_count];
    @memcpy(slot[0..name.len], name);
    slot[name.len] = 0;
    g.comp_count += 1;
    return g.comp_count >= max_completions;
}

/// Binary searches the sorted completion table for the first entry >= `prefix`.
/// Returns the insertion index (0..comp_count); existence is an eql() at the
/// returned index, inlined at the call site.
fn compLowerBound(prefix: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = g.comp_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, compName(mid), prefix) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn compName(i: usize) []const u8 {
    return std.mem.sliceTo(&g.comp_names[i], 0);
}

fn histEntry(i: usize) []const u8 {
    return std.mem.sliceTo(&g.hist_entries[(g.hist_head + i) % max_history], 0);
}

/// Clamps `suffix` into g.ghost_buf/g.ghost_len.  Shared by both updateGhost
/// branches, which only differ in how they find the match.
inline fn setGhost(suffix: []const u8) void {
    const n = @min(suffix.len, max_completion_len);
    @memcpy(g.ghost_buf[0..n], suffix[0..n]);
    g.ghost_len = n;
}

/// The word under the cursor: the buffer up to the cursor, back to the last
/// space, as {token, byte offset of the token's first byte}.
///
/// (27.3) The old code took the first space in the WHOLE buffer and bailed if
/// one existed, so nothing past the first argument could ever be completed --
/// "git ch" got no ghost even when "checkout" was in the table. Word-at-cursor
/// is what the completion sources actually need: they match a token, not a
/// prefix of a line, and the buffer they see is exactly the token.
///
/// `cursor` is passed rather than read so the split is a pure function of
/// (buffer, cursor) and testable without the module's global state.
pub const WordAtCursor = struct {
    token: []const u8,
    /// Byte offset of `token` within the buffer it came from.
    start: usize,
};

pub fn wordAtCursor(buf: []const u8, cursor: usize) WordAtCursor {
    const upto = buf[0..@min(cursor, buf.len)];
    const start = if (std.mem.lastIndexOfScalar(u8, upto, ' ')) |i| i + 1 else 0;
    return .{ .token = upto[start..], .start = start };
}

/// Where a candidate match comes from. (27.3)
///
/// The two sources need genuinely different lookups -- one walks a ring newest
/// first, the other binary-searches a sorted table -- but they are the same
/// QUESTION ("what extends this token?"), and expressing that as a union keeps
/// the priority order in one place instead of spread across two loops that
/// have to be kept in sync by hand.
pub const CompletionSource = enum {
    /// The history ring, newest entry first: what the user actually ran
    /// before, which outranks anything merely installed.
    history,
    /// The sorted executable table, lower-bounded to the first entry >=
    /// `token`. The first entry past the bound that starts with the token and
    /// is longer IS the shortest match, since the table is sorted.
    executables,
};

/// Ghost for `token` from `source`, or null when that source has no
/// completion. The suffix only: `setGhost` receives text to APPEND to what is
/// already typed.
///
/// Returned slices point into the module's own storage (the ring and the
/// comp table), so they are valid until the next completion-table or history
/// rebuild -- the same lifetime the caller's buffer already had.
fn completeToken(token: []const u8, source: CompletionSource) ?[]const u8 {
    if (token.len == 0) return null;
    return switch (source) {
        .history => completeFromHistory(token),
        .executables => completeFromExecutables(token),
    };
}

fn completeFromHistory(token: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < g.hist_count) : (i += 1) {
        const entry = histEntry(i);
        if (entry.len == 0) continue;
        // Cheap reject on the first byte: history is a ring of up to
        // max_history entries and nearly all fail here.
        if (entry[0] != token[0]) continue;
        // Match the token under the CURSOR, not the entry's first word. This is
        // the second half of (27.3): a multi-word history line completes its
        // last-word continuation, so "git ch" can complete from "git checkout".
        const target = wordAtCursor(entry, entry.len).token;
        if (target.len <= token.len) continue;
        if (!std.mem.startsWith(u8, target, token)) continue;
        // The tail is the completion, but only up to the next space: completing
        // the whole rest of the line would ghost in a trailing argument too.
        const rest = target[token.len..];
        const tail = if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| rest[0..sp] else rest;
        if (tail.len == 0) continue;
        return tail;
    }
    return null;
}

fn completeFromExecutables(token: []const u8) ?[]const u8 {
    var i: usize = compLowerBound(token);
    while (i < g.comp_count) : (i += 1) {
        const name = compName(i);
        if (!std.mem.startsWith(u8, name, token)) return null; // past all matches
        if (name.len <= token.len) continue; // exact match, not a completion
        return name[token.len..];
    }
    return null;
}

/// Recompute the ghost-text suggestion based on the current buffer.
/// Priority: history (newest first) -> any executable match.
/// INSERT mode only, and only with the cursor at the end of the buffer: a
/// ghost is a suggestion about text that is about to be appended, which a
/// mid-buffer cursor has no room for.
///
/// `vim_state` is the package core's editor state (the one the key handlers
/// drive); this module keeps no second copy.
pub fn updateGhost(vim_state: *const editor.EditorState) void {
    g.ghost_len = 0;

    if (vim_state.mode != .insert or vim_state.len == 0 or
        vim_state.cursor != vim_state.len) return;

    // The token under the cursor, so an ARGUMENT completes (27.3). The old
    // shape bailed on any space in the buffer, which made every second word
    // un-completable; the cost of the scan is nil because the buffer is at most
    // `max_input` (256) bytes and every candidate lookup below reads it anyway.
    const word = wordAtCursor(vim_state.buf[0..vim_state.len], vim_state.len);
    if (word.token.len == 0) return;

    for ([_]CompletionSource{ .history, .executables }) |source| {
        if (completeToken(word.token, source)) |suffix| {
            setGhost(suffix);
            return;
        }
    }
}

/// Prepend `cmd` to the in-memory history ring (newest at index 0), shifting
/// entries right by one slot.
/// Silently no-ops when cmd is empty or exceeds max_history_line.
fn histPrepend(cmd: []const u8) void {
    if (cmd.len == 0 or cmd.len > max_history_line) return;
    // Skip consecutive duplicates (shell convention): when the newest entry
    // already equals this command, re-running it must not stack the ring.
    if (g.hist_count > 0 and std.mem.eql(u8, histEntry(0), cmd)) return;

    g.hist_head = if (g.hist_head == 0) max_history - 1 else g.hist_head - 1;
    const slot = &g.hist_entries[g.hist_head];
    @memcpy(slot[0..cmd.len], cmd);
    slot[cmd.len] = 0;
    if (g.hist_count < max_history) g.hist_count += 1;
}

fn histAppendToFile(cmd: []const u8) void {
    if (cmd.len == 0) return;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    var path_buf: [history_path_buf_len:0]u8 = undefined;
    const file_path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}/{s}",
        .{ home, run_history_suffix },
    ) catch return;

    const last_sep = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse return;
    path_buf[last_sep] = 0;
    _ = c.mkdir(@ptrCast(&path_buf), 0o700);
    path_buf[last_sep] = '/';

    const fd = c.open(@ptrCast(&path_buf), c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_int, @intCast(paths.restricted_file_mode)));
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.write(fd, cmd.ptr, cmd.len);
    _ = c.write(fd, "\n", 1);
}

/// Parse one line from a shell history file into `out`, returning its length
/// (0 to skip).  Understands fish `"- cmd: ..."`, zsh `": <ts>:<elapsed>;..."` or
/// bare lines, and bash/run bare lines (`#` timestamp markers skipped).
fn histParseLine(line: []const u8, out: []u8) usize {
    if (line.len == 0) return 0;

    var cmd = line;

    if (std.mem.startsWith(u8, cmd, "- cmd: ")) {
        cmd = cmd["- cmd: ".len..];
    } else if (cmd.len > 2 and cmd[0] == ':' and cmd[1] == ' ') {
        if (std.mem.indexOfScalar(u8, cmd, ';')) |semi| {
            cmd = cmd[semi + 1 ..];
        }
    } else if (cmd[0] == '#') {
        return 0;
    }

    cmd = std.mem.trim(u8, cmd, " \t\r");

    if (cmd.len == 0 or cmd.len > max_history_line) return 0;
    @memcpy(out[0..cmd.len], cmd);
    return cmd.len;
}

/// Fixed byte window read from a history file's tail: an overgrown
/// file must not push its newest entries out of reach of one bounded read.
const hist_read_window: usize = 256 * 1024 - 1;

/// Load history from `path` into the in-memory ring, processing lines in
/// reverse so the newest entry ends up at index 0.
fn histLoadFile(allocator: std.mem.Allocator, path: []const u8) void {
    const io = std.Options.debug_io;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);

    // History semantics want the NEWEST entries, which live at the file's
    // tail. Position the read window at EOF - window so an overgrown file
    // can't push recent entries out of the fixed read; a partial
    // line at the window head is dropped below.
    const fsize: u64 = if (file.stat(io) catch null) |st| st.size else 0;
    const read_off: u64 = if (fsize > hist_read_window) fsize - hist_read_window else 0;

    const file_buf = allocator.alloc(u8, hist_read_window) catch return;
    defer allocator.free(file_buf);
    const n_read = file.readPositionalAll(io, file_buf, read_off) catch return;
    if (n_read == 0) return;
    var text = file_buf[0..n_read];
    if (read_off > 0) {
        // Drop the cut-mid-line fragment at the window start; its real
        // content lives in the unread region before the window.
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return;
        text = text[nl + 1 ..];
    }

    // Only the trailing max_lines lines are eligible: history consumers walk
    // them back-to-front for newest-first priority, so dropping the head of
    // an overgrown file keeps the freshest entries visible once it outgrows
    // the window. The ranges live in a ring indexed modulo max_lines, so the
    // scan only ever remembers the LAST max_lines lines.
    const max_lines = max_history * 2;
    var line_starts: [max_lines]usize = undefined;
    var line_ends: [max_lines]usize = undefined;
    var total: usize = 0;

    var pos: usize = 0;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        line_starts[total % max_lines] = pos;
        line_ends[total % max_lines] = end;
        total += 1;
        pos = end + 1;
    }

    var out_line: [max_history_line]u8 = undefined;

    // Build a hash set of already-loaded entries so duplicate detection is O(1)
    // instead of O(n^2).  Pre-populate with any entries that were prepended by
    // earlier histLoadFile calls in the same session.
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(allocator);
    for (0..g.hist_count) |di| {
        seen.put(allocator, std.hash.Wyhash.hash(0, histEntry(di)), {}) catch {};
    }

    // Walk the kept lines back-to-front so the newest entry ends up at index 0.
    var li: usize = 0;
    while (li < @min(total, max_lines)) : (li += 1) {
        if (g.hist_count >= max_history) break;
        const ri = (total - 1 - li) % max_lines;
        const line = text[line_starts[ri]..line_ends[ri]];
        const len = histParseLine(line, &out_line);
        if (len == 0) continue;
        const h = std.hash.Wyhash.hash(0, out_line[0..len]);
        if (seen.contains(h)) continue;
        histPrepend(out_line[0..len]);
        seen.put(allocator, h, {}) catch {};
    }
}

/// Load history from run -> bash -> zsh -> fish (load order).
/// Because `histPrepend()` inserts at index 0, fish ends up with the highest
/// suggestion priority in `updateGhost`.
pub fn loadHistory(allocator: std.mem.Allocator) void {
    g.is_hist_loaded = true;
    var path_buf: [history_path_buf_len]u8 = undefined;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    const history_suffixes = [_][]const u8{
        run_history_suffix,
        ".bash_history",
        ".zsh_history",
        ".local/share/fish/fish_history",
    };
    for (history_suffixes) |suffix| {
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, suffix }) catch continue;
        histLoadFile(allocator, path);
    }
}

pub fn spawnCommand(cmd: []const u8) void {
    histPrepend(cmd);
    histAppendToFile(cmd);

    // cmd.len <= default_max_input - 1 (enforced by the vim buffer
    // insert clamp), so buf always has room for the null terminator.
    var buf: [editor.default_max_input]u8 = undefined;
    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = buf[0..cmd.len :0];

    const pid = c.fork();
    if (pid == 0) {
        // Double-fork detaches the grandchild from this process so the bar
        // does not wait on it when it exits.
        const pid2 = c.fork();
        if (pid2 == 0) {
            _ = c.setsid();
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null };
            _ = c.execvp("/bin/sh", @ptrCast(&argv));
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
}
