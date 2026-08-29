//! Spawn engine: detached command execution for keybind `exec` actions.
//!
//! Double-fork so the grandchild re-parents to init and the WM never
//! accumulates zombies. A single O_CLOEXEC pipe carries the outcome: success
//! closes its copy automatically; otherwise the intermediate child writes
//! tag_pid and the grandchild writes tag_failed only if execvp() fails; two
//! independently-scheduled writers, so messages can arrive in either order
//! (finishSpawn() handles both). EOF ends the conversation; entries resolve via
//! drainPendingSpawns() (every event batch) or reapPendingChildren() (SIGCHLD).

const std = @import("std");

// libc bindings for fork/exec/wait (no Zig stdlib wrappers exist for these low-level syscalls)
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

const core = @import("core");
const utils = @import("utils");
const debug = @import("debug");
const tracking = @import("tracking");
const window = @import("window");

/// Tags for the two possible messages written onto the spawn pipe. Sent as
/// a leading byte so the reader can tell them apart no matter which order
/// they arrive in (see finishSpawn()).
const tag_pid: u8 = 0;
const tag_failed: u8 = 1;

/// Byte length of a tag_pid message: the tag plus a raw c_int.
const pid_msg_len: usize = 1 + @sizeOf(c_int);

/// Grandchild: detaches from the session and execs the command.
/// On execvp failure, writes a tag_failed byte to pipe_write before exiting.
/// On success this function never returns far enough to write anything;
/// pipe_write's O_CLOEXEC copy closes itself as part of the exec.
fn execAsGrandchild(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    _ = c.setsid();
    _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
    const msg = [1]u8{tag_failed};
    _ = c.write(pipe_write, &msg, msg.len);
    std.process.exit(1);
}

/// Intermediate child: forks the grandchild, forwards its PID over the
/// spawn pipe tagged as tag_pid, then exits so the grandchild is
/// re-parented to init.
fn forkIntermediate(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    const grandchild_pid = c.fork();
    if (grandchild_pid < 0) {
        debug.err("Second fork failed", .{});
        std.process.exit(1);
    }
    if (grandchild_pid == 0) {
        // Grandchild: keep pipe_write open rather than closing it up front.
        // Its copy is O_CLOEXEC, so a successful execvp() closes it for us;
        // execAsGrandchild only writes to it explicitly if exec fails.
        execAsGrandchild(pipe_write, cmd_z);
    }

    const gp: c_int = grandchild_pid;
    var msg: [pid_msg_len]u8 = undefined;
    msg[0] = tag_pid;
    @memcpy(msg[1..], std.mem.asBytes(&gp));
    _ = c.write(pipe_write, &msg, msg.len);
    _ = c.close(pipe_write);
    std.process.exit(0);
}

// Pending spawn table
//
// 16 execs within the ~100 ms before /bin/sh execs would be inhuman speed.

const max_pending_spawns: usize = 16;

/// Commands shorter than this are null-terminated on the stack; longer ones
/// are copied to the heap so executeShellCommand stays allocation-free for
/// the common short-command case.
const stack_cmd_capacity: usize = 256;

/// Largest possible spawn-pipe conversation: a tag_pid message plus an
/// optional trailing (or leading) tag_failed byte.
const spawn_msg_max: usize = pid_msg_len + 1;

/// Lifecycle state for a single double-fork spawn.
const PendingSpawn = struct {
    pid: c_int, // PID of intermediate child; used for targeted waitpid.
    spawn_fd: c_int, // Read end of the spawn pipe (O_NONBLOCK). -1 once done.
    buf: [spawn_msg_max]u8 = undefined, // Accumulates bytes until the conversation ends.
    len: usize = 0, // Valid bytes accumulated in buf so far.
    spawn_ws: ?u8, // Target workspace for window.registerSpawn.
};

// std.BoundedArray was removed in the Zig 0.16 toolchain; utils.BoundedList
// is the shared fixed-buffer-plus-length stand-in used everywhere this shape
// is needed.
var g_pending: utils.BoundedList(PendingSpawn, max_pending_spawns) = .{};

/// Spawns `cmd` as a detached grandchild (double-fork). Returns immediately;
/// lifecycle is tracked in g_pending and resolved by drainPendingSpawns() /
/// reapPendingChildren() without blocking the event loop.
pub fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the workspace now; correct for sequence actions of the form
    // [exec, switch_workspace] where a later action mutates g_current.
    const spawn_ws = tracking.getCurrentWorkspace();

    var cmd_buf: [stack_cmd_capacity]u8 = undefined;
    var heap_cmd_z: ?[:0]const u8 = null;
    defer if (heap_cmd_z) |h| core.getState().alloc.free(h);
    const cmd_z: [*:0]const u8 = if (cmd.len < cmd_buf.len) blk: {
        @memcpy(cmd_buf[0..cmd.len], cmd);
        cmd_buf[cmd.len] = 0;
        break :blk @ptrCast(&cmd_buf[0]);
    } else blk: {
        const owned = try core.getState().alloc.dupeZ(u8, cmd);
        heap_cmd_z = owned;
        break :blk owned.ptr;
    };

    if (g_pending.len >= max_pending_spawns)
        debug.warn("spawn: pending table full, spawning '{s}' without workspace routing", .{cmd});

    const pipe_fds = utils.makePipe() catch {
        debug.err("pipe2() failed (spawn pipe): {s}", .{cmd});
        return error.PipeFailed;
    };

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        debug.err("First fork failed: {s}", .{cmd});
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = c.close(pipe_fds[0]);
        forkIntermediate(pipe_fds[1], cmd_z);
    }

    // Parent: close the write end so our read end eventually sees EOF.
    _ = c.close(pipe_fds[1]);

    // Cursor position for spawn-crossing suppression is queried synchronously
    // in window.handleMapRequest when the MapRequest arrives; MapRequest fires
    // once per window, so the round-trip isn't worth pipelining here.

    const queued = g_pending.append(.{
        .pid = pid,
        .spawn_fd = pipe_fds[0],
        .spawn_ws = spawn_ws,
    });
    if (!queued) {
        // Table full: close the read end we won't track; reap `pid`
        // synchronously; it exits almost instantly and isn't tracked (no zombie).
        _ = c.close(pipe_fds[0]);
        _ = c.waitpid(pid, null, 0);
    }
}

/// Drains pending spawn entries non-blockingly (every event batch and on
/// SIGCHLD), until EOF or a full buffer; a full buffer already holds both
/// possible messages, so EOF needn't be awaited. finishSpawn() classifies.
pub fn drainPendingSpawns() void {
    if (g_pending.len == 0) return;
    var i: usize = 0;
    while (i < g_pending.len) {
        const entry = &g_pending.slice()[i];

        if (entry.spawn_fd >= 0) {
            const n = c.read(entry.spawn_fd, &entry.buf[entry.len], entry.buf.len - entry.len);
            if (n > 0) {
                entry.len += @intCast(n);
                if (entry.len == entry.buf.len) {
                    // Buffer full: both possible messages have necessarily
                    // arrived already; no need to wait for EOF too.
                    _ = c.close(entry.spawn_fd);
                    entry.spawn_fd = -1;
                }
            } else if (n < 0 and std.posix.errno(n) == .AGAIN) {
                // Not ready yet; retry on the next call.
            } else {
                // EOF (n == 0) or a hard read error: conversation is over.
                _ = c.close(entry.spawn_fd);
                entry.spawn_fd = -1;
            }
        }

        if (entry.spawn_fd >= 0) {
            i += 1;
            continue;
        }

        finishSpawn(entry);
        g_pending.swapRemove(i);
    }
}

/// Classifies a fully-drained spawn-pipe conversation and, on success,
/// registers the spawn for workspace routing.
///
/// Both writes are under PIPE_BUF, so neither is torn or interleaved: a
/// tag_failed byte anywhere is a reliable failure signal in any arrival
/// order; an empty buffer means the second fork() never ran.
fn finishSpawn(entry: *PendingSpawn) void {
    const data = entry.buf[0..entry.len];

    var grandchild: c_int = -1;
    var failed = data.len == 0;

    var idx: usize = 0;
    while (idx < data.len) {
        switch (data[idx]) {
            tag_pid => {
                if (idx + pid_msg_len > data.len) {
                    failed = true;
                    break;
                }
                grandchild = std.mem.bytesToValue(c_int, data[idx + 1 ..][0..@sizeOf(c_int)]);
                idx += pid_msg_len;
            },
            tag_failed => {
                failed = true;
                idx += 1;
            },
            else => {
                failed = true;
                break;
            },
        }
    }

    if (!failed) {
        if (entry.spawn_ws) |ws| {
            const pid_u32: u32 = if (grandchild > 0) @intCast(grandchild) else 0;
            window.registerSpawn(core.WorkspaceId.fromIndex(ws), pid_u32);
        }
    }
}

/// Reaps zombie intermediate children without blocking. Called from the
/// SIGCHLD handler; the spawn-pipe drain stays in signals.zig so it doesn't
/// run twice per SIGCHLD.
pub fn reapPendingChildren() void {
    for (g_pending.slice()) |*entry| {
        if (entry.pid > 0 and c.waitpid(entry.pid, null, c.WNOHANG) > 0)
            entry.pid = -1;
    }
}
