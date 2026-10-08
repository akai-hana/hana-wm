//! Per-test temp files, built on `std.testing.tmpDir`. (28.5)
//!
//! This replaces a hand-rolled scratch directory that had three separate
//! problems, all of which the standard helper already handles:
//!
//!   - Uniqueness was argued from a PRNG seeded by the realtime clock and the
//!     pid. `std.testing.tmpDir` is per-CALL and Zig guarantees each gets its
//!     own directory, so the clock argument was load-bearing for no reason.
//!   - Paths were formatted through `std.heap.page_allocator` while the test
//!     ran on `std.testing.allocator`. Everything page-allocated is invisible to
//!     the leak checker, so a genuine leak in the surrounding test could not be
//!     reported -- the file under test was hiding the failure it was written to
//!     catch.
//!   - `cleanupScratch` set `scratch_dir = null` whether or not
//!     `deleteDirAbsolute` succeeded. On failure the next call re-created a NEW
//!     directory and the old one was orphaned on disk, still holding its files.
//!     `TmpDir.cleanup` has no such branch to get wrong.

const std = @import("std");

const io = std.Options.debug_io;

/// One temp file that lives exactly as long as the test holding it.
pub const TmpFile = struct {
    tmp: std.testing.TmpDir,
    /// Backing storage for `path`. Lives inline because `loadConfig` and
    /// friends take a `[]const u8`, so a self-referential slice into a heap
    /// allocation would need its own lifetime dance.
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    /// True once `write` succeeded, so `deinit` never tries to remove a file
    /// that was never created.
    written: bool = false,

    /// Creates a temp directory and returns the absolute path of `name` inside
    /// it. The file is NOT created yet.
    pub fn init(name: []const u8) !TmpFile {
        var self: TmpFile = .{
            .tmp = std.testing.tmpDir(.{}),
        };
        errdefer self.tmp.cleanup();

        // The production config/handoff entry points take absolute paths, so
        // realPath is required rather than optional -- the point of the tmp dir
        // is the unique parent, not a relative name.
        // realPath fills the buffer and returns its LENGTH, not a slice.
        self.path_len = try self.tmp.dir.realPath(io, &self.path_buf);
        const written = try std.fmt.bufPrint(self.path_buf[self.path_len..], "/{s}", .{name});
        self.path_len += written.len;
        return self;
    }

    /// The absolute path, for handing to a production entry point.
    pub fn path(self: *const TmpFile) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Creates the file with `bytes` as its contents.
    pub fn write(self: *TmpFile, bytes: []const u8) !void {
        const f = try self.tmp.dir.createFile(io, self.basename(), .{});
        defer f.close(io);
        try f.writePositionalAll(io, bytes, 0);
        self.written = true;
    }

    /// The file's name within the temp dir (what `createFile` wants).
    pub fn basename(self: *const TmpFile) []const u8 {
        const p = self.path();
        return p[std.mem.lastIndexOfScalar(u8, p, '/').? + 1 ..];
    }

    pub fn deinit(self: *TmpFile) void {
        // TmpDir.cleanup removes the whole directory, so the file needs no
        // separate unlink -- and that is the fix for the orphan case: there is
        // no path where a failed removal silently forgets where the file was.
        self.tmp.cleanup();
    }
};

/// Loads a TOML string through the full production pipeline
/// (parse -> buildConfigFromDoc), like a real config file would be. The one
/// home of the scratch-config suffix policy: every file gets a `.toml`
/// extension, so a test path reads like the config it stands in for.
pub fn loadToml(alloc: std.mem.Allocator, name: []const u8, content: []const u8) !@import("types").Config {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const with_ext = std.fmt.bufPrint(&name_buf, "{s}.toml", .{name}) catch return error.NameTooLong;
    var f = try TmpFile.init(with_ext);
    defer f.deinit();
    try f.write(content);
    return try @import("config").loadConfig(alloc, f.path());
}
