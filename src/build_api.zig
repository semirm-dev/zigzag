//! `build.zig` integration: the primary, recommended front end. Registers a
//! `port` step that runs the generator and cross-compiles the shared library
//! for every target, using the consumer's own build graph to resolve module
//! imports.
//!
//! Decision D1: this is the ONLY place compilation happens. The CLI's `port`
//! subcommand writes a throwaway project that calls straight back into here,
//! so both front ends produce identical binaries from identical inputs.

const std = @import("std");
const targets = @import("core/targets.zig");
const names = @import("gen/names.zig");

pub const Import = struct {
    /// The name used in `@import("...")` inside the user's source.
    name: []const u8,
    /// The dependency name in their build.zig.zon.
    dependency: []const u8,
    /// The module name that dependency exposes.
    module: []const u8,
};

pub const PortOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    imports: []const Import = &.{},
    /// Target ids from src/core/targets.zig, e.g. "linux_x86_64". Empty means
    /// every target in `targets.all`.
    targets: []const []const u8 = &.{},
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
    link_libc: bool = false,
    out_go: ?std.Build.LazyPath = null,
    out_python: ?std.Build.LazyPath = null,
    out_c_header: ?std.Build.LazyPath = null,
    go_module_path: ?[]const u8 = null,
    step_name: []const u8 = "port",
    step_description: []const u8 = "Generate language bindings with zbridge",

    // --- extensions beyond the original stub -------------------------------

    /// Name zbridge is declared under in the caller's `build.zig.zon`. Only
    /// needs changing if the dependency was renamed.
    zbridge_dependency: []const u8 = "zbridge",
    /// Python import package name. Defaults to `name`; must match what the
    /// generator uses, because the compiled libraries are installed into
    /// `<out_python>/<package>/_native/<target id>/`.
    python_package: ?[]const u8 = null,
    /// Go package name. Defaults to `name`.
    go_package: ?[]const u8 = null,
    /// How `root_source_file` is spelled in the generated files' headers.
    /// Defaults to its path relative to this build's root. Generated output
    /// must never embed an absolute path, or it stops being byte-identical
    /// between machines and `git diff --exit-code` in CI becomes noise.
    input_display: ?[]const u8 = null,
};

pub const PortStep = struct {
    step: *std.Build.Step,

    // --- extensions beyond the original stub -------------------------------

    /// The `zbridge generate` invocation. Exposed so a caller can hang extra
    /// dependencies off it.
    generate: *std.Build.Step.Run,
    /// Directory holding the generated `<name>_zbridge_root.zig` glue file.
    glue_dir: std.Build.LazyPath,
    /// One entry per requested target, in the order they were requested.
    libraries: []const *std.Build.Step.Compile,
};

pub fn addPortStep(b: *std.Build, options: PortOptions) PortStep {
    // The name is interpolated into a Zig identifier, into generated file
    // names, into the Go `package` clause and into the Python package
    // directory. Catch it here, where the message can point at the build
    // script, rather than as a compile error inside generated code.
    if (validateLibName(options.name)) |why| std.debug.panic(
        "zbridge: invalid .name \"{s}\" in addPortStep: {s}",
        .{ options.name, why },
    );

    const step = b.step(options.step_name, options.step_description);

    const selected = resolveTargets(b, options.targets);
    const python_pkg = options.python_package orelse options.name;

    // ---------------------------------------------------------------- step 1
    // The generator, built for the host, run once to produce every text file
    // plus the Zig glue root the libraries below are compiled from.
    const zbridge_dep = b.dependency(options.zbridge_dependency, .{});
    const generator = zbridge_dep.artifact("zbridge");

    const run = b.addRunArtifact(generator);
    run.setName(b.fmt("zbridge generate {s}", .{options.name}));
    run.addArg("generate");

    run.addArg("--input");
    run.addFileArg(options.root_source_file);
    run.addArgs(&.{ "--input-display", options.input_display orelse displayPath(options.root_source_file) });

    run.addArgs(&.{ "--name", options.name });
    run.addArgs(&.{ "--targets", joinTargetIds(b, selected) });
    if (options.link_libc) run.addArg("--link-libc");

    // The glue root is a real build artifact: it lives in the cache and is
    // consumed as a module root below, so the graph tracks it for us.
    run.addArg("--out-zig");
    const glue_dir = run.addOutputDirectoryArg("zbridge-glue");

    // The bindings, by contrast, are meant to be committed, so they are
    // written straight into the source tree. That is a side effect the build
    // cache cannot model, which is exactly why the step declares it.
    if (options.out_go) |lp| {
        run.addArgs(&.{ "--out-go", absoluteDir(b, lp, "out_go") });
        run.addArgs(&.{ "--go-package", options.go_package orelse options.name });
        if (options.go_module_path) |m| run.addArgs(&.{ "--go-module", m });
    } else {
        run.addArg("--no-go");
    }
    if (options.out_python) |lp| {
        run.addArgs(&.{ "--out-python", absoluteDir(b, lp, "out_python") });
        run.addArgs(&.{ "--python-package", python_pkg });
    } else {
        run.addArg("--no-python");
    }
    if (options.out_c_header) |lp| {
        run.addArgs(&.{ "--out-c-header", absoluteDir(b, lp, "out_c_header") });
    }
    run.has_side_effects = true;

    step.dependOn(&run.step);

    // ---------------------------------------------------------------- step 2
    // One shared library per target, rooted at the generated glue file with
    // the user's own file attached as the `zbridge_input` module.
    const glue_root = glue_dir.path(b, b.fmt("{s}_zbridge_root.zig", .{options.name}));

    const install = b.addUpdateSourceFiles();
    install.step.name = b.fmt("zbridge install {s} binaries", .{options.name});

    const libs = b.allocator.alloc(*std.Build.Step.Compile, selected.len) catch @panic("OOM");

    for (selected, 0..) |t, i| {
        const query = std.Target.Query.parse(.{
            .arch_os_abi = targets.triple(t, options.link_libc),
        }) catch |err| std.debug.panic(
            "zbridge: target '{s}' has an unparseable triple '{s}': {s}",
            .{ t.id(), targets.triple(t, options.link_libc), @errorName(err) },
        );
        const resolved = b.resolveTargetQuery(query);

        // The user's file keeps its own module identity so its relative
        // `@import`s resolve from its own directory, and so named package
        // imports can be attached to it.
        const input_mod = b.createModule(.{
            .root_source_file = options.root_source_file,
            .target = resolved,
            .optimize = options.optimize,
            .link_libc = if (options.link_libc) true else null,
        });
        for (options.imports) |imp| {
            const dep = b.dependency(imp.dependency, .{
                .target = resolved,
                .optimize = options.optimize,
            });
            input_mod.addImport(imp.name, dep.module(imp.module));
        }

        const root_mod = b.createModule(.{
            .root_source_file = glue_root,
            .target = resolved,
            .optimize = options.optimize,
            .strip = true,
            .link_libc = if (options.link_libc) true else null,
        });
        root_mod.addImport("zbridge_input", input_mod);

        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = options.name,
            .root_module = root_mod,
        });
        // Name the step after the target so a cross-compile failure says which
        // one broke rather than just "zig build-lib zcounter".
        lib.step.name = b.fmt("zbridge build {s} for {s}", .{ options.name, t.id() });
        libs[i] = lib;

        const file_name = targets.libFileName(b.allocator, t, options.name) catch @panic("OOM");
        const bin = lib.getEmittedBin();

        if (options.out_go) |lp| {
            install.addCopyFileToSource(bin, b.pathJoin(&.{
                sourceSubPath(b, lp, "out_go"), "native", t.id(), file_name,
            }));
        }
        if (options.out_python) |lp| {
            install.addCopyFileToSource(bin, b.pathJoin(&.{
                sourceSubPath(b, lp, "out_python"), python_pkg, "_native", t.id(), file_name,
            }));
        }
    }

    // The binaries can only be copied once the loaders that reference them
    // exist, and the generated `go.mod` / `pyproject.toml` must not race with
    // the copy either.
    install.step.dependOn(&run.step);
    step.dependOn(&install.step);

    return .{
        .step = step,
        .generate = run,
        .glue_dir = glue_dir,
        .libraries = libs,
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Shared with the CLI front end, which reaches it through the `zbridge`
/// module. Both front ends must reject the same names, so there is one body.
pub const validateLibName = names.validateLibName;

fn resolveTargets(b: *std.Build, ids: []const []const u8) []const targets.Target {
    if (ids.len == 0) return &targets.all;
    const out = b.allocator.alloc(targets.Target, ids.len) catch @panic("OOM");
    for (ids, 0..) |id, i| {
        out[i] = targets.fromString(id) orelse std.debug.panic(
            "zbridge: unknown target id '{s}'. Known ids: {s}",
            .{ id, joinTargetIds(b, &targets.all) },
        );
    }
    return out;
}

fn joinTargetIds(b: *std.Build, list: []const targets.Target) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (list) |t| parts.append(b.allocator, t.id()) catch @panic("OOM");
    return std.mem.join(b.allocator, ",", parts.items) catch @panic("OOM");
}

/// How the input file is named in the generated headers. Never absolute.
fn displayPath(lp: std.Build.LazyPath) []const u8 {
    return switch (lp) {
        .src_path => |sp| sp.sub_path,
        .dependency => |d| d.sub_path,
        .generated => |g| g.sub_path,
        .cwd_relative => |p| std.fs.path.basename(p),
    };
}

/// An absolute filesystem path for an output directory, for passing to the
/// generator process (whose working directory we do not want to depend on).
fn absoluteDir(b: *std.Build, lp: std.Build.LazyPath, field: []const u8) []const u8 {
    _ = b;
    return switch (lp) {
        .src_path => |sp| sp.owner.pathFromRoot(sp.sub_path),
        .dependency => |d| d.dependency.builder.pathFromRoot(d.sub_path),
        .cwd_relative => |p| if (std.fs.path.isAbsolute(p)) p else std.debug.panic(
            "zbridge: {s} must be an absolute path when given as .cwd_relative, got '{s}'",
            .{ field, p },
        ),
        .generated => std.debug.panic(
            "zbridge: {s} cannot be a generated path; bindings are written into the source tree so they can be committed",
            .{field},
        ),
    };
}

/// The same directory, expressed relative to *this* build's root, which is
/// what `UpdateSourceFiles` wants. `..` components are fine and are what the
/// CLI's throwaway project relies on.
fn sourceSubPath(b: *std.Build, lp: std.Build.LazyPath, field: []const u8) []const u8 {
    switch (lp) {
        .src_path => |sp| if (sp.owner == b) return sp.sub_path,
        else => {},
    }
    const abs = absoluteDir(b, lp, field);
    const root = b.build_root.path orelse ".";
    return std.fs.path.relative(b.allocator, root, &b.graph.environ_map, root, abs) catch @panic("OOM");
}
