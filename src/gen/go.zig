//! The Go binding generator.
//!
//! Output layout (paths are relative to the Go output root):
//!
//!   go.mod                      user scaffold, only when a module path is set
//!   embed_<goos>_<goarch>.go    one per target, build-tagged, //go:embed
//!   embed_unsupported.go        the same symbols, empty, everywhere else
//!   loader_gen.go               extract -> cache -> dlopen -> ABI check
//!   loader_unix_gen.go          purego.Dlopen
//!   loader_windows_gen.go       syscall.LoadLibrary (purego has no Dlopen there)
//!   ctypes_{other,windows}_gen.go  c_long/c_ulong width, only when they are used
//!   <lib>_ffi_gen.go            raw typed purego bindings
//!   <lib>_gen.go                the idiomatic layer
//!   <lib>.go                    user scaffold, never regenerated
//!
//! Everything except the two scaffolds is overwritten on every run (D3).

const std = @import("std");

const ir = @import("../core/ir.zig");
const targets = @import("../core/targets.zig");
const gen = @import("context.zig");
const names = @import("names.zig");
const CodeWriter = @import("writer.zig").CodeWriter;

const loader_template = @embedFile("../templates/loader.go.tmpl");

pub fn generate(arena: std.mem.Allocator, ctx: gen.Context, files: *gen.FileList) !void {
    var g: Go = try .init(arena, ctx);
    try g.emitGoMod(files);
    try g.emitEmbeds(files);
    try g.emitLoader(files);
    try g.emitCTypes(files);
    try g.emitFfi(files);
    try g.emitIdiomatic(files);
    try g.emitScaffold(files);
}

// ---------------------------------------------------------------------------
// Type mapping
// ---------------------------------------------------------------------------

/// The Go type that occupies the same register as the Zig scalar at the C ABI.
///
/// `usize`/`isize` become `uintptr`/`int`, which are pointer-sized on every Go
/// platform. `c_long`/`c_ulong` are the only C types whose width is not fixed
/// across our targets (32-bit on Windows, pointer-sized elsewhere), so they go
/// through the generated `cLong`/`cULong` aliases instead of a concrete type.
fn goScalar(s: ir.Scalar) []const u8 {
    return switch (s) {
        .bool => "bool",
        .float => |f| switch (f) {
            .f32 => "float32",
            .f64 => "float64",
        },
        .int => |k| switch (k) {
            .u8 => "uint8",
            .u16 => "uint16",
            .u32 => "uint32",
            .u64 => "uint64",
            .i8 => "int8",
            .i16 => "int16",
            .i32 => "int32",
            .i64 => "int64",
            .usize => "uintptr",
            .isize => "int",
            .c_char => "int8",
            .c_short => "int16",
            .c_ushort => "uint16",
            .c_int => "int32",
            .c_uint => "uint32",
            .c_long => "cLong",
            .c_ulong => "cULong",
            .c_longlong => "int64",
            .c_ulonglong => "uint64",
        },
    };
}

fn scalarUsesCLong(s: ir.Scalar) bool {
    return s == .int and (s.int == .c_long or s.int == .c_ulong);
}

fn typeUsesCLong(t: ir.Type) bool {
    return switch (t) {
        .scalar => |s| scalarUsesCLong(s),
        .out_ptr => |p| scalarUsesCLong(p.child),
        else => false,
    };
}

/// The Go type of a raw C-ABI parameter or result. Empty string means "no
/// result at all", which is how `void` is spelled in a Go signature.
fn abiType(arena: std.mem.Allocator, t: ir.Type) ![]const u8 {
    return switch (t) {
        .void => "",
        .scalar => |s| goScalar(s),
        .handle => "uintptr",
        .many_u8 => "*byte",
        .out_ptr => |p| try std.fmt.allocPrint(arena, "*{s}", .{goScalar(p.child)}),
        .unsupported => error.UnsupportedType,
    };
}

/// gofmt rewrites `*` bullets in doc comments into `-` (the Go 1.19 doc comment
/// dialect), so a Zig `///` comment copied through verbatim can leave the
/// generated file failing `gofmt -l` through no fault of the author. Normalize
/// it here rather than asking library authors to write their Zig docs in Go's
/// dialect.
fn goDoc(arena: std.mem.Allocator, doc: ?[]const u8) !?[]const u8 {
    const text = doc orelse return null;
    if (std.mem.indexOfScalar(u8, text, '*') == null) return text;

    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const indent = l.len - std.mem.trimStart(u8, l, " \t").len;
        const rest = l[indent..];
        if (std.mem.startsWith(u8, rest, "* ")) {
            try out.appendSlice(arena, l[0..indent]);
            try out.appendSlice(arena, "- ");
            try out.appendSlice(arena, rest[2..]);
        } else {
            try out.appendSlice(arena, l);
        }
    }
    return try out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Per-function roles
// ---------------------------------------------------------------------------

/// What a function becomes in the idiomatic layer. Every variant but `free`
/// carries the index of the handle it belongs to.
const Role = union(enum) {
    ctor: usize,
    /// The single destructor: folded into `Close`, never emitted on its own.
    dtor: usize,
    /// One of several destructor-shaped functions. Each is emitted as a method
    /// that consumes the receiver, because every one of them frees the handle
    /// and zbridge cannot tell which is *the* destructor.
    dtor_method: usize,
    method: usize,
    free,
};

const Go = struct {
    arena: std.mem.Allocator,
    ctx: gen.Context,
    api: ir.Api,
    pkg: []const u8,
    lib: []const u8,
    banner: []const u8,
    lc: ir.Lifecycle,
    roles: []const Role,
    /// Go type name per handle, parallel to `api.handles`.
    handle_type: []const []const u8,
    /// Method receiver identifier per handle.
    handle_recv: []const []const u8,
    needs_clong: bool,
    uses_unsafe: bool,
    /// True when some non-optional `[*]u8` parameter exists, which is what the
    /// package-level scratch array is for.
    needs_scratch: bool,

    fn init(arena: std.mem.Allocator, ctx: gen.Context) !Go {
        const api = ctx.api.*;
        const lc = try ir.lifecycle(arena, api);

        const handle_type = try arena.alloc([]const u8, api.handles.len);
        const handle_recv = try arena.alloc([]const u8, api.handles.len);
        for (api.handles, 0..) |h, i| {
            const t = try names.toPascal(arena, h.name);
            handle_type[i] = t;
            handle_recv[i] = if (t.len == 0)
                "h"
            else
                try std.fmt.allocPrint(arena, "{c}", .{std.ascii.toLower(t[0])});
        }

        const roles = try arena.alloc(Role, api.functions.len);
        for (roles) |*r| r.* = .free;
        for (api.handles, 0..) |_, hi| {
            for (lc.ctors[hi]) |fi| roles[fi] = .{ .ctor = hi };
            if (lc.dtorFor(hi)) |fi| {
                roles[fi] = .{ .dtor = hi };
            } else {
                // Zero candidates leaves this loop empty. With two or more,
                // `dtorFor` gives up -- but each candidate still *frees* the
                // handle by name, so none of them may fall through to the
                // ordinary `.method` classification, which would call the
                // native free and leave the wrapper pointing at freed memory.
                for (lc.dtors[hi]) |fi| roles[fi] = .{ .dtor_method = hi };
            }
        }
        for (api.functions, 0..) |f, fi| {
            if (roles[fi] != .free) continue;
            if (f.params.len == 0 or f.params[0].ty != .handle) continue;
            for (api.handles, 0..) |h, hi| {
                if (std.mem.eql(u8, h.name, f.params[0].ty.handle.name)) {
                    roles[fi] = .{ .method = hi };
                    break;
                }
            }
        }

        var needs_clong = false;
        var uses_unsafe = false;
        var needs_scratch = false;
        for (api.functions) |f| {
            if (typeUsesCLong(f.ret)) needs_clong = true;
            for (f.params) |p| {
                if (typeUsesCLong(p.ty)) needs_clong = true;
            }
            for (try ir.lower(arena, f)) |lg| {
                switch (lg) {
                    .bytes_in, .bytes_out => |pair| {
                        uses_unsafe = true;
                        if (!f.params[pair.ptr].ty.many_u8.optional) needs_scratch = true;
                    },
                    .cstr_in => uses_unsafe = true,
                    else => {},
                }
            }
        }

        return .{
            .arena = arena,
            .ctx = ctx,
            .api = api,
            .pkg = ctx.goPackage(),
            .lib = ctx.libName(),
            .banner = try gen.banner(arena, ctx, "//"),
            .lc = lc,
            .roles = roles,
            .handle_type = handle_type,
            .handle_recv = handle_recv,
            .needs_clong = needs_clong,
            .uses_unsafe = uses_unsafe,
            .needs_scratch = needs_scratch,
        };
    }

    fn add(
        self: *const Go,
        files: *gen.FileList,
        path: []const u8,
        bytes: []const u8,
        tier: gen.Tier,
    ) !void {
        try files.append(self.arena, .{
            .lang = .go,
            .path = path,
            .bytes = bytes,
            .tier = tier,
        });
    }

    fn goHandleName(self: *const Go, zig_name: []const u8) []const u8 {
        for (self.api.handles, 0..) |h, i| {
            if (std.mem.eql(u8, h.name, zig_name)) return self.handle_type[i];
        }
        return zig_name;
    }

    /// Unexported variable holding the raw binding for `c_name`.
    fn ffiVar(self: *const Go, c_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "fn{s}", .{try names.toPascal(self.arena, c_name)});
    }

    /// Exported Go name for a function, per the naming rule: strip the library
    /// prefix, then PascalCase.
    fn exportedName(self: *const Go, c_name: []const u8) ![]const u8 {
        return names.toPascal(self.arena, names.stripPrefix(c_name, self.lib));
    }

    // -----------------------------------------------------------------------
    // go.mod
    // -----------------------------------------------------------------------

    fn emitGoMod(self: *const Go, files: *gen.FileList) !void {
        const module_path = self.ctx.go.module_path orelse return;
        const bytes = try std.fmt.allocPrint(self.arena,
            \\module {s}
            \\
            \\go {s}
            \\
            \\require github.com/ebitengine/purego {s}
            \\
        , .{ module_path, self.ctx.go.go_directive, self.ctx.go.purego_version });
        try self.add(files, "go.mod", bytes, .user_scaffold);
    }

    // -----------------------------------------------------------------------
    // embed_*.go
    // -----------------------------------------------------------------------

    fn emitEmbeds(self: *const Go, files: *gen.FileList) !void {
        const arena = self.arena;

        for (self.ctx.targets) |t| {
            const nfo = targets.info(t);
            const lib_file = try targets.libFileName(arena, t, self.lib);

            var w: CodeWriter = .init(arena, "\t");
            defer w.deinit();

            try w.raw(self.banner);
            try w.blank();
            try w.line("//go:build {s} && {s}", .{ nfo.go_os, nfo.go_arch });
            try w.blank();
            try w.line("package {s}", .{self.pkg});
            try w.blank();
            try w.raw("import _ \"embed\"");
            try w.blank();
            try w.raw("// nativeLib is this platform's shared library, baked into the binary so");
            try w.raw("// that a program using these bindings has nothing else to install.");
            // gofmt insists on a blank comment line before a directive.
            try w.raw("//");
            try w.line("//go:embed native/{s}/{s}", .{ t.id(), lib_file });
            try w.raw("var nativeLib []byte");
            try w.blank();
            try w.raw("// nativeName is the file name nativeLib is extracted under.");
            try w.line("const nativeName = \"{s}\"", .{lib_file});

            const path = try std.fmt.allocPrint(arena, "embed_{s}_{s}.go", .{ nfo.go_os, nfo.go_arch });
            try self.add(files, path, try w.toOwnedSlice(), .generated);
        }

        var w: CodeWriter = .init(arena, "\t");
        defer w.deinit();

        try w.raw(self.banner);
        try w.blank();
        try w.part("//go:build !(", .{});
        for (self.ctx.targets, 0..) |t, i| {
            const nfo = targets.info(t);
            if (i > 0) try w.part(" || ", .{});
            try w.part("({s} && {s})", .{ nfo.go_os, nfo.go_arch });
        }
        try w.part(")", .{});
        try w.endLine();
        try w.blank();
        try w.line("package {s}", .{self.pkg});
        try w.blank();
        try w.raw("// No native library is embedded for this platform. The symbols still exist");
        try w.raw("// so the package compiles everywhere, and Load reports a clear error rather");
        try w.line("// than the build failing to link. {s} still works.", .{try self.envVarName()});
        try w.raw("var nativeLib []byte");
        try w.blank();
        try w.raw("const nativeName = \"\"");

        try self.add(files, "embed_unsupported.go", try w.toOwnedSlice(), .generated);
    }

    fn envVarName(self: *const Go) ![]const u8 {
        const upper = try self.arena.alloc(u8, self.lib.len);
        for (self.lib, 0..) |c, i| {
            upper[i] = if (c == '-' or c == '.') '_' else std.ascii.toUpper(c);
        }
        return std.fmt.allocPrint(self.arena, "{s}_LIB_PATH", .{upper});
    }

    // -----------------------------------------------------------------------
    // loader_gen.go and its two platform halves
    // -----------------------------------------------------------------------

    fn emitLoader(self: *const Go, files: *gen.FileList) !void {
        const arena = self.arena;

        var body: []const u8 = loader_template;
        body = try replaceAll(arena, body, "{{PACKAGE}}", self.pkg);
        body = try replaceAll(arena, body, "{{LIB}}", self.lib);
        body = try replaceAll(arena, body, "{{VERSION}}", self.ctx.version);
        body = try replaceAll(arena, body, "{{ABI_HEX}}", self.ctx.abi_hash_hex);
        body = try replaceAll(arena, body, "{{ENV}}", try self.envVarName());

        try self.add(
            files,
            "loader_gen.go",
            try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ self.banner, body }),
            .generated,
        );

        {
            var w: CodeWriter = .init(arena, "\t");
            defer w.deinit();
            try w.raw(self.banner);
            try w.blank();
            try w.raw("//go:build !windows");
            try w.blank();
            try w.line("package {s}", .{self.pkg});
            try w.blank();
            try w.raw("import \"github.com/ebitengine/purego\"");
            try w.blank();
            try w.raw("// dlOpen loads the library into this process. RTLD_LOCAL keeps its symbols");
            try w.raw("// out of the global namespace, so two libraries that happen to export the");
            try w.raw("// same name cannot shadow one another.");
            try w.raw("func dlOpen(path string) (uintptr, error) {");
            w.indent();
            try w.raw("return purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_LOCAL)");
            w.dedent();
            try w.raw("}");
            try w.blank();
            try w.raw("func dlClose(handle uintptr) error {");
            w.indent();
            try w.raw("return purego.Dlclose(handle)");
            w.dedent();
            try w.raw("}");
            try self.add(files, "loader_unix_gen.go", try w.toOwnedSlice(), .generated);
        }

        {
            var w: CodeWriter = .init(arena, "\t");
            defer w.deinit();
            try w.raw(self.banner);
            try w.blank();
            try w.raw("//go:build windows");
            try w.blank();
            try w.line("package {s}", .{self.pkg});
            try w.blank();
            try w.raw("import (");
            w.indent();
            try w.raw("\"path/filepath\"");
            try w.raw("\"syscall\"");
            w.dedent();
            try w.raw(")");
            try w.blank();
            try w.raw("// dlOpen loads the library into this process. purego has no Dlopen on");
            try w.raw("// Windows; it resolves symbols out of a HMODULE instead, which is what");
            try w.raw("// syscall.LoadLibrary returns.");
            try w.raw("//");
            try w.raw("// The path is made absolute first. LoadLibrary applies the full DLL search");
            try w.raw("// order to a relative name -- application directory, system directories,");
            try w.raw("// then %PATH% -- so a bare name out of the environment override could load");
            try w.raw("// a different file than the one that was named. An absolute path names one");
            try w.raw("// file and nothing else.");
            try w.raw("func dlOpen(path string) (uintptr, error) {");
            w.indent();
            try w.raw("abs, err := filepath.Abs(path)");
            try w.raw("if err != nil {");
            w.indent();
            try w.raw("return 0, err");
            w.dedent();
            try w.raw("}");
            try w.raw("handle, err := syscall.LoadLibrary(abs)");
            try w.raw("if err != nil {");
            w.indent();
            try w.raw("return 0, err");
            w.dedent();
            try w.raw("}");
            try w.raw("return uintptr(handle), nil");
            w.dedent();
            try w.raw("}");
            try w.blank();
            try w.raw("func dlClose(handle uintptr) error {");
            w.indent();
            try w.raw("return syscall.FreeLibrary(syscall.Handle(handle))");
            w.dedent();
            try w.raw("}");
            try self.add(files, "loader_windows_gen.go", try w.toOwnedSlice(), .generated);
        }
    }

    // -----------------------------------------------------------------------
    // ctypes_*.go — only when c_long / c_ulong actually appear
    // -----------------------------------------------------------------------

    fn emitCTypes(self: *const Go, files: *gen.FileList) !void {
        if (!self.needs_clong) return;
        const arena = self.arena;

        const Variant = struct {
            path: []const u8,
            build_tag: []const u8,
            signed: []const u8,
            unsigned: []const u8,
            note: []const u8,
        };
        const variants = [_]Variant{
            .{
                .path = "ctypes_other_gen.go",
                .build_tag = "!windows",
                .signed = "int",
                .unsigned = "uint",
                .note = "Everywhere except Windows, C's long is the width of a pointer, which is" ++
                    "\n// exactly what Go's int and uint are.",
            },
            .{
                .path = "ctypes_windows_gen.go",
                .build_tag = "windows",
                .signed = "int32",
                .unsigned = "uint32",
                .note = "Windows is LLP64: C's long is 32 bits there even on 64-bit builds, so" ++
                    "\n// Go's int would be twice too wide.",
            },
        };

        for (variants) |v| {
            var w: CodeWriter = .init(arena, "\t");
            defer w.deinit();
            try w.raw(self.banner);
            try w.blank();
            try w.line("//go:build {s}", .{v.build_tag});
            try w.blank();
            try w.line("package {s}", .{self.pkg});
            try w.blank();
            try w.raw("// cLong and cULong are Zig's c_long and c_ulong.");
            try w.raw("//");
            try w.line("// {s}", .{v.note});
            try w.raw("//");
            try w.raw("// They are aliases, not defined types, so a caller outside this package can");
            try w.raw("// still pass and receive plain Go integers where one appears.");
            try w.line("type cLong = {s}", .{v.signed});
            try w.blank();
            try w.line("type cULong = {s}", .{v.unsigned});
            try self.add(files, v.path, try w.toOwnedSlice(), .generated);
        }
    }

    // -----------------------------------------------------------------------
    // <lib>_ffi_gen.go
    // -----------------------------------------------------------------------

    fn emitFfi(self: *const Go, files: *gen.FileList) !void {
        const arena = self.arena;
        var w: CodeWriter = .init(arena, "\t");
        defer w.deinit();

        try w.raw(self.banner);
        try w.blank();
        try w.line("package {s}", .{self.pkg});
        try w.blank();
        try w.raw("import \"github.com/ebitengine/purego\"");
        try w.blank();
        try w.raw("// One variable per exported Zig function, each holding the raw C-ABI call.");
        try w.raw("// Nothing here adds behaviour: the widths are the ones the shared library");
        try w.raw("// actually uses, so a mistake in this file is a miscall, not a type error.");

        for (self.api.functions) |f| {
            try w.blank();
            const sig = try self.abiSignature(f);
            try w.line("// {s} calls {s}.", .{ try self.ffiVar(f.name), try self.zigSignature(f) });
            try w.line("var {s} {s}", .{ try self.ffiVar(f.name), sig });
        }

        try w.blank();
        try w.raw("// bind resolves every exported symbol out of an opened library. purego panics");
        try w.raw("// when a symbol is missing; the loader turns that into an error.");
        try w.raw("func bind(handle uintptr) {");
        w.indent();
        if (self.api.functions.len == 0) {
            try w.raw("_ = handle");
        } else {
            for (self.api.functions) |f| {
                try w.line("purego.RegisterLibFunc(&{s}, handle, \"{s}\")", .{
                    try self.ffiVar(f.name),
                    f.name,
                });
            }
        }
        w.dedent();
        try w.raw("}");

        const path = try std.fmt.allocPrint(arena, "{s}_ffi_gen.go", .{self.lib});
        try self.add(files, path, try w.toOwnedSlice(), .generated);
    }

    /// `func(uintptr, *byte, uintptr) int32`
    fn abiSignature(self: *const Go, f: ir.Function) ![]const u8 {
        const arena = self.arena;
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        try out.writer.writeAll("func(");
        for (f.params, 0..) |p, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(try abiType(arena, p.ty));
        }
        try out.writer.writeAll(")");
        const ret = try abiType(arena, f.ret);
        if (ret.len > 0) try out.writer.print(" {s}", .{ret});
        return arena.dupe(u8, out.written());
    }

    /// `zc_add(i32, i32) i32`, for the comment above the variable.
    fn zigSignature(self: *const Go, f: ir.Function) ![]const u8 {
        const arena = self.arena;
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        try out.writer.print("{s}(", .{f.name});
        for (f.params, 0..) |p, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try p.ty.write(&out.writer);
        }
        try out.writer.writeAll(") ");
        try f.ret.write(&out.writer);
        return arena.dupe(u8, out.written());
    }

    // -----------------------------------------------------------------------
    // <lib>_gen.go — the idiomatic layer
    // -----------------------------------------------------------------------

    fn emitIdiomatic(self: *const Go, files: *gen.FileList) !void {
        const arena = self.arena;
        var w: CodeWriter = .init(arena, "\t");
        defer w.deinit();

        try w.raw(self.banner);
        try w.blank();
        try w.line("package {s}", .{self.pkg});

        const has_handles = self.api.handles.len > 0;
        const needs_runtime = has_handles or self.uses_unsafe;

        var imports: std.ArrayList([]const u8) = .empty;
        if (has_handles) try imports.append(arena, "errors");
        if (needs_runtime) try imports.append(arena, "runtime");
        if (self.uses_unsafe) try imports.append(arena, "unsafe");

        if (imports.items.len == 1) {
            try w.blank();
            try w.line("import \"{s}\"", .{imports.items[0]});
        } else if (imports.items.len > 1) {
            try w.blank();
            try w.raw("import (");
            w.indent();
            for (imports.items) |name| try w.line("\"{s}\"", .{name});
            w.dedent();
            try w.raw(")");
        }

        if (has_handles) {
            try w.blank();
            try w.raw("// ErrNullHandle is returned by a constructor when the native library");
            try w.raw("// produced a null handle. The library itself decides what that means;");
            try w.raw("// these bindings only refuse to wrap it.");
            try w.line("var ErrNullHandle = errors.New(\"{s}: null handle\")", .{self.lib});
        }

        if (self.needs_scratch) {
            try w.blank();
            try w.raw("// emptyScratch backs the pointer passed for an empty slice when the Zig");
            try w.raw("// parameter is a plain `[*]u8`. Zig's many-item pointer is not optional:");
            try w.raw("// the callee may assume it is non-null even when the length is 0, so a nil");
            try w.raw("// pointer there is undefined behaviour rather than an empty buffer. One");
            try w.raw("// byte of package-level storage gives the callee a real address to hold");
            try w.raw("// while the length stays honestly 0. Nothing ever reads or writes it.");
            try w.raw("var emptyScratch [1]byte");
        }

        for (self.api.handles, 0..) |h, hi| {
            try self.emitHandle(&w, h, hi);
        }

        for (self.api.functions, 0..) |f, fi| {
            switch (self.roles[fi]) {
                .dtor => continue, // becomes Close
                else => {},
            }
            try w.blank();
            try self.emitFunction(&w, f, self.roles[fi]);
        }

        const path = try std.fmt.allocPrint(arena, "{s}_gen.go", .{self.lib});
        try self.add(files, path, try w.toOwnedSlice(), .generated);
    }

    fn emitHandle(self: *const Go, w: *CodeWriter, h: ir.Handle, hi: usize) !void {
        const t = self.handle_type[hi];
        const recv = self.handle_recv[hi];
        const dtor = self.lc.dtorFor(hi);

        try w.blank();
        try w.line("// {s} wraps the native `{s}` handle. The zero value is not usable; get one", .{ t, h.name });
        try w.raw("// from a constructor.");
        if (h.doc) |_| {
            try w.raw("//");
            try w.docComment("// ", try goDoc(self.arena, h.doc));
        }
        try w.line("type {s} struct {{", .{t});
        w.indent();
        try w.raw("h uintptr");
        w.dedent();
        try w.raw("}");

        try w.blank();
        if (dtor) |fi| {
            try w.line("// Close releases {s} by calling {s}.", .{ recv, self.api.functions[fi].name });
            try w.raw("//");
            try w.raw("// Close is idempotent: a second call is a no-op. It is not safe to call it");
            try w.raw("// concurrently with the other methods.");
        } else if (self.lc.dtors[hi].len > 1) {
            try w.line("// Close drops {s}'s reference to the native handle without releasing it.", .{recv});
            try w.line("// zbridge found more than one destructor-shaped function for {s} and", .{t});
            try w.raw("// cannot tell which one Close should call, so each is a method that");
            try w.raw("// consumes the receiver instead. Call one of them to free the handle:");
            try w.raw("//");
            for (self.lc.dtors[hi]) |fi| {
                const fname = self.api.functions[fi].name;
                try w.line("//   - {s} ({s})", .{ try self.exportedName(fname), fname });
            }
        } else {
            try w.line("// Close drops {s}'s reference to the native handle. zbridge found no", .{recv});
            try w.line("// destructor for {s} -- no `*_destroy`, `*_free`, `*_deinit`, `*_close` or", .{t});
            try w.line("// `*_release` function taking a single *{s} -- so nothing is released", .{h.name});
            try w.raw("// natively and freeing it stays the caller's problem.");
        }
        try w.line("func ({s} *{s}) Close() error {{", .{ recv, t });
        w.indent();
        try w.line("if {s} == nil || {s}.h == 0 {{", .{ recv, recv });
        w.indent();
        try w.raw("return nil");
        w.dedent();
        try w.raw("}");
        if (dtor) |fi| {
            try w.line("handle := {s}.h", .{recv});
            try w.line("{s}.h = 0", .{recv});
            try w.line("runtime.SetFinalizer({s}, nil)", .{recv});
            try w.line("{s}(handle)", .{try self.ffiVar(self.api.functions[fi].name)});
        } else {
            try w.line("{s}.h = 0", .{recv});
            try w.line("runtime.SetFinalizer({s}, nil)", .{recv});
        }
        try w.raw("return nil");
        w.dedent();
        try w.raw("}");
    }

    fn emitFunction(self: *const Go, w: *CodeWriter, f: ir.Function, role: Role) !void {
        const arena = self.arena;
        const logicals = try ir.lower(arena, f);

        const is_dtor_method = role == .dtor_method;
        const is_method = role == .method or is_dtor_method;
        const is_ctor = role == .ctor;
        const handle_index: usize = switch (role) {
            .ctor, .dtor, .dtor_method, .method => |hi| hi,
            .free => 0,
        };
        const go_name = try self.exportedName(f.name);

        // Go names for every raw parameter, and the set of identifiers already
        // in use so generated locals never shadow one.
        var taken: std.ArrayList([]const u8) = .empty;
        const arg_names = try arena.alloc([]const u8, f.params.len);
        for (f.params, 0..) |p, i| {
            arg_names[i] = try self.goParamName(p.name, i);
        }
        for (arg_names, 0..) |n, i| {
            if (is_method and i == 0) continue;
            try taken.append(arena, n);
        }

        const recv = if (is_method)
            try self.fresh(&taken, self.handle_recv[handle_index])
        else
            "";

        var go_params: std.ArrayList([]const u8) = .empty;
        var prep: std.ArrayList([]const u8) = .empty;
        var call_args: std.ArrayList([]const u8) = .empty;
        var keep: std.ArrayList([]const u8) = .empty;
        var out_names: std.ArrayList([]const u8) = .empty;
        var out_types: std.ArrayList([]const u8) = .empty;

        for (logicals, 0..) |lg, li| {
            if (is_method and li == 0) {
                const rh = f.params[0].ty.handle;
                const type_name = self.handle_type[handle_index];
                if (is_dtor_method) {
                    // This function frees the handle, so the wrapper is
                    // invalidated exactly the way Close does it -- before the
                    // call, so a panic inside the library cannot leave `h`
                    // pointing at memory the callee already freed.
                    const hv = try self.fresh(&taken, "handle");
                    if (rh.optional) {
                        try prep.append(arena, try std.fmt.allocPrint(
                            arena,
                            "var {s} uintptr\nif {s} != nil {{\n\t{s} = {s}.h\n\t{s}.h = 0\n\truntime.SetFinalizer({s}, nil)\n}}",
                            .{ hv, recv, hv, recv, recv, recv },
                        ));
                    } else {
                        try prep.append(arena, try std.fmt.allocPrint(
                            arena,
                            "if {s} == nil || {s}.h == 0 {{\n\tpanic(\"{s}: {s} used after Close\")\n}}\n" ++
                                "{s} := {s}.h\n{s}.h = 0\nruntime.SetFinalizer({s}, nil)",
                            .{ recv, recv, self.pkg, type_name, hv, recv, recv, recv },
                        ));
                    }
                    try call_args.append(arena, hv);
                } else if (rh.optional) {
                    // `?*T`: a null receiver is a value the library accepts.
                    const v = try self.fresh(&taken, try std.fmt.allocPrint(arena, "{s}Handle", .{recv}));
                    try prep.append(arena, try std.fmt.allocPrint(
                        arena,
                        "var {s} uintptr\nif {s} != nil {{\n\t{s} = {s}.h\n}}",
                        .{ v, recv, v, recv },
                    ));
                    try call_args.append(arena, v);
                } else {
                    // `*T` is non-optional in Zig, so 0 is not a value the
                    // library can be handed: a closed (or nil) receiver has to
                    // stop here rather than become undefined behaviour inside
                    // someone else's shared library.
                    try prep.append(arena, try std.fmt.allocPrint(
                        arena,
                        "if {s} == nil || {s}.h == 0 {{\n\tpanic(\"{s}: {s} used after Close\")\n}}",
                        .{ recv, recv, self.pkg, type_name },
                    ));
                    try call_args.append(arena, try std.fmt.allocPrint(arena, "{s}.h", .{recv}));
                }
                try keep.append(arena, recv);
                continue;
            }
            switch (lg) {
                .scalar => |i| {
                    try go_params.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{
                        arg_names[i],
                        goScalar(f.params[i].ty.scalar),
                    }));
                    try call_args.append(arena, arg_names[i]);
                },
                .handle => |i| {
                    const name = arg_names[i];
                    const href = f.params[i].ty.handle;
                    const type_name = self.goHandleName(href.name);
                    try go_params.append(arena, try std.fmt.allocPrint(arena, "{s} *{s}", .{ name, type_name }));
                    if (href.optional) {
                        // `?*T`: nil is a value the library accepts, so forward 0.
                        const v = try self.fresh(&taken, try std.fmt.allocPrint(arena, "{s}Handle", .{name}));
                        try prep.append(arena, try std.fmt.allocPrint(
                            arena,
                            "var {s} uintptr\nif {s} != nil {{\n\t{s} = {s}.h\n}}",
                            .{ v, name, v, name },
                        ));
                        try call_args.append(arena, v);
                    } else {
                        // `*T`: the library never sees null here, so refuse a
                        // nil or already-closed wrapper instead of quietly
                        // forwarding 0.
                        try prep.append(arena, try std.fmt.allocPrint(
                            arena,
                            "if {s} == nil || {s}.h == 0 {{\n\tpanic(\"{s}: nil *{s} passed to {s}\")\n}}",
                            .{ name, name, self.pkg, type_name, go_name },
                        ));
                        try call_args.append(arena, try std.fmt.allocPrint(arena, "{s}.h", .{name}));
                    }
                    try keep.append(arena, name);
                },
                .bytes_in, .bytes_out => |pair| {
                    const name = arg_names[pair.ptr];
                    try go_params.append(arena, try std.fmt.allocPrint(arena, "{s} []byte", .{name}));
                    const v = try self.fresh(&taken, try std.fmt.allocPrint(arena, "{s}Ptr", .{name}));
                    // unsafe.SliceData is only documented to return nil for a
                    // nil slice, not for every empty one, so guard the length
                    // rather than trusting what it happens to return.
                    if (f.params[pair.ptr].ty.many_u8.optional) {
                        try prep.append(arena, try std.fmt.allocPrint(
                            arena,
                            "var {s} *byte\nif len({s}) > 0 {{\n\t{s} = unsafe.SliceData({s})\n}}",
                            .{ v, name, v, name },
                        ));
                    } else {
                        // Non-optional `[*]u8`: nil is not a value it can hold,
                        // so an empty slice gets the scratch byte's address.
                        try prep.append(arena, try std.fmt.allocPrint(
                            arena,
                            "{s} := &emptyScratch[0]\nif len({s}) > 0 {{\n\t{s} = unsafe.SliceData({s})\n}}",
                            .{ v, name, v, name },
                        ));
                    }
                    try call_args.append(arena, v);
                    try call_args.append(arena, try std.fmt.allocPrint(arena, "uintptr(len({s}))", .{name}));
                    try keep.append(arena, name);
                },
                .cstr_in => |i| {
                    const name = arg_names[i];
                    try go_params.append(arena, try std.fmt.allocPrint(arena, "{s} string", .{name}));
                    const v = try self.fresh(&taken, try std.fmt.allocPrint(arena, "{s}Bytes", .{name}));
                    try prep.append(arena, try std.fmt.allocPrint(
                        arena,
                        "{s} := append([]byte({s}), 0)",
                        .{ v, name },
                    ));
                    try call_args.append(arena, try std.fmt.allocPrint(arena, "unsafe.SliceData({s})", .{v}));
                    try keep.append(arena, v);
                },
                .out_ptr => |i| {
                    const type_name = goScalar(f.params[i].ty.out_ptr.child);
                    const v = try self.fresh(&taken, try std.fmt.allocPrint(arena, "{s}Out", .{arg_names[i]}));
                    try prep.append(arena, try std.fmt.allocPrint(arena, "var {s} {s}", .{ v, type_name }));
                    try call_args.append(arena, try std.fmt.allocPrint(arena, "&{s}", .{v}));
                    try out_names.append(arena, v);
                    try out_types.append(arena, type_name);
                },
            }
        }

        const ret_type = try self.idiomaticRetType(f.ret);
        const ret_var = if (ret_type.len > 0) try self.fresh(&taken, "cRet") else "";

        // Result list.
        var res_types: std.ArrayList([]const u8) = .empty;
        if (is_ctor) {
            try res_types.append(arena, try std.fmt.allocPrint(arena, "*{s}", .{self.handle_type[handle_index]}));
        } else if (ret_type.len > 0) {
            try res_types.append(arena, ret_type);
        }
        for (out_types.items) |t| try res_types.append(arena, t);
        if (is_ctor) try res_types.append(arena, "error");

        // ---- signature ----
        try w.line("// {s} wraps the exported Zig function {s}.", .{ go_name, f.name });
        if (f.doc) |_| {
            try w.raw("//");
            try w.docComment("// ", try goDoc(self.arena, f.doc));
        }
        if (is_dtor_method) {
            const t = self.handle_type[handle_index];
            try w.raw("//");
            try w.line("// {s} CONSUMES {s}: the native call releases the handle, so {s} is left", .{ go_name, recv, recv });
            try w.line("// closed exactly as Close leaves it and a later call on {s} panics.", .{recv});
            try w.raw("//");
            try w.line("// zbridge could not tell which of {s}'s {d} destructor-shaped functions is", .{ t, self.lc.dtors[handle_index].len });
            try w.raw("// the destructor, so none of them is folded into Close and each one consumes");
            try w.part("// the receiver. The candidates are: ", .{});
            for (self.lc.dtors[handle_index], 0..) |fi, i| {
                if (i > 0) try w.part(", ", .{});
                try w.part("{s}", .{self.api.functions[fi].name});
            }
            try w.part(".", .{});
            try w.endLine();
        }
        if (!is_ctor and f.ret == .handle) {
            try w.raw("//");
            try w.line("// The returned *{s} has no finalizer attached: whether the caller owns it", .{ret_type[1..]});
            try w.raw("// is not something the signature says, so Close is left to you.");
        }

        if (is_method) {
            try w.part("func ({s} *{s}) {s}(", .{ recv, self.handle_type[handle_index], go_name });
        } else {
            try w.part("func {s}(", .{go_name});
        }
        for (go_params.items, 0..) |p, i| {
            if (i > 0) try w.part(", ", .{});
            try w.part("{s}", .{p});
        }
        try w.part(")", .{});
        if (res_types.items.len == 1) {
            try w.part(" {s}", .{res_types.items[0]});
        } else if (res_types.items.len > 1) {
            try w.part(" (", .{});
            for (res_types.items, 0..) |t, i| {
                if (i > 0) try w.part(", ", .{});
                try w.part("{s}", .{t});
            }
            try w.part(")", .{});
        }
        try w.part(" {{", .{});
        try w.endLine();

        // ---- body ----
        w.indent();
        try w.raw("mustLoad()");
        for (prep.items) |p| try w.block(p);

        try w.part("", .{});
        if (ret_var.len > 0) try w.part("{s} := ", .{ret_var});
        try w.part("{s}(", .{try self.ffiVar(f.name)});
        for (call_args.items, 0..) |a, i| {
            if (i > 0) try w.part(", ", .{});
            try w.part("{s}", .{a});
        }
        try w.part(")", .{});
        try w.endLine();

        for (keep.items) |k| try w.line("runtime.KeepAlive({s})", .{k});

        try self.emitReturn(w, .{
            .is_ctor = is_ctor,
            .handle_index = handle_index,
            .ret = f.ret,
            .ret_var = ret_var,
            .out_names = out_names.items,
            .taken = &taken,
        });

        w.dedent();
        try w.raw("}");
    }

    const ReturnSpec = struct {
        is_ctor: bool,
        handle_index: usize,
        ret: ir.Type,
        ret_var: []const u8,
        out_names: []const []const u8,
        taken: *std.ArrayList([]const u8),
    };

    fn emitReturn(self: *const Go, w: *CodeWriter, spec: ReturnSpec) !void {
        if (spec.is_ctor) {
            const t = self.handle_type[spec.handle_index];
            try w.line("if {s} == 0 {{", .{spec.ret_var});
            w.indent();
            try w.part("return nil", .{});
            for (spec.out_names) |o| try w.part(", {s}", .{o});
            try w.part(", ErrNullHandle", .{});
            try w.endLine();
            w.dedent();
            try w.raw("}");
            const obj = try self.fresh(spec.taken, "wrapped");
            try w.line("{s} := &{s}{{h: {s}}}", .{ obj, t, spec.ret_var });
            if (self.lc.dtorFor(spec.handle_index) != null) {
                try w.line("runtime.SetFinalizer({s}, func(v *{s}) {{ _ = v.Close() }})", .{ obj, t });
            }
            try w.part("return {s}", .{obj});
            for (spec.out_names) |o| try w.part(", {s}", .{o});
            try w.part(", nil", .{});
            try w.endLine();
            return;
        }

        if (spec.ret == .handle) {
            const t = self.goHandleName(spec.ret.handle.name);
            const obj = try self.fresh(spec.taken, "wrapped");
            try w.line("var {s} *{s}", .{ obj, t });
            try w.line("if {s} != 0 {{", .{spec.ret_var});
            w.indent();
            try w.line("{s} = &{s}{{h: {s}}}", .{ obj, t, spec.ret_var });
            w.dedent();
            try w.raw("}");
            try w.part("return {s}", .{obj});
            for (spec.out_names) |o| try w.part(", {s}", .{o});
            try w.endLine();
            return;
        }

        const has_primary = spec.ret_var.len > 0;
        if (!has_primary and spec.out_names.len == 0) return;

        try w.part("return ", .{});
        var first = true;
        if (has_primary) {
            try w.part("{s}", .{spec.ret_var});
            first = false;
        }
        for (spec.out_names) |o| {
            if (!first) try w.part(", ", .{});
            try w.part("{s}", .{o});
            first = false;
        }
        try w.endLine();
    }

    fn idiomaticRetType(self: *const Go, t: ir.Type) ![]const u8 {
        return switch (t) {
            .void => "",
            .scalar => |s| goScalar(s),
            .handle => |h| try std.fmt.allocPrint(self.arena, "*{s}", .{self.goHandleName(h.name)}),
            .many_u8 => "*byte",
            .out_ptr => |p| try std.fmt.allocPrint(self.arena, "*{s}", .{goScalar(p.child)}),
            .unsupported => error.UnsupportedType,
        };
    }

    /// Go-flavoured parameter name: camelCase first so keyword checks see the
    /// identifier that actually lands in the file.
    fn goParamName(self: *const Go, zig_name: []const u8, index: usize) ![]const u8 {
        const camel = try names.toCamel(self.arena, zig_name);
        const safe = try names.safeParamName(self.arena, camel, index);
        // These would shadow a package the generated code imports, or the
        // package-level scratch array the empty-slice guard points at.
        const shadows = [_][]const u8{ "unsafe", "runtime", "purego", "errors", "syscall", "emptyScratch" };
        for (shadows) |s| {
            if (std.mem.eql(u8, s, safe)) {
                return std.fmt.allocPrint(self.arena, "{s}_", .{safe});
            }
        }
        return safe;
    }

    fn fresh(self: *const Go, taken: *std.ArrayList([]const u8), base: []const u8) ![]const u8 {
        var candidate = base;
        while (contains(taken.items, candidate)) {
            candidate = try std.fmt.allocPrint(self.arena, "{s}_", .{candidate});
        }
        try taken.append(self.arena, candidate);
        return candidate;
    }

    // -----------------------------------------------------------------------
    // <lib>.go — the user's file
    // -----------------------------------------------------------------------

    fn emitScaffold(self: *const Go, files: *gen.FileList) !void {
        const bytes = try std.fmt.allocPrint(self.arena,
            \\package {s}
            \\
            \\// This file is yours. zbridge writes it once and never regenerates or
            \\// overwrites it. Put hand-written helpers, option types and anything else
            \\// that needs judgement here.
            \\//
            \\// Everything in the *_gen.go files is rewritten from the Zig source on every
            \\// run, so edits there are lost.
            \\
        , .{self.pkg});
        const path = try std.fmt.allocPrint(self.arena, "{s}.go", .{self.lib});
        try self.add(files, path, bytes, .user_scaffold);
    }
};

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

fn replaceAll(
    arena: std.mem.Allocator,
    text: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const size = std.mem.replacementSize(u8, text, needle, replacement);
    const buf = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, text, needle, replacement, buf);
    return buf;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sInt(k: ir.IntKind) ir.Type {
    return .{ .scalar = .{ .int = k } };
}

fn handleType(name: []const u8, optional: bool) ir.Type {
    return .{ .handle = .{ .name = name, .optional = optional, .is_const = false } };
}

/// One API that exercises every shape the generator has a rule for: an opaque
/// handle with a constructor and a destructor, a method, bytes in, bytes out,
/// a C string, an out-parameter, a c_long, and a package-level function.
///
/// `Ctx` covers the memory-safety rules that only show up in the awkward
/// shapes: two destructor-shaped functions and no way to tell which is the
/// destructor, an optional receiver, an optional and a non-optional handle
/// parameter side by side, and an optional byte buffer.
const golden_api: ir.Api = .{
    .lib_name = "zdemo",
    .handles = &.{
        .{ .name = "Doc", .doc = "An open document." },
        .{ .name = "Ctx", .doc = "A rendering context." },
    },
    .functions = &.{
        .{
            .name = "zdemo_doc_open",
            .doc = "Open the document at `path`. Returns null when it cannot be read.",
            .ret = handleType("Doc", true),
            .params = &.{.{ .name = "path", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = true } } }},
        },
        .{
            .name = "zdemo_doc_close",
            .ret = .void,
            .params = &.{.{ .name = "doc", .ty = handleType("Doc", false) }},
        },
        .{
            .name = "zdemo_doc_write",
            .doc = "Append `data` to the document.\nReturns the number of bytes written.",
            .ret = sInt(.i32),
            .params = &.{
                .{ .name = "doc", .ty = handleType("Doc", false) },
                .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false } } },
                .{ .name = "len", .ty = sInt(.usize) },
            },
        },
        .{
            .name = "zdemo_doc_read",
            .ret = .{ .scalar = .bool },
            .params = &.{
                .{ .name = "doc", .ty = handleType("Doc", false) },
                .{ .name = "out", .ty = .{ .many_u8 = .{ .is_const = false, .sentinel_zero = false } } },
                .{ .name = "out_len", .ty = sInt(.usize) },
                .{ .name = "written", .ty = .{ .out_ptr = .{ .child = .{ .int = .usize }, .optional = false } } },
            },
        },
        .{
            .name = "zdemo_doc_seek",
            .ret = sInt(.c_long),
            .params = &.{
                .{ .name = "doc", .ty = handleType("Doc", false) },
                .{ .name = "offset", .ty = sInt(.c_long) },
            },
        },
        .{
            .name = "zdemo_add",
            .doc = "Add two numbers. The obligatory smoke test.",
            .ret = sInt(.i32),
            .params = &.{
                .{ .name = "a", .ty = sInt(.i32) },
                .{ .name = "b", .ty = sInt(.i32) },
            },
        },
        .{
            .name = "zdemo_scale",
            .ret = .{ .scalar = .{ .float = .f64 } },
            .params = &.{
                .{ .name = "value", .ty = .{ .scalar = .{ .float = .f64 } } },
                .{ .name = "factor", .ty = .{ .scalar = .{ .float = .f32 } } },
            },
        },
        .{
            .name = "zdemo_ctx_new",
            .doc = "Create a rendering context.",
            .ret = handleType("Ctx", true),
            .params = &.{},
        },
        // Two destructor-shaped names for one handle: both free it, and
        // neither may be emitted as an ordinary method.
        .{
            .name = "zdemo_ctx_free",
            .ret = .void,
            .params = &.{.{ .name = "ctx", .ty = handleType("Ctx", false) }},
        },
        .{
            .name = "zdemo_ctx_close",
            .ret = .void,
            .params = &.{.{ .name = "ctx", .ty = handleType("Ctx", false) }},
        },
        // An optional receiver: a nil *Ctx is a value this one accepts.
        .{
            .name = "zdemo_ctx_depth",
            .ret = sInt(.i32),
            .params = &.{.{ .name = "ctx", .ty = handleType("Ctx", true) }},
        },
        .{
            .name = "zdemo_doc_render",
            .ret = sInt(.i32),
            .params = &.{
                .{ .name = "doc", .ty = handleType("Doc", false) },
                .{ .name = "ctx", .ty = handleType("Ctx", false) },
                .{ .name = "overlay", .ty = handleType("Ctx", true) },
            },
        },
        .{
            .name = "zdemo_doc_hint",
            .ret = .void,
            .params = &.{
                .{ .name = "doc", .ty = handleType("Doc", false) },
                .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false, .optional = true } } },
                .{ .name = "len", .ty = sInt(.usize) },
            },
        },
    },
};

const golden_targets = [_]targets.Target{ .linux_x86_64, .windows_x86_64 };

fn goldenContext() gen.Context {
    return .{
        .api = &golden_api,
        .abi_hash = 0x0123456789abcdef,
        .abi_hash_hex = "0123456789abcdef",
        .targets = &golden_targets,
        .link_libc = false,
        .version = "0.1.0",
        .input_path = "src/c_api.zig",
        .go = .{
            .module_path = "github.com/example/zdemo-go",
            .purego_version = "v0.9.0",
        },
    };
}

fn goldenFiles(arena: std.mem.Allocator) ![]const gen.OutFile {
    var files: gen.FileList = .empty;
    try generate(arena, goldenContext(), &files);
    return files.toOwnedSlice(arena);
}

fn findFile(files: []const gen.OutFile, path: []const u8) ?gen.OutFile {
    for (files) |f| {
        if (std.mem.eql(u8, f.path, path)) return f;
    }
    return null;
}

const golden_expected = [_]struct { path: []const u8, want: []const u8, tier: gen.Tier }{
    .{ .path = "go.mod", .want = @embedFile("testdata/go/go.mod.golden"), .tier = .user_scaffold },
    .{ .path = "embed_linux_amd64.go", .want = @embedFile("testdata/go/embed_linux_amd64.go.golden"), .tier = .generated },
    .{ .path = "embed_windows_amd64.go", .want = @embedFile("testdata/go/embed_windows_amd64.go.golden"), .tier = .generated },
    .{ .path = "embed_unsupported.go", .want = @embedFile("testdata/go/embed_unsupported.go.golden"), .tier = .generated },
    .{ .path = "loader_gen.go", .want = @embedFile("testdata/go/loader_gen.go.golden"), .tier = .generated },
    .{ .path = "loader_unix_gen.go", .want = @embedFile("testdata/go/loader_unix_gen.go.golden"), .tier = .generated },
    .{ .path = "loader_windows_gen.go", .want = @embedFile("testdata/go/loader_windows_gen.go.golden"), .tier = .generated },
    .{ .path = "ctypes_other_gen.go", .want = @embedFile("testdata/go/ctypes_other_gen.go.golden"), .tier = .generated },
    .{ .path = "ctypes_windows_gen.go", .want = @embedFile("testdata/go/ctypes_windows_gen.go.golden"), .tier = .generated },
    .{ .path = "zdemo_ffi_gen.go", .want = @embedFile("testdata/go/zdemo_ffi_gen.go.golden"), .tier = .generated },
    .{ .path = "zdemo_gen.go", .want = @embedFile("testdata/go/zdemo_gen.go.golden"), .tier = .generated },
    .{ .path = "zdemo.go", .want = @embedFile("testdata/go/zdemo.go.golden"), .tier = .user_scaffold },
};

test "go generator matches the golden output" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = try goldenFiles(arena);
    try testing.expectEqual(golden_expected.len, files.len);

    for (golden_expected) |exp| {
        const got = findFile(files, exp.path) orelse {
            std.debug.print("go generator did not emit {s}\n", .{exp.path});
            return error.MissingFile;
        };
        try testing.expectEqual(exp.tier, got.tier);
        testing.expectEqualStrings(exp.want, got.bytes) catch |err| {
            std.debug.print("go generator: {s} differs from its golden\n", .{exp.path});
            return err;
        };
    }
}

test "go generator writes only scaffolds as user_scaffold" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (try goldenFiles(arena)) |f| {
        try testing.expectEqual(gen.Lang.go, f.lang);
        const is_scaffold = std.mem.eql(u8, f.path, "go.mod") or std.mem.eql(u8, f.path, "zdemo.go");
        try testing.expectEqual(is_scaffold, f.tier == .user_scaffold);
        // Deterministic output: LF only, and a trailing newline.
        try testing.expect(std.mem.indexOfScalar(u8, f.bytes, '\r') == null);
        try testing.expect(std.mem.endsWith(u8, f.bytes, "\n"));
    }
}

test "go generator omits go.mod without a module path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = goldenContext();
    ctx.go.module_path = null;

    var files: gen.FileList = .empty;
    try generate(arena, ctx, &files);
    try testing.expect(findFile(files.items, "go.mod") == null);
    try testing.expect(findFile(files.items, "zdemo_gen.go") != null);
}

test "go generator omits the c_long aliases when nothing uses them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "zc_add",
            .ret = sInt(.i32),
            .params = &.{
                .{ .name = "a", .ty = sInt(.i32) },
                .{ .name = "b", .ty = sInt(.i32) },
            },
        }},
    };
    var ctx = goldenContext();
    ctx.api = &api;

    var files: gen.FileList = .empty;
    try generate(arena, ctx, &files);
    try testing.expect(findFile(files.items, "ctypes_other_gen.go") == null);
    try testing.expect(findFile(files.items, "ctypes_windows_gen.go") == null);

    // No handles and no buffers: the idiomatic file imports nothing.
    const idiomatic = findFile(files.items, "zc_gen.go").?;
    try testing.expect(std.mem.indexOf(u8, idiomatic.bytes, "import") == null);
    try testing.expect(std.mem.indexOf(u8, idiomatic.bytes, "func Add(a int32, b int32) int32 {") != null);
}

test "go generator maps the scalar types" {
    try testing.expectEqualStrings("uintptr", goScalar(.{ .int = .usize }));
    try testing.expectEqualStrings("int", goScalar(.{ .int = .isize }));
    try testing.expectEqualStrings("int32", goScalar(.{ .int = .c_int }));
    try testing.expectEqualStrings("cLong", goScalar(.{ .int = .c_long }));
    try testing.expectEqualStrings("uint64", goScalar(.{ .int = .c_ulonglong }));
    try testing.expectEqualStrings("float32", goScalar(.{ .float = .f32 }));
    try testing.expectEqualStrings("bool", goScalar(.bool));
}

test "go generator rewrites doc bullets into gofmt's dialect" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // gofmt turns `*` list markers into `-`, so a doc comment copied straight
    // from Zig would otherwise make the generated file fail `gofmt -l`.
    try std.testing.expectEqualStrings(
        \\Writes the digest:
        \\
        \\  - out_len >= 8 writes 8 bytes;
        \\  - out_len == 0 writes nothing.
    , (try goDoc(arena,
        \\Writes the digest:
        \\
        \\  * out_len >= 8 writes 8 bytes;
        \\  * out_len == 0 writes nothing.
    )).?);

    // A `*` that isn't a list marker is left alone, as is a doc with none.
    try std.testing.expectEqualStrings(
        "the result of a*b",
        (try goDoc(arena, "the result of a*b")).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), try goDoc(arena, null));
}

// --- memory safety -----------------------------------------------------------
//
// One test per rule the generated bindings have to keep. They read the
// generated text rather than the goldens so a golden that was updated without
// being read still fails here.

fn generatedFile(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return (findFile(try goldenFiles(arena), path) orelse return error.MissingFile).bytes;
}

/// `func ... <name>(` with its doc comment, up to the closing brace at column 0.
fn goFunc(src: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, name)) |i| {
        from = i + name.len;
        var line_start = if (std.mem.lastIndexOfScalar(u8, src[0..i], '\n')) |n| n + 1 else 0;
        if (!std.mem.startsWith(u8, src[line_start..], "func ")) continue;
        // Walk back over the doc comment so a test can assert on it too.
        while (line_start > 0) {
            const prev_end = line_start - 1;
            const prev_start = if (std.mem.lastIndexOfScalar(u8, src[0..prev_end], '\n')) |n| n + 1 else 0;
            if (!std.mem.startsWith(u8, src[prev_start..], "//")) break;
            line_start = prev_start;
        }
        const end = std.mem.indexOfPos(u8, src, i, "\n}\n") orelse src.len;
        return src[line_start..end];
    }
    return null;
}

test "go generator turns every destructor candidate into a consuming method" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = try generatedFile(arena, "zdemo_gen.go");

    // Ctx has two destructor-shaped functions, so `dtorFor` gives up. Neither
    // may become an ordinary method that frees the handle behind the wrapper's
    // back: each has to invalidate the receiver exactly as Close does.
    for ([_][]const u8{ "CtxFree", "CtxClose" }) |name| {
        const body = goFunc(src, name) orelse {
            std.debug.print("no method named {s}\n", .{name});
            return error.MissingMethod;
        };
        try testing.expect(std.mem.indexOf(u8, body, "func (c *Ctx) ") != null);
        try testing.expect(std.mem.indexOf(u8, body, "CONSUMES c") != null);
        try testing.expect(std.mem.indexOf(u8, body, "could not tell which of Ctx's 2") != null);
        // Capture, invalidate, then call -- and never `c.h` at the call site.
        try testing.expect(std.mem.indexOf(u8, body, "handle := c.h\n\tc.h = 0\n\truntime.SetFinalizer(c, nil)") != null);
        try testing.expect(std.mem.indexOf(u8, body, "(handle)\n") != null);
        try testing.expect(std.mem.indexOf(u8, body, "(c.h)") == null);
        try testing.expect(std.mem.indexOf(u8, body, "panic(\"zdemo: Ctx used after Close\")") != null);
    }

    // Close cannot pick one of them, so it releases nothing and says so.
    const ctx_close = std.mem.indexOf(u8, src, "func (c *Ctx) Close() error {").?;
    const ctx_close_body = src[ctx_close..(std.mem.indexOfPos(u8, src, ctx_close, "\n}\n").?)];
    try testing.expect(std.mem.indexOf(u8, ctx_close_body, "fnZdemoCtx") == null);
    try testing.expect(std.mem.indexOf(u8, src, "//   - CtxFree (zdemo_ctx_free)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "//   - CtxClose (zdemo_ctx_close)") != null);

    // Doc has exactly one, which stays folded into Close and is not a method.
    try testing.expect(std.mem.indexOf(u8, src, "fnZdemoDocClose(handle)") != null);
    try testing.expect(goFunc(src, "DocClose") == null);
}

test "go generator refuses a closed receiver for a non-optional handle" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = try generatedFile(arena, "zdemo_gen.go");

    // `*Doc` receivers: a zeroed handle must stop here, not become a null
    // pointer the library is entitled to assume is non-null.
    for ([_][]const u8{ "DocWrite", "DocRead", "DocSeek", "DocRender", "DocHint" }) |name| {
        const body = goFunc(src, name) orelse return error.MissingMethod;
        try testing.expect(std.mem.indexOf(
            u8,
            body,
            "if d == nil || d.h == 0 {\n\t\tpanic(\"zdemo: Doc used after Close\")\n\t}",
        ) != null);
    }

    // `?*Ctx` receiver: nil is a value the library accepts, so it is forwarded
    // as 0 and nothing panics.
    const depth = goFunc(src, "CtxDepth") orelse return error.MissingMethod;
    try testing.expect(std.mem.indexOf(u8, depth, "panic(") == null);
    try testing.expect(std.mem.indexOf(u8, depth, "var cHandle uintptr\n\tif c != nil {\n\t\tcHandle = c.h\n\t}") != null);
}

test "go generator splits handle parameters by optionality" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = try generatedFile(arena, "zdemo_gen.go");
    const body = goFunc(src, "DocRender") orelse return error.MissingMethod;

    // `ctx: *Ctx` -- nil is not a value it can hold.
    try testing.expect(std.mem.indexOf(
        u8,
        body,
        "if ctx == nil || ctx.h == 0 {\n\t\tpanic(\"zdemo: nil *Ctx passed to DocRender\")\n\t}",
    ) != null);
    // `overlay: ?*Ctx` -- nil is legal and keeps forwarding 0.
    try testing.expect(std.mem.indexOf(
        u8,
        body,
        "var overlayHandle uintptr\n\tif overlay != nil {\n\t\toverlayHandle = overlay.h\n\t}",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, body, "fnZdemoDocRender(d.h, ctx.h, overlayHandle)") != null);
}

test "go generator gives an empty non-optional buffer a valid pointer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = try generatedFile(arena, "zdemo_gen.go");
    try testing.expect(std.mem.indexOf(u8, src, "var emptyScratch [1]byte") != null);

    // `[*]const u8` and `[*]u8`: never null, so an empty slice gets the
    // scratch byte's address and an honest length of 0.
    const write = goFunc(src, "DocWrite") orelse return error.MissingMethod;
    try testing.expect(std.mem.indexOf(
        u8,
        write,
        "dataPtr := &emptyScratch[0]\n\tif len(data) > 0 {\n\t\tdataPtr = unsafe.SliceData(data)\n\t}",
    ) != null);
    const read = goFunc(src, "DocRead") orelse return error.MissingMethod;
    try testing.expect(std.mem.indexOf(u8, read, "outPtr := &emptyScratch[0]") != null);

    // `?[*]const u8`: nil is a value it can hold, so nothing changes.
    const hint = goFunc(src, "DocHint") orelse return error.MissingMethod;
    try testing.expect(std.mem.indexOf(u8, hint, "emptyScratch") == null);
    try testing.expect(std.mem.indexOf(
        u8,
        hint,
        "var dataPtr *byte\n\tif len(data) > 0 {\n\t\tdataPtr = unsafe.SliceData(data)\n\t}",
    ) != null);
}

test "go generator omits the scratch array when no buffer needs it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api: ir.Api = .{
        .lib_name = "zc",
        .handles = &.{},
        .functions = &.{.{
            .name = "zc_hint",
            .ret = .void,
            .params = &.{
                .{ .name = "data", .ty = .{ .many_u8 = .{ .is_const = true, .sentinel_zero = false, .optional = true } } },
                .{ .name = "len", .ty = sInt(.usize) },
            },
        }},
    };
    var ctx = goldenContext();
    ctx.api = &api;

    var files: gen.FileList = .empty;
    try generate(arena, ctx, &files);
    const src = findFile(files.items, "zc_gen.go").?.bytes;
    try testing.expect(std.mem.indexOf(u8, src, "emptyScratch") == null);
    try testing.expect(std.mem.indexOf(u8, src, "var dataPtr *byte") != null);
}

test "go loader verifies the cached file by content, not by size" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = try generatedFile(arena, "loader_gen.go");

    // The cache directory name is derived from the embedded bytes and says
    // nothing about the file on disk, so a size comparison lets anyone who can
    // write to that directory hand this process a library to dlopen.
    try testing.expect(std.mem.indexOf(u8, src, "info.Size()") == null);
    try testing.expect(std.mem.indexOf(u8, src, "func fileHasDigest(path string, want [sha256.Size]byte) bool {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "if fileHasDigest(path, sum) {") != null);
    // The write path the reviewer confirmed is correct stays as it was.
    try testing.expect(std.mem.indexOf(u8, src, "os.CreateTemp(dir, nativeName+\".tmp-*\")") != null);
    try testing.expect(std.mem.indexOf(u8, src, "os.Rename(tmpName, path)") != null);

    // A failure after the library is open closes it again, whichever step
    // failed: purego panics are caught where the caller can still dlClose.
    try testing.expect(std.mem.indexOf(u8, src, "if err := checkABI(handle); err != nil {\n\t\t_ = dlClose(handle)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "if err := bindAll(handle); err != nil {\n\t\t_ = dlClose(handle)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "func bindAll(handle uintptr) (err error) {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "func checkABI(handle uintptr) (err error) {") != null);
}

test "go windows loader resolves the library path before loading it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A relative name sends LoadLibrary through the whole DLL search order,
    // which can find a different file than the one the caller named.
    const src = try generatedFile(arena, "loader_windows_gen.go");
    try testing.expect(std.mem.indexOf(u8, src, "abs, err := filepath.Abs(path)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "syscall.LoadLibrary(abs)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "syscall.LoadLibrary(path)") == null);
}
