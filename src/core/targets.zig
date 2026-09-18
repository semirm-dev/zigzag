//! The one target table. Every other file — the build step, the Go loader, the
//! Python loader, the packaging metadata — reads platform facts from here so
//! they can never disagree about what a target is called.

const std = @import("std");

pub const Target = enum {
    linux_x86_64,
    linux_aarch64,
    macos_aarch64,
    macos_x86_64,
    windows_x86_64,

    pub fn id(self: Target) []const u8 {
        return @tagName(self);
    }
};

pub const Os = enum { linux, macos, windows };

pub const Info = struct {
    os: Os,
    /// Zig target triple used when the library does not link libc (default).
    triple_nolibc: []const u8,
    /// Zig target triple used with `link_libc`. glibc 2.17 on Linux keeps the
    /// result manylinux2014-compatible; a musl `-dynamic` build would instead
    /// statically link musl into the .so and put two libcs in the host process.
    triple_libc: []const u8,
    go_os: []const u8,
    go_arch: []const u8,
    /// `platform.system()` in Python.
    py_system: []const u8,
    /// Accepted values of `platform.machine().lower()`.
    py_machines: []const []const u8,
    lib_prefix: []const u8,
    lib_ext: []const u8,
    /// Wheel platform tag used when building one wheel per target.
    wheel_tag: []const u8,
};

pub fn info(self: Target) Info {
    return switch (self) {
        .linux_x86_64 => .{
            .os = .linux,
            .triple_nolibc = "x86_64-linux-musl",
            .triple_libc = "x86_64-linux-gnu.2.17",
            .go_os = "linux",
            .go_arch = "amd64",
            .py_system = "Linux",
            .py_machines = &.{ "x86_64", "amd64", "x86-64" },
            .lib_prefix = "lib",
            .lib_ext = ".so",
            .wheel_tag = "manylinux2014_x86_64",
        },
        .linux_aarch64 => .{
            .os = .linux,
            .triple_nolibc = "aarch64-linux-musl",
            .triple_libc = "aarch64-linux-gnu.2.17",
            .go_os = "linux",
            .go_arch = "arm64",
            .py_system = "Linux",
            .py_machines = &.{ "aarch64", "arm64" },
            .lib_prefix = "lib",
            .lib_ext = ".so",
            .wheel_tag = "manylinux2014_aarch64",
        },
        .macos_aarch64 => .{
            .os = .macos,
            .triple_nolibc = "aarch64-macos.11.0",
            .triple_libc = "aarch64-macos.11.0",
            .go_os = "darwin",
            .go_arch = "arm64",
            .py_system = "Darwin",
            .py_machines = &.{ "arm64", "aarch64" },
            .lib_prefix = "lib",
            .lib_ext = ".dylib",
            .wheel_tag = "macosx_11_0_arm64",
        },
        .macos_x86_64 => .{
            .os = .macos,
            .triple_nolibc = "x86_64-macos.11.0",
            .triple_libc = "x86_64-macos.11.0",
            .go_os = "darwin",
            .go_arch = "amd64",
            .py_system = "Darwin",
            .py_machines = &.{ "x86_64", "amd64" },
            .lib_prefix = "lib",
            .lib_ext = ".dylib",
            .wheel_tag = "macosx_11_0_x86_64",
        },
        .windows_x86_64 => .{
            .os = .windows,
            .triple_nolibc = "x86_64-windows-gnu",
            .triple_libc = "x86_64-windows-gnu",
            .go_os = "windows",
            .go_arch = "amd64",
            .py_system = "Windows",
            .py_machines = &.{ "amd64", "x86_64" },
            .lib_prefix = "",
            .lib_ext = ".dll",
            .wheel_tag = "win_amd64",
        },
    };
}

pub fn triple(self: Target, link_libc: bool) []const u8 {
    const i = info(self);
    return if (link_libc) i.triple_libc else i.triple_nolibc;
}

/// e.g. ("zpdf", .linux_x86_64) -> "libzpdf.so"
pub fn libFileName(arena: std.mem.Allocator, self: Target, lib_name: []const u8) ![]const u8 {
    const i = info(self);
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ i.lib_prefix, lib_name, i.lib_ext });
}

pub fn fromString(s: []const u8) ?Target {
    if (std.meta.stringToEnum(Target, s)) |t| return t;
    // Accept the Zig-triple-ish spellings people naturally type.
    const aliases = .{
        .{ "x86_64-linux", Target.linux_x86_64 },
        .{ "linux-x86_64", Target.linux_x86_64 },
        .{ "linux-amd64", Target.linux_x86_64 },
        .{ "aarch64-linux", Target.linux_aarch64 },
        .{ "linux-aarch64", Target.linux_aarch64 },
        .{ "linux-arm64", Target.linux_aarch64 },
        .{ "aarch64-macos", Target.macos_aarch64 },
        .{ "macos-aarch64", Target.macos_aarch64 },
        .{ "macos-arm64", Target.macos_aarch64 },
        .{ "x86_64-macos", Target.macos_x86_64 },
        .{ "macos-x86_64", Target.macos_x86_64 },
        .{ "x86_64-windows", Target.windows_x86_64 },
        .{ "windows-x86_64", Target.windows_x86_64 },
        .{ "windows-amd64", Target.windows_x86_64 },
    };
    inline for (aliases) |a| {
        if (std.mem.eql(u8, s, a[0])) return a[1];
    }
    return null;
}

pub const all = [_]Target{
    .linux_x86_64,
    .linux_aarch64,
    .macos_aarch64,
    .macos_x86_64,
    .windows_x86_64,
};

pub const default: []const Target = &all;

/// The target matching the host, used by tests and by `--targets host`.
pub fn host() ?Target {
    const b = @import("builtin");
    return switch (b.target.os.tag) {
        .linux => switch (b.target.cpu.arch) {
            .x86_64 => .linux_x86_64,
            .aarch64 => .linux_aarch64,
            else => null,
        },
        .macos => switch (b.target.cpu.arch) {
            .aarch64 => .macos_aarch64,
            .x86_64 => .macos_x86_64,
            else => null,
        },
        .windows => switch (b.target.cpu.arch) {
            .x86_64 => .windows_x86_64,
            else => null,
        },
        else => null,
    };
}

const testing = std.testing;

test "target names round-trip" {
    for (all) |t| {
        try testing.expectEqual(t, fromString(t.id()).?);
    }
    try testing.expectEqual(Target.macos_aarch64, fromString("macos-arm64").?);
    try testing.expectEqual(@as(?Target, null), fromString("plan9-mips"));
}

test "library file names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("libzpdf.so", try libFileName(arena, .linux_x86_64, "zpdf"));
    try testing.expectEqualStrings("libzpdf.dylib", try libFileName(arena, .macos_aarch64, "zpdf"));
    try testing.expectEqualStrings("zpdf.dll", try libFileName(arena, .windows_x86_64, "zpdf"));
}
