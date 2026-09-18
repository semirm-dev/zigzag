//! The C header generator (decision D6).
//!
//! `zig build-lib -femit-h` is broken on 0.16 (ziglang/zig#9698), so zbridge
//! writes `<lib>.h` itself, straight off the IR. The header describes the
//! *raw* C ABI: `ptr`/`len` pairs stay two parameters, because that is what the
//! symbol actually takes. Collapsing them is the job of the idiomatic Go and
//! Python layers, not of the C view.
//!
//! An `.unsupported` type fails with `error.UnsupportedType`, exactly as the Go
//! and Python generators do. The validator rejects those long before a
//! generator runs, so this is unreachable in practice — but if the validator
//! ever grows a hole, every generator must fail loudly rather than one of them
//! quietly emitting a header that describes the wrong ABI.

const std = @import("std");
const ir = @import("../core/ir.zig");
const gen = @import("context.zig");
const CodeWriter = @import("writer.zig").CodeWriter;

pub fn generate(arena: std.mem.Allocator, ctx: gen.Context, files: *gen.FileList) !void {
    var w: CodeWriter = .init(arena, "    ");
    errdefer w.deinit();

    const guard = try guardName(arena, ctx.libName());

    try w.block(try gen.banner(arena, ctx, "//"));
    try w.blank();

    try w.line("#ifndef {s}", .{guard});
    try w.line("#define {s}", .{guard});
    try w.blank();
    try w.raw("#include <stdint.h>");
    try w.raw("#include <stdbool.h>");
    try w.raw("#include <stddef.h>");
    try w.blank();
    try w.raw("#ifdef __cplusplus");
    try w.raw("extern \"C\" {");
    try w.raw("#endif");

    for (ctx.api.handles) |h| {
        try w.blank();
        try w.docComment("// ", h.doc);
        try w.line("typedef struct {s} {s};", .{ h.name, h.name });
    }

    try w.blank();
    try w.raw("// Identifies the exported surface this binary was built from.");
    try w.line("uint64_t {s}_zbridge_abi_hash(void);", .{ctx.libName()});

    for (ctx.api.functions) |f| {
        try w.blank();
        try w.docComment("// ", f.doc);
        try w.raw(try prototype(arena, f));
    }

    try w.blank();
    try w.raw("#ifdef __cplusplus");
    try w.raw("}  // extern \"C\"");
    try w.raw("#endif");
    try w.blank();
    try w.line("#endif  // {s}", .{guard});

    try files.append(arena, .{
        .lang = .c,
        .tier = .generated,
        .path = try std.fmt.allocPrint(arena, "{s}.h", .{ctx.libName()}),
        .bytes = try w.toOwnedSlice(),
    });
}

// ---------------------------------------------------------------------------
// Include guard
// ---------------------------------------------------------------------------

/// "zcounter" -> "ZBRIDGE_ZCOUNTER_H". Anything that is not `[A-Za-z0-9]`
/// becomes `_`, and a name starting with a digit still yields a legal macro
/// because of the fixed `ZBRIDGE_` prefix.
pub fn guardName(arena: std.mem.Allocator, lib_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "ZBRIDGE_");
    for (lib_name) |c| {
        try out.append(arena, if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_');
    }
    try out.appendSlice(arena, "_H");
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Prototypes
// ---------------------------------------------------------------------------

fn prototype(arena: std.mem.Allocator, f: ir.Function) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;

    try w.print("{s} {s}(", .{ try cType(arena, f.ret), f.name });
    if (f.params.len == 0) {
        try w.writeAll("void");
    } else {
        for (f.params, 0..) |p, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{s} {s}", .{
                try cType(arena, p.ty),
                try paramName(arena, p.name, i),
            });
        }
    }
    try w.writeAll(");");
    return arena.dupe(u8, out.written());
}

/// The IR name, `argN` when the source omitted it, with a `_` appended when it
/// would collide with a C or C++ keyword.
fn paramName(arena: std.mem.Allocator, name: []const u8, index: usize) ![]const u8 {
    if (name.len == 0) return std.fmt.allocPrint(arena, "arg{d}", .{index});
    if (isCKeyword(name)) return std.fmt.allocPrint(arena, "{s}_", .{name});
    return name;
}

const c_keywords = [_][]const u8{
    "auto",     "bool",     "break",    "case",     "char",   "const",
    "continue", "default",  "do",       "double",   "else",   "enum",
    "extern",   "float",    "for",      "goto",     "if",     "inline",
    "int",      "long",     "register", "restrict", "return", "short",
    "signed",   "sizeof",   "static",   "struct",   "switch", "typedef",
    "union",    "unsigned", "void",     "volatile", "while",
};

fn isCKeyword(name: []const u8) bool {
    for (c_keywords) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Type mapping
// ---------------------------------------------------------------------------

/// The C spelling of an IR type, as it appears left of a declarator.
pub fn cType(arena: std.mem.Allocator, t: ir.Type) ![]const u8 {
    return switch (t) {
        .void => "void",
        .scalar => |s| cScalar(s),
        .handle => |h| if (h.is_const)
            try std.fmt.allocPrint(arena, "const {s}*", .{h.name})
        else
            try std.fmt.allocPrint(arena, "{s}*", .{h.name}),
        // A `[*:0]` pointer is a C string; anything else is a byte buffer.
        // `optional` makes no difference: both are just pointers in C.
        .many_u8 => |m| if (m.sentinel_zero)
            (if (m.is_const) "const char*" else "char*")
        else
            (if (m.is_const) "const uint8_t*" else "uint8_t*"),
        .out_ptr => |p| try std.fmt.allocPrint(arena, "{s}*", .{cScalar(p.child)}),
        // Unreachable behind the validator, which rejects `.unsupported` long
        // before generation. If one ever reaches here it means the validator
        // has a hole, and the honest response is to fail exactly like the Go
        // and Python generators do. Emitting `void*` with a comment would
        // produce a header that compiles and silently describes the wrong ABI
        // — a guess, which this tool does not make (plan §8).
        .unsupported => error.UnsupportedType,
    };
}

fn cScalar(s: ir.Scalar) []const u8 {
    return switch (s) {
        .bool => "bool",
        .float => |k| switch (k) {
            .f32 => "float",
            .f64 => "double",
        },
        .int => |k| switch (k) {
            .u8 => "uint8_t",
            .u16 => "uint16_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .i8 => "int8_t",
            .i16 => "int16_t",
            .i32 => "int32_t",
            .i64 => "int64_t",
            .usize => "size_t",
            .isize => "ptrdiff_t",
            .c_char => "char",
            .c_short => "short",
            .c_ushort => "unsigned short",
            .c_int => "int",
            .c_uint => "unsigned int",
            .c_long => "long",
            .c_ulong => "unsigned long",
            .c_longlong => "long long",
            .c_ulonglong => "unsigned long long",
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn si(k: ir.IntKind) ir.Type {
    return .{ .scalar = .{ .int = k } };
}

fn sf(k: ir.FloatKind) ir.Type {
    return .{ .scalar = .{ .float = k } };
}

fn ctxFor(api: *const ir.Api) gen.Context {
    return .{
        .api = api,
        .abi_hash = 0x0123456789abcdef,
        .abi_hash_hex = "0123456789abcdef",
        .targets = &.{},
        .link_libc = false,
        .version = "0.1.0-test",
        .input_path = "examples/kitchen_sink/src/c_api.zig",
    };
}

test "guard name derivation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("ZBRIDGE_ZCOUNTER_H", try guardName(arena, "zcounter"));
    try testing.expectEqualStrings("ZBRIDGE_KITCHEN_SINK_H", try guardName(arena, "kitchen_sink"));
    try testing.expectEqualStrings("ZBRIDGE_MY_LIB_2_H", try guardName(arena, "my-lib.2"));
    try testing.expectEqualStrings("ZBRIDGE_ZPDF_H", try guardName(arena, "ZPdf"));
    try testing.expectEqualStrings("ZBRIDGE__H", try guardName(arena, ""));
}

test "zero-parameter functions take (void)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{ .name = "zc_add", .ret = si(.i32), .params = &.{} },
        },
    };
    var files: gen.FileList = .empty;
    try generate(arena, ctxFor(&api), &files);

    try testing.expectEqual(@as(usize, 1), files.items.len);
    const f = files.items[0];
    try testing.expectEqual(gen.Lang.c, f.lang);
    try testing.expectEqual(gen.Tier.generated, f.tier);
    try testing.expectEqualStrings("zc.h", f.path);

    try testing.expect(std.mem.indexOf(u8, f.bytes, "int32_t zc_add(void);") != null);
    try testing.expect(std.mem.indexOf(u8, f.bytes, "zc_add()") == null);
    try testing.expect(std.mem.indexOf(u8, f.bytes, "uint64_t zc_zbridge_abi_hash(void);") != null);
    try testing.expect(std.mem.endsWith(u8, f.bytes, "#endif  // ZBRIDGE_ZC_H\n"));
}

const ctx_ptr: ir.Type = .{ .handle = .{ .name = "Ctx", .optional = false, .is_const = false } };

/// Exercises every arm of the type map at once and locks the exact bytes.
/// File scope, so the nested `&.{...}` literals are comptime-known statics
/// rather than pointers into a dead stack frame.
const kitchen_sink_api: ir.Api = .{
    .lib_name = "kitchen_sink",
    .handles = &.{
        .{ .name = "Ctx", .doc = "An open counter.\nDestroy it with ks_ctx_destroy." },
        .{ .name = "Sink" },
    },
    .functions = &.{
        // .void return, no params.
        .{ .name = "ks_reset", .ret = .void, .params = &.{}, .doc = "Reset global state." },
        // Every IntKind, as parameters and one as the return type.
        .{
            .name = "ks_ints",
            .ret = si(.i64),
            .doc = "Every integer shape in the allowlist.",
            .params = &.{
                .{ .name = "a", .ty = si(.u8) },
                .{ .name = "b", .ty = si(.u16) },
                .{ .name = "c", .ty = si(.u32) },
                .{ .name = "d", .ty = si(.u64) },
                .{ .name = "e", .ty = si(.i8) },
                .{ .name = "f", .ty = si(.i16) },
                .{ .name = "g", .ty = si(.i32) },
                .{ .name = "h", .ty = si(.i64) },
                .{ .name = "i", .ty = si(.usize) },
                .{ .name = "j", .ty = si(.isize) },
                .{ .name = "k", .ty = si(.c_char) },
                .{ .name = "l", .ty = si(.c_short) },
                .{ .name = "m", .ty = si(.c_ushort) },
                .{ .name = "n", .ty = si(.c_int) },
                .{ .name = "o", .ty = si(.c_uint) },
                .{ .name = "p", .ty = si(.c_long) },
                .{ .name = "q", .ty = si(.c_ulong) },
                .{ .name = "r", .ty = si(.c_longlong) },
                .{ .name = "s", .ty = si(.c_ulonglong) },
            },
        },
        // Floats and bool.
        .{
            .name = "ks_floats",
            .ret = sf(.f64),
            .params = &.{
                .{ .name = "x", .ty = sf(.f32) },
                .{ .name = "y", .ty = sf(.f64) },
            },
        },
        .{
            .name = "ks_toggle",
            .ret = .{ .scalar = .bool },
            .params = &.{.{ .name = "on", .ty = .{ .scalar = .bool } }},
        },
        // Handles: optional return, plain, const.
        .{
            .name = "ks_ctx_new",
            .doc = "Allocates a context. Returns NULL on failure.",
            .ret = .{ .handle = .{ .name = "Ctx", .optional = true, .is_const = false } },
            .params = &.{},
        },
        .{
            .name = "ks_ctx_destroy",
            .ret = .void,
            .params = &.{.{ .name = "ctx", .ty = ctx_ptr }},
        },
        .{
            .name = "ks_ctx_label",
            .ret = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = true } },
            .params = &.{
                .{ .name = "ctx", .ty = .{ .handle = .{ .name = "Ctx", .optional = false, .is_const = true } } },
                .{ .name = "sink", .ty = .{ .handle = .{ .name = "Sink", .optional = true, .is_const = true } } },
            },
        },
        // Byte buffers: const in, mutable out, optional, plus a mutable
        // C string. The ptr/len pairs stay two parameters.
        .{
            .name = "ks_feed",
            .doc = "Raw C ABI: ptr and len stay separate parameters.",
            .ret = si(.isize),
            .params = &.{
                .{ .name = "ctx", .ty = ctx_ptr },
                .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
                .{ .name = "len", .ty = si(.usize) },
                .{ .name = "out", .ty = .{ .many_u8 = .{ .is_const = false, .sentinel_zero = false } } },
                .{ .name = "out_len", .ty = si(.usize) },
                .{ .name = "opt", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false, .optional = true } } },
                .{ .name = "opt_len", .ty = si(.usize) },
            },
        },
        .{
            .name = "ks_open",
            .ret = .void,
            .params = &.{
                .{ .name = "path", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = true } } },
                .{ .name = "scratch", .ty = .{ .many_u8 = .{ .is_const = false, .sentinel_zero = true } } },
            },
        },
        // Out-pointers, including an optional one.
        .{
            .name = "ks_query",
            .ret = .void,
            .params = &.{
                .{ .name = "ctx", .ty = ctx_ptr },
                .{ .name = "out_i32", .ty = .{ .out_ptr = .{ .child = .{ .int = .i32 }, .optional = false } } },
                .{ .name = "out_flag", .ty = .{ .out_ptr = .{ .child = .bool, .optional = true } } },
                .{ .name = "out_num", .ty = .{ .out_ptr = .{ .child = .{ .float = .f64 }, .optional = false } } },
            },
        },
        // Names: empty ones become argN, C keywords get a trailing `_`.
        .{
            .name = "ks_names",
            .ret = .void,
            .params = &.{
                .{ .name = "", .ty = si(.i32) },
                .{ .name = "", .ty = sf(.f32) },
                .{ .name = "int", .ty = si(.c_int) },
                .{ .name = "register", .ty = si(.u32) },
                .{ .name = "switch", .ty = .{ .scalar = .bool } },
                .{ .name = "restrict", .ty = ctx_ptr },
            },
        },
    },
};

test "kitchen sink header matches the golden file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = kitchen_sink_api;
    var files: gen.FileList = .empty;
    try generate(arena, ctxFor(&api), &files);

    try testing.expectEqual(@as(usize, 1), files.items.len);
    try testing.expectEqualStrings("kitchen_sink.h", files.items[0].path);
    try testing.expectEqual(gen.Lang.c, files.items[0].lang);
    try testing.expectEqual(gen.Tier.generated, files.items[0].tier);

    const golden = @embedFile("testdata/c/kitchen_sink.h");
    try testing.expectEqualStrings(golden, files.items[0].bytes);
}

test "generation is deterministic" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = kitchen_sink_api;
    var a: gen.FileList = .empty;
    var b: gen.FileList = .empty;
    try generate(arena, ctxFor(&api), &a);
    try generate(arena, ctxFor(&api), &b);
    try testing.expectEqualStrings(a.items[0].bytes, b.items[0].bytes);
    try testing.expect(std.mem.endsWith(u8, a.items[0].bytes, "\n"));
    try testing.expect(std.mem.indexOf(u8, a.items[0].bytes, "\r") == null);
}

test "an unsupported type is an error, not a guess" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Go and Python both return error.UnsupportedType for this shape. The C
    // header must agree: a header that compiles but describes the wrong ABI is
    // worse than no header, because nothing downstream can detect it.
    try testing.expectError(
        error.UnsupportedType,
        cType(arena, .{ .unsupported = "anyerror!void" }),
    );
    try testing.expectError(
        error.UnsupportedType,
        prototype(arena, .{
            .name = "ks_bad",
            .ret = .void,
            .params = &.{.{ .name = "cb", .ty = .{ .unsupported = "*const fn () void" } }},
        }),
    );
}
