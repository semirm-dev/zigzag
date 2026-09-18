//! zcounter — the end-to-end example library for zbridge.
//!
//! It is deliberately tiny but exercises every shape the v1 allowlist supports:
//! an opaque handle with a constructor/destructor pair (decision D7 finds them
//! by name), a free function of scalars, a `[*]const u8` + `usize` input pair,
//! a `[*:0]const u8` C string, a `[*]u8` + `usize` output pair, and a `*u64`
//! out-parameter.
//!
//! Constraints this file lives under (decision D4):
//!
//!   * **No libc.** The default build is `-dynamic` with no libc, so there is
//!     no allocator here at all: counters come from a fixed static pool that is
//!     claimed with an atomic compare-exchange.
//!   * **No reachable panic.** Every exported function range-checks its inputs,
//!     validates the handle before touching it, tolerates a zero length and a
//!     null pointer, and uses wrapping arithmetic.
//!   * **No `std.debug.print`**, and nothing that would pull in a libc symbol.

const std = @import("std");
const digest = @import("digest.zig");

/// An opaque running counter: an FNV-1a-64 digest over every byte fed to it
/// plus the total number of bytes seen. Create one with `zcounter_new` and
/// release it with `zcounter_destroy`.
pub const Counter = opaque {};

/// Number of counters that can be live at once. A fixed pool keeps the library
/// allocator-free and therefore libc-free.
const pool_size = 64;

const Slot = struct {
    /// Claimed by `zcounter_new` with a compare-exchange; cleared by
    /// `zcounter_destroy`. The only cross-thread state in the library.
    in_use: std.atomic.Value(bool) = .{ .raw = false },
    state: u64 = digest.offset_basis,
    total: u64 = 0,
};

var pool: [pool_size]Slot = @splat(.{});

/// Resolve a caller-supplied handle back to a live slot.
///
/// This is the one place the library trusts a pointer from the other side of
/// the FFI boundary, so it is paranoid on purpose: the address must lie inside
/// `pool`, be exactly on a slot boundary, and name a slot that is currently in
/// use. Anything else — a null pointer, a stale handle, a pointer that never
/// came from this library — yields null and the caller reports failure instead
/// of corrupting memory.
fn slotOf(c: ?*Counter) ?*Slot {
    const addr = @intFromPtr(c orelse return null);
    const base = @intFromPtr(&pool[0]);
    if (addr < base) return null;
    const offset = addr - base;
    if (offset % @sizeOf(Slot) != 0) return null;
    const index = offset / @sizeOf(Slot);
    if (index >= pool_size) return null;
    const slot = &pool[index];
    if (!slot.in_use.load(.acquire)) return null;
    return slot;
}

/// Allocate a counter from the fixed pool.
///
/// Returns null when all 64 slots are in use; the generated bindings turn that
/// into an error (Go) or an exception (Python). The returned handle must be
/// released exactly once with `zcounter_destroy`.
export fn zcounter_new() ?*Counter {
    for (&pool) |*slot| {
        if (slot.in_use.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            slot.state = digest.offset_basis;
            slot.total = 0;
            return @ptrCast(slot);
        }
    }
    return null;
}

/// Release a counter back to the pool.
///
/// Calling this once per handle is required; calling it again with the same
/// (now stale) handle is a no-op rather than a double free, which is what makes
/// an idempotent `Close()` / `close()` safe to generate.
export fn zcounter_destroy(c: *Counter) void {
    const slot = slotOf(c) orelse return;
    slot.state = digest.offset_basis;
    slot.total = 0;
    slot.in_use.store(false, .release);
}

/// Add two integers with wrapping arithmetic, so no input can trap.
export fn zcounter_add(a: i32, b: i32) i32 {
    return a +% b;
}

/// Mix `data[0..len]` into the counter's digest and add `len` to its byte
/// total, returning the new total.
///
/// `len == 0` is explicitly allowed and leaves the counter untouched: the
/// pointer is never dereferenced in that case, because a zero-length slice in
/// Go or an empty `bytes()` in Python can carry a null or dangling data
/// pointer. Returns 0 if the handle is not live.
export fn zcounter_feed(c: *Counter, data: [*]const u8, len: usize) u64 {
    const slot = slotOf(c) orelse return 0;
    if (len == 0 or @intFromPtr(data) == 0) return slot.total;
    slot.state = digest.mix(slot.state, data[0..len]);
    // usize is 64-bit on every supported target, so this cast is a no-op.
    slot.total +%= @as(u64, @intCast(len));
    return slot.total;
}

/// Same as `zcounter_feed`, but over a NUL-terminated string; the terminator
/// itself is not counted. Returns the new total, or 0 if the handle is not
/// live. A null pointer is treated as an empty string.
export fn zcounter_feed_str(c: *Counter, text: [*:0]const u8) u64 {
    const slot = slotOf(c) orelse return 0;
    if (@intFromPtr(text) == 0) return slot.total;
    const bytes = std.mem.span(text);
    if (bytes.len == 0) return slot.total;
    slot.state = digest.mix(slot.state, bytes);
    slot.total +%= @as(u64, @intCast(bytes.len));
    return slot.total;
}

/// Write the counter's 8-byte big-endian FNV-1a-64 digest into `out[0..out_len]`
/// and return the number of bytes **actually written**.
///
/// The digest is always 8 bytes, so:
///
///   * `out_len >= 8` writes 8 bytes and returns 8;
///   * `out_len < 8` writes the first `out_len` bytes and returns `out_len`
///     (the digest is truncated, never padded, and `out` is never overrun);
///   * `out_len == 0` writes nothing and returns 0.
///
/// Returns 0 if the handle is not live.
export fn zcounter_digest(c: *Counter, out: [*]u8, out_len: usize) usize {
    const slot = slotOf(c) orelse return 0;
    if (out_len == 0 or @intFromPtr(out) == 0) return 0;
    const be = digest.toBigEndian(slot.state);
    const n = @min(out_len, be.len);
    @memcpy(out[0..n], be[0..n]);
    return n;
}

/// Write the counter's running byte total through `out` and return true.
///
/// Returns false without touching `out` when the handle is not live, which is
/// the out-parameter shape the generators lower into an extra return value.
export fn zcounter_total(c: *Counter, out: *u64) bool {
    const slot = slotOf(c) orelse return false;
    if (@intFromPtr(out) == 0) return false;
    out.* = slot.total;
    return true;
}

// ---------------------------------------------------------------------------
// Tests — these never run in the shared library build; they exist so
// `zig test src/c_api.zig` can check the semantics the bindings rely on.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "new/destroy round-trips and destroy is idempotent" {
    const c = zcounter_new().?;
    var total: u64 = 12345;
    try testing.expect(zcounter_total(c, &total));
    try testing.expectEqual(@as(u64, 0), total);
    zcounter_destroy(c);
    // Stale handle: no double free, and the handle no longer resolves.
    zcounter_destroy(c);
    try testing.expect(!zcounter_total(c, &total));
}

test "add wraps instead of trapping" {
    try testing.expectEqual(@as(i32, 3), zcounter_add(1, 2));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), zcounter_add(std.math.maxInt(i32), 1));
}

test "feed accepts a zero length without dereferencing the pointer" {
    const c = zcounter_new().?;
    defer zcounter_destroy(c);

    const dangling: [*]const u8 = @ptrFromInt(0xdeadbeef);
    try testing.expectEqual(@as(u64, 0), zcounter_feed(c, dangling, 0));

    try testing.expectEqual(@as(u64, 3), zcounter_feed(c, "abc", 3));
    try testing.expectEqual(@as(u64, 3), zcounter_feed(c, dangling, 0));
}

test "feed and feed_str agree" {
    const a = zcounter_new().?;
    defer zcounter_destroy(a);
    const b = zcounter_new().?;
    defer zcounter_destroy(b);

    _ = zcounter_feed(a, "foobar", 6);
    _ = zcounter_feed_str(b, "foobar");

    var da: [8]u8 = undefined;
    var db: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), zcounter_digest(a, &da, da.len));
    try testing.expectEqual(@as(usize, 8), zcounter_digest(b, &db, db.len));
    try testing.expectEqualSlices(u8, &da, &db);
    try testing.expectEqualSlices(u8, &.{ 0x85, 0x94, 0x41, 0x71, 0xf7, 0x39, 0x67, 0xe8 }, &da);
}

test "digest truncates to the buffer it is given" {
    const c = zcounter_new().?;
    defer zcounter_destroy(c);
    _ = zcounter_feed_str(c, "foobar");

    var small: [3]u8 = @splat(0xaa);
    try testing.expectEqual(@as(usize, 3), zcounter_digest(c, &small, small.len));
    try testing.expectEqualSlices(u8, &.{ 0x85, 0x94, 0x41 }, &small);

    var big: [16]u8 = @splat(0xaa);
    try testing.expectEqual(@as(usize, 8), zcounter_digest(c, &big, big.len));
    try testing.expectEqual(@as(u8, 0xaa), big[8]);

    var none: [1]u8 = @splat(0xaa);
    try testing.expectEqual(@as(usize, 0), zcounter_digest(c, &none, 0));
    try testing.expectEqual(@as(u8, 0xaa), none[0]);
}

test "the pool runs out instead of failing" {
    var held: [pool_size]?*Counter = @splat(null);
    for (&held) |*slot| slot.* = zcounter_new();
    defer for (held) |c| {
        if (c) |h| zcounter_destroy(h);
    };
    for (held) |c| try testing.expect(c != null);
    try testing.expectEqual(@as(?*Counter, null), zcounter_new());
}
