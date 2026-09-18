//! Identifier conversion shared by the generators, plus the keyword tables the
//! validator uses to reject names that cannot be translated.

const std = @import("std");

/// "zc_ctx_new" -> "ZcCtxNew"
pub fn toPascal(arena: std.mem.Allocator, snake: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var upper_next = true;
    for (snake) |c| {
        if (c == '_') {
            upper_next = true;
            continue;
        }
        try out.append(arena, if (upper_next) std.ascii.toUpper(c) else c);
        upper_next = false;
    }
    return out.toOwnedSlice(arena);
}

/// "zc_ctx_new" -> "zcCtxNew"
pub fn toCamel(arena: std.mem.Allocator, snake: []const u8) ![]const u8 {
    const pascal = try toPascal(arena, snake);
    if (pascal.len == 0) return pascal;
    const out = try arena.dupe(u8, pascal);
    out[0] = std.ascii.toLower(out[0]);
    return out;
}

/// "ZcCtxNew" / "zc_ctx_new" -> "zc_ctx_new"
pub fn toSnake(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            const prev_is_lower = i > 0 and std.ascii.isLower(name[i - 1]);
            const prev_is_upper = i > 0 and std.ascii.isUpper(name[i - 1]);
            const next_is_lower = i + 1 < name.len and std.ascii.isLower(name[i + 1]);
            if (i > 0 and (prev_is_lower or (prev_is_upper and next_is_lower))) {
                try out.append(arena, '_');
            }
            try out.append(arena, std.ascii.toLower(c));
        } else {
            try out.append(arena, c);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Drop a leading `<lib>_` so `zpdf_open` becomes `open` before it is turned
/// into a method name. Returns the input unchanged when the prefix is absent
/// or when stripping would leave nothing.
pub fn stripPrefix(name: []const u8, lib_name: []const u8) []const u8 {
    if (lib_name.len == 0) return name;
    if (!std.mem.startsWith(u8, name, lib_name)) return name;
    var rest = name[lib_name.len..];
    if (rest.len > 0 and rest[0] == '_') rest = rest[1..];
    if (rest.len == 0) return name;
    // Don't produce an identifier that starts with a digit.
    if (std.ascii.isDigit(rest[0])) return name;
    return rest;
}

pub const go_keywords = [_][]const u8{
    "break",  "case",        "chan",    "const",   "continue", "default", "defer",
    "else",   "fallthrough", "for",     "func",    "go",       "goto",    "if",
    "import", "interface",   "map",     "package", "range",    "return",  "select",
    "struct", "switch",      "type",    "var",     "nil",      "true",    "false",
    "iota",   "len",         "cap",     "make",    "new",      "append",  "copy",
    "delete", "panic",       "recover", "print",   "println",  "string",  "byte",
    "rune",   "error",       "any",
};

pub const python_keywords = [_][]const u8{
    "False",  "None",   "True",    "and",      "as",       "assert", "async",
    "await",  "break",  "class",   "continue", "def",      "del",    "elif",
    "else",   "except", "finally", "for",      "from",     "global", "if",
    "import", "in",     "is",      "lambda",   "nonlocal", "not",    "or",
    "pass",   "raise",  "return",  "try",      "while",    "with",   "yield",
    "self",   "cls",
};

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

pub fn isGoKeyword(name: []const u8) bool {
    return inList(&go_keywords, name);
}

pub fn isPythonKeyword(name: []const u8) bool {
    return inList(&python_keywords, name);
}

/// Make a parameter name safe in both languages: keywords and empty names get
/// a deterministic replacement rather than an error, because the caller never
/// sees a parameter name in a positional call.
pub fn safeParamName(arena: std.mem.Allocator, name: []const u8, index: usize) ![]const u8 {
    if (name.len == 0 or std.mem.eql(u8, name, "_")) {
        return std.fmt.allocPrint(arena, "arg{d}", .{index});
    }
    if (isGoKeyword(name) or isPythonKeyword(name)) {
        return std.fmt.allocPrint(arena, "{s}_", .{name});
    }
    return name;
}

/// Why `name` cannot be used as a library name, or null when it can.
///
/// The name is interpolated into a Zig identifier (`<name>_zbridge_abi_hash`),
/// into generated file names, into a Go `package` clause and into a Python
/// package directory, so a name that is merely unusual in one of those places
/// breaks the build in a confusing way — and one containing a path separator
/// would let generated output escape the output directory entirely.
pub fn validateLibName(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "it is empty";
    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        return "it contains a path separator, which would let output escape the output directory";
    }
    if (std.mem.indexOf(u8, name, "..") != null) {
        return "it contains '..', which would let output escape the output directory";
    }
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') {
        return "it must start with a letter or '_' to be a legal identifier";
    }
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return "it may only contain letters, digits and '_'";
        }
    }
    if (isGoKeyword(name)) return "it is a Go keyword, so `package <name>` would not compile";
    if (isPythonKeyword(name)) return "it is a Python keyword, so `import <name>` would not parse";
    return null;
}

test "library name validation" {
    try testing.expectEqual(@as(?[]const u8, null), validateLibName("zpdf"));
    try testing.expectEqual(@as(?[]const u8, null), validateLibName("_z9"));
    try testing.expect(validateLibName("") != null);
    try testing.expect(validateLibName("my-lib") != null);
    try testing.expect(validateLibName("../../x") != null);
    try testing.expect(validateLibName("a/b") != null);
    try testing.expect(validateLibName("2fast") != null);
    try testing.expect(validateLibName("range") != null);
    try testing.expect(validateLibName("lambda") != null);
}

const testing = std.testing;

test "case conversion" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("ZcCtxNew", try toPascal(a, "zc_ctx_new"));
    try testing.expectEqualStrings("zcCtxNew", try toCamel(a, "zc_ctx_new"));
    try testing.expectEqualStrings("zc_ctx_new", try toSnake(a, "ZcCtxNew"));
    try testing.expectEqualStrings("http_server", try toSnake(a, "HTTPServer"));
    try testing.expectEqualStrings("already_snake", try toSnake(a, "already_snake"));
}

test "prefix stripping" {
    try testing.expectEqualStrings("open", stripPrefix("zpdf_open", "zpdf"));
    try testing.expectEqualStrings("zpdf", stripPrefix("zpdf", "zpdf"));
    try testing.expectEqualStrings("other_open", stripPrefix("other_open", "zpdf"));
}

test "safe parameter names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("arg2", try safeParamName(a, "", 2));
    try testing.expectEqualStrings("type_", try safeParamName(a, "type", 0));
    try testing.expectEqualStrings("lambda_", try safeParamName(a, "lambda", 0));
    try testing.expectEqualStrings("data", try safeParamName(a, "data", 0));
}
