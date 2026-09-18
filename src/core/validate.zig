//! IR -> diagnostics. Every violation is reported in one pass; the run fails
//! as a whole rather than silently porting a subset of the API.
//!
//! The rules here are the enforcement half of `ir.lower` and `ir.lifecycle`:
//! anything `lower` refuses to collapse must already have been reported as a
//! user-facing error by the time a generator runs, so a `lower` failure on a
//! validated API is a bug in this file (see `checkLowerable`).

const std = @import("std");
const ir = @import("ir.zig");
const diag = @import("diagnostics.zig");
const names = @import("../gen/names.zig");

/// Plan §4: the answer to an unsupported shape is always a hand-written shim,
/// never a guess by the generator.
const unsupported_hint = "expose a narrower `export fn` shim that takes ABI-safe types";
const pair_hint = "byte buffers cross the boundary as a `ptr, len` pair: `data: [*]const u8, data_len: usize`";
const writable_hint = "use `[*]u8` followed by a `usize` capacity parameter";
const return_ptr_hint = "return bytes through a caller-allocated `[*]u8, usize` out-parameter pair, or return an opaque handle";
const c_char_hint = "write `u8` or `i8`: C `char` is unsigned on aarch64 and signed on x86_64, both of which zbridge builds for, so `c_char` would mean two different things in one binding";
const rename_fn_hint = "rename one of the `export fn`s";
const rename_one_hint = "rename the `export fn`";
const rename_handle_hint = "rename the `opaque {}` declaration";
const rename_either_hint = "rename the `export fn` or the `opaque {}` declaration";
const rename_handles_hint = "rename one of the `opaque {}` declarations";
const callconv_hint = "an `export fn` defaults to the C calling convention; drop the `callconv` or write `callconv(.c)`";
const len_name_hint = "a `ptr, len` pair is positional: name the length after its buffer (`data_len`), or move the parameter if it is not one";
const dtor_hint = "a destructor is an `export fn` returning void, taking one `*Handle`, whose name ends in _destroy, _free, _deinit, _close or _release";

pub fn validate(arena: std.mem.Allocator, api: ir.Api, diags: *diag.List) !void {
    if (api.functions.len == 0) {
        // Nothing downstream is actionable without exports, so stop here
        // rather than burying the real problem under handle warnings.
        try diags.err(.{}, "no `export fn` declarations found; nothing to port", .{});
        return;
    }

    // Set for any function that tripped rules 1-4, so `checkLowerable` can
    // tell a reported problem apart from a hole in this validator.
    const reported = try arena.alloc(bool, api.functions.len);
    @memset(reported, false);

    var handles_hint: ?[]const u8 = null;
    for (api.functions, 0..) |f, i| {
        try checkCallconv(f, diags);
        try checkReturn(arena, api, f, &reported[i], &handles_hint, diags);
        try checkParams(arena, api, f, &reported[i], &handles_hint, diags);
    }

    try checkNames(arena, api, diags);
    try checkLifecycle(arena, api, diags);
    try checkLowerable(arena, api, reported);
}

/// True when the API is safe to hand to a generator.
pub fn isPortable(api: ir.Api) bool {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diags: diag.List = .init(arena, "");
    validate(arena, api, &diags) catch return false;
    return !diags.hasErrors();
}

// ---------------------------------------------------------------------------
// Rules 1-5: one function's signature
// ---------------------------------------------------------------------------

/// Rule 0: the calling convention. An `export fn` with no `callconv` uses the
/// C convention, which is the only one a Go/Python binding can call. Anything
/// else — `.naked`, an interrupt handler, a target-specific vector ABI — would
/// be called as if it were C, so it is rejected rather than mis-called.
fn checkCallconv(f: ir.Function, diags: *diag.List) !void {
    const written = f.callconv_src orelse return;
    const spelling = callconvArg(written);
    if (isCCallconv(spelling)) return;
    try diags.errHint(
        f.loc,
        callconv_hint,
        "{s}: calling convention `{s}` is not the C calling convention; a generated binding can only call `callconv(.c)`",
        .{ f.name, spelling },
    );
}

/// Accepts either the whole `callconv(...)` source text or just its argument,
/// so the rule does not depend on how much of the expression the parser kept.
fn callconvArg(src: []const u8) []const u8 {
    var t = std.mem.trim(u8, src, " \t\r\n");
    if (std.mem.startsWith(u8, t, "callconv")) {
        t = std.mem.trim(u8, t["callconv".len..], " \t\r\n");
    }
    if (t.len >= 2 and t[0] == '(' and t[t.len - 1] == ')') {
        t = std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n");
    }
    return t;
}

/// Zig 0.16 spells the C convention `.c` (verified against the 0.16 compiler,
/// which rejects the older `.C` outright); a qualified
/// `std.builtin.CallingConvention.c` means the same thing. `.C` is accepted
/// here too, so a file written for an older Zig is refused by the compiler for
/// its spelling rather than by zbridge for its convention.
///
/// A payload form such as `.{ .x86_64_sysv = .{} }` is target-specific even
/// when it happens to match C on one target, so it is not accepted.
fn isCCallconv(spelling: []const u8) bool {
    var t = spelling;
    if (t.len == 0) return false;
    for (t) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
    }
    if (std.mem.lastIndexOfScalar(u8, t, '.')) |i| t = t[i + 1 ..];
    return std.mem.eql(u8, t, "c") or std.mem.eql(u8, t, "C");
}

fn checkReturn(
    arena: std.mem.Allocator,
    api: ir.Api,
    f: ir.Function,
    reported: *bool,
    handles_hint: *?[]const u8,
    diags: *diag.List,
) !void {
    switch (f.ret) {
        .unsupported => |src| {
            reported.* = true;
            try diags.errHint(f.loc, unsupported_hint, "{s}: return type '{s}' is not supported", .{ f.name, src });
        },
        // Rule 4: whoever frees the pointee is undefined once it leaves Zig.
        .many_u8, .out_ptr => {
            reported.* = true;
            try diags.errHint(f.loc, return_ptr_hint, "{s}: returns '{s}'; ownership of a pointer cannot cross the boundary", .{
                f.name,
                try f.ret.toString(arena),
            });
        },
        .handle => |h| if (api.findHandle(h.name) == null) {
            try diags.errHint(
                f.loc,
                try declaredHandles(arena, api, handles_hint),
                "{s}: return type references opaque type '{s}', which is not declared in this file",
                .{ f.name, h.name },
            );
        },
        .void, .scalar => {},
    }
    if (usesCChar(f.ret)) {
        try diags.errHint(f.loc, c_char_hint, "{s}: return type '{s}' uses `c_char`, whose signedness depends on the target", .{
            f.name,
            try f.ret.toString(arena),
        });
    }
}

/// Plan §4's allowlist never included `c_char`; it only reaches a generator
/// because `ir.IntKind` carries it for the parser's benefit. Neither target
/// language can represent it honestly: Go gets `int8` even though C `char` —
/// and so Zig's `c_char` — is *unsigned* on aarch64, which zbridge ships
/// binaries for, and `ctypes.c_char`'s value is `bytes` while the generated
/// type hint says `int`. One source file would mean two different things on
/// two supported targets, so it is rejected rather than mapped.
fn usesCChar(t: ir.Type) bool {
    return switch (t) {
        .scalar => |s| s == .int and s.int == .c_char,
        .out_ptr => |p| p.child == .int and p.child.int == .c_char,
        .void, .handle, .many_u8, .unsupported => false,
    };
}

fn checkParams(
    arena: std.mem.Allocator,
    api: ir.Api,
    f: ir.Function,
    reported: *bool,
    handles_hint: *?[]const u8,
    diags: *diag.List,
) !void {
    // Index advancement mirrors `ir.lower` exactly: a consumed `usize` length
    // must not then be examined as a parameter in its own right.
    var i: usize = 0;
    while (i < f.params.len) : (i += 1) {
        const p = f.params[i];
        const label = try paramLabel(arena, p, i);
        switch (p.ty) {
            .unsupported => |src| {
                reported.* = true;
                try diags.errHint(p.loc, unsupported_hint, "{s}: parameter {s} has unsupported type '{s}'", .{ f.name, label, src });
            },
            .void => {
                reported.* = true;
                try diags.err(p.loc, "{s}: parameter {s} has type 'void', which cannot be passed across the C ABI", .{ f.name, label });
            },
            .handle => |h| if (api.findHandle(h.name) == null) {
                try diags.errHint(
                    p.loc,
                    try declaredHandles(arena, api, handles_hint),
                    "{s}: parameter {s} references opaque type '{s}', which is not declared in this file",
                    .{ f.name, label, h.name },
                );
            },
            .many_u8 => |m| {
                if (m.sentinel_zero) {
                    // `[*:0]u8` is writable but its capacity is unknowable:
                    // the sentinel only says where the *current* data ends.
                    if (!m.is_const) {
                        reported.* = true;
                        try diags.errHint(p.loc, writable_hint, "{s}: parameter {s} has type '{s}'; a writable buffer has no knowable capacity", .{
                            f.name,
                            label,
                            try p.ty.toString(arena),
                        });
                    }
                    continue;
                }
                const next = i + 1;
                if (next >= f.params.len or !isLen(f.params[next].ty)) {
                    reported.* = true;
                    try diags.errHint(p.loc, pair_hint, "{s}: parameter {s} of type '{s}' must be immediately followed by a `usize` length parameter", .{
                        f.name,
                        label,
                        try p.ty.toString(arena),
                    });
                    continue;
                }
                // The pairing is positional (plan §4), so the `usize` in this
                // slot *is* the buffer's length as far as every generator is
                // concerned. When its name says otherwise, the call still
                // generates — with `len(buf)` in that slot — so warn rather
                // than reject a legitimately terse name.
                const len_param = f.params[next];
                if (!looksLikeLength(len_param.name)) {
                    try diags.add(
                        .warning,
                        if (len_param.loc.line == 0) p.loc else len_param.loc,
                        len_name_hint,
                        "{s}: parameter {s} follows {s} of type '{s}', so zbridge is treating it as that buffer's length; its name does not look like one",
                        .{
                            f.name,
                            try paramLabel(arena, len_param, next),
                            label,
                            try p.ty.toString(arena),
                        },
                    );
                }
                i = next;
            },
            .scalar, .out_ptr => {},
        }
        if (usesCChar(p.ty)) {
            try diags.errHint(p.loc, c_char_hint, "{s}: parameter {s} has type '{s}', whose signedness depends on the target", .{
                f.name,
                label,
                try p.ty.toString(arena),
            });
        }
    }
}

fn isLen(t: ir.Type) bool {
    return t == .scalar and t.scalar == .int and t.scalar.int == .usize;
}

/// Names a `usize` that plausibly carries a byte count. Matched
/// case-insensitively, either on its own (`n`, `len`) or as the last word of a
/// compound (`data_len`, `outSize`) — never as a bare suffix, so `token` is
/// not read as an `n`.
const length_words = [_][]const u8{
    "len", "length", "size", "count", "n", "nbytes", "cap", "capacity",
};

fn looksLikeLength(name: []const u8) bool {
    if (name.len == 0) return false;
    for (length_words) |w| {
        if (name.len < w.len) continue;
        if (!std.ascii.eqlIgnoreCase(name[name.len - w.len ..], w)) continue;
        if (name.len == w.len) return true;
        const boundary = name[name.len - w.len - 1];
        const word_start = name[name.len - w.len];
        if (boundary == '_') return true;
        // camelCase boundary: `outSize`, but not the tail of `TOKEN`.
        if (std.ascii.isUpper(word_start) and !std.ascii.isUpper(boundary)) return true;
    }
    return false;
}

fn paramLabel(arena: std.mem.Allocator, p: ir.Param, index: usize) ![]const u8 {
    if (p.name.len == 0 or std.mem.eql(u8, p.name, "_")) {
        return std.fmt.allocPrint(arena, "#{d}", .{index});
    }
    return std.fmt.allocPrint(arena, "'{s}'", .{p.name});
}

fn declaredHandles(arena: std.mem.Allocator, api: ir.Api, cache: *?[]const u8) ![]const u8 {
    if (cache.*) |c| return c;
    const text = blk: {
        if (api.handles.len == 0) break :blk "no `opaque {}` types are declared in this file";
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        try out.writer.writeAll("declared handles: ");
        for (api.handles, 0..) |h, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(h.name);
        }
        break :blk try arena.dupe(u8, out.written());
    };
    cache.* = text;
    return text;
}

// ---------------------------------------------------------------------------
// Rule 6: generated names
// ---------------------------------------------------------------------------

fn checkNames(arena: std.mem.Allocator, api: ir.Api, diags: *diag.List) !void {
    const go = try arena.alloc([]const u8, api.functions.len);
    const py = try arena.alloc([]const u8, api.functions.len);

    for (api.functions, 0..) |f, i| {
        const base = names.stripPrefix(f.name, api.lib_name);
        go[i] = try names.toPascal(arena, base);
        py[i] = try names.toSnake(arena, base);

        if (names.isGoKeyword(go[i])) {
            try diags.errHint(f.loc, rename_one_hint, "'{s}' generates the Go name '{s}', which is a Go keyword", .{ f.name, go[i] });
        }
        if (names.isPythonKeyword(py[i])) {
            try diags.errHint(f.loc, rename_one_hint, "'{s}' generates the Python name '{s}', which is a Python keyword", .{ f.name, py[i] });
        }
    }

    for (api.functions, 0..) |f, i| {
        for (api.functions[i + 1 ..], i + 1..) |g, j| {
            if (std.mem.eql(u8, go[i], go[j])) {
                try diags.errHint(g.loc, rename_fn_hint, "'{s}' and '{s}' both generate the Go method name '{s}'", .{ f.name, g.name, go[j] });
            }
            if (std.mem.eql(u8, py[i], py[j])) {
                try diags.errHint(g.loc, rename_fn_hint, "'{s}' and '{s}' both generate the Python method name '{s}'", .{ f.name, g.name, py[j] });
            }
        }
    }

    // A handle becomes a package-scope type in Go and a module-scope class in
    // Python. `go.zig` names the type `toPascal(handle)`; `python.zig` names
    // the class `toPascal(toSnake(handle))`, which differs for a handle that
    // was already Pascal-cased in Zig.
    const go_ty = try arena.alloc([]const u8, api.handles.len);
    const py_cls = try arena.alloc([]const u8, api.handles.len);
    for (api.handles, 0..) |h, i| {
        go_ty[i] = try names.toPascal(arena, h.name);
        py_cls[i] = try names.toPascal(arena, try names.toSnake(arena, h.name));

        if (names.isGoKeyword(go_ty[i])) {
            try diags.errHint(h.loc, rename_handle_hint, "handle '{s}' generates the Go name '{s}', which is a Go keyword", .{ h.name, go_ty[i] });
        }
        if (names.isPythonKeyword(py_cls[i])) {
            try diags.errHint(h.loc, rename_handle_hint, "handle '{s}' generates the Python name '{s}', which is a Python keyword", .{ h.name, py_cls[i] });
        }
    }

    // Two handles that differ only in case converge on one type name.
    for (api.handles, 0..) |h, i| {
        for (api.handles[i + 1 ..], i + 1..) |g, j| {
            if (std.mem.eql(u8, go_ty[i], go_ty[j])) {
                try diags.errHint(g.loc, rename_handles_hint, "handles '{s}' and '{s}' both generate the Go type name '{s}'", .{ h.name, g.name, go_ty[j] });
            }
            if (std.mem.eql(u8, py_cls[i], py_cls[j])) {
                try diags.errHint(g.loc, rename_handles_hint, "handles '{s}' and '{s}' both generate the Python class name '{s}'", .{ h.name, g.name, py_cls[j] });
            }
        }
    }

    // A function that is not emitted as a method lands next to those types at
    // package/module scope, where the two declarations collide.
    const lc = try ir.lifecycle(arena, api);
    for (api.functions, 0..) |f, fi| {
        const scope = declScope(api, lc, fi);
        for (api.handles, 0..) |h, hi| {
            if (scope.go_package and std.mem.eql(u8, go[fi], go_ty[hi])) {
                try diags.errHint(f.loc, rename_either_hint, "'{s}' generates the Go name '{s}', which is also the Go type generated for handle '{s}'", .{ f.name, go[fi], h.name });
            }
            if (scope.py_module and std.mem.eql(u8, py[fi], py_cls[hi])) {
                try diags.errHint(f.loc, rename_either_hint, "'{s}' generates the Python name '{s}', which is also the Python class generated for handle '{s}'", .{ f.name, py[fi], h.name });
            }
        }
    }
}

/// Where a function's generated declaration lives. Mirrors the classification
/// in `gen/go.zig` and `gen/python.zig`: only a declaration at package (Go) or
/// module (Python) scope can collide with a handle's type name — a method sits
/// inside the type's own namespace, and the folded destructor is not emitted
/// at all. Go emits a constructor as a package-scope function; Python emits it
/// as a classmethod, so the two scopes are tracked separately.
const DeclScope = struct { go_package: bool, py_module: bool };

fn declScope(api: ir.Api, lc: ir.Lifecycle, fi: usize) DeclScope {
    for (api.handles, 0..) |_, hi| {
        for (lc.ctors[hi]) |ci| {
            if (ci == fi) return .{ .go_package = true, .py_module = false };
        }
    }
    for (api.handles, 0..) |_, hi| {
        for (lc.dtors[hi]) |di| {
            // The single destructor is folded into Close()/close(); several
            // candidates each become a consuming method. Neither is package
            // scope.
            if (di == fi) return .{ .go_package = false, .py_module = false };
        }
    }
    const f = api.functions[fi];
    if (f.params.len > 0 and f.params[0].ty == .handle and
        api.findHandle(f.params[0].ty.handle.name) != null)
    {
        return .{ .go_package = false, .py_module = false };
    }
    return .{ .go_package = true, .py_module = true };
}

// ---------------------------------------------------------------------------
// Rule 8: lifecycle conventions (D7) — warnings only, never errors, because
// a library with no destructor is awkward to use but still portable.
// ---------------------------------------------------------------------------

fn checkLifecycle(arena: std.mem.Allocator, api: ir.Api, diags: *diag.List) !void {
    const lc = try ir.lifecycle(arena, api);

    for (api.handles, 0..) |h, hi| {
        const dtors = lc.dtors[hi];
        if (dtors.len == 0) {
            try diags.add(.warning, h.loc, dtor_hint, "handle '{s}' has no destructor; the generated binding cannot free it", .{h.name});
        } else if (dtors.len > 1) {
            var list: std.Io.Writer.Allocating = .init(arena);
            defer list.deinit();
            for (dtors, 0..) |fi, i| {
                if (i > 0) try list.writer.writeAll(", ");
                try list.writer.print("'{s}'", .{api.functions[fi].name});
            }
            try diags.warn(h.loc, "handle '{s}' has {d} destructor candidates ({s}); zbridge cannot tell which is the destructor, so Close()/close() will not call one; each is emitted as a method that consumes the handle", .{
                h.name,
                dtors.len,
                list.written(),
            });
        }

        if (!isReturnedAnywhere(api, h.name)) {
            try diags.warn(h.loc, "handle '{s}' is not returned by any export fn; it cannot be constructed through the generated binding", .{h.name});
        }
    }

    if (api.lib_name.len != 0) {
        for (api.functions) |f| {
            if (std.mem.startsWith(u8, f.name, api.lib_name)) continue;
            const method = try names.toPascal(arena, names.stripPrefix(f.name, api.lib_name));
            try diags.warn(f.loc, "export fn '{s}' does not start with the library prefix '{s}'; it will generate the method name '{s}'", .{
                f.name,
                api.lib_name,
                method,
            });
        }
    }
}

fn isReturnedAnywhere(api: ir.Api, handle_name: []const u8) bool {
    for (api.functions) |f| {
        if (f.ret == .handle and std.mem.eql(u8, f.ret.handle.name, handle_name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Rule 9: the validator and `ir.lower` must agree
// ---------------------------------------------------------------------------

/// A `lower` failure on a function this validator did not complain about would
/// mean a generator silently drops it. Surface it as a hard error instead.
fn checkLowerable(arena: std.mem.Allocator, api: ir.Api, reported: []const bool) !void {
    for (api.functions, 0..) |f, i| {
        if (reported[i]) continue;
        _ = try ir.lower(arena, f);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn int(k: ir.IntKind) ir.Type {
    return .{ .scalar = .{ .int = k } };
}

fn handleTy(name: []const u8, optional: bool) ir.Type {
    return .{ .handle = .{ .name = name, .optional = optional, .is_const = false } };
}

fn bytes(is_const: bool) ir.Type {
    return .{ .many_u8 = .{ .is_const = is_const, .sentinel_zero = false } };
}

fn cstr(is_const: bool) ir.Type {
    return .{ .many_u8 = .{ .is_const = is_const, .sentinel_zero = true } };
}

fn render(arena: std.mem.Allocator, api: ir.Api) ![]const u8 {
    var diags: diag.List = .init(arena, "src/c_api.zig");
    try validate(arena, api, &diags);
    diags.sort();
    return diags.toString(arena);
}

fn countErrors(arena: std.mem.Allocator, api: ir.Api) !usize {
    var diags: diag.List = .init(arena, "src/c_api.zig");
    try validate(arena, api, &diags);
    return diags.errorCount();
}

test "rule 0: only the C calling convention can be called through a binding" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{ .name = "zc_bare", .ret = .void, .params = &.{}, .loc = .{ .line = 2, .column = 1 } },
            .{ .name = "zc_c", .ret = .void, .params = &.{}, .callconv_src = ".c", .loc = .{ .line = 4, .column = 1 } },
            .{ .name = "zc_wrapped", .ret = .void, .params = &.{}, .callconv_src = "callconv(.c)", .loc = .{ .line = 6, .column = 1 } },
            .{ .name = "zc_qualified", .ret = .void, .params = &.{}, .callconv_src = "std.builtin.CallingConvention.c", .loc = .{ .line = 8, .column = 1 } },
            // Rejected by the 0.16 compiler for its spelling; accepted here so
            // the convention is not what the user gets blamed for.
            .{ .name = "zc_old", .ret = .void, .params = &.{}, .callconv_src = ".C", .loc = .{ .line = 10, .column = 1 } },
            .{ .name = "zc_naked", .ret = .void, .params = &.{}, .callconv_src = ".naked", .loc = .{ .line = 12, .column = 1 } },
            .{ .name = "zc_vfabi", .ret = .void, .params = &.{}, .callconv_src = "callconv(.aarch64_vfabi)", .loc = .{ .line = 14, .column = 1 } },
            .{ .name = "zc_irq", .ret = .void, .params = &.{}, .callconv_src = ".{ .x86_64_interrupt = .{} }", .loc = .{ .line = 16, .column = 1 } },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:12:1: error: zc_naked: calling convention `.naked` is not the C calling convention; a generated binding can only call `callconv(.c)`
        \\    note: an `export fn` defaults to the C calling convention; drop the `callconv` or write `callconv(.c)`
        \\src/c_api.zig:14:1: error: zc_vfabi: calling convention `.aarch64_vfabi` is not the C calling convention; a generated binding can only call `callconv(.c)`
        \\    note: an `export fn` defaults to the C calling convention; drop the `callconv` or write `callconv(.c)`
        \\src/c_api.zig:16:1: error: zc_irq: calling convention `.{ .x86_64_interrupt = .{} }` is not the C calling convention; a generated binding can only call `callconv(.c)`
        \\    note: an `export fn` defaults to the C calling convention; drop the `callconv` or write `callconv(.c)`
        \\
    , try render(arena, api));
    try testing.expect(!isPortable(api));
}

test "rule 1: c_char is rejected wherever it appears" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{
                .name = "zc_put",
                .ret = .void,
                .loc = .{ .line = 2, .column = 1 },
                .params = &.{
                    .{ .name = "ch", .ty = int(.c_char), .loc = .{ .line = 2, .column = 18 } },
                    .{ .name = "out", .ty = .{ .out_ptr = .{ .child = .{ .int = .c_char }, .optional = false } }, .loc = .{ .line = 2, .column = 32 } },
                },
            },
            .{ .name = "zc_peek", .ret = int(.c_char), .params = &.{}, .loc = .{ .line = 4, .column = 1 } },
            // Every other C integer type stays in the allowlist.
            .{
                .name = "zc_ok",
                .ret = int(.c_int),
                .loc = .{ .line = 6, .column = 1 },
                .params = &.{.{ .name = "n", .ty = int(.c_long), .loc = .{ .line = 6, .column = 17 } }},
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:18: error: zc_put: parameter 'ch' has type 'c_char', whose signedness depends on the target
        \\    note: write `u8` or `i8`: C `char` is unsigned on aarch64 and signed on x86_64, both of which zbridge builds for, so `c_char` would mean two different things in one binding
        \\src/c_api.zig:2:32: error: zc_put: parameter 'out' has type '*c_char', whose signedness depends on the target
        \\    note: write `u8` or `i8`: C `char` is unsigned on aarch64 and signed on x86_64, both of which zbridge builds for, so `c_char` would mean two different things in one binding
        \\src/c_api.zig:4:1: error: zc_peek: return type 'c_char' uses `c_char`, whose signedness depends on the target
        \\    note: write `u8` or `i8`: C `char` is unsigned on aarch64 and signed on x86_64, both of which zbridge builds for, so `c_char` would mean two different things in one binding
        \\
    , try render(arena, api));
    try testing.expect(!isPortable(api));
}

test "rule 5: a package-scope function collides with a handle type" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `const Ctx = opaque {};` plus `export fn zc_ctx(n: u32) u32` generates
    // both `type Ctx struct` and `func Ctx(...)` in one Go package.
    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx", .loc = .{ .line = 2, .column = 1 } }},
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = handleTy("Ctx", true), .params = &.{}, .loc = .{ .line = 4, .column = 1 } },
            .{
                .name = "zc_ctx_destroy",
                .ret = .void,
                .loc = .{ .line = 6, .column = 1 },
                .params = &.{.{ .name = "c", .ty = handleTy("Ctx", false) }},
            },
            .{
                .name = "zc_ctx",
                .ret = int(.u32),
                .loc = .{ .line = 8, .column = 1 },
                .params = &.{.{ .name = "n", .ty = int(.u32) }},
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:8:1: error: 'zc_ctx' generates the Go name 'Ctx', which is also the Go type generated for handle 'Ctx'
        \\    note: rename the `export fn` or the `opaque {}` declaration
        \\
    , try render(arena, api));
    try testing.expect(!isPortable(api));
}

test "rule 5: a method named after its own handle is not a collision" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `func (c *Ctx) Ctx()` lives in the type's namespace, not the package's.
    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx", .loc = .{ .line = 2, .column = 1 } }},
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = handleTy("Ctx", true), .params = &.{}, .loc = .{ .line = 4, .column = 1 } },
            .{
                .name = "zc_ctx_destroy",
                .ret = .void,
                .loc = .{ .line = 6, .column = 1 },
                .params = &.{.{ .name = "c", .ty = handleTy("Ctx", false) }},
            },
            .{
                .name = "zc_ctx",
                .ret = int(.u32),
                .loc = .{ .line = 8, .column = 1 },
                .params = &.{.{ .name = "c", .ty = handleTy("Ctx", false) }},
            },
        },
    };

    try testing.expectEqualStrings("", try render(arena, api));
}

test "rule 5: two handles that differ only in case" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{
            .{ .name = "foo_bar", .loc = .{ .line = 2, .column = 1 } },
            .{ .name = "FooBar", .loc = .{ .line = 3, .column = 1 } },
        },
        .functions = &.{
            .{ .name = "zc_tick", .ret = .void, .params = &.{}, .loc = .{ .line = 5, .column = 1 } },
        },
    };

    const text = try render(arena, api);
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        "error: handles 'foo_bar' and 'FooBar' both generate the Go type name 'FooBar'",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        "error: handles 'foo_bar' and 'FooBar' both generate the Python class name 'FooBar'",
    ) != null);
    try testing.expectEqual(@as(usize, 2), try countErrors(arena, api));
}

test "rule 3: a length parameter whose name is not a length warns" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{
                .name = "zc_at",
                .ret = int(.u8),
                .loc = .{ .line = 2, .column = 1 },
                .params = &.{
                    .{ .name = "buf", .ty = bytes(true), .loc = .{ .line = 2, .column = 18 } },
                    .{ .name = "index", .ty = int(.usize), .loc = .{ .line = 2, .column = 36 } },
                },
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:36: warning: zc_at: parameter 'index' follows 'buf' of type '[*]const u8', so zbridge is treating it as that buffer's length; its name does not look like one
        \\    note: a `ptr, len` pair is positional: name the length after its buffer (`data_len`), or move the parameter if it is not one
        \\
    , try render(arena, api));
    // A warning, never an error: the positional rule still stands.
    try testing.expect(isPortable(api));
}

test "rule 3: names that read as a length produce no warning" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (.{ "len", "LENGTH", "size", "count", "n", "nbytes", "cap", "capacity", "data_len", "out_size", "outSize" }) |name| {
        const api: ir.Api = .{
            .lib_name = "zc",
            .handles = &.{},
            .functions = &.{
                .{
                    .name = "zc_put",
                    .ret = .void,
                    .loc = .{ .line = 2, .column = 1 },
                    .params = &.{
                        .{ .name = "data", .ty = bytes(true), .loc = .{ .line = 2, .column = 18 } },
                        .{ .name = name, .ty = int(.usize), .loc = .{ .line = 2, .column = 36 } },
                    },
                },
            },
        };
        try testing.expectEqualStrings("", try render(arena, api));
    }

    // Not lengths: a bare suffix match must not count.
    try testing.expect(!looksLikeLength("token"));
    try testing.expect(!looksLikeLength("index"));
    try testing.expect(!looksLikeLength(""));
    try testing.expect(looksLikeLength("N"));
}

test "rule 1: unsupported parameter and return types" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{
                .name = "zc_open",
                .ret = .void,
                .loc = .{ .line = 3, .column = 1 },
                .params = &.{
                    .{ .name = "opts", .ty = .{ .unsupported = "Options" }, .loc = .{ .line = 3, .column = 15 } },
                },
            },
            .{ .name = "zc_get", .ret = .{ .unsupported = "!u32" }, .params = &.{}, .loc = .{ .line = 5, .column = 1 } },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:3:15: error: zc_open: parameter 'opts' has unsupported type 'Options'
        \\    note: expose a narrower `export fn` shim that takes ABI-safe types
        \\src/c_api.zig:5:1: error: zc_get: return type '!u32' is not supported
        \\    note: expose a narrower `export fn` shim that takes ABI-safe types
        \\
    , try render(arena, api));
}

test "rule 2: a void parameter" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{
                .name = "zc_tick",
                .ret = .void,
                .loc = .{ .line = 2, .column = 1 },
                .params = &.{.{ .name = "nothing", .ty = .void, .loc = .{ .line = 2, .column = 18 } }},
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:18: error: zc_tick: parameter 'nothing' has type 'void', which cannot be passed across the C ABI
        \\
    , try render(arena, api));
}

test "rule 3: buffer pairing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            // No length parameter at all.
            .{
                .name = "zc_write",
                .ret = .void,
                .loc = .{ .line = 2, .column = 1 },
                .params = &.{.{ .name = "data", .ty = bytes(true), .loc = .{ .line = 2, .column = 20 } }},
            },
            // A length parameter of the wrong type.
            .{
                .name = "zc_put",
                .ret = .void,
                .loc = .{ .line = 4, .column = 1 },
                .params = &.{
                    .{ .name = "data", .ty = bytes(true), .loc = .{ .line = 4, .column = 18 } },
                    .{ .name = "n", .ty = int(.u32), .loc = .{ .line = 4, .column = 40 } },
                },
            },
            // Writable sentinel pointer: no knowable capacity.
            .{
                .name = "zc_name",
                .ret = .void,
                .loc = .{ .line = 6, .column = 1 },
                .params = &.{.{ .name = "buf", .ty = cstr(false), .loc = .{ .line = 6, .column = 19 } }},
            },
            // Legal: a const sentinel pointer needs no length.
            .{
                .name = "zc_label",
                .ret = .void,
                .loc = .{ .line = 8, .column = 1 },
                .params = &.{.{ .name = "text", .ty = cstr(true), .loc = .{ .line = 8, .column = 20 } }},
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:20: error: zc_write: parameter 'data' of type '[*]const u8' must be immediately followed by a `usize` length parameter
        \\    note: byte buffers cross the boundary as a `ptr, len` pair: `data: [*]const u8, data_len: usize`
        \\src/c_api.zig:4:18: error: zc_put: parameter 'data' of type '[*]const u8' must be immediately followed by a `usize` length parameter
        \\    note: byte buffers cross the boundary as a `ptr, len` pair: `data: [*]const u8, data_len: usize`
        \\src/c_api.zig:6:19: error: zc_name: parameter 'buf' has type '[*:0]u8'; a writable buffer has no knowable capacity
        \\    note: use `[*]u8` followed by a `usize` capacity parameter
        \\
    , try render(arena, api));
}

test "rule 4: a pointer as the return type" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{ .name = "zc_take", .ret = bytes(false), .params = &.{}, .loc = .{ .line = 2, .column = 1 } },
            .{
                .name = "zc_slot",
                .ret = .{ .out_ptr = .{ .child = .{ .int = .u32 }, .optional = false } },
                .params = &.{},
                .loc = .{ .line = 4, .column = 1 },
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:1: error: zc_take: returns '[*]u8'; ownership of a pointer cannot cross the boundary
        \\    note: return bytes through a caller-allocated `[*]u8, usize` out-parameter pair, or return an opaque handle
        \\src/c_api.zig:4:1: error: zc_slot: returns '*u32'; ownership of a pointer cannot cross the boundary
        \\    note: return bytes through a caller-allocated `[*]u8, usize` out-parameter pair, or return an opaque handle
        \\
    , try render(arena, api));
}

test "rule 5: a handle that is not declared in this file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx", .loc = .{ .line = 2, .column = 1 } }},
        .functions = &.{
            .{
                .name = "zc_use",
                .ret = .void,
                .loc = .{ .line = 4, .column = 1 },
                .params = &.{.{ .name = "d", .ty = handleTy("Doc", false), .loc = .{ .line = 4, .column = 18 } }},
            },
            .{ .name = "zc_doc_new", .ret = handleTy("Doc", true), .params = &.{}, .loc = .{ .line = 6, .column = 1 } },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:1: warning: handle 'Ctx' has no destructor; the generated binding cannot free it
        \\    note: a destructor is an `export fn` returning void, taking one `*Handle`, whose name ends in _destroy, _free, _deinit, _close or _release
        \\src/c_api.zig:2:1: warning: handle 'Ctx' is not returned by any export fn; it cannot be constructed through the generated binding
        \\src/c_api.zig:4:18: error: zc_use: parameter 'd' references opaque type 'Doc', which is not declared in this file
        \\    note: declared handles: Ctx
        \\src/c_api.zig:6:1: error: zc_doc_new: return type references opaque type 'Doc', which is not declared in this file
        \\    note: declared handles: Ctx
        \\
    , try render(arena, api));
}

test "rule 5: hint when no handles are declared at all" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{
                .name = "zc_use",
                .ret = .void,
                .loc = .{ .line = 2, .column = 1 },
                .params = &.{.{ .name = "c", .ty = handleTy("Ctx", false), .loc = .{ .line = 2, .column = 18 } }},
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:18: error: zc_use: parameter 'c' references opaque type 'Ctx', which is not declared in this file
        \\    note: no `opaque {}` types are declared in this file
        \\
    , try render(arena, api));
}

test "rule 6: generated method names collide" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{ .name = "zc_read_all", .ret = .void, .params = &.{}, .loc = .{ .line = 2, .column = 1 } },
            .{ .name = "zc_readAll", .ret = .void, .params = &.{}, .loc = .{ .line = 4, .column = 1 } },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:4:1: error: 'zc_read_all' and 'zc_readAll' both generate the Go method name 'ReadAll'
        \\    note: rename one of the `export fn`s
        \\src/c_api.zig:4:1: error: 'zc_read_all' and 'zc_readAll' both generate the Python method name 'read_all'
        \\    note: rename one of the `export fn`s
        \\
    , try render(arena, api));
}

test "rule 6: generated names that are target-language keywords" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "None", .loc = .{ .line = 2, .column = 1 } }},
        .functions = &.{
            .{ .name = "zc_class", .ret = .void, .params = &.{}, .loc = .{ .line = 4, .column = 1 } },
            .{ .name = "zc_none_new", .ret = handleTy("None", true), .params = &.{}, .loc = .{ .line = 6, .column = 1 } },
            .{
                .name = "zc_none_free",
                .ret = .void,
                .loc = .{ .line = 8, .column = 1 },
                .params = &.{.{ .name = "n", .ty = handleTy("None", false), .loc = .{ .line = 8, .column = 24 } }},
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:1: error: handle 'None' generates the Python name 'None', which is a Python keyword
        \\    note: rename the `opaque {}` declaration
        \\src/c_api.zig:4:1: error: 'zc_class' generates the Python name 'class', which is a Python keyword
        \\    note: rename the `export fn`
        \\
    , try render(arena, api));
}

test "rule 7: an empty API" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{ .lib_name = "zc", .handles = &.{}, .functions = &.{} };

    try testing.expectEqualStrings(
        \\src/c_api.zig:0:0: error: no `export fn` declarations found; nothing to port
        \\
    , try render(arena, api));
}

test "rule 8: lifecycle and prefix warnings are never errors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{
            .{ .name = "Ctx", .loc = .{ .line = 2, .column = 1 } },
            .{ .name = "Doc", .loc = .{ .line = 3, .column = 1 } },
        },
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = handleTy("Ctx", true), .params = &.{}, .loc = .{ .line = 5, .column = 1 } },
            .{
                .name = "zc_ctx_free",
                .ret = .void,
                .loc = .{ .line = 7, .column = 1 },
                .params = &.{.{ .name = "c", .ty = handleTy("Ctx", false), .loc = .{ .line = 7, .column = 23 } }},
            },
            .{
                .name = "zc_ctx_close",
                .ret = .void,
                .loc = .{ .line = 9, .column = 1 },
                .params = &.{.{ .name = "c", .ty = handleTy("Ctx", false), .loc = .{ .line = 9, .column = 24 } }},
            },
            .{
                .name = "zc_doc_render",
                .ret = .void,
                .loc = .{ .line = 11, .column = 1 },
                .params = &.{.{ .name = "d", .ty = handleTy("Doc", false), .loc = .{ .line = 11, .column = 25 } }},
            },
            .{ .name = "other_helper", .ret = int(.i32), .params = &.{}, .loc = .{ .line = 13, .column = 1 } },
        },
    };

    var diags: diag.List = .init(arena, "src/c_api.zig");
    try validate(arena, api, &diags);
    diags.sort();

    try testing.expectEqual(@as(usize, 0), diags.errorCount());
    try testing.expectEqualStrings(
        \\src/c_api.zig:2:1: warning: handle 'Ctx' has 2 destructor candidates ('zc_ctx_free', 'zc_ctx_close'); zbridge cannot tell which is the destructor, so Close()/close() will not call one; each is emitted as a method that consumes the handle
        \\src/c_api.zig:3:1: warning: handle 'Doc' has no destructor; the generated binding cannot free it
        \\    note: a destructor is an `export fn` returning void, taking one `*Handle`, whose name ends in _destroy, _free, _deinit, _close or _release
        \\src/c_api.zig:3:1: warning: handle 'Doc' is not returned by any export fn; it cannot be constructed through the generated binding
        \\src/c_api.zig:13:1: warning: export fn 'other_helper' does not start with the library prefix 'zc'; it will generate the method name 'OtherHelper'
        \\
    , try diags.toString(arena));
    try testing.expect(isPortable(api));
}

/// A container-scope constant, not a function: `&.{...}` inside a function
/// body would hand back pointers into that function's frame.
const valid_api: ir.Api = .{
    .lib_name = "zc",
    .handles = &.{.{ .name = "Ctx", .loc = .{ .line = 2, .column = 1 } }},
    .functions = &.{
        .{ .name = "zc_ctx_new", .ret = handleTy("Ctx", true), .params = &.{}, .loc = .{ .line = 4, .column = 1 } },
        .{
            .name = "zc_ctx_destroy",
            .ret = .void,
            .loc = .{ .line = 6, .column = 1 },
            .params = &.{.{ .name = "ctx", .ty = handleTy("Ctx", false) }},
        },
        .{
            .name = "zc_feed",
            .ret = int(.i32),
            .loc = .{ .line = 8, .column = 1 },
            .params = &.{
                .{ .name = "ctx", .ty = handleTy("Ctx", false) },
                .{ .name = "data", .ty = bytes(true) },
                .{ .name = "data_len", .ty = int(.usize) },
            },
        },
        .{
            .name = "zc_drain",
            .ret = int(.i32),
            .loc = .{ .line = 10, .column = 1 },
            .params = &.{
                .{ .name = "ctx", .ty = handleTy("Ctx", false) },
                .{ .name = "out", .ty = bytes(false) },
                .{ .name = "out_len", .ty = int(.usize) },
            },
        },
        .{
            .name = "zc_open_path",
            .ret = .{ .scalar = .bool },
            .loc = .{ .line = 12, .column = 1 },
            .params = &.{
                .{ .name = "ctx", .ty = handleTy("Ctx", false) },
                .{ .name = "path", .ty = cstr(true) },
            },
        },
        .{
            .name = "zc_count",
            .ret = .void,
            .loc = .{ .line = 14, .column = 1 },
            .params = &.{
                .{ .name = "ctx", .ty = handleTy("Ctx", false) },
                .{ .name = "out_n", .ty = .{ .out_ptr = .{ .child = .{ .int = .u64 }, .optional = false } } },
            },
        },
    },
};

test "a fully valid API produces no diagnostics at all" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = valid_api;
    try testing.expectEqualStrings("", try render(arena, api));
    try testing.expect(isPortable(api));
}

test "rule 9: lower never fails on an API the validator accepts" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = valid_api;
    // `validate` itself re-lowers every clean function and propagates the
    // error; calling it with `try` is the assertion.
    var diags: diag.List = .init(arena, "src/c_api.zig");
    try validate(arena, api, &diags);
    try testing.expectEqual(@as(usize, 0), diags.items.items.len);

    for (api.functions) |f| {
        const logical = try ir.lower(arena, f);
        try testing.expect(logical.len <= f.params.len);
    }
}

test "every unsupported function is reported in a single pass" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{
                .name = "zc_one",
                .ret = .void,
                .loc = .{ .line = 2, .column = 1 },
                .params = &.{.{ .name = "s", .ty = .{ .unsupported = "Options" }, .loc = .{ .line = 2, .column = 16 } }},
            },
            .{
                .name = "zc_two",
                .ret = .void,
                .loc = .{ .line = 4, .column = 1 },
                .params = &.{.{ .name = "d", .ty = bytes(true), .loc = .{ .line = 4, .column = 16 } }},
            },
            .{ .name = "zc_three", .ret = .{ .unsupported = "anyerror!void" }, .params = &.{}, .loc = .{ .line = 6, .column = 1 } },
        },
    };

    try testing.expectEqual(@as(usize, 3), try countErrors(arena, api));

    const text = try render(arena, api);
    try testing.expect(std.mem.indexOf(u8, text, "zc_one") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zc_two") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zc_three") != null);
    try testing.expect(!isPortable(api));
}

test "an unnamed parameter is reported by position" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{
                .name = "zc_go",
                .ret = .void,
                .loc = .{ .line = 2, .column = 1 },
                .params = &.{
                    .{ .name = "n", .ty = int(.u32), .loc = .{ .line = 2, .column = 15 } },
                    .{ .name = "_", .ty = .{ .unsupported = "Options" }, .loc = .{ .line = 2, .column = 24 } },
                },
            },
        },
    };

    try testing.expectEqualStrings(
        \\src/c_api.zig:2:24: error: zc_go: parameter #1 has unsupported type 'Options'
        \\    note: expose a narrower `export fn` shim that takes ABI-safe types
        \\
    , try render(arena, api));
}

test "consecutive buffer pairs are accepted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{
                .name = "zc_copy",
                .ret = int(.i32),
                .loc = .{ .line = 2, .column = 1 },
                .params = &.{
                    .{ .name = "src", .ty = bytes(true) },
                    .{ .name = "src_len", .ty = int(.usize) },
                    .{ .name = "dst", .ty = bytes(false) },
                    .{ .name = "dst_len", .ty = int(.usize) },
                },
            },
        },
    };

    try testing.expectEqualStrings("", try render(arena, api));
}
