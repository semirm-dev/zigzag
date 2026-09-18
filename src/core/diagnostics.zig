//! Diagnostics, rendered in Zig's own `file:line:col: error: message` shape so
//! editors and CI logs can link to them.

const std = @import("std");
const ir = @import("ir.zig");

pub const Severity = enum {
    @"error",
    warning,

    pub fn label(self: Severity) []const u8 {
        return @tagName(self);
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    loc: ir.Loc,
    message: []const u8,
    /// Optional second line, rendered as `note:`.
    hint: ?[]const u8 = null,
};

pub const List = struct {
    arena: std.mem.Allocator,
    file_path: []const u8,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(arena: std.mem.Allocator, file_path: []const u8) List {
        return .{ .arena = arena, .file_path = file_path };
    }

    pub fn add(
        self: *List,
        severity: Severity,
        loc: ir.Loc,
        hint: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.items.append(self.arena, .{
            .severity = severity,
            .loc = loc,
            .message = try std.fmt.allocPrint(self.arena, fmt, args),
            .hint = hint,
        });
    }

    pub fn err(self: *List, loc: ir.Loc, comptime fmt: []const u8, args: anytype) !void {
        try self.add(.@"error", loc, null, fmt, args);
    }

    pub fn errHint(
        self: *List,
        loc: ir.Loc,
        hint: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.add(.@"error", loc, hint, fmt, args);
    }

    pub fn warn(self: *List, loc: ir.Loc, comptime fmt: []const u8, args: anytype) !void {
        try self.add(.warning, loc, null, fmt, args);
    }

    pub fn hasErrors(self: List) bool {
        for (self.items.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn errorCount(self: List) usize {
        var n: usize = 0;
        for (self.items.items) |d| {
            if (d.severity == .@"error") n += 1;
        }
        return n;
    }

    /// Stable order: by source position, then by message, so snapshot tests
    /// don't depend on the order rules happen to run in.
    pub fn sort(self: *List) void {
        std.mem.sort(Diagnostic, self.items.items, {}, lessThan);
    }

    fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
        if (a.loc.line != b.loc.line) return a.loc.line < b.loc.line;
        if (a.loc.column != b.loc.column) return a.loc.column < b.loc.column;
        return std.mem.lessThan(u8, a.message, b.message);
    }

    pub fn render(self: List, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.items.items) |d| {
            try w.print("{s}:{d}:{d}: {s}: {s}\n", .{
                self.file_path,
                d.loc.line,
                d.loc.column,
                d.severity.label(),
                d.message,
            });
            if (d.hint) |h| try w.print("    note: {s}\n", .{h});
        }
    }

    pub fn toString(self: List, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        try self.render(&out.writer);
        return arena.dupe(u8, out.written());
    }
};

const testing = std.testing;

test "render and sort" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: List = .init(arena, "src/c_api.zig");
    try list.err(.{ .line = 12, .column = 5 }, "zpdf_open: bad param '{s}'", .{"opts"});
    try list.warn(.{ .line = 3, .column = 1 }, "no destructor for handle 'Ctx'", .{});
    list.sort();

    try testing.expect(list.hasErrors());
    try testing.expectEqual(@as(usize, 1), list.errorCount());
    try testing.expectEqualStrings(
        \\src/c_api.zig:3:1: warning: no destructor for handle 'Ctx'
        \\src/c_api.zig:12:5: error: zpdf_open: bad param 'opts'
        \\
    , try list.toString(arena));
}
