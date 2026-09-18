//! FNV-1a (64-bit) in its own file so the generated glue root has to resolve a
//! relative `@import` from the user's `c_api.zig`. Nothing here allocates, uses
//! libc, or can panic.

/// Starting state of an FNV-1a-64 hash.
pub const offset_basis: u64 = 0xcbf29ce484222325;

/// The FNV-1a-64 prime.
pub const prime: u64 = 0x00000100000001b3;

/// Mix `bytes` into `state` and return the new state. `bytes.len == 0` returns
/// `state` unchanged. Multiplication wraps, so this can never panic.
pub fn mix(state: u64, bytes: []const u8) u64 {
    var h = state;
    for (bytes) |b| {
        h ^= b;
        h = h *% prime;
    }
    return h;
}

/// Big-endian byte order of `state`, which is what `zcounter_digest` writes.
pub fn toBigEndian(state: u64) [8]u8 {
    var out: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast((7 - i) * 8);
        out[i] = @truncate(state >> shift);
    }
    return out;
}

const std = @import("std");
const testing = std.testing;

test "empty input leaves the state alone" {
    try testing.expectEqual(offset_basis, mix(offset_basis, ""));
}

test "known FNV-1a-64 vector" {
    // FNV-1a-64("a") == 0xaf63dc4c8601ec8c
    try testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), mix(offset_basis, "a"));
    // FNV-1a-64("foobar") == 0x85944171f73967e8
    try testing.expectEqual(@as(u64, 0x85944171f73967e8), mix(offset_basis, "foobar"));
}

test "big-endian encoding" {
    try testing.expectEqualSlices(
        u8,
        &.{ 0xaf, 0x63, 0xdc, 0x4c, 0x86, 0x01, 0xec, 0x8c },
        &toBigEndian(0xaf63dc4c8601ec8c),
    );
}

test "mixing is incremental" {
    const one = mix(offset_basis, "foobar");
    const two = mix(mix(offset_basis, "foo"), "bar");
    try testing.expectEqual(one, two);
}
