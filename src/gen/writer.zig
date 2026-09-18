//! An indentation-aware code emitter. Every generator writes through this so
//! nested output stays readable without manual padding in format strings.

const std = @import("std");

pub const CodeWriter = struct {
    out: std.Io.Writer.Allocating,
    depth: u32 = 0,
    /// One indentation level. Go uses a tab, Python four spaces.
    unit: []const u8,
    at_line_start: bool = true,

    pub fn init(gpa: std.mem.Allocator, unit: []const u8) CodeWriter {
        return .{ .out = .init(gpa), .unit = unit };
    }

    pub fn deinit(self: *CodeWriter) void {
        self.out.deinit();
    }

    pub fn written(self: *CodeWriter) []const u8 {
        return self.out.written();
    }

    /// Hands ownership of the buffer to the caller.
    pub fn toOwnedSlice(self: *CodeWriter) ![]u8 {
        return self.out.toOwnedSlice();
    }

    pub fn indent(self: *CodeWriter) void {
        self.depth += 1;
    }

    pub fn dedent(self: *CodeWriter) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }

    fn writeIndent(self: *CodeWriter) !void {
        if (!self.at_line_start) return;
        for (0..self.depth) |_| try self.out.writer.writeAll(self.unit);
        self.at_line_start = false;
    }

    /// Write a full line at the current indentation.
    pub fn line(self: *CodeWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.writeIndent();
        try self.out.writer.print(fmt, args);
        try self.out.writer.writeByte('\n');
        self.at_line_start = true;
    }

    /// Write a bare string as a line. Empty strings emit an empty line with no
    /// trailing indentation, which keeps generated files free of trailing
    /// whitespace.
    pub fn raw(self: *CodeWriter, text: []const u8) !void {
        if (text.len == 0) {
            try self.out.writer.writeByte('\n');
            self.at_line_start = true;
            return;
        }
        try self.writeIndent();
        try self.out.writer.writeAll(text);
        try self.out.writer.writeByte('\n');
        self.at_line_start = true;
    }

    /// Write without ending the line, for building a line in pieces.
    pub fn part(self: *CodeWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.writeIndent();
        try self.out.writer.print(fmt, args);
    }

    pub fn endLine(self: *CodeWriter) !void {
        try self.out.writer.writeByte('\n');
        self.at_line_start = true;
    }

    pub fn blank(self: *CodeWriter) !void {
        try self.raw("");
    }

    /// Emit a multi-line block verbatim, re-indenting each non-empty line.
    /// Used for the static loader templates.
    pub fn block(self: *CodeWriter, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            const trimmed = std.mem.trimEnd(u8, l, "\r");
            try self.raw(trimmed);
        }
    }

    /// Emit `///`-style docs in the target language's comment syntax.
    /// `prefix` is e.g. "// " for Go.
    pub fn docComment(self: *CodeWriter, prefix: []const u8, doc: ?[]const u8) !void {
        const text = doc orelse return;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            const trimmed = std.mem.trimEnd(u8, l, " \t\r");
            if (trimmed.len == 0) {
                try self.raw(std.mem.trimEnd(u8, prefix, " "));
            } else {
                try self.line("{s}{s}", .{ prefix, trimmed });
            }
        }
    }
};

const testing = std.testing;

test "indentation and blank lines" {
    var w: CodeWriter = .init(testing.allocator, "    ");
    defer w.deinit();

    try w.line("def f():", .{});
    w.indent();
    try w.line("return {d}", .{42});
    try w.blank();
    try w.line("# done", .{});
    w.dedent();
    try w.line("f()", .{});

    try testing.expectEqualStrings(
        \\def f():
        \\    return 42
        \\
        \\    # done
        \\f()
        \\
    , w.written());
}

test "block re-indents" {
    var w: CodeWriter = .init(testing.allocator, "\t");
    defer w.deinit();
    w.indent();
    try w.block("a\n\nb");
    try testing.expectEqualStrings("\ta\n\n\tb\n", w.written());
}

test "doc comments" {
    var w: CodeWriter = .init(testing.allocator, "\t");
    defer w.deinit();
    try w.docComment("// ", "first\nsecond");
    try w.docComment("// ", null);
    try testing.expectEqualStrings("// first\n// second\n", w.written());
}
