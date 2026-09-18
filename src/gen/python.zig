//! The Python generator.
//!
//! Emits six files under the Python output root (`<pkg>` is
//! `ctx.pythonPackage()`):
//!
//!   pyproject.toml        user scaffold, written once
//!   <pkg>/__init__.py     user scaffold, written once
//!   <pkg>/py.typed        marker so type checkers trust the hints
//!   <pkg>/_loader_gen.py  platform detection, CDLL, ABI check
//!   <pkg>/_ffi_gen.py     argtypes/restype, one block per export fn
//!   <pkg>/_gen.py         the idiomatic layer: classes, methods, buffers
//!
//! The compiled binaries live at `<pkg>/_native/<target id>/<lib file>` and are
//! put there by the build step, not by this file. Both the loader table and the
//! build step read those names from `core/targets.zig`, so they cannot drift.

const std = @import("std");
const gen = @import("context.zig");
const ir = @import("../core/ir.zig");
const names = @import("names.zig");
const targets = @import("../core/targets.zig");
const CodeWriter = @import("writer.zig").CodeWriter;

const loader_template = @embedFile("../templates/loader.py.tmpl");

/// Four spaces, per PEP 8.
const unit = "    ";

pub fn generate(arena: std.mem.Allocator, ctx: gen.Context, files: *gen.FileList) !void {
    const pkg = ctx.pythonPackage();

    if (ctx.python.emit_pyproject) {
        try files.append(arena, .{
            .lang = .python,
            .path = "pyproject.toml",
            .bytes = try renderPyproject(arena, ctx),
            .tier = .user_scaffold,
        });
    }

    try files.append(arena, .{
        .lang = .python,
        .path = try pkgPath(arena, pkg, "__init__.py"),
        .bytes = try renderInit(arena, ctx),
        .tier = .user_scaffold,
    });

    try files.append(arena, .{
        .lang = .python,
        .path = try pkgPath(arena, pkg, "py.typed"),
        .bytes = "",
        .tier = .generated,
    });

    try files.append(arena, .{
        .lang = .python,
        .path = try pkgPath(arena, pkg, "_loader_gen.py"),
        .bytes = try renderLoader(arena, ctx),
        .tier = .generated,
    });

    try files.append(arena, .{
        .lang = .python,
        .path = try pkgPath(arena, pkg, "_ffi_gen.py"),
        .bytes = try renderFfi(arena, ctx),
        .tier = .generated,
    });

    try files.append(arena, .{
        .lang = .python,
        .path = try pkgPath(arena, pkg, "_gen.py"),
        .bytes = try renderIdiomatic(arena, ctx),
        .tier = .generated,
    });
}

fn pkgPath(arena: std.mem.Allocator, pkg: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ pkg, name });
}

// ---------------------------------------------------------------------------
// Type mapping
// ---------------------------------------------------------------------------

fn ctypesScalar(s: ir.Scalar) []const u8 {
    return switch (s) {
        .bool => "ctypes.c_bool",
        .float => |f| switch (f) {
            .f32 => "ctypes.c_float",
            .f64 => "ctypes.c_double",
        },
        .int => |k| switch (k) {
            .u8 => "ctypes.c_uint8",
            .u16 => "ctypes.c_uint16",
            .u32 => "ctypes.c_uint32",
            .u64 => "ctypes.c_uint64",
            .i8 => "ctypes.c_int8",
            .i16 => "ctypes.c_int16",
            .i32 => "ctypes.c_int32",
            .i64 => "ctypes.c_int64",
            .usize => "ctypes.c_size_t",
            .isize => "ctypes.c_ssize_t",
            .c_char => "ctypes.c_char",
            .c_short => "ctypes.c_short",
            .c_ushort => "ctypes.c_ushort",
            .c_int => "ctypes.c_int",
            .c_uint => "ctypes.c_uint",
            .c_long => "ctypes.c_long",
            .c_ulong => "ctypes.c_ulong",
            .c_longlong => "ctypes.c_longlong",
            .c_ulonglong => "ctypes.c_ulonglong",
        },
    };
}

/// The ctypes spelling used in `argtypes` / `restype`.
///
/// Buffers: a const `[*]const u8` becomes `c_char_p`, which accepts a `bytes`
/// object directly with no copy. A mutable `[*]u8` becomes `POINTER(c_char)`
/// instead: both spellings physically accept the `(c_char * n).from_buffer(...)`
/// view the wrapper builds over the caller's `bytearray`, but `c_char_p` also
/// silently accepts an immutable `bytes`, and a callee writing through that
/// pointer would corrupt an object Python believes is frozen. `POINTER(c_char)`
/// states the intent and keeps the two directions distinguishable.
fn ctypesType(arena: std.mem.Allocator, t: ir.Type) ![]const u8 {
    return switch (t) {
        .void => "None",
        .scalar => |s| ctypesScalar(s),
        .handle => "ctypes.c_void_p",
        .many_u8 => |m| if (m.is_const) "ctypes.c_char_p" else "ctypes.POINTER(ctypes.c_char)",
        .out_ptr => |p| std.fmt.allocPrint(arena, "ctypes.POINTER({s})", .{ctypesScalar(p.child)}),
        .unsupported => error.UnsupportedType,
    };
}

fn scalarHint(s: ir.Scalar) []const u8 {
    return switch (s) {
        .bool => "bool",
        .int => "int",
        .float => "float",
    };
}

// ---------------------------------------------------------------------------
// pyproject.toml / __init__.py (user scaffold, no banner: they are the user's)
// ---------------------------------------------------------------------------

fn renderPyproject(arena: std.mem.Allocator, ctx: gen.Context) ![]const u8 {
    const pkg = ctx.pythonPackage();
    const dist = ctx.python.dist_name orelse pkg;
    return std.fmt.allocPrint(arena,
        \\# Written once by zbridge and never regenerated: this file is yours.
        \\[build-system]
        \\requires = ["hatchling"]
        \\build-backend = "hatchling.build"
        \\
        \\[project]
        \\name = "{s}"
        \\version = "0.1.0"
        \\description = "Python bindings for the {s} native library."
        \\requires-python = ">=3.9"
        \\
        \\[tool.hatch.build.targets.wheel]
        \\packages = ["{s}"]
        \\
        \\[tool.hatch.build]
        \\# The native libraries under {s}/_native/<target>/ are build outputs, so
        \\# they are usually gitignored; hatchling skips gitignored files unless
        \\# they are listed here.
        \\artifacts = [
        \\  "{s}/py.typed",
        \\  "{s}/_native/**/*.so",
        \\  "{s}/_native/**/*.dylib",
        \\  "{s}/_native/**/*.dll",
        \\]
        \\
    , .{ dist, ctx.libName(), pkg, pkg, pkg, pkg, pkg, pkg });
}

fn renderInit(arena: std.mem.Allocator, ctx: gen.Context) ![]const u8 {
    const pkg = ctx.pythonPackage();
    return std.fmt.allocPrint(arena,
        \\"""{s} — Python bindings for the {s} native library.
        \\
        \\This file is yours. zbridge writes it once and never regenerates it, so
        \\it is the right place for your own helpers, subclasses and re-exports.
        \\
        \\_gen.py, _ffi_gen.py and _loader_gen.py are rewritten on every run; do
        \\not edit those.
        \\"""
        \\
        \\from ._gen import *  # noqa: F401,F403
        \\from ._gen import __all__ as _generated_all
        \\
        \\__all__ = list(_generated_all)
        \\
    , .{ pkg, ctx.libName() });
}

// ---------------------------------------------------------------------------
// _loader_gen.py
// ---------------------------------------------------------------------------

fn envVarName(arena: std.mem.Allocator, lib_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lib_name) |c| {
        try out.append(arena, if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_');
    }
    try out.appendSlice(arena, "_LIB_PATH");
    return out.toOwnedSlice(arena);
}

fn replaceAll(
    arena: std.mem.Allocator,
    input: []const u8,
    needle: []const u8,
    repl: []const u8,
) ![]const u8 {
    const n = std.mem.count(u8, input, needle);
    if (n == 0) return input;
    const size = input.len - n * needle.len + n * repl.len;
    const buf = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, input, needle, repl, buf);
    return buf;
}

fn renderLoader(arena: std.mem.Allocator, ctx: gen.Context) ![]const u8 {
    var platform_rows: std.Io.Writer.Allocating = .init(arena);
    var libfile_rows: std.Io.Writer.Allocating = .init(arena);

    for (ctx.targets) |t| {
        const nfo = targets.info(t);
        for (nfo.py_machines) |m| {
            try platform_rows.writer.print(
                "{s}(\"{s}\", \"{s}\"): \"{s}\",\n",
                .{ unit, nfo.py_system, m, t.id() },
            );
        }
        try libfile_rows.writer.print(
            "{s}\"{s}\": \"{s}\",\n",
            .{ unit, t.id(), try targets.libFileName(arena, t, ctx.libName()) },
        );
    }

    const abi_fn = try std.fmt.allocPrint(arena, "{s}_zbridge_abi_hash", .{ctx.libName()});

    var body: []const u8 = loader_template;
    body = try replaceAll(arena, body, "@@LIB@@", ctx.libName());
    body = try replaceAll(arena, body, "@@ABI_HASH@@", ctx.abi_hash_hex);
    body = try replaceAll(arena, body, "@@ENV@@", try envVarName(arena, ctx.libName()));
    body = try replaceAll(arena, body, "@@ABI_FN@@", abi_fn);
    body = try replaceAll(arena, body, "@@PLATFORM_ROWS@@", platform_rows.written());
    body = try replaceAll(arena, body, "@@LIBFILE_ROWS@@", libfile_rows.written());

    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ try gen.banner(arena, ctx, "#"), body });
}

// ---------------------------------------------------------------------------
// _ffi_gen.py
// ---------------------------------------------------------------------------

fn zigSignature(arena: std.mem.Allocator, f: ir.Function) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{s}(", .{f.name});
    for (f.params, 0..) |p, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try p.ty.write(&out.writer);
    }
    try out.writer.writeAll(") ");
    try f.ret.write(&out.writer);
    return out.written();
}

fn renderFfi(arena: std.mem.Allocator, ctx: gen.Context) ![]const u8 {
    var w: CodeWriter = .init(arena, unit);

    try w.raw(try gen.banner(arena, ctx, "#"));
    try w.blank();
    try w.raw("\"\"\"ctypes prototypes for every exported function.");
    try w.blank();
    try w.raw("One block per `export fn`, setting argtypes and restype and nothing");
    try w.raw("else. Call the idiomatic layer in _gen.py instead of this module.");
    try w.raw("\"\"\"");
    try w.blank();
    try w.raw("from __future__ import annotations");
    try w.blank();
    try w.raw("import ctypes");
    try w.raw("import threading");
    try w.blank();
    try w.raw("from ._loader_gen import get_lib");
    try w.blank();
    try w.raw("_ffi: ctypes.CDLL | None = None");
    try w.raw("_ffi_lock = threading.Lock()");
    try w.blank();
    try w.blank();
    try w.raw("def get_ffi() -> ctypes.CDLL:");
    w.indent();
    try w.raw("\"\"\"Return the library with every prototype declared on it.");
    try w.blank();
    try w.raw("Bound once, under a lock: an unguarded check-then-set lets two threads");
    try w.raw("each load the library and each run bind() over it, and on a");
    try w.raw("free-threaded build there is no GIL making those steps look atomic.");
    try w.raw("\"\"\"");
    try w.raw("global _ffi");
    try w.raw("ffi = _ffi");
    try w.raw("if ffi is not None:");
    w.indent();
    try w.raw("return ffi");
    w.dedent();
    try w.raw("with _ffi_lock:");
    w.indent();
    try w.raw("if _ffi is None:");
    w.indent();
    try w.raw("lib = get_lib()");
    try w.raw("bind(lib)");
    try w.raw("_ffi = lib");
    w.dedent();
    try w.raw("return _ffi");
    w.dedent();
    w.dedent();
    try w.blank();
    try w.blank();
    try w.raw("def bind(lib: ctypes.CDLL) -> None:");
    w.indent();
    try w.raw("\"\"\"Declare argtypes/restype for every export. Idempotent.\"\"\"");

    if (ctx.api.functions.len == 0) try w.raw("return");

    for (ctx.api.functions) |f| {
        try w.blank();
        try w.line("# {s}", .{try zigSignature(arena, f)});
        try w.line("_fn = lib.{s}", .{f.name});

        var args: std.Io.Writer.Allocating = .init(arena);
        for (f.params, 0..) |p, i| {
            if (i > 0) try args.writer.writeAll(", ");
            try args.writer.writeAll(try ctypesType(arena, p.ty));
        }
        try w.line("_fn.argtypes = [{s}]", .{args.written()});

        if (f.ret == .handle) {
            // The single most expensive default in ctypes: an unset restype is
            // c_int, which truncates a 64-bit pointer to its low 32 bits and
            // hands back a handle that looks plausible and is not.
            try w.raw("# Must be explicit: the ctypes default of c_int would truncate this pointer.");
        }
        try w.line("_fn.restype = {s}", .{try ctypesType(arena, f.ret)});
    }
    w.dedent();

    return w.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// _gen.py — the idiomatic layer
// ---------------------------------------------------------------------------

/// How a function is presented in the idiomatic layer.
///
/// `.dtor` is the unambiguous destructor, folded into `close()` and never
/// emitted on its own. `.consuming` is what a destructor-shaped function
/// becomes when a handle has more than one of them: zbridge cannot tell which
/// is the real destructor, but every one of them frees the handle, so each is
/// emitted as a method that invalidates the instance the way `close()` does.
const Kind = enum { module, method, ctor, dtor, consuming };

const FnPlan = struct {
    kind: Kind = .module,
    /// Index into `api.handles`, meaningful for every kind but `.module`.
    handle: usize = 0,
    /// Python name: toSnake(stripPrefix(fn.name, lib_name)).
    py_name: []const u8 = "",
};

fn handleIndex(api: *const ir.Api, name: []const u8) ?usize {
    for (api.handles, 0..) |h, i| {
        if (std.mem.eql(u8, h.name, name)) return i;
    }
    return null;
}

/// Class name for a handle: `Ctx` stays `Ctx`, `HTTPServer` becomes
/// `HttpServer`, so the spelling never depends on how the Zig side capitalised.
fn className(arena: std.mem.Allocator, handle_name: []const u8) ![]const u8 {
    return names.toPascal(arena, try names.toSnake(arena, handle_name));
}

fn errorClassName(arena: std.mem.Allocator, lib_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}Error", .{try names.toPascal(arena, lib_name)});
}

/// Escape a Zig doc comment so it can sit inside a `"""` docstring.
fn escapeDoc(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const no_backslash = try replaceAll(arena, text, "\\", "\\\\");
    return replaceAll(arena, no_backslash, "\"\"\"", "\\\"\\\"\\\"");
}

/// Emit a `"""..."""` docstring. `note`, when given, is appended as extra
/// paragraphs after the user's own text and forces the multi-line form; it is
/// generator prose, so it is not escaped.
fn emitDocstring(
    arena: std.mem.Allocator,
    w: *CodeWriter,
    doc: ?[]const u8,
    fallback: []const u8,
    note: ?[]const u8,
) !void {
    const raw_text = doc orelse fallback;
    const text = try escapeDoc(arena, std.mem.trim(u8, raw_text, " \t\n"));
    const multiline = std.mem.indexOfScalar(u8, text, '\n') != null;
    if (note == null and !multiline and !std.mem.endsWith(u8, text, "\"")) {
        try w.line("\"\"\"{s}\"\"\"", .{text});
        return;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    const first = it.next().?;
    try w.line("\"\"\"{s}", .{first});
    while (it.next()) |l| try w.raw(std.mem.trimEnd(u8, l, " \t\r"));
    if (note) |n| {
        try w.blank();
        var nit = std.mem.splitScalar(u8, n, '\n');
        while (nit.next()) |l| try w.raw(std.mem.trimEnd(u8, l, " \t\r"));
    }
    try w.raw("\"\"\"");
}

/// One logical argument, rendered into the four places it shows up.
const Arg = struct {
    /// Signature fragment, e.g. `data: bytes | bytearray | memoryview`. Empty
    /// for an out-param, which is not something the caller passes.
    sig: []const u8 = "",
    /// Statement emitted before the call, if any.
    prep: ?[]const u8 = null,
    /// Expression(s) passed at the call site; may be a `ptr, len` pair.
    call: []const u8,
    /// Expression contributing to the return value, for out-params.
    result: ?[]const u8 = null,
    /// Type hint of that result.
    result_hint: []const u8 = "",
};

fn buildArgs(
    arena: std.mem.Allocator,
    ctx: gen.Context,
    f: ir.Function,
    logicals: []const ir.Logical,
    /// When true, the leading handle argument is `self`, not a parameter.
    as_method: bool,
) ![]Arg {
    var out: std.ArrayList(Arg) = .empty;

    for (logicals, 0..) |lg, li| {
        const idx = lg.nameIndex();
        const pname = try names.safeParamName(arena, f.params[idx].name, idx);
        switch (lg) {
            .scalar => |i| {
                const s = f.params[i].ty.scalar;
                try out.append(arena, .{
                    .sig = try std.fmt.allocPrint(arena, "{s}: {s}", .{ pname, scalarHint(s) }),
                    .call = pname,
                });
            },
            .handle => |i| {
                if (as_method and li == 0) {
                    try out.append(arena, .{ .call = "self._as_arg()" });
                    continue;
                }
                const h = f.params[i].ty.handle;
                const cls = if (handleIndex(ctx.api, h.name) != null)
                    try className(arena, h.name)
                else
                    "int";
                if (h.optional) {
                    try out.append(arena, .{
                        .sig = try std.fmt.allocPrint(arena, "{s}: {s} | None", .{ pname, cls }),
                        .call = try std.fmt.allocPrint(
                            arena,
                            "(None if {s} is None else {s}._as_arg())",
                            .{ pname, pname },
                        ),
                    });
                } else {
                    try out.append(arena, .{
                        .sig = try std.fmt.allocPrint(arena, "{s}: {s}", .{ pname, cls }),
                        .call = try std.fmt.allocPrint(arena, "{s}._as_arg()", .{pname}),
                    });
                }
            },
            .bytes_in => |p| {
                // `[*]const u8` is a non-null pointer type in Zig, so an empty
                // buffer still has to arrive as a real address; `?[*]const u8`
                // is the only shape where NULL is a legal value.
                const optional = f.params[p.ptr].ty.many_u8.optional;
                const nn = if (optional) ", nonnull=False" else "";
                try out.append(arena, .{
                    .sig = try std.fmt.allocPrint(
                        arena,
                        "{s}: bytes | bytearray | memoryview{s}",
                        .{ pname, if (optional) " | None" else "" },
                    ),
                    .prep = try std.fmt.allocPrint(
                        arena,
                        "_{s}_ptr, _{s}_len = _bytes_in({s}{s})",
                        .{ pname, pname, pname, nn },
                    ),
                    .call = try std.fmt.allocPrint(arena, "_{s}_ptr, _{s}_len", .{ pname, pname }),
                });
            },
            .bytes_out => |p| {
                const optional = f.params[p.ptr].ty.many_u8.optional;
                const nn = if (optional) ", nonnull=False" else "";
                try out.append(arena, .{
                    .sig = try std.fmt.allocPrint(
                        arena,
                        "{s}: bytearray{s}",
                        .{ pname, if (optional) " | None" else "" },
                    ),
                    .prep = try std.fmt.allocPrint(
                        arena,
                        "_{s}_ptr, _{s}_len = _bytes_out({s}{s})",
                        .{ pname, pname, pname, nn },
                    ),
                    .call = try std.fmt.allocPrint(arena, "_{s}_ptr, _{s}_len", .{ pname, pname }),
                });
            },
            .cstr_in => {
                try out.append(arena, .{
                    .sig = try std.fmt.allocPrint(arena, "{s}: str | bytes", .{pname}),
                    .prep = try std.fmt.allocPrint(
                        arena,
                        "_{s}_c = _cstr_in({s})",
                        .{ pname, pname },
                    ),
                    .call = try std.fmt.allocPrint(arena, "_{s}_c", .{pname}),
                });
            },
            .out_ptr => |i| {
                const child = f.params[i].ty.out_ptr.child;
                try out.append(arena, .{
                    .prep = try std.fmt.allocPrint(
                        arena,
                        "_{s}_out = {s}()",
                        .{ pname, ctypesScalar(child) },
                    ),
                    .call = try std.fmt.allocPrint(arena, "ctypes.byref(_{s}_out)", .{pname}),
                    .result = try std.fmt.allocPrint(arena, "_{s}_out.value", .{pname}),
                    .result_hint = scalarHint(child),
                });
            },
        }
    }
    return out.toOwnedSlice(arena);
}

fn emitFunction(
    arena: std.mem.Allocator,
    ctx: gen.Context,
    w: *CodeWriter,
    f: ir.Function,
    plan: FnPlan,
) !void {
    const logicals = try ir.lower(arena, f);
    const as_method = plan.kind == .method;
    const args = try buildArgs(arena, ctx, f, logicals, as_method);
    const err_cls = try errorClassName(arena, ctx.libName());

    // Signature -----------------------------------------------------------
    var sig: std.Io.Writer.Allocating = .init(arena);
    switch (plan.kind) {
        .method => try sig.writer.writeAll("self"),
        .ctor => try sig.writer.writeAll("cls"),
        else => {},
    }
    for (args) |a| {
        if (a.sig.len == 0) continue;
        if (sig.written().len > 0) try sig.writer.writeAll(", ");
        try sig.writer.writeAll(a.sig);
    }

    // Results -------------------------------------------------------------
    var result_exprs: std.ArrayList([]const u8) = .empty;
    var result_hints: std.ArrayList([]const u8) = .empty;
    const ret_is_handle = f.ret == .handle;
    const ret_cls: ?[]const u8 = if (ret_is_handle)
        (if (handleIndex(ctx.api, f.ret.handle.name)) |_| try className(arena, f.ret.handle.name) else null)
    else
        null;

    switch (f.ret) {
        .void => {},
        .scalar => |s| {
            try result_exprs.append(arena, "_ret");
            try result_hints.append(arena, scalarHint(s));
        },
        .handle => {
            if (plan.kind == .ctor) {
                try result_exprs.append(arena, "cls(_ret)");
                try result_hints.append(arena, try className(arena, f.ret.handle.name));
            } else if (ret_cls) |cls| {
                // NOT a constructor: nothing in the signature says the caller
                // owns this pointer, so the wrapper must not free it. See the
                // note appended to the docstring below.
                try result_exprs.append(arena, try std.fmt.allocPrint(arena, "{s}._borrow(_ret)", .{cls}));
                try result_hints.append(arena, cls);
            } else {
                try result_exprs.append(arena, "_ret");
                try result_hints.append(arena, "int");
            }
        },
        .many_u8 => {
            try result_exprs.append(arena, "_ret");
            try result_hints.append(arena, "bytes | None");
        },
        // A bare `*T` return is not in the allowlist; the validator rejects it
        // before a generator ever sees it.
        .out_ptr, .unsupported => return error.UnsupportedType,
    }
    for (args) |a| {
        if (a.result) |r| {
            try result_exprs.append(arena, r);
            try result_hints.append(arena, a.result_hint);
        }
    }

    const ret_hint: []const u8 = switch (result_hints.items.len) {
        0 => "None",
        1 => result_hints.items[0],
        else => blk: {
            var h: std.Io.Writer.Allocating = .init(arena);
            try h.writer.writeAll("tuple[");
            for (result_hints.items, 0..) |x, i| {
                if (i > 0) try h.writer.writeAll(", ");
                try h.writer.writeAll(x);
            }
            try h.writer.writeAll("]");
            break :blk h.written();
        },
    };

    if (plan.kind == .ctor) try w.raw("@classmethod");
    try w.line("def {s}({s}) -> {s}:", .{ plan.py_name, sig.written(), ret_hint });
    w.indent();

    const fallback = try std.fmt.allocPrint(arena, "Call ``{s}``.", .{f.name});
    const note: ?[]const u8 = if (plan.kind != .ctor and ret_cls != null)
        try std.fmt.allocPrint(arena,
            \\The returned {s} does NOT own its handle: whether the caller owns a
            \\pointer is not something the signature says, so close(), __exit__ and
            \\__del__ leave it alone. If the library expects you to release it, call
            \\its destructor explicitly.
        , .{ret_cls.?})
    else
        null;
    try emitDocstring(arena, w, f.doc, fallback, note);

    try w.raw("_lib = get_ffi()");
    for (args) |a| {
        if (a.prep) |p| try w.raw(p);
    }

    var call: std.Io.Writer.Allocating = .init(arena);
    try call.writer.print("_lib.{s}(", .{f.name});
    var first = true;
    for (args) |a| {
        if (a.call.len == 0) continue;
        if (!first) try call.writer.writeAll(", ");
        try call.writer.writeAll(a.call);
        first = false;
    }
    try call.writer.writeAll(")");

    if (f.ret == .void) {
        try w.raw(call.written());
    } else {
        try w.line("_ret = {s}", .{call.written()});
    }

    if (ret_is_handle) {
        try w.raw("if not _ret:");
        w.indent();
        try w.line("raise {s}(\"{s} returned NULL\")", .{ err_cls, f.name });
        w.dedent();
    }

    if (result_exprs.items.len == 0) {
        try w.raw("return None");
    } else if (result_exprs.items.len == 1) {
        try w.line("return {s}", .{result_exprs.items[0]});
    } else {
        var r: std.Io.Writer.Allocating = .init(arena);
        for (result_exprs.items, 0..) |x, i| {
            if (i > 0) try r.writer.writeAll(", ");
            try r.writer.writeAll(x);
        }
        try w.line("return {s}", .{r.written()});
    }
    w.dedent();
}

/// Comma-joined Zig names of every destructor-shaped candidate for a handle.
fn dtorNameList(arena: std.mem.Allocator, api: *const ir.Api, list: []const u32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (list, 0..) |fi, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(api.functions[fi].name);
    }
    return out.written();
}

/// Emit one of several ambiguous destructors as a handle-consuming method.
///
/// `ir.lifecycle` only accepts a `void fn(*H)` as a destructor candidate, so
/// the shape is fixed: no arguments beyond `self`, no results. The instance is
/// invalidated *before* the native call, under the same lock `close()` uses, so
/// a racing `close()`, `__del__` or second call cannot reach the freed pointer.
fn emitConsumingDtor(
    arena: std.mem.Allocator,
    ctx: gen.Context,
    w: *CodeWriter,
    f: ir.Function,
    plan: FnPlan,
    cls: []const u8,
    candidates: []const u8,
) !void {
    const err_cls = try errorClassName(arena, ctx.libName());

    try w.line("def {s}(self) -> None:", .{plan.py_name});
    w.indent();

    const fallback = try std.fmt.allocPrint(arena, "Call ``{s}``.", .{f.name});
    const note = try std.fmt.allocPrint(arena,
        \\Consumes the handle. This instance is closed before the native call, so
        \\a later use raises {s} instead of reaching freed memory, and close(),
        \\__exit__ and __del__ then do nothing.
        \\
        \\zbridge found more than one destructor-shaped name for ``{s}`` and
        \\cannot tell which one is the real destructor, so each is emitted as a
        \\consuming method and close() calls none of them. The candidates are:
        \\{s}.
    , .{ err_cls, cls, candidates });
    try emitDocstring(arena, w, f.doc, fallback, note);

    // Resolve the library first: if that raises, the handle is still valid.
    try w.raw("_lib = get_ffi()");
    try w.raw("with self._lock:");
    w.indent();
    try w.raw("_handle, self._handle = self._handle, None");
    w.dedent();
    try w.raw("if _handle is None:");
    w.indent();
    try w.line("raise {s}(\"{s} is closed\")", .{ err_cls, cls });
    w.dedent();
    try w.line("_lib.{s}(_handle)", .{f.name});
    try w.raw("return None");
    w.dedent();
}

const helpers =
    \\#: One byte this module owns, handed to the callee in place of an empty
    \\#: buffer's pointer. Zig spells a non-optional buffer parameter `[*]u8`,
    \\#: which is a non-null pointer type: passing NULL is undefined behaviour
    \\#: even when the paired length is 0. What CPython hands out for a
    \\#: zero-length buffer is an implementation detail, so it is not relied on.
    \\_EMPTY = (ctypes.c_char * 1)()
    \\
    \\
    \\def _bytes_in(
    \\    data: bytes | bytearray | memoryview | None,
    \\    *,
    \\    nonnull: bool = True,
    \\) -> tuple[object, int]:
    \\    """Borrow a read-only pointer to `data`, copying only when forced to.
    \\
    \\    `bytes` is passed straight through (ctypes converts it to a char* with
    \\    no copy). A `bytearray` or writable `memoryview` is wrapped in place, so
    \\    the callee reads the caller's own memory. A read-only `memoryview` over
    \\    a non-`bytes` object is the one case that has to be copied.
    \\
    \\    `nonnull` is True for a `[*]const u8` parameter and False for the
    \\    optional `?[*]const u8`, which is the only shape where the callee
    \\    asked to be able to see NULL; there, and only there, `None` is
    \\    accepted and passed through as NULL.
    \\    """
    \\    if data is None:
    \\        if nonnull:
    \\            raise TypeError("this buffer argument is not optional, so None is not allowed")
    \\        return None, 0
    \\    if isinstance(data, bytes):
    \\        if nonnull and not data:
    \\            return _EMPTY, 0
    \\        return data, len(data)
    \\    view = memoryview(data)
    \\    if view.ndim != 1 or view.format != "B":
    \\        view = view.cast("B")
    \\    if nonnull and view.nbytes == 0:
    \\        return _EMPTY, 0
    \\    if view.readonly:
    \\        raw = view.tobytes()
    \\        return raw, len(raw)
    \\    return (ctypes.c_char * view.nbytes).from_buffer(view), view.nbytes
    \\
    \\
    \\def _bytes_out(buf: bytearray | None, *, nonnull: bool = True) -> tuple[object, int]:
    \\    """Wrap a caller-allocated buffer so the callee can write into it.
    \\
    \\    The result aliases `buf`; nothing is copied back afterwards, which is
    \\    why a read-only object is rejected here instead of silently discarding
    \\    whatever the callee wrote.
    \\
    \\    An empty buffer still yields a real address when `nonnull` is set, for
    \\    the same reason as in _bytes_in; the length stays 0, so a correct
    \\    callee never dereferences it. `None` is accepted only for the optional
    \\    `?[*]u8`, where it becomes NULL.
    \\    """
    \\    if buf is None:
    \\        if nonnull:
    \\            raise TypeError("this buffer argument is not optional, so None is not allowed")
    \\        return None, 0
    \\    view = memoryview(buf)
    \\    if view.readonly:
    \\        raise TypeError(
    \\            "expected a writable buffer such as bytearray, got a read-only "
    \\            f"{type(buf).__name__}"
    \\        )
    \\    if view.ndim != 1 or view.format != "B":
    \\        view = view.cast("B")
    \\    if nonnull and view.nbytes == 0:
    \\        return _EMPTY, 0
    \\    return (ctypes.c_char * view.nbytes).from_buffer(view), view.nbytes
    \\
    \\
    \\def _cstr_in(text: str | bytes) -> bytes:
    \\    """Encode a NUL-terminated string argument. ctypes appends the NUL."""
    \\    if isinstance(text, bytes):
    \\        return text
    \\    return text.encode("utf-8")
;

fn renderIdiomatic(arena: std.mem.Allocator, ctx: gen.Context) ![]const u8 {
    const api = ctx.api;
    const lc = try ir.lifecycle(arena, api.*);
    const err_cls = try errorClassName(arena, ctx.libName());

    // Classify every function ---------------------------------------------
    const plans = try arena.alloc(FnPlan, api.functions.len);
    for (api.functions, 0..) |f, i| {
        plans[i] = .{
            .py_name = try names.toSnake(arena, names.stripPrefix(f.name, ctx.libName())),
        };
    }
    for (api.handles, 0..) |_, hi| {
        for (lc.ctors[hi]) |fi| plans[fi].kind = .ctor;
        for (lc.ctors[hi]) |fi| plans[fi].handle = hi;
        // Only an unambiguous destructor is folded into close(). When a handle
        // has several, none of them is special — but every one of them is
        // destructor-shaped by name, so none may be emitted as an ordinary
        // method that frees the handle and leaves `self._handle` dangling.
        if (lc.dtorFor(hi)) |fi| {
            plans[fi].kind = .dtor;
            plans[fi].handle = hi;
        } else {
            for (lc.dtors[hi]) |fi| {
                plans[fi].kind = .consuming;
                plans[fi].handle = hi;
            }
        }
    }
    for (api.functions, 0..) |f, i| {
        if (plans[i].kind != .module) continue;
        if (f.params.len == 0) continue;
        if (f.params[0].ty != .handle) continue;
        const hi = handleIndex(api, f.params[0].ty.handle.name) orelse continue;
        plans[i].kind = .method;
        plans[i].handle = hi;
    }

    var w: CodeWriter = .init(arena, unit);

    try w.raw(try gen.banner(arena, ctx, "#"));
    try w.blank();
    try w.line("\"\"\"The {s} API: one class per handle, one function per export.", .{ctx.libName()});
    try w.blank();
    try w.raw("Regenerated in full on every zbridge run. Put your own code in");
    try w.raw("__init__.py, or subclass from there; edits here are lost.");
    try w.raw("\"\"\"");
    try w.blank();
    try w.raw("from __future__ import annotations");
    try w.blank();
    try w.raw("import ctypes");
    try w.raw("import threading");
    try w.blank();
    try w.raw("from ._ffi_gen import get_ffi");
    try w.blank();

    // __all__ --------------------------------------------------------------
    var exported: std.ArrayList([]const u8) = .empty;
    try exported.append(arena, err_cls);
    for (api.handles) |h| try exported.append(arena, try className(arena, h.name));
    for (api.functions, 0..) |_, i| {
        if (plans[i].kind == .module) try exported.append(arena, plans[i].py_name);
    }

    try w.raw("__all__ = [");
    w.indent();
    for (exported.items) |name| try w.line("\"{s}\",", .{name});
    w.dedent();
    try w.raw("]");
    try w.blank();
    try w.blank();

    // Error type -----------------------------------------------------------
    try w.line("class {s}(RuntimeError):", .{err_cls});
    w.indent();
    try w.line("\"\"\"Raised when a {s} call fails or returns a NULL handle.\"\"\"", .{ctx.libName()});
    w.dedent();
    try w.blank();
    try w.blank();

    // Buffer helpers -------------------------------------------------------
    try w.raw(helpers);
    try w.blank();
    try w.blank();

    // One class per handle -------------------------------------------------
    for (api.handles, 0..) |h, hi| {
        const cls = try className(arena, h.name);
        try w.line("class {s}:", .{cls});
        w.indent();
        const fallback = try std.fmt.allocPrint(
            arena,
            "Handle for the native ``{s}`` type.",
            .{h.name},
        );
        try emitDocstring(arena, &w, h.doc, fallback, null);
        try w.blank();
        try w.raw("__slots__ = (\"_handle\", \"_owned\", \"_lock\")");
        try w.blank();
        try w.raw("def __init__(self, handle: int, owned: bool = True) -> None:");
        w.indent();
        try w.raw("\"\"\"Wrap a raw pointer. Prefer the constructors below.");
        try w.blank();
        try w.raw("`owned` decides what close() and __del__ do: an owning wrapper calls");
        try w.raw("the native destructor, a borrowed one only drops its reference. Only");
        try w.raw("a constructor can know the answer, so only a constructor owns.");
        try w.raw("\"\"\"");
        // Every slot is populated before anything can raise, so a failed
        // __init__ leaves __del__ a consistent object to look at.
        try w.raw("self._handle: ctypes.c_void_p | None = None");
        try w.raw("self._owned: bool = owned");
        try w.raw("self._lock = threading.Lock()");
        try w.raw("if not handle:");
        w.indent();
        try w.line("raise {s}(\"{s}: NULL handle\")", .{ err_cls, cls });
        w.dedent();
        try w.raw("self._handle = ctypes.c_void_p(handle)");
        w.dedent();
        try w.blank();

        try w.raw("@classmethod");
        try w.line("def _borrow(cls, handle: int) -> {s}:", .{cls});
        w.indent();
        try w.raw("\"\"\"Wrap a pointer this object does not own; close() will not free it.\"\"\"");
        try w.raw("return cls(handle, owned=False)");
        w.dedent();
        try w.blank();

        try w.raw("def _as_arg(self) -> ctypes.c_void_p:");
        w.indent();
        try w.raw("\"\"\"Return the pointer, refusing to use one that was closed.\"\"\"");
        try w.raw("if self._handle is None:");
        w.indent();
        try w.line("raise {s}(\"{s} is closed\")", .{ err_cls, cls });
        w.dedent();
        try w.raw("return self._handle");
        w.dedent();
        try w.blank();

        // Constructors -----------------------------------------------------
        for (lc.ctors[hi]) |fi| {
            try emitFunction(arena, ctx, &w, api.functions[fi], plans[fi]);
            try w.blank();
        }

        // Methods ----------------------------------------------------------
        const candidates = try dtorNameList(arena, api, lc.dtors[hi]);
        for (api.functions, 0..) |f, i| {
            if (plans[i].handle != hi) continue;
            switch (plans[i].kind) {
                .method => try emitFunction(arena, ctx, &w, f, plans[i]),
                .consuming => try emitConsumingDtor(arena, ctx, &w, f, plans[i], cls, candidates),
                else => continue,
            }
            try w.blank();
        }

        // close / context manager / __del__ --------------------------------
        try w.raw("def close(self) -> None:");
        w.indent();
        if (lc.dtorFor(hi)) |fi| {
            const dtor = api.functions[fi];
            try w.line("\"\"\"Release the handle by calling ``{s}``.", .{dtor.name});
            try w.blank();
            try w.raw("Idempotent and thread safe: the handle is taken under a per-instance");
            try w.raw("lock and cleared before the destructor runs, so a second call, a call");
            try w.raw("after __exit__, and a __del__ racing another thread all do nothing.");
            try w.blank();
            try w.raw("A wrapper that does not own its handle (see _borrow) only drops it:");
            try w.raw("the native destructor is never called on a borrowed pointer.");
            try w.raw("\"\"\"");
            try w.raw("with self._lock:");
            w.indent();
            try w.raw("handle, self._handle = self._handle, None");
            try w.raw("owned = self._owned");
            w.dedent();
            try w.raw("if handle is None or not owned or get_ffi is None:");
            w.indent();
            try w.raw("# get_ffi can already be None during interpreter shutdown.");
            try w.raw("return");
            w.dedent();
            try w.line("get_ffi().{s}(handle)", .{dtor.name});
        } else if (lc.dtors[hi].len > 1) {
            try w.line("\"\"\"Drop the handle. {s} has several destructor-shaped names.", .{h.name});
            try w.blank();
            try w.raw("zbridge cannot tell which of them is the real destructor, so nothing");
            try w.raw("native is called here; call the consuming method you want instead.");
            try w.line("The candidates are: {s}.", .{candidates});
            try w.blank();
            try w.raw("Idempotent and thread safe.");
            try w.raw("\"\"\"");
            try w.raw("with self._lock:");
            w.indent();
            try w.raw("self._handle = None");
            w.dedent();
        } else {
            try w.line("\"\"\"Drop the handle. No destructor was found for {s}.", .{h.name});
            try w.blank();
            try w.raw("zbridge recognises a destructor by name: a `void` function taking");
            try w.raw("exactly this handle and ending in _destroy, _free, _deinit, _close");
            try w.raw("or _release. Nothing native is called here.");
            try w.raw("\"\"\"");
            try w.raw("with self._lock:");
            w.indent();
            try w.raw("self._handle = None");
            w.dedent();
        }
        w.dedent();
        try w.blank();

        try w.line("def __enter__(self) -> {s}:", .{cls});
        w.indent();
        try w.raw("return self");
        w.dedent();
        try w.blank();

        try w.raw("def __exit__(self, exc_type: object, exc: object, tb: object) -> None:");
        w.indent();
        try w.raw("self.close()");
        w.dedent();
        try w.blank();

        try w.raw("def __del__(self) -> None:");
        w.indent();
        try w.raw("# A safety net, not the intended path: use `with` or close().");
        try w.raw("# Anything can already be torn down here, so nothing may escape.");
        try w.raw("try:");
        w.indent();
        try w.raw("self.close()");
        w.dedent();
        try w.raw("except Exception:");
        w.indent();
        try w.raw("pass");
        w.dedent();
        w.dedent();
        try w.blank();

        try w.raw("def __repr__(self) -> str:");
        w.indent();
        try w.raw("if self._handle is None:");
        w.indent();
        try w.line("return \"<{s} closed>\"", .{cls});
        w.dedent();
        try w.line("return f\"<{s} open{{'' if self._owned else ', borrowed'}}>\"", .{cls});
        w.dedent();

        w.dedent();
        try w.blank();
        try w.blank();
    }

    // Module-level functions ----------------------------------------------
    var emitted_module = false;
    for (api.functions, 0..) |f, i| {
        if (plans[i].kind != .module) continue;
        if (emitted_module) {
            try w.blank();
            try w.blank();
        }
        emitted_module = true;
        try emitFunction(arena, ctx, &w, f, plans[i]);
    }

    var text = try w.toOwnedSlice();
    // The class loop leaves two blank lines behind; keep exactly one trailing
    // newline so the file is byte-stable and POSIX-clean.
    var end = text.len;
    while (end > 0 and text[end - 1] == '\n') end -= 1;
    return std.fmt.allocPrint(arena, "{s}\n", .{text[0..end]});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scalar(s: ir.Scalar) ir.Type {
    return .{ .scalar = s };
}

fn int(k: ir.IntKind) ir.Type {
    return .{ .scalar = .{ .int = k } };
}

const ctx_handle: ir.Type = .{ .handle = .{ .name = "Ctx", .optional = false, .is_const = false } };
const ctx_handle_opt: ir.Type = .{ .handle = .{ .name = "Ctx", .optional = true, .is_const = false } };

/// The fixture the golden files are generated from: a handle with a
/// constructor and a destructor, bytes in, bytes out, a C string, out-params,
/// and a module-level function.
const sample_api: ir.Api = .{
    .lib_name = "zc",
    .handles = &.{.{ .name = "Ctx", .doc = "A counting context.\nNot thread safe." }},
    .functions = &.{
        .{
            .name = "zc_ctx_new",
            .ret = ctx_handle_opt,
            .doc = "Create a context with room for `cap` items.\nReturns null when out of memory.",
            .params = &.{.{ .name = "cap", .ty = int(.usize) }},
        },
        .{
            .name = "zc_ctx_destroy",
            .ret = .void,
            .doc = "Free a context.",
            .params = &.{.{ .name = "ctx", .ty = ctx_handle }},
        },
        .{
            .name = "zc_ctx_feed",
            .ret = int(.i32),
            .doc = "Feed bytes in; returns the number consumed.",
            .params = &.{
                .{ .name = "ctx", .ty = ctx_handle },
                .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
                .{ .name = "len", .ty = int(.usize) },
                .{ .name = "flags", .ty = int(.u32) },
            },
        },
        .{
            .name = "zc_ctx_digest",
            .ret = int(.usize),
            .doc = "Write the digest into `out`; returns the byte count written.",
            .params = &.{
                .{ .name = "ctx", .ty = ctx_handle },
                .{ .name = "out", .ty = .{ .many_u8 = .{ .is_const = false, .sentinel_zero = false } } },
                .{ .name = "out_len", .ty = int(.usize) },
            },
        },
        .{
            .name = "zc_ctx_label",
            .ret = .void,
            .doc = "Attach a label to the context.",
            .params = &.{
                .{ .name = "ctx", .ty = ctx_handle },
                .{ .name = "name", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = true } } },
            },
        },
        .{
            .name = "zc_ctx_stats",
            .ret = scalar(.bool),
            .doc = "Read the counters. False when the context is empty.",
            .params = &.{
                .{ .name = "ctx", .ty = ctx_handle },
                .{ .name = "total", .ty = .{ .out_ptr = .{ .child = .{ .int = .u64 }, .optional = false } } },
                .{ .name = "mean", .ty = .{ .out_ptr = .{ .child = .{ .float = .f64 }, .optional = false } } },
            },
        },
        .{
            .name = "zc_add",
            .ret = int(.i32),
            .doc = "Add two numbers. Exists to prove the plumbing works.",
            .params = &.{
                .{ .name = "a", .ty = int(.i32) },
                .{ .name = "b", .ty = int(.i32) },
            },
        },
        .{
            .name = "zc_probe",
            .ret = scalar(.bool),
            .doc = "Report the build's tuning constant through an out-param.",
            .params = &.{
                .{ .name = "value", .ty = .{ .out_ptr = .{ .child = .{ .float = .f64 }, .optional = false } } },
            },
        },
    },
};

const sample_targets = [_]targets.Target{ .linux_x86_64, .macos_aarch64, .windows_x86_64 };

fn sampleContext(api: *const ir.Api) gen.Context {
    return .{
        .api = api,
        .abi_hash = 0x0123456789abcdef,
        .abi_hash_hex = "0123456789abcdef",
        .targets = &sample_targets,
        .link_libc = false,
        .version = "0.1.0",
        .input_path = "src/c_api.zig",
    };
}

fn findFile(files: []const gen.OutFile, path: []const u8) ?gen.OutFile {
    for (files) |f| {
        if (std.mem.eql(u8, f.path, path)) return f;
    }
    return null;
}

fn generateSample(arena: std.mem.Allocator, api: *const ir.Api) ![]const gen.OutFile {
    var files: gen.FileList = .empty;
    try generate(arena, sampleContext(api), &files);
    return files.toOwnedSlice(arena);
}

test "python golden files" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    const files = try generateSample(arena, &api);

    const cases = .{
        .{ "pyproject.toml", @embedFile("testdata/python/pyproject.toml.golden") },
        .{ "zc/__init__.py", @embedFile("testdata/python/__init__.py.golden") },
        .{ "zc/_loader_gen.py", @embedFile("testdata/python/_loader_gen.py.golden") },
        .{ "zc/_ffi_gen.py", @embedFile("testdata/python/_ffi_gen.py.golden") },
        .{ "zc/_gen.py", @embedFile("testdata/python/_gen.py.golden") },
    };

    inline for (cases) |c| {
        const got = findFile(files, c[0]) orelse {
            std.debug.print("missing generated file: {s}\n", .{c[0]});
            return error.MissingFile;
        };
        try testing.expectEqualStrings(c[1], got.bytes);
    }

    const marker = findFile(files, "zc/py.typed").?;
    try testing.expectEqualStrings("", marker.bytes);
}

test "python file tiers and layout" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    const files = try generateSample(arena, &api);

    try testing.expectEqual(@as(usize, 6), files.len);
    for (files) |f| try testing.expectEqual(gen.Lang.python, f.lang);

    try testing.expectEqual(gen.Tier.user_scaffold, findFile(files, "pyproject.toml").?.tier);
    try testing.expectEqual(gen.Tier.user_scaffold, findFile(files, "zc/__init__.py").?.tier);
    for ([_][]const u8{ "zc/py.typed", "zc/_loader_gen.py", "zc/_ffi_gen.py", "zc/_gen.py" }) |p| {
        try testing.expectEqual(gen.Tier.generated, findFile(files, p).?.tier);
    }

    // Every generated .py file carries the banner; the scaffold ones must not,
    // because the user owns them.
    const banner_head = "# Code generated by zbridge 0.1.0. DO NOT EDIT.";
    for ([_][]const u8{ "zc/_loader_gen.py", "zc/_ffi_gen.py", "zc/_gen.py" }) |p| {
        try testing.expect(std.mem.startsWith(u8, findFile(files, p).?.bytes, banner_head));
    }
    try testing.expect(!std.mem.startsWith(u8, findFile(files, "zc/__init__.py").?.bytes, "#"));
}

test "pyproject is omitted when not requested" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    var ctx = sampleContext(&api);
    ctx.python.emit_pyproject = false;
    ctx.python.package_name = "zcounter";

    var files: gen.FileList = .empty;
    try generate(arena, ctx, &files);

    try testing.expectEqual(@as(?gen.OutFile, null), findFile(files.items, "pyproject.toml"));
    try testing.expect(findFile(files.items, "zcounter/_gen.py") != null);
}

test "pyproject uses the distribution name and packages the package dir" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    var ctx = sampleContext(&api);
    ctx.python.package_name = "zcounter";
    ctx.python.dist_name = "zcounter-bindings";

    var files: gen.FileList = .empty;
    try generate(arena, ctx, &files);
    const text = findFile(files.items, "pyproject.toml").?.bytes;

    try testing.expect(std.mem.indexOf(u8, text, "name = \"zcounter-bindings\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "packages = [\"zcounter\"]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "requires-python = \">=3.9\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hatchling.build") != null);
}

// The trap this test exists for: ctypes defaults restype to c_int, which
// truncates a 64-bit pointer. Every handle-returning function must say
// c_void_p out loud.
test "every handle-returning function sets restype to c_void_p" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const other: ir.Type = .{ .handle = .{ .name = "Other", .optional = true, .is_const = false } };
    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{ .{ .name = "Ctx" }, .{ .name = "Other" } },
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = ctx_handle_opt, .params = &.{} },
            .{ .name = "zc_ctx_clone", .ret = ctx_handle, .params = &.{.{ .name = "c", .ty = ctx_handle }} },
            // Deliberately not named like a constructor: still returns a pointer.
            .{ .name = "zc_borrow_other", .ret = other, .params = &.{.{ .name = "c", .ty = ctx_handle }} },
            .{ .name = "zc_count", .ret = int(.i32), .params = &.{.{ .name = "c", .ty = ctx_handle }} },
        },
    };

    const files = try generateSample(arena, &api);
    const ffi = findFile(files, "zc/_ffi_gen.py").?.bytes;

    var handle_returning: usize = 0;
    for (api.functions) |f| {
        const anchor = try std.fmt.allocPrint(arena, "_fn = lib.{s}\n", .{f.name});
        const at = std.mem.indexOf(u8, ffi, anchor) orelse return error.FunctionNotBound;
        const rest = ffi[at + anchor.len ..];
        const restype_at = std.mem.indexOf(u8, rest, "_fn.restype = ").?;
        const line_end = std.mem.indexOfScalarPos(u8, rest, restype_at, '\n').?;
        const restype = rest[restype_at + "_fn.restype = ".len .. line_end];

        if (f.ret == .handle) {
            handle_returning += 1;
            try testing.expectEqualStrings("ctypes.c_void_p", restype);
        } else {
            try testing.expect(!std.mem.eql(u8, restype, "ctypes.c_void_p"));
        }
    }
    try testing.expectEqual(@as(usize, 3), handle_returning);
}

test "void return maps to restype None" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    const files = try generateSample(arena, &api);
    const ffi = findFile(files, "zc/_ffi_gen.py").?.bytes;
    try testing.expect(std.mem.indexOf(u8, ffi, "_fn = lib.zc_ctx_destroy\n" ++
        "    _fn.argtypes = [ctypes.c_void_p]\n" ++
        "    _fn.restype = None\n") != null);
}

test "buffer directions get different ctypes spellings" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    const files = try generateSample(arena, &api);
    const ffi = findFile(files, "zc/_ffi_gen.py").?.bytes;

    // in: c_char_p (accepts bytes with no copy)
    try testing.expect(std.mem.indexOf(u8, ffi, "_fn.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint32]") != null);
    // out: POINTER(c_char) (mutable, refuses a bare bytes at the call site)
    try testing.expect(std.mem.indexOf(u8, ffi, "_fn.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char), ctypes.c_size_t]") != null);
}

test "loader maps every target's machine spellings" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{ .lib_name = "zc", .handles = &.{}, .functions = &.{} };
    var ctx = sampleContext(&api);
    ctx.targets = &targets.all;

    var files: gen.FileList = .empty;
    try generate(arena, ctx, &files);
    const loader = findFile(files.items, "zc/_loader_gen.py").?.bytes;

    for (targets.all) |t| {
        const nfo = targets.info(t);
        for (nfo.py_machines) |m| {
            const row = try std.fmt.allocPrint(
                arena,
                "(\"{s}\", \"{s}\"): \"{s}\",",
                .{ nfo.py_system, m, t.id() },
            );
            try testing.expect(std.mem.indexOf(u8, loader, row) != null);
        }
        const file_row = try std.fmt.allocPrint(
            arena,
            "\"{s}\": \"{s}\",",
            .{ t.id(), try targets.libFileName(arena, t, "zc") },
        );
        try testing.expect(std.mem.indexOf(u8, loader, file_row) != null);
    }

    try testing.expect(std.mem.indexOf(u8, loader, "ENV_LIB_PATH = \"ZC_LIB_PATH\"") != null);
    try testing.expect(std.mem.indexOf(u8, loader, "ABI_HASH = 0x0123456789abcdef") != null);
    try testing.expect(std.mem.indexOf(u8, loader, "getattr(lib, \"zc_zbridge_abi_hash\")") != null);
    try testing.expect(std.mem.indexOf(u8, loader, "ctypes.c_uint64") != null);
    try testing.expect(std.mem.indexOf(u8, loader, "ctypes.CDLL(str(path))") != null);
    // WinDLL is deliberately not used; the comment explaining that must stay.
    try testing.expect(std.mem.indexOf(u8, loader, "ctypes.WinDLL declares") != null);
}

test "idiomatic layer shape" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    const files = try generateSample(arena, &api);
    const text = findFile(files, "zc/_gen.py").?.bytes;

    const expected = [_][]const u8{
        "class ZcError(RuntimeError):",
        "class Ctx:",
        "@classmethod",
        // `cap` is a Go keyword, so names.safeParamName renames it in both
        // languages; keeping the two bindings' parameter names identical is
        // worth more than a marginally prettier Python signature.
        "def ctx_new(cls, cap_: int) -> Ctx:",
        "def ctx_feed(self, data: bytes | bytearray | memoryview, flags: int) -> int:",
        "def ctx_digest(self, out: bytearray) -> int:",
        "def ctx_label(self, name: str | bytes) -> None:",
        "def ctx_stats(self) -> tuple[bool, int, float]:",
        "def close(self) -> None:",
        "def __enter__(self) -> Ctx:",
        "def __exit__(self, exc_type: object, exc: object, tb: object) -> None:",
        "def __del__(self) -> None:",
        "def add(a: int, b: int) -> int:",
        "def probe() -> tuple[bool, float]:",
        "get_ffi().zc_ctx_destroy(handle)",
        "raise ZcError(\"zc_ctx_new returned NULL\")",
        // Docs from the Zig `///` comments survive.
        "Feed bytes in; returns the number consumed.",
        "A counting context.",
    };
    for (expected) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("missing from _gen.py: {s}\n", .{needle});
            return error.MissingOutput;
        }
    }

    // The destructor is reached through close(), never exposed as a method.
    try testing.expect(std.mem.indexOf(u8, text, "def ctx_destroy(") == null);
    // __all__ lists the classes and the module-level functions only.
    try testing.expect(std.mem.indexOf(u8, text, "__all__ = [\n    \"ZcError\",\n    \"Ctx\",\n    \"add\",\n    \"probe\",\n]") != null);
}

test "a handle with no destructor still closes cleanly" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx" }},
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = ctx_handle_opt, .params = &.{} },
        },
    };
    const files = try generateSample(arena, &api);
    const text = findFile(files, "zc/_gen.py").?.bytes;

    try testing.expect(std.mem.indexOf(u8, text, "No destructor was found for Ctx") != null);
    try testing.expect(std.mem.indexOf(u8, text, "self._handle = None") != null);
}

test "an empty api still produces importable files" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{ .lib_name = "zc", .handles = &.{}, .functions = &.{} };
    const files = try generateSample(arena, &api);

    const ffi = findFile(files, "zc/_ffi_gen.py").?.bytes;
    try testing.expect(std.mem.indexOf(u8, ffi, "Idempotent.\"\"\"\n    return\n") != null);

    const text = findFile(files, "zc/_gen.py").?.bytes;
    try testing.expect(std.mem.indexOf(u8, text, "__all__ = [\n    \"ZcError\",\n]") != null);
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "optional handle parameters accept None" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx" }},
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = ctx_handle_opt, .params = &.{} },
            .{ .name = "zc_ctx_destroy", .ret = .void, .params = &.{.{ .name = "c", .ty = ctx_handle }} },
            .{ .name = "zc_ctx_merge", .ret = .void, .params = &.{
                .{ .name = "c", .ty = ctx_handle },
                .{ .name = "other", .ty = ctx_handle_opt },
            } },
        },
    };
    const files = try generateSample(arena, &api);
    const text = findFile(files, "zc/_gen.py").?.bytes;

    try testing.expect(std.mem.indexOf(u8, text, "def ctx_merge(self, other: Ctx | None) -> None:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(None if other is None else other._as_arg())") != null);
}

test "names strip the library prefix and snake-case" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zpdf",
        .handles = &.{},
        .functions = &.{
            .{ .name = "zpdf_PageCount", .ret = int(.i32), .params = &.{} },
        },
    };
    var files: gen.FileList = .empty;
    var ctx = sampleContext(&api);
    try generate(arena, ctx, &files);
    _ = &ctx;
    const text = findFile(files.items, "zpdf/_gen.py").?.bytes;
    try testing.expect(std.mem.indexOf(u8, text, "def page_count() -> int:") != null);
}

// -- Memory safety ----------------------------------------------------------
//
// Each of the four tests below pins one bug that produced a double free, a
// use-after-free or a data race in an earlier generator.

// A handle that comes back from something that is not a constructor may be
// borrowed — a singleton the library still owns is the usual case. Wrapping it
// in an owning object makes __del__ free memory the library is still using.
test "a non-constructor handle return is wrapped without ownership" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx" }},
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = ctx_handle_opt, .params = &.{} },
            .{ .name = "zc_ctx_destroy", .ret = .void, .params = &.{.{ .name = "c", .ty = ctx_handle }} },
            // Not a constructor by name: a borrowed process-wide singleton.
            .{ .name = "zc_ctx_current", .ret = ctx_handle_opt, .params = &.{} },
            // Not a constructor either, and reached as a method.
            .{ .name = "zc_ctx_peer", .ret = ctx_handle_opt, .params = &.{.{ .name = "c", .ty = ctx_handle }} },
        },
    };
    const files = try generateSample(arena, &api);
    const text = findFile(files, "zc/_gen.py").?.bytes;

    // The constructor keeps ownership; the other two must not take it.
    try testing.expect(std.mem.indexOf(u8, text, "return cls(_ret)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "return Ctx._borrow(_ret)") != null);
    // Exactly one owning construction (the ctor) and two borrows.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "Ctx._borrow(_ret)"));
    try testing.expect(std.mem.indexOf(u8, text, "return Ctx(_ret)") == null);

    // The borrow helper, the flag it sets and the close() branch that reads it.
    try testing.expect(std.mem.indexOf(u8, text, "def _borrow(cls, handle: int) -> Ctx:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "return cls(handle, owned=False)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "__slots__ = (\"_handle\", \"_owned\", \"_lock\")") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if handle is None or not owned or get_ffi is None:") != null);

    // And the docstring says so, because the signature cannot.
    try testing.expect(std.mem.indexOf(u8, text, "The returned Ctx does NOT own its handle") != null);
}

// Two destructor-shaped names for one handle: ir.Lifecycle.dtorFor gives up,
// but both still free the handle, so neither may be emitted as a plain method
// that leaves self._handle pointing at freed memory.
test "every destructor candidate consumes the handle when there are several" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx" }},
        .functions = &.{
            .{ .name = "zc_ctx_new", .ret = ctx_handle_opt, .params = &.{} },
            .{ .name = "zc_ctx_free", .ret = .void, .params = &.{.{ .name = "c", .ty = ctx_handle }} },
            .{ .name = "zc_ctx_close", .ret = .void, .params = &.{.{ .name = "c", .ty = ctx_handle }} },
            // An ordinary method, to prove only the candidates are special.
            .{ .name = "zc_ctx_count", .ret = int(.i32), .params = &.{.{ .name = "c", .ty = ctx_handle }} },
        },
    };
    const files = try generateSample(arena, &api);
    const text = findFile(files, "zc/_gen.py").?.bytes;

    for ([_][]const u8{ "ctx_free", "ctx_close" }) |name| {
        const def = try std.fmt.allocPrint(arena, "def {s}(self) -> None:", .{name});
        const at = std.mem.indexOf(u8, text, def) orelse {
            std.debug.print("missing consuming method: {s}\n", .{def});
            return error.MissingOutput;
        };
        const body = text[at..];
        // The instance is invalidated under the lock *before* the native call.
        const invalidate = std.mem.indexOf(u8, body, "_handle, self._handle = self._handle, None").?;
        const raise = std.mem.indexOf(u8, body, "raise ZcError(\"Ctx is closed\")").?;
        const native = std.mem.indexOf(u8, body, try std.fmt.allocPrint(arena, "_lib.zc_{s}(_handle)", .{name})).?;
        try testing.expect(invalidate < raise);
        try testing.expect(raise < native);
        try testing.expect(std.mem.indexOf(u8, body, "Consumes the handle.") != null);
    }

    // It must NOT reach the plain-method path that keeps the handle alive.
    try testing.expect(std.mem.indexOf(u8, text, "_lib.zc_ctx_free(self._as_arg())") == null);
    try testing.expect(std.mem.indexOf(u8, text, "_lib.zc_ctx_close(self._as_arg())") == null);
    // The ordinary method still is one.
    try testing.expect(std.mem.indexOf(u8, text, "_ret = _lib.zc_ctx_count(self._as_arg())") != null);

    // close() calls none of them and says why.
    try testing.expect(std.mem.indexOf(u8, text, "Ctx has several destructor-shaped names") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zc_ctx_free, zc_ctx_close") != null);
    try testing.expect(std.mem.indexOf(u8, text, "get_ffi().zc_ctx_free(") == null);
    try testing.expect(std.mem.indexOf(u8, text, "get_ffi().zc_ctx_close(") == null);
}

// `handle, self._handle = self._handle, None` is two bytecodes with a switch
// point between them, and on a free-threaded build there is no GIL at all.
test "close takes the handle under a per-instance lock" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    const files = try generateSample(arena, &api);
    const text = findFile(files, "zc/_gen.py").?.bytes;

    try testing.expect(std.mem.indexOf(u8, text, "import threading") != null);
    try testing.expect(std.mem.indexOf(u8, text, "self._lock = threading.Lock()") != null);
    try testing.expect(std.mem.indexOf(u8, text,
        \\        with self._lock:
        \\            handle, self._handle = self._handle, None
        \\            owned = self._owned
    ) != null);
    // The unguarded swap must be gone everywhere it used to appear.
    try testing.expect(std.mem.indexOf(u8, text, "\n        handle, self._handle = self._handle, None") == null);

    // A handle with no destructor at all still clears under the lock.
    const bare: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{.{ .name = "Ctx" }},
        .functions = &.{.{ .name = "zc_ctx_new", .ret = ctx_handle_opt, .params = &.{} }},
    };
    const bare_text = findFile(try generateSample(arena, &bare), "zc/_gen.py").?.bytes;
    try testing.expect(std.mem.indexOf(u8, bare_text, "with self._lock:\n            self._handle = None") != null);
}

// Both lazy singletons were check-then-set: two threads could each load the
// library, and each run bind() over it.
test "the loader and the ffi table are initialised under a lock" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    const files = try generateSample(arena, &api);

    const loader = findFile(files, "zc/_loader_gen.py").?.bytes;
    try testing.expect(std.mem.indexOf(u8, loader, "import threading") != null);
    try testing.expect(std.mem.indexOf(u8, loader, "_lib_lock = threading.Lock()") != null);
    try testing.expect(std.mem.indexOf(u8, loader,
        \\    with _lib_lock:
        \\        if _lib is None:
        \\            _lib = load()
        \\        return _lib
    ) != null);
    try testing.expect(std.mem.indexOf(u8, loader, "    if _lib is None:\n        _lib = load()\n    return _lib") == null);

    const ffi = findFile(files, "zc/_ffi_gen.py").?.bytes;
    try testing.expect(std.mem.indexOf(u8, ffi, "import threading") != null);
    try testing.expect(std.mem.indexOf(u8, ffi, "_ffi_lock = threading.Lock()") != null);
    try testing.expect(std.mem.indexOf(u8, ffi,
        \\    with _ffi_lock:
        \\        if _ffi is None:
        \\            lib = get_lib()
        \\            bind(lib)
        \\            _ffi = lib
        \\        return _ffi
    ) != null);
}

// Zig's `[*]u8` is a non-null pointer type, so a zero-length buffer still has
// to arrive as a real address. `?[*]u8` is the one shape where NULL is legal.
test "an empty non-optional buffer still gets a real pointer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api = sample_api;
    const text = findFile(try generateSample(arena, &api), "zc/_gen.py").?.bytes;

    try testing.expect(std.mem.indexOf(u8, text, "_EMPTY = (ctypes.c_char * 1)()") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if nonnull and not data:\n            return _EMPTY, 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if nonnull and view.nbytes == 0:\n        return _EMPTY, 0") != null);
    // Non-optional buffers take the default, which is nonnull.
    try testing.expect(std.mem.indexOf(u8, text, "_bytes_in(data)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "_bytes_out(out)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "nonnull=False") == null);

    // An optional buffer opts out: NULL is a value the callee asked for.
    const opt_in: ir.Type = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false, .optional = true } };
    const opt_out: ir.Type = .{ .many_u8 = .{ .is_const = false, .sentinel_zero = false, .optional = true } };
    const opt_api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{
            .{ .name = "zc_sink", .ret = .void, .params = &.{
                .{ .name = "data", .ty = opt_in },
                .{ .name = "len", .ty = int(.usize) },
            } },
            .{ .name = "zc_fill", .ret = .void, .params = &.{
                .{ .name = "out", .ty = opt_out },
                .{ .name = "out_len", .ty = int(.usize) },
            } },
        },
    };
    const opt_text = findFile(try generateSample(arena, &opt_api), "zc/_gen.py").?.bytes;
    try testing.expect(std.mem.indexOf(u8, opt_text, "_bytes_in(data, nonnull=False)") != null);
    try testing.expect(std.mem.indexOf(u8, opt_text, "_bytes_out(out, nonnull=False)") != null);
    // Only an optional buffer may be spelled None at the call site, and the
    // helpers refuse None for every other one.
    try testing.expect(std.mem.indexOf(u8, opt_text, "def sink(data: bytes | bytearray | memoryview | None) -> None:") != null);
    try testing.expect(std.mem.indexOf(u8, opt_text, "def fill(out: bytearray | None) -> None:") != null);
    try testing.expect(std.mem.indexOf(u8, opt_text, "if data is None:\n        if nonnull:\n            raise TypeError(") != null);
    // A non-optional buffer parameter keeps its None-free signature.
    try testing.expect(std.mem.indexOf(u8, text, "def ctx_digest(self, out: bytearray) -> int:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "data: bytes | bytearray | memoryview, flags: int") != null);
}
