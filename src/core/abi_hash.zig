//! A stable hash of the exported surface. The generated bindings carry it as a
//! constant and the compiled library exports it as a function, so a binding
//! loaded against a stale binary fails at load time instead of miscalling.
//!
//! It hashes a canonical form that covers exactly what a caller can observe
//! when it makes a call: `lib_name`, every function's name, its parameter
//! types in order and its return type, including integer width and signedness.
//!
//! It is deliberately blind to everything else, because an already-built binary
//! that still answers the same calls must keep passing the load-time check:
//!
//!   * the order `export fn`s appear in the file — functions are folded in
//!     sorted name order, not source order;
//!   * parameter names and doc comments;
//!   * the name of an `opaque {}` (every handle is one opaque pointer at the
//!     ABI), and handles nothing references — there is no handles section;
//!   * optionality and constness on a handle pointer: `?*const Ctx`, `*Ctx`
//!     and `?*Doc` are all the same C pointer.
//!
//! What it does *not* fold away is anything that changes how a call is made:
//! adding, removing or renaming a function, reordering or retyping its
//! parameters, changing a return type, or changing `lib_name`.

const std = @import("std");
const ir = @import("ir.zig");

pub fn compute(api: ir.Api) u64 {
    var hasher: std.hash.Wyhash = .init(0x7a62726964676531); // "zbridge1"
    hasher.update(api.lib_name);
    hasher.update("\x00fns\x00");

    // Sorted by name, without allocating: an O(n^2) walk over a handful of
    // exports costs nothing and keeps `compute` callable from anywhere.
    var prev: ?usize = null;
    while (nextFunction(api, prev)) |i| {
        const f = api.functions[i];
        hasher.update(f.name);
        hasher.update("(");
        for (f.params) |p| {
            hashType(&hasher, p.ty);
            hasher.update(",");
        }
        hasher.update(")");
        hashType(&hasher, f.ret);
        hasher.update(";");
        prev = i;
    }
    return hasher.final();
}

/// Index of the next function in (name, index) order after `prev`, or null.
/// Equal names are impossible in a file Zig accepts, but the index tiebreak
/// keeps the walk total rather than dropping one of them.
fn nextFunction(api: ir.Api, prev: ?usize) ?usize {
    var best: ?usize = null;
    for (0..api.functions.len) |i| {
        if (prev) |p| {
            if (!sortsBefore(api, p, i)) continue;
        }
        if (best) |b| {
            if (sortsBefore(api, i, b)) best = i;
        } else {
            best = i;
        }
    }
    return best;
}

fn sortsBefore(api: ir.Api, a: usize, b: usize) bool {
    return switch (std.mem.order(u8, api.functions[a].name, api.functions[b].name)) {
        .lt => true,
        .gt => false,
        .eq => a < b,
    };
}

/// The canonical spelling of a type, written straight into the hasher: no
/// intermediate buffer, so a pathologically long spelling cannot be truncated
/// into a collision with another type that shares its prefix.
///
/// This is not `ir.Type.write`: that one is for humans and spells out
/// everything the user wrote. This one folds away what the ABI cannot see.
fn hashType(hasher: *std.hash.Wyhash, t: ir.Type) void {
    switch (t) {
        .void => hasher.update("v:void"),
        .scalar => |s| {
            hasher.update("s:");
            hasher.update(s.zigName());
        },
        // Handle name, constness and optionality are all invisible to a
        // caller: what crosses the boundary is one opaque pointer.
        .handle => hasher.update("h:*opaque"),
        .many_u8 => |m| {
            // Constness and the sentinel change the direction and the shape of
            // the call, so they stay; `?` does not.
            hasher.update("b:");
            hasher.update(if (m.sentinel_zero) "[*:0]" else "[*]");
            if (m.is_const) hasher.update("const ");
            hasher.update("u8");
        },
        .out_ptr => |p| {
            hasher.update("o:*");
            hasher.update(p.child.zigName());
        },
        // An unsupported type never reaches a generator (the validator fails
        // the run first), but hashing its full source text keeps `compute`
        // total and collision-free for tools that hash an unvalidated API.
        .unsupported => |src| {
            hasher.update("u:");
            hasher.update(src);
        },
    }
}

/// Rendered the same way everywhere: 16 lowercase hex digits.
pub fn format(arena: std.mem.Allocator, hash: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{x:0>16}", .{hash});
}

const testing = std.testing;

fn i32t() ir.Type {
    return .{ .scalar = .{ .int = .i32 } };
}

fn handle(name: []const u8, optional: bool, is_const: bool) ir.Type {
    return .{ .handle = .{ .name = name, .optional = optional, .is_const = is_const } };
}

test "hash ignores param names and docs but not types" {
    const base: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "add",
            .ret = i32t(),
            .params = &.{
                .{ .name = "a", .ty = i32t() },
                .{ .name = "b", .ty = i32t() },
            },
        }},
    };
    const renamed: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "add",
            .ret = i32t(),
            .doc = "adds",
            .params = &.{
                .{ .name = "x", .ty = i32t() },
                .{ .name = "y", .ty = i32t() },
            },
        }},
    };
    const retyped: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "add",
            .ret = .{ .scalar = .{ .int = .i64 } },
            .params = &.{
                .{ .name = "a", .ty = i32t() },
                .{ .name = "b", .ty = i32t() },
            },
        }},
    };

    try testing.expectEqual(compute(base), compute(renamed));
    try testing.expect(compute(base) != compute(retyped));
}

test "hash ignores the order export fns appear in the file" {
    const one: ir.Function = .{ .name = "zc_one", .ret = .void, .params = &.{} };
    const two: ir.Function = .{ .name = "zc_two", .ret = i32t(), .params = &.{.{ .name = "n", .ty = i32t() }} };

    const forward: ir.Api = .{ .lib_name = "zc", .handles = &.{}, .functions = &.{ one, two } };
    const reversed: ir.Api = .{ .lib_name = "zc", .handles = &.{}, .functions = &.{ two, one } };

    try testing.expectEqual(compute(forward), compute(reversed));
}

test "hash ignores handle names, unused handles and pointer optionality" {
    const ctx: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx" }},
        .functions = &.{
            .{ .name = "zc_new", .ret = handle("Ctx", true, false), .params = &.{} },
            .{
                .name = "zc_use",
                .ret = .void,
                .params = &.{
                    .{ .name = "c", .ty = handle("Ctx", false, false) },
                    .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
                    .{ .name = "data_len", .ty = .{ .scalar = .{ .int = .usize } } },
                },
            },
        },
    };

    // The same file with the opaque renamed: every `*Ctx` becomes `*Session`.
    const renamed: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Session" }},
        .functions = &.{
            .{ .name = "zc_new", .ret = handle("Session", true, false), .params = &.{} },
            .{
                .name = "zc_use",
                .ret = .void,
                .params = &.{
                    .{ .name = "c", .ty = handle("Session", false, false) },
                    .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
                    .{ .name = "data_len", .ty = .{ .scalar = .{ .int = .usize } } },
                },
            },
        },
    };

    // An extra `opaque {}` no exported function mentions.
    const extra_handle: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{ .{ .name = "Ctx" }, .{ .name = "Unused" } },
        .functions = ctx.functions,
    };

    // `?*Ctx` / `?[*]const u8` instead of the non-optional spellings: the same
    // C pointers.
    const optional: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx" }},
        .functions = &.{
            .{ .name = "zc_new", .ret = handle("Ctx", true, false), .params = &.{} },
            .{
                .name = "zc_use",
                .ret = .void,
                .params = &.{
                    .{ .name = "c", .ty = handle("Ctx", true, true) },
                    .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false, .optional = true } } },
                    .{ .name = "data_len", .ty = .{ .scalar = .{ .int = .usize } } },
                },
            },
        },
    };

    try testing.expectEqual(compute(ctx), compute(renamed));
    try testing.expectEqual(compute(ctx), compute(extra_handle));
    try testing.expectEqual(compute(ctx), compute(optional));
}

test "hash still changes for anything a caller can observe" {
    const base: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "zc_feed",
            .ret = i32t(),
            .params = &.{
                .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
                .{ .name = "data_len", .ty = .{ .scalar = .{ .int = .usize } } },
            },
        }},
    };

    const other_lib: ir.Api = .{ .lib_name = "zd", .handles = base.handles, .functions = base.functions };
    const renamed_fn: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{ .name = "zc_feed2", .ret = i32t(), .params = base.functions[0].params }},
    };
    const swapped: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "zc_feed",
            .ret = i32t(),
            .params = &.{
                .{ .name = "data_len", .ty = .{ .scalar = .{ .int = .usize } } },
                .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
            },
        }},
    };
    const unsigned: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{ .name = "zc_feed", .ret = .{ .scalar = .{ .int = .u32 } }, .params = base.functions[0].params }},
    };
    const wider: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{ .name = "zc_feed", .ret = .{ .scalar = .{ .int = .i64 } }, .params = base.functions[0].params }},
    };
    const writable: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "zc_feed",
            .ret = i32t(),
            .params = &.{
                .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = false, .sentinel_zero = false } } },
                .{ .name = "data_len", .ty = .{ .scalar = .{ .int = .usize } } },
            },
        }},
    };
    const extra_fn: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            base.functions[0],
            .{ .name = "zc_reset", .ret = .void, .params = &.{} },
        },
    };

    for ([_]ir.Api{ other_lib, renamed_fn, swapped, unsigned, wider, writable, extra_fn }) |changed| {
        try testing.expect(compute(base) != compute(changed));
    }
}

test "a type spelling longer than any buffer is hashed in full" {
    // Two `unsupported` spellings that share a 4096-byte prefix. A fixed-size
    // intermediate buffer would hash both as the same truncated prefix, and
    // the load-time check would then accept a binary built from the other one.
    var long_a: [4096]u8 = undefined;
    @memset(&long_a, 'A');
    var long_b: [4097]u8 = undefined;
    @memset(&long_b, 'A');
    long_b[4096] = 'B';

    const a: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "zc_odd",
            .ret = .void,
            .params = &.{.{ .name = "x", .ty = .{ .unsupported = &long_a } }},
        }},
    };
    const b: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "zc_odd",
            .ret = .void,
            .params = &.{.{ .name = "x", .ty = .{ .unsupported = &long_b } }},
        }},
    };

    try testing.expect(compute(a) != compute(b));
}

test "hash formatting is fixed width" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("00000000000000ff", try format(arena_state.allocator(), 255));
}
