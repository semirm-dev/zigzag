//! Zig source -> IR. Implemented against `std.zig.Ast`, the same parser
//! `zig fmt` uses, so the user's own code is the only source of truth.
//!
//! The parser is deliberately total: the only failure it reports is a source
//! file that does not parse as Zig. Every other problem — a struct by value, an
//! error union, a pointer to an undeclared type — becomes `ir.Type.unsupported`
//! carrying the original source text, so the validator can report *all* of them
//! at once instead of stopping at the first.

const std = @import("std");
const Ast = std.zig.Ast;
const ir = @import("ir.zig");
const diag = @import("diagnostics.zig");

/// How far a chain of `const A = B;` aliases is followed. Aliases exist so an
/// `export fn` can name a shorthand, not to support type-level indirection, so
/// the limit doubles as cycle protection without a visited set.
const max_alias_depth = 8;

/// Parse one file's top-level declarations. Returns null only when the source
/// does not parse as Zig; an unsupported *type* is not a parse failure, it is
/// recorded as `ir.Type.unsupported` for the validator to report.
pub fn parseSource(
    arena: std.mem.Allocator,
    lib_name: []const u8,
    source: [:0]const u8,
    diags: *diag.List,
) !?ir.Api {
    var tree = try Ast.parse(arena, source, .zig);

    if (tree.errors.len > 0) {
        try reportParseErrors(arena, tree, diags);
        return null;
    }

    var w: Walker = .{ .arena = arena, .tree = &tree };

    // One sweep for every declaration that a later `export fn` may refer to,
    // so order inside the file never matters.
    for (tree.rootDecls()) |node| {
        const vd = tree.fullVarDecl(node) orelse continue;
        try w.collectDecl(vd, diags);
    }

    for (tree.rootDecls()) |node| {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        try w.collectFn(proto);
    }

    // Everything above only ever looked at file scope. A symbol exported from
    // anywhere else is real in the `.so` but absent from the IR, so it has to
    // be reported rather than silently dropped.
    try w.reportExportsOutsideFileScope(diags);

    return ir.Api{
        .lib_name = lib_name,
        .handles = try w.handles.toOwnedSlice(arena),
        .functions = try w.functions.toOwnedSlice(arena),
    };
}

/// Every string literal passed to `@import(...)` in this file, in source order,
/// deduplicated. Used by the CLI to detect named-package imports it cannot
/// resolve (decision D2).
///
/// Works off the raw tokenizer rather than the AST so a file that fails to
/// parse can still be inspected.
pub fn scanImports(arena: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var tok: std.zig.Tokenizer = .init(source);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .builtin) continue;
        if (!std.mem.eql(u8, source[t.loc.start..t.loc.end], "@import")) continue;

        if (tok.next().tag != .l_paren) continue;
        const lit = tok.next();
        if (lit.tag != .string_literal) continue;

        const path = std.zig.string_literal.parseAlloc(
            arena,
            source[lit.loc.start..lit.loc.end],
        ) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.InvalidLiteral => continue,
        };
        if (!containsString(out.items, path)) try out.append(arena, path);
    }
    return out.toOwnedSlice(arena);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// Ast errors carry a token, not a location, and notes are separate entries
/// that belong to the error before them.
fn reportParseErrors(arena: std.mem.Allocator, tree: Ast, diags: *diag.List) !void {
    for (tree.errors) |e| {
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        try tree.renderError(e, &out.writer);

        const l = tree.tokenLocation(0, e.token);
        const loc: ir.Loc = .{
            .line = @intCast(l.line + 1),
            .column = @intCast(l.column + 1 + tree.errorOffset(e)),
        };

        if (e.is_note and diags.items.items.len > 0) {
            diags.items.items[diags.items.items.len - 1].hint =
                try arena.dupe(u8, out.written());
        } else {
            try diags.err(loc, "{s}", .{out.written()});
        }
    }
}

const Alias = struct { name: []const u8, node: Ast.Node.Index };

/// The one place a bare identifier is matched against Zig's primitive type
/// names. Shared by every resolution path so a `const u32 = opaque {};` cannot
/// mean an integer in one position and a handle in another (§3.2 step 5:
/// primitive, then alias, then handle).
fn primitiveType(name: []const u8) ?ir.Type {
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "bool")) return .{ .scalar = .bool };
    if (ir.IntKind.fromName(name)) |k| return .{ .scalar = .{ .int = k } };
    if (ir.FloatKind.fromName(name)) |k| return .{ .scalar = .{ .float = k } };
    return null;
}

const Walker = struct {
    arena: std.mem.Allocator,
    tree: *const Ast,
    handles: std.ArrayList(ir.Handle) = .empty,
    aliases: std.ArrayList(Alias) = .empty,
    functions: std.ArrayList(ir.Function) = .empty,
    /// Every `export` keyword this walker has already accounted for, so the
    /// token sweep in `reportExportsOutsideFileScope` can tell a declaration it
    /// read from one it never saw.
    seen_export_tokens: std.ArrayList(Ast.TokenIndex) = .empty,

    fn collectDecl(self: *Walker, vd: Ast.full.VarDecl, diags: *diag.List) !void {
        const tree = self.tree;
        const name = tree.tokenSlice(vd.ast.mut_token + 1);
        const decl_loc = self.loc(vd.firstToken());

        if (vd.extern_export_token) |t| {
            if (tree.tokenTag(t) == .keyword_export) {
                try self.seen_export_tokens.append(self.arena, t);
                try diags.errHint(
                    decl_loc,
                    "wrap the value in an `export fn` accessor instead",
                    "zbridge does not support exported variables, only functions" ++
                        " (found '{s}')",
                    .{name},
                );
                return;
            }
        }

        const init_node = vd.ast.init_node.unwrap() orelse return;

        var cbuf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&cbuf, init_node)) |cd| {
            if (tree.tokenTag(cd.ast.main_token) == .keyword_opaque) {
                try self.handles.append(self.arena, .{
                    .name = name,
                    .doc = try self.docComment(vd.firstToken()),
                    .loc = decl_loc,
                });
                return;
            }
        }

        // Anything else that is `const` is a candidate alias. Whether it names
        // a type at all is decided lazily, when an `export fn` refers to it.
        if (tree.tokenTag(vd.ast.mut_token) == .keyword_const) {
            try self.aliases.append(self.arena, .{ .name = name, .node = init_node });
        }
    }

    fn collectFn(self: *Walker, proto: Ast.full.FnProto) !void {
        const tree = self.tree;
        const export_token = proto.extern_export_inline_token orelse return;
        if (tree.tokenTag(export_token) != .keyword_export) return;
        try self.seen_export_tokens.append(self.arena, export_token);
        const name_token = proto.name_token orelse return;

        var params: std.ArrayList(ir.Param) = .empty;
        var it = proto.iterate(tree);
        while (it.next()) |p| {
            // `anytype` and C-variadic `...` are not sub-expressions, so they
            // arrive with no `type_expr`; the token says which one it was.
            const param_token = p.name_token orelse
                if (p.type_expr) |te|
                    tree.firstToken(te)
                else if (p.anytype_ellipsis3) |t|
                    t
                else
                    proto.lparen;

            try params.append(self.arena, .{
                .name = if (p.name_token) |t| tree.tokenSlice(t) else "",
                .ty = try self.resolveParam(p, param_token),
                .loc = self.loc(param_token),
            });
        }

        const ret: ir.Type = if (proto.ast.return_type.unwrap()) |node|
            self.resolveReturn(node)
        else
            .{ .unsupported = tree.tokenSlice(name_token) };

        try self.functions.append(self.arena, .{
            .name = tree.tokenSlice(name_token),
            .params = try params.toOwnedSlice(self.arena),
            .ret = ret,
            // Recorded, not judged: `export fn` defaults to the C convention,
            // and the validator decides which explicit spellings are callable.
            .callconv_src = if (proto.ast.callconv_expr.unwrap()) |n|
                tree.getNodeSource(n)
            else
                null,
            .doc = try self.docComment(proto.firstToken()),
            .loc = self.loc(proto.firstToken()),
            .is_pub = proto.visib_token != null,
        });
    }

    /// One parameter's type, including the modifiers that live on the
    /// parameter rather than inside its type expression. `comptime` and
    /// `noalias` change what the callee may assume, so neither can be dropped.
    fn resolveParam(
        self: *const Walker,
        p: Ast.full.FnProto.Param,
        param_token: Ast.TokenIndex,
    ) !ir.Type {
        const tree = self.tree;

        // Neither shape is a sub-expression, so name the construct itself:
        // "unsupported type 'anytype'" rather than "unsupported type 'x'".
        if (p.anytype_ellipsis3) |t| {
            return .{ .unsupported = if (tree.tokenTag(t) == .ellipsis3) "..." else "anytype" };
        }

        const type_expr = p.type_expr orelse
            return .{ .unsupported = tree.tokenSlice(param_token) };

        // `comptime` and `noalias` change what the callee may assume, so the
        // parameter is not the bare type it looks like.
        if (p.comptime_noalias) |modifier| {
            return .{ .unsupported = try std.fmt.allocPrint(self.arena, "{s} {s}", .{
                tree.tokenSlice(modifier),
                tree.getNodeSource(type_expr),
            }) };
        }

        return self.resolveType(type_expr, 0);
    }

    /// `!T` keeps the `!` out of the return-type node, so the bang has to be
    /// read off the token stream or an error union would look like a plain `T`.
    fn resolveReturn(self: *const Walker, node: Ast.Node.Index) ir.Type {
        const tree = self.tree;
        const first = tree.firstToken(node);
        if (first > 0 and tree.tokenTag(first - 1) == .bang) {
            const start = tree.tokenStart(first - 1);
            const len = (tree.tokenStart(first) - start) + tree.getNodeSource(node).len;
            return .{ .unsupported = tree.source[start..][0..len] };
        }
        return self.resolveType(node, 0);
    }

    fn resolveType(self: *const Walker, node: Ast.Node.Index, depth: u8) ir.Type {
        const tree = self.tree;
        switch (tree.nodeTag(node)) {
            .identifier => return self.resolveIdentifier(node, depth),
            .optional_type => {
                const inner = self.resolveType(tree.nodeData(node).node, depth);
                return switch (inner) {
                    .handle => |h| if (h.optional)
                        self.unsupported(node)
                    else
                        .{ .handle = .{ .name = h.name, .optional = true, .is_const = h.is_const } },
                    .many_u8 => |m| if (m.optional)
                        self.unsupported(node)
                    else
                        .{ .many_u8 = .{
                            .is_const = m.is_const,
                            .sentinel_zero = m.sentinel_zero,
                            .optional = true,
                        } },
                    .out_ptr => |p| if (p.optional)
                        self.unsupported(node)
                    else
                        .{ .out_ptr = .{ .child = p.child, .optional = true } },
                    else => self.unsupported(node),
                };
            },
            else => {},
        }
        if (tree.fullPtrType(node)) |ptr| return self.resolvePtr(node, ptr, depth);
        return self.unsupported(node);
    }

    fn resolveIdentifier(self: *const Walker, node: Ast.Node.Index, depth: u8) ir.Type {
        const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));

        if (primitiveType(name)) |t| return t;

        if (depth < max_alias_depth) {
            if (self.aliasNode(name)) |rhs| {
                const resolved = self.resolveType(rhs, depth + 1);
                // Diagnostics should quote what the user wrote at the use site,
                // not the alias's right-hand side from somewhere else in the file.
                return if (resolved == .unsupported) self.unsupported(node) else resolved;
            }
        }

        // A bare opaque name is a by-value opaque, which has no size: it falls
        // through to `.unsupported` on purpose.
        return self.unsupported(node);
    }

    fn resolvePtr(
        self: *const Walker,
        node: Ast.Node.Index,
        ptr: Ast.full.PtrType,
        depth: u8,
    ) ir.Type {
        const tree = self.tree;
        const is_const = ptr.const_token != null;

        // Alignment, volatility, allowzero and address space all change what
        // the callee may assume about the pointer, and none of them survive a
        // trip through a generated binding. Quote the whole pointer type so
        // the diagnostic shows the modifier that caused it.
        if (ptr.ast.align_node.unwrap() != null or
            ptr.ast.addrspace_node.unwrap() != null or
            ptr.ast.bit_range_start.unwrap() != null or
            ptr.volatile_token != null or
            ptr.allowzero_token != null)
        {
            return self.unsupported(node);
        }

        switch (ptr.size) {
            .many => {
                var sentinel_zero = false;
                if (ptr.ast.sentinel.unwrap()) |s| {
                    if (!std.mem.eql(u8, tree.getNodeSource(s), "0")) return self.unsupported(node);
                    sentinel_zero = true;
                }
                const child = self.resolveType(ptr.ast.child_type, depth);
                const is_u8 = child == .scalar and child.scalar == .int and
                    child.scalar.int == .u8;
                if (!is_u8) return self.unsupported(node);
                return .{ .many_u8 = .{ .is_const = is_const, .sentinel_zero = sentinel_zero } };
            },
            .one => {
                if (self.handleName(ptr.ast.child_type, depth)) |name| {
                    return .{ .handle = .{ .name = name, .optional = false, .is_const = is_const } };
                }
                const child = self.resolveType(ptr.ast.child_type, depth);
                // `*const T` for a scalar T is an in-pointer, and `out_ptr`
                // cannot express constness: mapping it would silently turn a
                // read-only argument into an extra return value.
                if (child == .scalar and !is_const) {
                    return .{ .out_ptr = .{ .child = child.scalar, .optional = false } };
                }
                return self.unsupported(node);
            },
            .slice, .c => return self.unsupported(node),
        }
    }

    /// The name of the `opaque {}` this node denotes, following alias chains.
    ///
    /// Resolution order is primitive -> alias -> handle, the same order
    /// `resolveIdentifier` uses, so one identifier can never mean a scalar on
    /// one path and a handle on the other.
    fn handleName(self: *const Walker, node: Ast.Node.Index, depth: u8) ?[]const u8 {
        if (self.tree.nodeTag(node) != .identifier) return null;
        const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
        if (primitiveType(name) != null) return null;
        if (depth < max_alias_depth) {
            if (self.aliasNode(name)) |rhs| return self.handleName(rhs, depth + 1);
        }
        for (self.handles.items) |h| {
            if (std.mem.eql(u8, h.name, name)) return h.name;
        }
        return null;
    }

    /// v1 reads file-scope `export fn` declarations and nothing else
    /// (IMPLEMENTATION §3.2). A symbol exported any other way still lands in
    /// the shared library, so the bindings would describe a smaller surface
    /// than the artifact actually has — report it instead of dropping it.
    ///
    /// This runs over the token stream rather than the AST so that an `export`
    /// nested at any depth is caught: inside a container, inside a function
    /// body, inside a `comptime` block.
    fn reportExportsOutsideFileScope(self: *Walker, diags: *diag.List) !void {
        const tree = self.tree;
        var tok: Ast.TokenIndex = 0;
        while (tok < tree.tokens.len) : (tok += 1) {
            switch (tree.tokenTag(tok)) {
                .keyword_export => {
                    if (self.sawExportToken(tok)) continue;
                    try diags.errHint(
                        self.loc(tok),
                        "move it to file scope as an `export fn`",
                        "{s} is exported but is not a file-scope `export fn`;" ++
                            " zbridge only reads file-scope `export fn` declarations," ++
                            " so this symbol will be in the binary but not in the bindings",
                        .{try self.subject(self.exportFnName(tok), "this declaration")},
                    );
                },
                .builtin => {
                    if (!std.mem.eql(u8, tree.tokenSlice(tok), "@export")) continue;
                    try diags.errHint(
                        self.loc(tok),
                        "declare it directly as a file-scope `export fn`",
                        "{s} is exported by `@export`;" ++
                            " zbridge only reads file-scope `export fn` declarations," ++
                            " so this symbol will be in the binary but not in the bindings",
                        .{try self.subject(self.exportBuiltinName(tok), "a symbol")},
                    );
                },
                else => {},
            }
        }
    }

    /// `'zc_hidden'` when the name could be recovered, else `fallback`.
    fn subject(self: *const Walker, name: ?[]const u8, fallback: []const u8) ![]const u8 {
        const n = name orelse return fallback;
        return std.fmt.allocPrint(self.arena, "'{s}'", .{n});
    }

    fn sawExportToken(self: *const Walker, tok: Ast.TokenIndex) bool {
        for (self.seen_export_tokens.items) |t| {
            if (t == tok) return true;
        }
        return false;
    }

    /// `export [inline] fn NAME` -> "NAME", best effort.
    fn exportFnName(self: *const Walker, export_token: Ast.TokenIndex) ?[]const u8 {
        const tree = self.tree;
        var t = export_token + 1;
        while (t < tree.tokens.len and tree.tokenTag(t) == .keyword_inline) t += 1;
        if (t + 1 >= tree.tokens.len) return null;
        const is_named_decl = switch (tree.tokenTag(t)) {
            .keyword_fn, .keyword_const, .keyword_var => true,
            else => false,
        };
        if (!is_named_decl) return null;
        if (tree.tokenTag(t + 1) != .identifier) return null;
        return tree.tokenSlice(t + 1);
    }

    /// The `.name = "..."` of an `@export(&x, .{ .name = "..." })` call, best
    /// effort: the options may be a comptime expression with no literal name.
    fn exportBuiltinName(self: *const Walker, builtin_token: Ast.TokenIndex) ?[]const u8 {
        const tree = self.tree;
        var t = builtin_token + 1;
        var depth: u32 = 0;
        while (t < tree.tokens.len) : (t += 1) {
            switch (tree.tokenTag(t)) {
                .l_paren, .l_brace, .l_bracket => depth += 1,
                .r_paren, .r_brace, .r_bracket => {
                    if (depth <= 1) return null;
                    depth -= 1;
                },
                .identifier => {
                    if (!std.mem.eql(u8, tree.tokenSlice(t), "name")) continue;
                    if (t + 2 >= tree.tokens.len) return null;
                    if (tree.tokenTag(t + 1) != .equal) continue;
                    if (tree.tokenTag(t + 2) != .string_literal) continue;
                    return std.zig.string_literal.parseAlloc(
                        self.arena,
                        tree.tokenSlice(t + 2),
                    ) catch null;
                },
                .eof => return null,
                else => {},
            }
        }
        return null;
    }

    fn aliasNode(self: *const Walker, name: []const u8) ?Ast.Node.Index {
        for (self.aliases.items) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.node;
        }
        return null;
    }

    fn unsupported(self: *const Walker, node: Ast.Node.Index) ir.Type {
        return .{ .unsupported = self.tree.getNodeSource(node) };
    }

    /// The `///` block immediately above `first_token`, joined in source order
    /// with the markers stripped, or null when there is none.
    fn docComment(self: *const Walker, first_token: Ast.TokenIndex) !?[]const u8 {
        const tree = self.tree;
        var start = first_token;
        while (start > 0 and tree.tokenTag(start - 1) == .doc_comment) start -= 1;
        if (start == first_token) return null;

        var out: std.Io.Writer.Allocating = .init(self.arena);
        defer out.deinit();
        var t = start;
        while (t < first_token) : (t += 1) {
            if (t > start) try out.writer.writeByte('\n');
            var text = tree.tokenSlice(t)["///".len..];
            if (text.len > 0 and text[0] == ' ') text = text[1..];
            try out.writer.writeAll(std.mem.trimEnd(u8, text, " \t\r"));
        }
        return try self.arena.dupe(u8, out.written());
    }

    fn loc(self: *const Walker, token: Ast.TokenIndex) ir.Loc {
        const l = self.tree.tokenLocation(0, token);
        return .{ .line = @intCast(l.line + 1), .column = @intCast(l.column + 1) };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    diags: diag.List,
    api: ?ir.Api,

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
    }

    fn arena(self: *Fixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn get(self: *Fixture) ir.Api {
        return self.api.?;
    }

    fn func(self: *Fixture, name: []const u8) ir.Function {
        for (self.get().functions) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        std.debug.panic("no exported function named '{s}'", .{name});
    }
};

fn parseFixture(source: [:0]const u8) !Fixture {
    var f: Fixture = .{
        .arena_state = .init(testing.allocator),
        .diags = undefined,
        .api = null,
    };
    f.diags = .init(f.arena(), "fixture.zig");
    f.api = try parseSource(f.arena(), "zc", source, &f.diags);
    return f;
}

const handles_src: [:0]const u8 = @embedFile("testdata/parse/handles.zig.txt");
const docs_src: [:0]const u8 = @embedFile("testdata/parse/docs.zig.txt");
const aliases_src: [:0]const u8 = @embedFile("testdata/parse/aliases.zig.txt");
const pointers_src: [:0]const u8 = @embedFile("testdata/parse/pointers.zig.txt");
const unsupported_src: [:0]const u8 = @embedFile("testdata/parse/unsupported.zig.txt");
const data_export_src: [:0]const u8 = @embedFile("testdata/parse/data_export.zig.txt");
const syntax_error_src: [:0]const u8 = @embedFile("testdata/parse/syntax_error.zig.txt");
const empty_src: [:0]const u8 = @embedFile("testdata/parse/empty.zig.txt");
const imports_src: [:0]const u8 = @embedFile("testdata/parse/imports.zig.txt");
const ptr_modifiers_src: [:0]const u8 = @embedFile("testdata/parse/ptr_modifiers.zig.txt");
const callconv_src: [:0]const u8 = @embedFile("testdata/parse/callconv.zig.txt");
const param_modifiers_src: [:0]const u8 = @embedFile("testdata/parse/param_modifiers.zig.txt");
const nested_export_src: [:0]const u8 = @embedFile("testdata/parse/nested_export.zig.txt");
const primitive_shadow_src: [:0]const u8 = @embedFile("testdata/parse/primitive_shadow.zig.txt");

test "opaque declarations become handles and non-export fns are ignored" {
    var f = try parseFixture(handles_src);
    defer f.deinit();

    const api = f.get();
    try testing.expectEqualStrings("zc", api.lib_name);
    try testing.expectEqual(@as(usize, 2), api.handles.len);
    try testing.expectEqualStrings("Ctx", api.handles[0].name);
    try testing.expectEqual(@as(u32, 4), api.handles[0].loc.line);
    try testing.expectEqual(@as(u32, 1), api.handles[0].loc.column);
    try testing.expectEqualStrings("An open encoder.", api.handles[0].doc.?);
    try testing.expectEqualStrings("Scratch", api.handles[1].name);
    try testing.expectEqual(@as(?[]const u8, null), api.handles[1].doc);

    // `helper` has no `export`, so it must not appear.
    try testing.expectEqual(@as(usize, 3), api.functions.len);
    try testing.expect(!f.diags.hasErrors());
}

test "pub export fn is marked pub and plain export fn is not" {
    var f = try parseFixture(handles_src);
    defer f.deinit();

    const new = f.func("zc_new");
    try testing.expect(new.is_pub);
    try testing.expectEqual(@as(u32, 9), new.loc.line);
    try testing.expectEqualStrings("Ctx", new.ret.handle.name);
    try testing.expect(new.ret.handle.optional);
    try testing.expect(!new.ret.handle.is_const);
    try testing.expectEqual(@as(usize, 0), new.params.len);

    const free = f.func("zc_free");
    try testing.expect(!free.is_pub);
    try testing.expect(free.ret == .void);
    try testing.expectEqualStrings("ctx", free.params[0].name);
    try testing.expectEqualStrings("Ctx", free.params[0].ty.handle.name);
    try testing.expect(!free.params[0].ty.handle.optional);
}

test "an optional const handle pointer keeps both qualifiers" {
    var f = try parseFixture(handles_src);
    defer f.deinit();

    const peek = f.func("zc_peek");
    const ty = peek.params[0].ty.handle;
    try testing.expectEqualStrings("Ctx", ty.name);
    try testing.expect(ty.optional);
    try testing.expect(ty.is_const);
    try testing.expectEqual(ir.IntKind.i32, peek.ret.scalar.int);
    try testing.expectEqual(@as(u32, 22), peek.params[0].loc.line);
}

test "doc comments are joined without their markers" {
    var f = try parseFixture(docs_src);
    defer f.deinit();

    try testing.expectEqualStrings("One line.", f.func("zc_one").doc.?);
    try testing.expectEqualStrings(
        \\Feed bytes to the encoder.
        \\
        \\Returns the number consumed.
    , f.func("zc_many").doc.?);
    try testing.expectEqual(@as(?[]const u8, null), f.func("zc_none").doc);
}

test "single-level aliases resolve to their underlying type" {
    var f = try parseFixture(aliases_src);
    defer f.deinit();

    const g = f.func("zc_alias");
    try testing.expectEqual(ir.IntKind.usize, g.params[0].ty.scalar.int);
    try testing.expect(g.params[1].ty.many_u8.is_const);
    try testing.expect(!g.params[1].ty.many_u8.sentinel_zero);
    try testing.expectEqualStrings("Engine", g.params[2].ty.handle.name);
    try testing.expect(!g.params[2].ty.handle.optional);
    try testing.expectEqualStrings("Engine", g.params[3].ty.handle.name);
    try testing.expect(g.params[3].ty.handle.optional);
    // `*Len` where `Len = usize` is still an out-pointer.
    try testing.expectEqual(ir.IntKind.usize, g.params[4].ty.out_ptr.child.int);
    try testing.expect(g.ret == .void);
}

test "an alias chain resolves up to the depth limit" {
    var f = try parseFixture(aliases_src);
    defer f.deinit();

    const g = f.func("zc_chain");
    try testing.expectEqual(ir.IntKind.usize, g.params[0].ty.scalar.int);
    try testing.expectEqualStrings("Engine", g.params[1].ty.handle.name);
}

test "an alias to a non-type is reported as the user spelled it" {
    var f = try parseFixture(aliases_src);
    defer f.deinit();

    const g = f.func("zc_bad_alias");
    try testing.expectEqualStrings("NotAType", g.params[0].ty.unsupported);
}

test "pointer shapes map onto the allowlist" {
    var f = try parseFixture(pointers_src);
    defer f.deinit();

    const g = f.func("zc_write");
    try testing.expectEqual(@as(usize, 4), g.params.len);
    try testing.expectEqualStrings("ctx", g.params[0].name);
    try testing.expectEqualStrings("Ctx", g.params[0].ty.handle.name);
    // A `//` comment and a blank line between params must not shift anything.
    try testing.expectEqualStrings("data", g.params[1].name);
    try testing.expect(g.params[1].ty.many_u8.is_const);
    try testing.expect(!g.params[1].ty.many_u8.sentinel_zero);
    try testing.expectEqualStrings("len", g.params[2].name);
    try testing.expectEqual(ir.IntKind.usize, g.params[2].ty.scalar.int);
    try testing.expectEqualStrings("out", g.params[3].name);
    try testing.expectEqual(ir.IntKind.u64, g.params[3].ty.out_ptr.child.int);
    try testing.expect(!g.params[3].ty.out_ptr.optional);
    try testing.expectEqual(ir.IntKind.usize, g.ret.scalar.int);

    const open = f.func("zc_open");
    try testing.expect(open.params[0].ty.many_u8.is_const);
    try testing.expect(open.params[0].ty.many_u8.sentinel_zero);
    try testing.expect(!open.params[1].ty.many_u8.is_const);
    try testing.expect(!open.params[1].ty.many_u8.sentinel_zero);
    try testing.expect(open.params[2].ty.out_ptr.optional);
    try testing.expectEqual(ir.FloatKind.f64, open.params[3].ty.scalar.float);
    try testing.expect(open.params[4].ty.scalar == .bool);
    try testing.expectEqualStrings("", open.params[5].name);
    try testing.expectEqual(ir.IntKind.c_int, open.params[5].ty.scalar.int);
}

test "callconv does not hide an export fn" {
    var f = try parseFixture(pointers_src);
    defer f.deinit();
    try testing.expectEqual(ir.IntKind.usize, f.func("zc_write").ret.scalar.int);
}

test "a pointer modifier is never dropped: it makes the whole pointer unsupported" {
    var f = try parseFixture(ptr_modifiers_src);
    defer f.deinit();

    // The diagnostic has to quote the modifier the user wrote, not the plain
    // pointer it would otherwise be mistaken for.
    try testing.expectEqualStrings("*align(64) u32", f.func("zc_put").params[0].ty.unsupported);
    try testing.expectEqualStrings("*volatile u32", f.func("zc_poke").params[0].ty.unsupported);
    try testing.expectEqualStrings("*allowzero u32", f.func("zc_maybe").params[0].ty.unsupported);
    try testing.expectEqualStrings(
        "*addrspace(.generic) u32",
        f.func("zc_far").params[0].ty.unsupported,
    );

    // The modifier survives the optional and many-item wrappers too...
    try testing.expectEqualStrings(
        "?*align(16) u32",
        f.func("zc_opt_align").params[0].ty.unsupported,
    );
    try testing.expectEqualStrings(
        "[*]align(32) const u8",
        f.func("zc_many_align").params[0].ty.unsupported,
    );
    // ...and an aligned handle pointer must not slip through as a plain handle.
    try testing.expectEqualStrings(
        "*align(8) Ctx",
        f.func("zc_handle_align").params[0].ty.unsupported,
    );

    // An unadorned pointer still maps.
    try testing.expectEqual(ir.IntKind.u32, f.func("zc_plain").params[0].ty.out_ptr.child.int);
}

test "an explicit callconv is recorded verbatim, not judged" {
    var f = try parseFixture(callconv_src);
    defer f.deinit();

    try testing.expectEqualStrings(".naked", f.func("zc_boot").callconv_src.?);
    // `.c` is the one a binding can call: accepted, and still recorded.
    try testing.expectEqualStrings(".c", f.func("zc_c").callconv_src.?);
    try testing.expect(f.func("zc_c").ret == .scalar);
    try testing.expectEqual(@as(?[]const u8, null), f.func("zc_default").callconv_src);

    // Recording is the parser's whole job here; the validator decides.
    try testing.expect(!f.diags.hasErrors());
}

test "callconv on a fixture that also has params is recorded" {
    var f = try parseFixture(pointers_src);
    defer f.deinit();
    try testing.expectEqualStrings(".c", f.func("zc_write").callconv_src.?);
    try testing.expectEqual(@as(?[]const u8, null), f.func("zc_open").callconv_src);
}

test "comptime and noalias parameters are unsupported, quoting the modifier" {
    var f = try parseFixture(param_modifiers_src);
    defer f.deinit();

    try testing.expectEqualStrings("comptime u32", f.func("zc_ct").params[0].ty.unsupported);
    try testing.expectEqualStrings(
        "noalias [*]const u8",
        f.func("zc_na").params[0].ty.unsupported,
    );
    // The unmodified trailing param is untouched.
    try testing.expectEqual(ir.IntKind.usize, f.func("zc_na").params[1].ty.scalar.int);
}

test "anytype and a C-variadic name themselves in the diagnostic" {
    var f = try parseFixture(param_modifiers_src);
    defer f.deinit();

    // These are the strings the validator quotes, so they must read as types:
    // "parameter 'x' has unsupported type 'anytype'", not "... type 'x'".
    const any = f.func("zc_any");
    try testing.expectEqualStrings("x", any.params[0].name);
    try testing.expectEqualStrings("anytype", any.params[0].ty.unsupported);

    const printf = f.func("zc_printf");
    try testing.expectEqual(@as(usize, 2), printf.params.len);
    try testing.expect(printf.params[0].ty.many_u8.sentinel_zero);
    try testing.expectEqualStrings("", printf.params[1].name);
    try testing.expectEqualStrings("...", printf.params[1].ty.unsupported);
    // The `...` points at itself, not at the `(`.
    try testing.expectEqual(@as(u32, 14), printf.params[1].loc.line);
    try testing.expectEqual(@as(u32, 41), printf.params[1].loc.column);
}

test "an export outside file scope is reported, not dropped" {
    var f = try parseFixture(nested_export_src);
    defer f.deinit();

    // The file-scope export is still collected normally.
    try testing.expectEqual(@as(usize, 1), f.get().functions.len);
    try testing.expectEqualStrings("zc_visible", f.get().functions[0].name);

    try testing.expectEqual(@as(usize, 2), f.diags.errorCount());
    f.diags.sort();
    try testing.expectEqualStrings(
        \\fixture.zig:2:9: error: 'zc_hidden' is exported but is not a file-scope `export fn`; zbridge only reads file-scope `export fn` declarations, so this symbol will be in the binary but not in the bindings
        \\    note: move it to file scope as an `export fn`
        \\fixture.zig:12:5: error: 'zc_also_hidden' is exported by `@export`; zbridge only reads file-scope `export fn` declarations, so this symbol will be in the binary but not in the bindings
        \\    note: declare it directly as a file-scope `export fn`
        \\
    , try f.diags.toString(f.arena()));
}

test "a file-scope export fn is not mistaken for a nested one" {
    var f = try parseFixture(handles_src);
    defer f.deinit();
    try testing.expect(!f.diags.hasErrors());
}

test "an exported variable is reported once, by the decl walk only" {
    var f = try parseFixture(data_export_src);
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.diags.errorCount());
}

test "a type named like a primitive resolves the same way everywhere" {
    var f = try parseFixture(primitive_shadow_src);
    defer f.deinit();

    // `const u32 = opaque {};` must not make `u32` mean two things: the
    // primitive wins on both the value path and the pointer path.
    try testing.expectEqual(ir.IntKind.u32, f.func("zc_take").params[0].ty.scalar.int);
    const ret = f.func("zc_new").ret;
    try testing.expect(ret != .handle);
    try testing.expectEqual(ir.IntKind.u32, ret.out_ptr.child.int);
    try testing.expect(ret.out_ptr.optional);
}

test "unsupported shapes keep their source text instead of failing" {
    var f = try parseFixture(unsupported_src);
    defer f.deinit();

    try testing.expect(!f.diags.hasErrors());

    const by_value = f.func("zc_by_value");
    try testing.expectEqualStrings("Options", by_value.params[0].ty.unsupported);
    try testing.expectEqualStrings("struct { a: i32 }", by_value.params[1].ty.unsupported);
    // A by-value opaque has no size, so it is not a handle.
    try testing.expectEqualStrings("Ctx", by_value.params[2].ty.unsupported);

    try testing.expectEqualStrings("!void", f.func("zc_infer_err").ret.unsupported);
    try testing.expectEqualStrings("anyerror!i32", f.func("zc_named_err").ret.unsupported);
    try testing.expectEqualStrings("[]const u8", f.func("zc_slice").params[0].ty.unsupported);
    try testing.expectEqualStrings("*anyopaque", f.func("zc_anyopaque").params[0].ty.unsupported);
    try testing.expectEqualStrings("*const u32", f.func("zc_const_ptr").params[0].ty.unsupported);
    try testing.expectEqualStrings("u128", f.func("zc_u128").ret.unsupported);
}

test "an exported variable is an error but does not stop the parse" {
    var f = try parseFixture(data_export_src);
    defer f.deinit();

    try testing.expect(f.api != null);
    try testing.expectEqual(@as(usize, 2), f.diags.errorCount());
    try testing.expectEqual(@as(usize, 1), f.get().functions.len);

    f.diags.sort();
    try testing.expectEqualStrings(
        \\fixture.zig:3:1: error: zbridge does not support exported variables, only functions (found 'zc_counter')
        \\    note: wrap the value in an `export fn` accessor instead
        \\fixture.zig:5:1: error: zbridge does not support exported variables, only functions (found 'zc_limit')
        \\    note: wrap the value in an `export fn` accessor instead
        \\
    , try f.diags.toString(f.arena()));
}

test "a syntax error returns null with a diagnostic" {
    var f = try parseFixture(syntax_error_src);
    defer f.deinit();

    try testing.expectEqual(@as(?ir.Api, null), f.api);
    try testing.expect(f.diags.hasErrors());
    try testing.expectEqual(@as(u32, 2), f.diags.items.items[0].loc.line);
}

test "an empty file yields an empty api, not an error" {
    var f = try parseFixture(empty_src);
    defer f.deinit();

    try testing.expectEqual(@as(usize, 0), f.get().handles.len);
    try testing.expectEqual(@as(usize, 0), f.get().functions.len);
    try testing.expect(!f.diags.hasErrors());
}

test "scanImports returns every import path once, in source order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const got = try scanImports(arena_state.allocator(), imports_src);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("std", got[0]);
    try testing.expectEqualStrings("./helper.zig", got[1]);
    try testing.expectEqualStrings("mylib", got[2]);
}

test "scanImports works on a file that does not parse" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const got = try scanImports(arena_state.allocator(), syntax_error_src);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("std", got[0]);
}
