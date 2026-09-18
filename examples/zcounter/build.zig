//! The end-to-end example: a tiny Zig library ported to Go and Python by
//! zbridge, dogfooding the `build.zig` integration (IMPLEMENTATION.md §5.2).
//!
//!   zig build port    # generate bindings + cross-compile every target
//!   zig build test    # the library's own Zig tests
//!
//! Everything `port` writes under `bindings/` is committed, so CI can prove
//! generation is deterministic with `git diff --exit-code`.

const std = @import("std");
const zbridge = @import("zbridge");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library's own tests, so a broken example fails before the port does.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the zcounter Zig tests").dependOn(&b.addRunArtifact(tests).step);

    _ = zbridge.addPortStep(b, .{
        .name = "zcounter",
        .root_source_file = b.path("src/c_api.zig"),
        // Every supported target. Cross-compiling all five from any host is
        // the whole point of using Zig as the toolchain.
        .targets = &.{
            "linux_x86_64",
            "linux_aarch64",
            "macos_aarch64",
            "macos_x86_64",
            "windows_x86_64",
        },
        // Decision D4: no libc, so the shared library has no runtime
        // dependencies at all and can never put a second libc into the host
        // Go or Python process.
        .link_libc = false,
        .out_go = b.path("bindings/go"),
        .out_python = b.path("bindings/python"),
        .out_c_header = b.path("bindings/c"),
        .go_module_path = "example.com/zcounter/bindings/go",
    });
}
