//! The IR: the only contract between the parser, the validator and every
//! generator. Pure data, no allocation policy of its own — everything is
//! allocated in the caller's arena and borrowed from the parsed source.
//!
//! FROZEN: changing a declaration here changes every generator. Treat edits as
//! a cross-cutting change, not a local one.

const std = @import("std");

pub const Loc = struct {
    line: u32 = 0,
    column: u32 = 0,

    pub fn format(self: Loc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ self.line, self.column });
    }
};

/// Integer shapes that are ABI-safe across the C boundary.
pub const IntKind = enum {
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    usize,
    isize,
    c_char,
    c_short,
    c_ushort,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_longlong,
    c_ulonglong,

    pub fn fromName(name: []const u8) ?IntKind {
        return std.meta.stringToEnum(IntKind, name);
    }

    pub fn zigName(self: IntKind) []const u8 {
        return @tagName(self);
    }

    /// Bit width when it is fixed across every supported target, else null
    /// (c_long is 32-bit on Windows and 64-bit elsewhere; usize varies).
    pub fn fixedBits(self: IntKind) ?u16 {
        return switch (self) {
            .u8, .i8, .c_char => 8,
            .u16, .i16, .c_short, .c_ushort => 16,
            .u32, .i32, .c_int, .c_uint => 32,
            .u64, .i64, .c_longlong, .c_ulonglong => 64,
            .usize, .isize, .c_long, .c_ulong => null,
        };
    }

    pub fn isSigned(self: IntKind) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .isize, .c_char, .c_short, .c_int, .c_long, .c_longlong => true,
            .u8, .u16, .u32, .u64, .usize, .c_ushort, .c_uint, .c_ulong, .c_ulonglong => false,
        };
    }

    pub fn isPointerSized(self: IntKind) bool {
        return self == .usize or self == .isize;
    }
};

pub const FloatKind = enum {
    f32,
    f64,

    pub fn fromName(name: []const u8) ?FloatKind {
        return std.meta.stringToEnum(FloatKind, name);
    }
};

/// A by-value primitive: legal as a parameter, a return type, or the child of
/// an out-pointer.
pub const Scalar = union(enum) {
    bool,
    int: IntKind,
    float: FloatKind,

    pub fn eql(a: Scalar, b: Scalar) bool {
        return std.meta.eql(a, b);
    }

    pub fn zigName(self: Scalar) []const u8 {
        return switch (self) {
            .bool => "bool",
            .int => |k| k.zigName(),
            .float => |k| @tagName(k),
        };
    }
};

/// A pointer to a `const X = opaque {};` declared in the same file.
pub const HandleRef = struct {
    /// Name of the opaque declaration, e.g. "Ctx".
    name: []const u8,
    /// `?*Ctx` rather than `*Ctx`.
    optional: bool,
    /// `*const Ctx`.
    is_const: bool,
};

/// `[*]u8`, `[*]const u8` or `[*:0]const u8`.
pub const ManyU8 = struct {
    is_const: bool,
    sentinel_zero: bool,
    optional: bool = false,
};

pub const Type = union(enum) {
    void,
    scalar: Scalar,
    handle: HandleRef,
    many_u8: ManyU8,
    /// `*T` / `?*T` where T is a scalar: a single out-parameter.
    out_ptr: struct { child: Scalar, optional: bool },
    /// Anything outside the allowlist. Never dropped: the validator reports it
    /// with the original source text so the error names what the user wrote.
    unsupported: []const u8,

    pub fn isUnsupported(self: Type) bool {
        return self == .unsupported;
    }

    /// Canonical spelling, used by the ABI hash and by diagnostics.
    pub fn write(self: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .void => try w.writeAll("void"),
            .scalar => |s| try w.writeAll(s.zigName()),
            .handle => |h| {
                if (h.optional) try w.writeByte('?');
                try w.writeByte('*');
                if (h.is_const) try w.writeAll("const ");
                try w.writeAll(h.name);
            },
            .many_u8 => |m| {
                if (m.optional) try w.writeByte('?');
                try w.writeAll(if (m.sentinel_zero) "[*:0]" else "[*]");
                if (m.is_const) try w.writeAll("const ");
                try w.writeAll("u8");
            },
            .out_ptr => |p| {
                if (p.optional) try w.writeByte('?');
                try w.writeByte('*');
                try w.writeAll(p.child.zigName());
            },
            .unsupported => |src| try w.writeAll(src),
        }
    }

    pub fn toString(self: Type, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        try self.write(&out.writer);
        return arena.dupe(u8, out.written());
    }
};

pub const Param = struct {
    /// May be empty when the source wrote `_: usize` or omitted the name.
    name: []const u8,
    ty: Type,
    loc: Loc = .{},
};

pub const Function = struct {
    name: []const u8,
    params: []const Param,
    ret: Type,
    /// Source text of an explicit `callconv(...)`, or null when the function
    /// did not spell one. An `export fn` defaults to the C calling convention,
    /// which is the only one a binding can call; anything else (`.naked`,
    /// `.aarch64_vfabi`, an interrupt handler) must be rejected rather than
    /// called as if it were C.
    callconv_src: ?[]const u8 = null,
    /// Joined `///` lines, without the leading `///`, or null.
    doc: ?[]const u8 = null,
    loc: Loc = .{},
    /// True for `pub export fn`; informational only.
    is_pub: bool = false,

    pub fn paramIndexByName(self: Function, name: []const u8) ?u32 {
        for (self.params, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, name)) return @intCast(i);
        }
        return null;
    }
};

pub const Handle = struct {
    name: []const u8,
    doc: ?[]const u8 = null,
    loc: Loc = .{},
};

pub const Api = struct {
    /// Library base name, e.g. "zpdf". Set by the front end, not the parser.
    lib_name: []const u8,
    handles: []const Handle,
    functions: []const Function,

    pub fn findHandle(self: Api, name: []const u8) ?Handle {
        for (self.handles) |h| {
            if (std.mem.eql(u8, h.name, name)) return h;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Lowering: raw C-ABI params -> the logical arguments a binding exposes.
// Shared by every generator so Go, Python and the C header agree on which
// params collapse into one another.
// ---------------------------------------------------------------------------

pub const Logical = union(enum) {
    /// A plain by-value primitive.
    scalar: u32,
    /// An opaque handle pointer.
    handle: u32,
    /// `[*]const u8` + `usize` pair: caller-owned input bytes.
    bytes_in: Pair,
    /// `[*]u8` + `usize` pair: caller-allocated output buffer.
    bytes_out: Pair,
    /// `[*:0]const u8`: NUL-terminated string in, no length param.
    cstr_in: u32,
    /// `*T` where T is a scalar: an out-parameter.
    out_ptr: u32,

    pub const Pair = struct { ptr: u32, len: u32 };

    /// Index of the param this logical argument takes its name from.
    pub fn nameIndex(self: Logical) u32 {
        return switch (self) {
            .scalar, .handle, .cstr_in, .out_ptr => |i| i,
            .bytes_in, .bytes_out => |p| p.ptr,
        };
    }
};

pub const LowerError = error{ OutOfMemory, UnpairedBuffer, UnsupportedType };

/// Collapse `ptr, len` pairs into single logical arguments. Only valid on an
/// API that passed validation; returns an error otherwise so a generator can
/// never emit code for a shape the validator would have rejected.
pub fn lower(gpa: std.mem.Allocator, f: Function) LowerError![]Logical {
    var out: std.ArrayList(Logical) = .empty;
    errdefer out.deinit(gpa);

    var i: u32 = 0;
    while (i < f.params.len) : (i += 1) {
        const p = f.params[i];
        switch (p.ty) {
            .unsupported => return error.UnsupportedType,
            .void => return error.UnsupportedType,
            .scalar => try out.append(gpa, .{ .scalar = i }),
            .handle => try out.append(gpa, .{ .handle = i }),
            .out_ptr => try out.append(gpa, .{ .out_ptr = i }),
            .many_u8 => |m| {
                if (m.sentinel_zero) {
                    if (!m.is_const) return error.UnsupportedType;
                    try out.append(gpa, .{ .cstr_in = i });
                    continue;
                }
                const next = i + 1;
                if (next >= f.params.len) return error.UnpairedBuffer;
                const len_ty = f.params[next].ty;
                const is_len = len_ty == .scalar and len_ty.scalar == .int and
                    len_ty.scalar.int == .usize;
                if (!is_len) return error.UnpairedBuffer;
                const pair: Logical.Pair = .{ .ptr = i, .len = next };
                try out.append(gpa, if (m.is_const)
                    .{ .bytes_in = pair }
                else
                    .{ .bytes_out = pair });
                i = next;
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Lifecycle conventions (decision D7): naming, not annotations.
// ---------------------------------------------------------------------------

pub const ctor_suffixes = [_][]const u8{ "new", "create", "init", "open", "alloc" };
pub const dtor_suffixes = [_][]const u8{ "destroy", "free", "deinit", "close", "release" };

pub const Lifecycle = struct {
    /// Indices into `Api.functions`, parallel to `Api.handles`.
    ctors: []const []const u32,
    dtors: []const []const u32,

    pub fn dtorFor(self: Lifecycle, handle_index: usize) ?u32 {
        const list = self.dtors[handle_index];
        return if (list.len == 1) list[0] else null;
    }
};

fn hasSuffix(name: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |s| {
        if (std.mem.endsWith(u8, name, s)) {
            // Require a `_` before the suffix, or an exact match, so
            // `zc_reopen` doesn't read as a constructor.
            if (name.len == s.len) return true;
            if (name[name.len - s.len - 1] == '_') return true;
        }
    }
    return false;
}

/// A function is a constructor for handle H when its name ends in a
/// constructor word and it returns `*H` / `?*H`. It is a destructor when its
/// name ends in a destructor word, it returns void and takes exactly one
/// param, a `*H`.
pub fn lifecycle(gpa: std.mem.Allocator, api: Api) !Lifecycle {
    const ctors = try gpa.alloc([]const u32, api.handles.len);
    const dtors = try gpa.alloc([]const u32, api.handles.len);

    for (api.handles, 0..) |h, hi| {
        var c: std.ArrayList(u32) = .empty;
        var d: std.ArrayList(u32) = .empty;
        for (api.functions, 0..) |f, fi| {
            const idx: u32 = @intCast(fi);
            if (f.ret == .handle and std.mem.eql(u8, f.ret.handle.name, h.name) and
                hasSuffix(f.name, &ctor_suffixes))
            {
                try c.append(gpa, idx);
            }
            if (f.ret == .void and f.params.len == 1 and f.params[0].ty == .handle and
                std.mem.eql(u8, f.params[0].ty.handle.name, h.name) and
                hasSuffix(f.name, &dtor_suffixes))
            {
                try d.append(gpa, idx);
            }
        }
        ctors[hi] = try c.toOwnedSlice(gpa);
        dtors[hi] = try d.toOwnedSlice(gpa);
    }
    return .{ .ctors = ctors, .dtors = dtors };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scalarInt(k: IntKind) Type {
    return .{ .scalar = .{ .int = k } };
}

test "lower collapses ptr+len pairs" {
    const f: Function = .{
        .name = "zc_feed",
        .ret = scalarInt(.i32),
        .params = &.{
            .{ .name = "ctx", .ty = .{ .handle = .{ .name = "Ctx", .optional = false, .is_const = false } } },
            .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
            .{ .name = "len", .ty = scalarInt(.usize) },
            .{ .name = "out", .ty = .{ .many_u8 = .{ .is_const = false, .sentinel_zero = false } } },
            .{ .name = "out_len", .ty = scalarInt(.usize) },
            .{ .name = "flags", .ty = scalarInt(.u32) },
        },
    };
    const got = try lower(testing.allocator, f);
    defer testing.allocator.free(got);

    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expect(got[0] == .handle);
    try testing.expectEqual(@as(u32, 1), got[1].bytes_in.ptr);
    try testing.expectEqual(@as(u32, 2), got[1].bytes_in.len);
    try testing.expectEqual(@as(u32, 3), got[2].bytes_out.ptr);
    try testing.expectEqual(@as(u32, 5), got[3].scalar);
}

test "lower rejects an unpaired buffer" {
    const f: Function = .{
        .name = "bad",
        .ret = .void,
        .params = &.{
            .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
        },
    };
    try testing.expectError(error.UnpairedBuffer, lower(testing.allocator, f));
}

test "lower treats a sentinel pointer as a string" {
    const f: Function = .{
        .name = "open",
        .ret = .void,
        .params = &.{
            .{ .name = "path", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = true } } },
        },
    };
    const got = try lower(testing.allocator, f);
    defer testing.allocator.free(got);
    try testing.expect(got[0] == .cstr_in);
}

test "lifecycle finds one constructor and one destructor" {
    const handle: Type = .{ .handle = .{ .name = "Ctx", .optional = false, .is_const = false } };
    const api: Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx" }},
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = .{ .handle = .{ .name = "Ctx", .optional = true, .is_const = false } }, .params = &.{} },
            .{ .name = "zc_ctx_destroy", .ret = .void, .params = &.{.{ .name = "c", .ty = handle }} },
            .{ .name = "zc_ctx_reopen", .ret = .void, .params = &.{.{ .name = "c", .ty = handle }} },
        },
    };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const lc = try lifecycle(arena_state.allocator(), api);
    try testing.expectEqual(@as(usize, 1), lc.ctors[0].len);
    try testing.expectEqual(@as(u32, 1), lc.dtorFor(0).?);
}

test "type canonical spelling" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t: Type = .{ .handle = .{ .name = "Ctx", .optional = true, .is_const = true } };
    try testing.expectEqualStrings("?*const Ctx", try t.toString(arena));
    const b: Type = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = true } };
    try testing.expectEqualStrings("[*:0]const u8", try b.toString(arena));
}
