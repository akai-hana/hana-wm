//! Restart module identity tests (F-29). The binary-change decision surface
//! is xcb-free, so these run headless. `execNext` is deliberately not called
//! (it would replace the process image of the test runner).
//!
//! restart.init takes ownership of the supplied path for the REST of the
//! process (its `exec_path_z` is deliberately process-lifetime and never
//! freed), so every dupe here is allocated from page_allocator: it stays
//! valid across tests and is untracked by the per-test leak check.
//!
//! S-F note: the third test pins the documented degrade-to-unchanged
//! contract for a missing exec path. core/restart.zig:75 currently checks
//! `std.posix.errno(rc)` which, for libc-linked builds (this test binary and
//! the production executable), is std.c.errno: it reads the C thread-local
//! errno instead of the statx(2) return value, so a failed statx leaves the
//! previous errno untouched (usually 0) and statIdentity returns a fabricated
//! all-zero identity instead of null. The syscall did return -ENOENT (rc=-2,
//! strace-confirmed); the fix is `std.os.linux.errno(rc)`, which decodes the
//! syscall rc. Test 3 stays red until that one-liner lands in src/core.

const std = @import("std");
const testing = std.testing;

const restart = @import("restart");
const scratch = @import("scratch");

const page_alloc = std.heap.page_allocator;

test "F29: init(null) sees an unchanged running image" {
    // No override: the exec path resolves to /proc/self/exe, which is the
    // very file this process is running from -- the identity cannot differ.
    restart.init(page_alloc, null);

    try testing.expect(!restart.binaryChanged());
    // And the resolved self path is non-empty.
    try testing.expect(restart.selfPath() != null);
}

test "F29: a different file at the exec path reports a change" {
    const other_path = try scratch.scratchPath(page_alloc, "hana-restart-", "other");
    try scratch.writeScratchFile(other_path, "a file that is not the running image");
    defer scratch.cleanupScratch(other_path);

    restart.init(page_alloc, other_path);
    try testing.expect(restart.binaryChanged());
}

test "F29: an unreadable exec path degrades to unchanged" {
    // A missing path must never abort a reload -- it just means no re-exec.
    // (Stats the real path via the same statx the module uses; see the S-F
    // note above: until core/restart.zig checks the syscall rc, this fails
    // because the stale C errno reads as SUCCESS.)
    const missing_path = try scratch.scratchPath(page_alloc, "hana-restart-", "missing");
    // Deliberately never wrote the file.
    restart.init(page_alloc, missing_path);
    try testing.expect(!restart.binaryChanged());
}
