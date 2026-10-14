//! The spawn pipe's success/failure rule, pinned without forking anything.
//!
//! (4.12) exists because the rule was inverted and nothing noticed. The bug was
//! only visible by reading the predicate against its own comment, so the
//! comment is not evidence; these are.

const std = @import("std");
const testing = std.testing;

const spawn = @import("spawn");

test "a clean EOF is success" {
    // A successful execvp closes the O_CLOEXEC write end, so the parent reads
    // zero bytes. Zero bytes is the ONLY success signal, which is why the
    // classifier is a length test and not a tag comparison.
    try testing.expect(!spawn.conversationFailed(""));
}

test "the real tag_failed byte is failure" {
    // The case the old predicate got backwards: this byte is the failure
    // signal, and the old code compared it to itself, concluded it was not
    // tag_failed, and registered a spawn that had never exec'd.
    try testing.expect(spawn.conversationFailed(&[_]u8{spawn.tag_failed}));
}

test "a byte that is NOT the tag is still failure, not success" {
    // No other byte is ever sent, so this is the protocol-violation case. The
    // old predicate treated it as the failure and the real tag as success --
    // exactly backwards. Either way the answer is failure: crediting an
    // unrecognized message as a launch would route focus to nothing.
    try testing.expect(spawn.conversationFailed(&[_]u8{0}));
    try testing.expect(spawn.conversationFailed(&[_]u8{0xff}));
}

test "a multi-byte tail never reads as success" {
    // `buf` is one byte today, so this is unreachable through the real
    // conversation. It is asserted anyway because the rule is "any bytes mean
    // failure": a future change that enlarges `buf` must not reintroduce a
    // pattern-match that could let a longer buffer slip through as success.
    try testing.expect(spawn.conversationFailed(&[_]u8{ 1, 0 }));
    try testing.expect(spawn.conversationFailed(&[_]u8{ 0, 1 }));
    try testing.expect(spawn.conversationFailed(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }));
}

test "the fixtures above use the real wire tag" {
    // Guards the byte-level cases above against a silent protocol change: the
    // child writes `tag_failed`, and the hand-typed `1` in them is only failure
    // BECAUSE that is the tag byte. Pin the value itself -- the predicate call
    // was byte-identical to the case above and proved nothing new.
    try testing.expectEqual(@as(u8, 1), spawn.tag_failed);
}
