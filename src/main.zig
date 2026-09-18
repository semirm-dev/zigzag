//! The `zbridge` CLI: a thin front end over the same pipeline the build
//! integration uses.
//!
//! `zbridge generate` is the low-level half — parse, validate, write the
//! generated sources — and is what `addPortStep` invokes. `zbridge port` is
//! `generate` plus compilation, and per decision D1 it does *not* compile
//! anything itself: it writes a throwaway `build.zig` that calls
//! `addPortStep` and drives `zig build port` over it, so there is exactly one
//! compile path in the whole tool.

const std = @import("std");
const Io = std.Io;
const zbridge = @import("zbridge");

const generate = zbridge.generate;
const targets = zbridge.targets;
const diag = zbridge.diagnostics;
const gen = zbridge.gen.context;
const gen_names = zbridge.gen.names;

const exit_usage = 2;
const exit_failure = 1;

const usage_text =
    \\zbridge — generate Go and Python bindings for a Zig C-ABI surface.
    \\
    \\Usage:
    \\  zbridge port     --input <file.zig> [options]   generate, then cross-compile
    \\  zbridge generate --input <file.zig> [options]   generate sources only (low level)
    \\  zbridge targets                                 list target ids
    \\  zbridge version                                 print the zbridge version
    \\
    \\Options:
    \\  --input <path>          The Zig file holding the `export fn` surface. Required.
    \\  --input-display <path>  The spelling of --input recorded in the generated file
    \\                          headers. Defaults to --input. The build integration sets
    \\                          it so generated output does not embed an absolute path
    \\                          and therefore stays byte-identical across machines.
    \\  --name <name>           Library base name: letters, digits and '_', starting with a
    \\                          letter or '_'. Defaults to the input file's stem. A stem
    \\                          that says nothing about the library (c_api, api, ffi, lib,
    \\                          root, main, exports, bindings, c, ...) is rejected rather
    \\                          than guessed at, because the name feeds the ABI hash, every
    \\                          generated file name and both package names.
    \\  --targets <a,b,...>     Target ids, or `host`, or `all` (the default).
    \\  --link-libc             Link libc. Off by default: a no-libc shared library has no
    \\                          runtime dependencies and cannot put a second libc into the
    \\                          host process.
    \\  --out-go <dir>          Write the Go bindings here.
    \\  --out-python <dir>      Write the Python bindings here.
    \\  --out-c-header <dir>    Write <name>.h here.
    \\  --out-zig <dir>         Write the generated Zig glue root here. `port` manages this
    \\                          itself; you only need it when driving compilation by hand.
    \\  --go-module <path>      Go module path for the generated go.mod, e.g.
    \\                          github.com/me/zpdf-go.
    \\  --go-package <name>     Go package name. Defaults to --name.
    \\  --python-package <name> Python import package name. Defaults to --name.
    \\  --no-go                 Do not emit Go bindings.
    \\  --no-python             Do not emit Python bindings.
    \\  --force                 Overwrite user scaffold files that already exist.
    \\  --dry-run               Report what each file would become and write nothing.
    \\  -h, --help              Show this message.
    \\
    \\Environment:
    \\  ZBRIDGE_ROOT            Path to the zbridge checkout `port` compiles against.
    \\                          Normally inferred from the location of this executable.
    \\
;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var out_buf: [8192]u8 = undefined;
    var err_buf: [8192]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var stderr: Io.File.Writer = .init(.stderr(), io, &err_buf);
    defer stdout.interface.flush() catch {};
    defer stderr.interface.flush() catch {};

    const argv = try init.minimal.args.toSlice(gpa);
    const code = run(gpa, io, init.minimal.environ, argv, &stdout.interface, &stderr.interface) catch |err| {
        try stderr.interface.print("zbridge: {s}\n", .{@errorName(err)});
        try stderr.interface.flush();
        std.process.exit(exit_failure);
    };

    try stdout.interface.flush();
    try stderr.interface.flush();
    if (code != 0) std.process.exit(code);
}

fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    argv: []const [:0]const u8,
    out: *Io.Writer,
    err: *Io.Writer,
) !u8 {
    if (argv.len < 2) {
        try err.writeAll(usage_text);
        return exit_usage;
    }

    const cmd = argv[1];
    if (eq(cmd, "-h") or eq(cmd, "--help") or eq(cmd, "help")) {
        try out.writeAll(usage_text);
        return 0;
    }
    if (eq(cmd, "version") or eq(cmd, "--version")) {
        try out.print("{s}\n", .{zbridge.version.string});
        return 0;
    }
    if (eq(cmd, "targets")) {
        try printTargets(out);
        return 0;
    }
    if (!eq(cmd, "port") and !eq(cmd, "generate")) {
        try err.print("zbridge: unknown subcommand '{s}'\n\n", .{cmd});
        try err.writeAll(usage_text);
        return exit_usage;
    }

    var opts: Cli = .{};
    switch (try parseArgs(gpa, argv[2..], &opts, err)) {
        .ok => {},
        .help => {
            try out.writeAll(usage_text);
            return 0;
        },
        .usage_error => return exit_usage,
    }

    const input = opts.input orelse {
        try err.writeAll("zbridge: --input is required\n\n");
        try err.writeAll(usage_text);
        return exit_usage;
    };

    return switch (eq(cmd, "port")) {
        true => cmdPort(gpa, io, environ, input, opts, out, err),
        false => cmdGenerate(gpa, io, input, opts, out, err),
    };
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const Cli = struct {
    input: ?[]const u8 = null,
    input_display: ?[]const u8 = null,
    name: ?[]const u8 = null,
    target_ids: ?[]const u8 = null,
    link_libc: bool = false,
    out_go: ?[]const u8 = null,
    out_python: ?[]const u8 = null,
    out_c_header: ?[]const u8 = null,
    out_zig: ?[]const u8 = null,
    go_module: ?[]const u8 = null,
    go_package: ?[]const u8 = null,
    python_package: ?[]const u8 = null,
    no_go: bool = false,
    no_python: bool = false,
    force: bool = false,
    dry_run: bool = false,
};

const ParseOutcome = enum { ok, help, usage_error };

fn parseArgs(
    gpa: std.mem.Allocator,
    args: []const [:0]const u8,
    opts: *Cli,
    err: *Io.Writer,
) !ParseOutcome {
    _ = gpa;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];

        if (eq(a, "-h") or eq(a, "--help")) return .help;
        if (eq(a, "--link-libc")) {
            opts.link_libc = true;
            continue;
        }
        if (eq(a, "--force")) {
            opts.force = true;
            continue;
        }
        if (eq(a, "--dry-run")) {
            opts.dry_run = true;
            continue;
        }
        if (eq(a, "--no-go")) {
            opts.no_go = true;
            continue;
        }
        if (eq(a, "--no-python")) {
            opts.no_python = true;
            continue;
        }

        const Flag = struct { name: []const u8, field: *?[]const u8 };
        const flags = [_]Flag{
            .{ .name = "--input", .field = &opts.input },
            .{ .name = "--input-display", .field = &opts.input_display },
            .{ .name = "--name", .field = &opts.name },
            .{ .name = "--targets", .field = &opts.target_ids },
            .{ .name = "--out-go", .field = &opts.out_go },
            .{ .name = "--out-python", .field = &opts.out_python },
            .{ .name = "--out-c-header", .field = &opts.out_c_header },
            .{ .name = "--out-zig", .field = &opts.out_zig },
            .{ .name = "--go-module", .field = &opts.go_module },
            .{ .name = "--go-package", .field = &opts.go_package },
            .{ .name = "--python-package", .field = &opts.python_package },
        };

        var matched = false;
        for (flags) |f| {
            // Accept both `--flag value` and `--flag=value`.
            if (eq(a, f.name)) {
                i += 1;
                if (i >= args.len) {
                    try err.print("zbridge: {s} needs a value\n\n", .{f.name});
                    try err.writeAll(usage_text);
                    return .usage_error;
                }
                if (try setOnce(f.field, f.name, args[i], err)) return .usage_error;
                matched = true;
                break;
            }
            if (a.len > f.name.len and std.mem.startsWith(u8, a, f.name) and a[f.name.len] == '=') {
                if (try setOnce(f.field, f.name, a[f.name.len + 1 ..], err)) return .usage_error;
                matched = true;
                break;
            }
        }
        if (matched) continue;

        try err.print("zbridge: unknown flag '{s}'\n\n", .{a});
        try err.writeAll(usage_text);
        return .usage_error;
    }
    return .ok;
}

/// Assigns a flag's value, or reports that the flag was given twice. Silently
/// keeping the last one hides a real mistake: `--targets host --targets all`
/// looks like it asked for both.
fn setOnce(
    field: *?[]const u8,
    name: []const u8,
    value: []const u8,
    err: *Io.Writer,
) !bool {
    if (field.*) |previous| {
        try err.print(
            "zbridge: {s} was specified twice ('{s}' then '{s}'); pass it once\n\n",
            .{ name, previous, value },
        );
        try err.writeAll(usage_text);
        return true;
    }
    field.* = value;
    return false;
}

fn printTargets(out: *Io.Writer) !void {
    try out.writeAll("id               zig triple (no libc)     zig triple (libc)        go            python\n");
    for (targets.all) |t| {
        const i = targets.info(t);
        try out.print("{s: <16} {s: <24} {s: <24} {s}/{s: <8} {s}/{s}\n", .{
            t.id(),           i.triple_nolibc, i.triple_libc,
            i.go_os,          i.go_arch,       i.py_system,
            i.py_machines[0],
        });
    }
}

// ---------------------------------------------------------------------------
// `zbridge generate`
// ---------------------------------------------------------------------------

fn cmdGenerate(
    gpa: std.mem.Allocator,
    io: Io,
    input: []const u8,
    opts: Cli,
    out: *Io.Writer,
    err: *Io.Writer,
) !u8 {
    const cwd: Io.Dir = .cwd();

    const source = cwd.readFileAllocOptions(io, input, gpa, .limited(16 << 20), .of(u8), 0) catch |e| {
        try err.print("zbridge: cannot read '{s}': {s}\n", .{ input, @errorName(e) });
        return exit_failure;
    };

    const lib_name = (try resolveLibName(gpa, opts, input, err)) orelse return exit_usage;
    const selected = resolveTargets(gpa, opts.target_ids, err) catch return exit_usage;

    var diags: diag.List = .init(gpa, input);

    const options: generate.Options = .{
        .lib_name = lib_name,
        .input_path = opts.input_display orelse input,
        .targets = selected,
        .link_libc = opts.link_libc,
        .emit_go = !opts.no_go and opts.out_go != null,
        .emit_python = !opts.no_python and opts.out_python != null,
        .emit_c_header = opts.out_c_header != null,
        .go = .{
            .module_path = opts.go_module,
            .package_name = opts.go_package,
        },
        .python = .{
            .package_name = opts.python_package,
        },
    };

    const result = try generate.run(gpa, source, options, &diags);

    // Warnings print either way; only errors stop the run.
    try diags.render(err);

    const res = result orelse {
        try err.print("zbridge: {d} error(s); nothing was written\n", .{diags.errorCount()});
        return exit_failure;
    };

    const roots: generate.Roots = .{
        .go = opts.out_go,
        .python = opts.out_python,
        .c = opts.out_c_header,
        .zig_glue = opts.out_zig,
    };

    // Collect actions as they happen rather than only on success: writing
    // walks the file list in order, so a failure part-way leaves the earlier
    // files on disk, and the user needs to know which ones.
    var actions_list: std.ArrayList(generate.FileAction) = .empty;
    generate.writeFilesInto(io, gpa, roots, res.files, .{
        .force = opts.force,
        .dry_run = opts.dry_run,
    }, &actions_list) catch |e| {
        try err.print("zbridge: failed while writing generated files: {s}\n", .{@errorName(e)});
        if (actions_list.items.len == 0) {
            try err.print("    note: nothing was written.\n", .{});
        } else {
            try err.print("    note: these files were already written:\n", .{});
            for (actions_list.items) |a| try err.print("      {s}\n", .{a.path});
        }
        return exit_failure;
    };
    const actions = actions_list.items;

    try reportDropped(out, roots, res.files);
    try report(out, lib_name, res.abi_hash_hex, actions, opts.dry_run);
    return 0;
}

/// The CLI flag that decides where a language's files go.
fn outFlagFor(lang: gen.Lang) []const u8 {
    return switch (lang) {
        .go => "--out-go",
        .python => "--out-python",
        .c => "--out-c-header",
        .zig_glue => "--out-zig",
    };
}

/// `writeFiles` skips any file whose language has no output root. That is the
/// right behaviour, but doing it silently means `--out-zig` being absent looks
/// identical to the glue root not existing. Name what was produced and
/// dropped, so the omission is a choice rather than a surprise.
fn reportDropped(out: *Io.Writer, roots: generate.Roots, files: []const gen.OutFile) !void {
    var saw_glue = false;
    for (files) |f| {
        if (roots.forLang(f.lang) != null) continue;
        try out.print("not written    {s}  (no {s})\n", .{ f.path, outFlagFor(f.lang) });
        if (f.lang == .zig_glue) saw_glue = true;
    }
    if (saw_glue) {
        try out.writeAll(
            \\    note: the Zig glue root is what `zbridge port` compiles as the shared
            \\          library. Pass --out-zig to keep it, or use `port`, which manages
            \\          it for you.
            \\
        );
    }
}

fn report(
    out: *Io.Writer,
    lib_name: []const u8,
    abi_hex: []const u8,
    actions: []const generate.FileAction,
    dry_run: bool,
) !void {
    const stats: generate.WriteStats = .{ .actions = actions };

    if (dry_run) {
        for (actions) |a| try out.print("{s: <14} {s}\n", .{ @tagName(a.action), a.path });
    } else {
        for (actions) |a| switch (a.action) {
            .created, .overwritten => try out.print("{s: <14} {s}\n", .{ @tagName(a.action), a.path }),
            .unchanged, .skipped_exists => {},
        };
    }

    try out.print("zbridge: {s} (abi {s}) — {d} created, {d} overwritten, {d} unchanged, {d} kept{s}\n", .{
        lib_name,
        abi_hex,
        stats.count(.created),
        stats.count(.overwritten),
        stats.count(.unchanged),
        stats.count(.skipped_exists),
        if (dry_run) " (dry run, nothing written)" else "",
    });
}

// ---------------------------------------------------------------------------
// `zbridge port`
// ---------------------------------------------------------------------------

fn cmdPort(
    gpa: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    input: []const u8,
    opts: Cli,
    out: *Io.Writer,
    err: *Io.Writer,
) !u8 {
    // Decision D2: a named package import can only be resolved by a build
    // graph, and we do not have the user's build.zig. Say so instead of
    // failing later with a confusing "file not found" from the compiler.
    // This also reports an unreadable or non-file --input, so `port` fails the
    // same way `generate` does rather than writing a project around it.
    if (try checkImports(gpa, io, input, err)) |code| return code;

    const lib_name = (try resolveLibName(gpa, opts, input, err)) orelse return exit_usage;
    const selected = resolveTargets(gpa, opts.target_ids, err) catch return exit_usage;

    // --dry-run must not touch the filesystem, and everything below this point
    // writes: the throwaway project, then the compiler. Report what generation
    // would do (which `cmdGenerate` computes without writing) plus the compile
    // plan, and stop here.
    if (opts.dry_run) {
        const code = try cmdGenerate(gpa, io, input, opts, out, err);
        if (code != 0) return code;
        try out.print(
            "zbridge: --dry-run, would then compile {s} for {d} target(s):\n",
            .{ lib_name, selected.len },
        );
        for (selected) |t| {
            try out.print("    {s: <16} {s}\n", .{ t.id(), targets.triple(t, opts.link_libc) });
        }
        return 0;
    }

    const zbridge_root = findZbridgeRoot(gpa, io, environ) catch |e| {
        try err.print(
            \\zbridge: cannot locate the zbridge source tree ({s}).
            \\    note: `port` compiles through a generated build.zig that depends on it.
            \\    note: set ZBRIDGE_ROOT to the directory containing zbridge's build.zig.
            \\
        , .{@errorName(e)});
        return exit_failure;
    };

    const project = try writeThrowawayProject(gpa, io, .{
        .zbridge_root = zbridge_root,
        .input = input,
        .lib_name = lib_name,
        .targets = selected,
        .opts = opts,
    });

    try out.print("zbridge: compiling {s} for {d} target(s) via {s}\n", .{
        lib_name, selected.len, project,
    });
    try out.flush();

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ "zig", "build", "--build-file", try std.fs.path.join(gpa, &.{ project, "build.zig" }), "port" });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        try err.print("zbridge: cannot run `zig build`: {s}\n", .{@errorName(e)});
        return exit_failure;
    };

    switch (try child.wait(io)) {
        .exited => |c| {
            if (c != 0) {
                try err.print("zbridge: `zig build port` failed with exit code {d}\n", .{c});
                return exit_failure;
            }
        },
        else => |t| {
            try err.print("zbridge: `zig build port` terminated abnormally: {any}\n", .{t});
            return exit_failure;
        },
    }

    try out.print("zbridge: {s} ported\n", .{lib_name});
    return 0;
}

const ProjectSpec = struct {
    zbridge_root: []const u8,
    input: []const u8,
    lib_name: []const u8,
    targets: []const targets.Target,
    opts: Cli,
};

/// Fingerprint accepted by Zig for the package name `zbridge_port`. Zig
/// derives it from the name, so it is a constant for a constant name.
const throwaway_fingerprint = "0x25737a509f11884a";

fn writeThrowawayProject(gpa: std.mem.Allocator, io: Io, spec: ProjectSpec) ![]const u8 {
    const cwd: Io.Dir = .cwd();

    const input_abs = try absolute(gpa, io, spec.input);

    // One directory per distinct configuration, so two concurrent ports of
    // different libraries cannot fight over the same build cache.
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(input_abs);
    hasher.update(spec.lib_name);
    hasher.update(spec.zbridge_root);
    for (spec.targets) |t| hasher.update(t.id());
    hasher.update(if (spec.opts.link_libc) "libc" else "nolibc");
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/zbridge/port-{x:0>16}", .{hasher.final()});
    try cwd.createDirPath(io, dir);
    const dir_abs = try absolute(gpa, io, dir);

    var b: Io.Writer.Allocating = .init(gpa);
    const w = &b.writer;

    try w.print(
        \\// Generated by zbridge {s}. Throwaway project; safe to delete.
        \\//
        \\// Decision D1: the CLI never shells out to `zig build-lib`. It writes
        \\// this and lets the same `addPortStep` the build integration exposes do
        \\// the work, so both front ends emit identical binaries.
        \\const std = @import("std");
        \\const zbridge = @import("zbridge");
        \\
        \\pub fn build(bld: *std.Build) void {{
        \\    _ = zbridge.addPortStep(bld, .{{
        \\        .name = "{s}",
        \\        .root_source_file = .{{ .cwd_relative = "{f}" }},
        \\        // Recorded verbatim in the generated headers, so that porting
        \\        // the same file from the CLI and from a build.zig produces
        \\        // byte-identical output.
        \\        .input_display = "{f}",
        \\        .optimize = .ReleaseFast,
        \\        .link_libc = {},
        \\        .targets = &.{{
        \\
    , .{
        zbridge.version.string,
        spec.lib_name,
        zigString(input_abs),
        zigString(spec.opts.input_display orelse spec.input),
        spec.opts.link_libc,
    });

    for (spec.targets) |t| try w.print("            \"{s}\",\n", .{t.id()});
    try w.writeAll("        },\n");

    if (spec.opts.out_go) |p| {
        try w.print("        .out_go = .{{ .cwd_relative = \"{f}\" }},\n", .{zigString(try absolute(gpa, io, p))});
    }
    if (spec.opts.out_python) |p| {
        try w.print("        .out_python = .{{ .cwd_relative = \"{f}\" }},\n", .{zigString(try absolute(gpa, io, p))});
    }
    if (spec.opts.out_c_header) |p| {
        try w.print("        .out_c_header = .{{ .cwd_relative = \"{f}\" }},\n", .{zigString(try absolute(gpa, io, p))});
    }
    if (spec.opts.go_module) |m| try w.print("        .go_module_path = \"{f}\",\n", .{zigString(m)});
    if (spec.opts.go_package) |m| try w.print("        .go_package = \"{f}\",\n", .{zigString(m)});
    if (spec.opts.python_package) |m| try w.print("        .python_package = \"{f}\",\n", .{zigString(m)});

    try w.writeAll("    });\n}\n");

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(gpa, &.{ dir, "build.zig" }),
        .data = b.written(),
    });

    // Zig rejects an absolute `.path` dependency, so it has to be expressed
    // relative to the throwaway project. Which is fine: the throwaway lives in
    // the user's own cache dir, so a relative path always exists (except
    // across Windows drives, which we report rather than guess at).
    const root_abs = try absolute(gpa, io, spec.zbridge_root);
    const root_rel = std.fs.path.relative(gpa, dir_abs, null, dir_abs, root_abs) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (root_rel.len == 0) return error.ZbridgeRootNotFound;
    // `.zig-cache` may sit on another volume on Windows; a relative path that
    // still looks absolute means no relative path exists.
    const dep_path = if (std.fs.path.isAbsolute(root_rel)) return error.ZbridgeRootNotRelative else toSlashes(gpa, root_rel) catch return error.OutOfMemory;

    const zon = try std.fmt.allocPrint(gpa,
        \\.{{
        \\    .name = .zbridge_port,
        \\    .version = "0.0.0",
        \\    .fingerprint = {s},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        .zbridge = .{{ .path = "{f}" }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon" }},
        \\}}
        \\
    , .{ throwaway_fingerprint, zigString(dep_path) });

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(gpa, &.{ dir, "build.zig.zon" }),
        .data = zon,
    });

    return dir_abs;
}

/// Escapes a path for embedding in a Zig string literal. Windows paths are
/// full of backslashes, so this is not optional.
const ZigString = struct {
    bytes: []const u8,

    pub fn format(self: ZigString, w: *Io.Writer) Io.Writer.Error!void {
        for (self.bytes) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        };
    }
};

fn zigString(bytes: []const u8) ZigString {
    return .{ .bytes = bytes };
}

/// `build.zig.zon` paths use `/` on every platform.
fn toSlashes(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.sep == '/') return path;
    const out = try gpa.dupe(u8, path);
    std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

/// Where the zbridge package lives, so the throwaway project can depend on it.
/// `ZBRIDGE_ROOT` wins; otherwise walk up from the running executable, which
/// covers both `zig-out/bin/zbridge` in a checkout and `bin/zbridge` in a
/// release archive.
fn findZbridgeRoot(gpa: std.mem.Allocator, io: Io, environ: std.process.Environ) ![]const u8 {
    if (environ.getAlloc(gpa, "ZBRIDGE_ROOT")) |v| {
        if (v.len > 0) return v;
    } else |_| {}

    const exe_dir = try std.process.executableDirPathAlloc(io, gpa);
    var candidate: []const u8 = exe_dir;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (looksLikeZbridgeRoot(io, candidate)) return candidate;
        candidate = std.fs.path.dirname(candidate) orelse break;
    }
    return error.ZbridgeRootNotFound;
}

fn looksLikeZbridgeRoot(io: Io, path: []const u8) bool {
    const cwd: Io.Dir = .cwd();
    var buf: [4096]u8 = undefined;
    const build_zig = std.fmt.bufPrint(&buf, "{s}/build.zig", .{path}) catch return false;
    cwd.access(io, build_zig, .{}) catch return false;
    var buf2: [4096]u8 = undefined;
    const api = std.fmt.bufPrint(&buf2, "{s}/src/build_api.zig", .{path}) catch return false;
    cwd.access(io, api, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Decision D2: reject named package imports
// ---------------------------------------------------------------------------

/// Returns an exit code when the run must stop, null when it may continue.
fn checkImports(gpa: std.mem.Allocator, io: Io, input: []const u8, err: *Io.Writer) !?u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList(Pending) = .empty;
    var offenders: std.ArrayList(Offender) = .empty;
    var unreadable: std.ArrayList(Unreadable) = .empty;

    try queue.append(gpa, .{ .path = input, .imported_by = null });
    try seen.put(gpa, input, {});

    const cwd: Io.Dir = .cwd();
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const node = queue.items[qi];
        const source = cwd.readFileAllocOptions(io, node.path, gpa, .limited(16 << 20), .of(u8), 0) catch |e| {
            // Not "the compiler's problem": a file we cannot open is a file we
            // cannot scan, so we cannot claim this input is free of named
            // package imports. Saying so now beats a confusing failure inside
            // `zig build` later.
            try unreadable.append(gpa, .{
                .path = node.path,
                .imported_by = node.imported_by,
                .reason = @errorName(e),
            });
            continue;
        };

        const imports = try scanImports(gpa, source);
        for (imports) |spec| {
            if (eq(spec, "std") or eq(spec, "builtin") or eq(spec, "root")) continue;
            if (!std.mem.endsWith(u8, spec, ".zig")) {
                try offenders.append(gpa, .{ .file = node.path, .name = spec });
                continue;
            }
            // Follow absolute `.zig` imports as well as relative ones. An
            // absolute import is unusual but perfectly legal, and it can reach
            // a named package exactly like a relative one can — skipping it
            // was a hole straight through this check.
            const next = if (std.fs.path.isAbsolute(spec))
                try gpa.dupe(u8, spec)
            else blk: {
                const dir = std.fs.path.dirname(node.path) orelse ".";
                break :blk try std.fs.path.resolve(gpa, &.{ dir, spec });
            };
            if (seen.contains(next)) continue;
            try seen.put(gpa, next, {});
            try queue.append(gpa, .{ .path = next, .imported_by = node.path });
        }
    }

    // The input itself being unreadable (a directory, a typo, no permission)
    // is the most basic failure there is; report it exactly as `generate`
    // does and stop, since nothing was scanned.
    for (unreadable.items) |u| {
        if (u.imported_by != null) continue;
        try err.print("zbridge: cannot read '{s}': {s}\n", .{ u.path, u.reason });
        return exit_failure;
    }

    if (unreadable.items.len > 0) {
        try err.writeAll(
            \\zbridge: cannot read every file this input imports, so it cannot be checked
            \\         for named package imports.
            \\
        );
        for (unreadable.items) |u| {
            try err.print("    {s}: {s} (imported by {s})\n", .{
                u.path,
                u.reason,
                u.imported_by.?,
            });
        }
        try err.writeAll(
            \\
            \\    note: `zig build` would fail on these too. Fix the paths, or use the
            \\          build.zig integration, which resolves imports through your own
            \\          build graph.
            \\
        );
        return exit_failure;
    }

    if (offenders.items.len == 0) return null;

    try err.writeAll(
        \\zbridge: this input imports named packages, which the CLI cannot resolve.
        \\
    );
    for (offenders.items) |o| {
        try err.print("    {s}: @import(\"{s}\")\n", .{ o.file, o.name });
    }
    try err.writeAll(
        \\
        \\    note: only a build graph knows how a package name maps to a module. That
        \\          mapping lives in your build.zig, which this CLI cannot read.
        \\    note: use the build.zig integration instead (IMPLEMENTATION.md §5.2):
        \\
        \\              const zbridge = @import("zbridge");
        \\              zbridge.addPortStep(b, .{
        \\                  .name = "mylib",
        \\                  .root_source_file = b.path("src/c_api.zig"),
        \\                  .imports = &.{
        \\                      .{ .name = "<the name above>", .dependency = "<zon dep>", .module = "<module>" },
        \\                  },
        \\                  .out_go = b.path("bindings/go"),
        \\                  .out_python = b.path("bindings/python"),
        \\              });
        \\
        \\    note: `zbridge generate` still works — it never compiles anything.
        \\
    );
    return exit_failure;
}

const Offender = struct { file: []const u8, name: []const u8 };
const Pending = struct { path: []const u8, imported_by: ?[]const u8 };
const Unreadable = struct { path: []const u8, imported_by: ?[]const u8, reason: []const u8 };

/// Prefers `parse.scanImports` when the parser exposes it, so both halves of
/// the tool agree on what an import is. Falls back to a local token scan
/// otherwise, and treats an empty result as "nothing to check" rather than as
/// "no imports exist", so a stub implementation degrades to a no-op.
fn scanImports(gpa: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    if (@hasDecl(zbridge.parse, "scanImports")) {
        const info = @typeInfo(@TypeOf(zbridge.parse.scanImports)).@"fn";
        const found = switch (info.params.len) {
            2 => try zbridge.parse.scanImports(gpa, source),
            else => @compileError("unexpected parse.scanImports signature; expected fn(Allocator, [:0]const u8)"),
        };
        if (found.len > 0) return found;
    }
    return localScanImports(gpa, source);
}

/// `@import("x")` at the token level. Deliberately not AST-based: this runs
/// before validation and must work on files the parser would reject.
fn localScanImports(gpa: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var tok: std.zig.Tokenizer = .init(source);

    var state: enum { idle, saw_import, saw_lparen } = .idle;
    while (true) {
        const t = tok.next();
        switch (t.tag) {
            .eof => break,
            .builtin => {
                state = if (eq(source[t.loc.start..t.loc.end], "@import")) .saw_import else .idle;
            },
            .l_paren => state = if (state == .saw_import) .saw_lparen else .idle,
            .string_literal => {
                if (state == .saw_lparen) {
                    const raw = source[t.loc.start..t.loc.end];
                    const parsed = std.zig.string_literal.parseAlloc(gpa, raw) catch {
                        state = .idle;
                        continue;
                    };
                    try out.append(gpa, parsed);
                }
                state = .idle;
            },
            else => state = .idle,
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn absolute(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    return std.fs.path.resolve(gpa, &.{ cwd, path });
}

fn resolveTargets(
    gpa: std.mem.Allocator,
    spec: ?[]const u8,
    err: *Io.Writer,
) ![]const targets.Target {
    const text = spec orelse return targets.default;
    if (eq(text, "all")) return targets.default;

    var out: std.ArrayList(targets.Target) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        if (eq(name, "host")) {
            const h = targets.host() orelse {
                try err.writeAll("zbridge: this host is not one of the supported targets\n");
                return error.UnknownTarget;
            };
            try appendUniqueTarget(gpa, &out, h, name, err);
            continue;
        }
        const t = targets.fromString(name) orelse {
            try err.print("zbridge: unknown target '{s}'. Run `zbridge targets` for the list.\n", .{name});
            return error.UnknownTarget;
        };
        try appendUniqueTarget(gpa, &out, t, name, err);
    }
    if (out.items.len == 0) {
        try err.writeAll("zbridge: --targets was empty\n");
        return error.UnknownTarget;
    }
    return out.toOwnedSlice(gpa);
}

/// One target can be spelled several ways (`linux_x86_64`, `linux-amd64`,
/// `host`). Without this, `--targets linux_x86_64,linux-amd64` would build the
/// same library twice into the same destination path.
fn appendUniqueTarget(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(targets.Target),
    t: targets.Target,
    spelling: []const u8,
    err: *Io.Writer,
) !void {
    for (out.items) |existing| {
        if (existing == t) {
            try err.print(
                "zbridge: warning: '{s}' repeats target '{s}'; it will be built once\n",
                .{ spelling, t.id() },
            );
            return;
        }
    }
    try out.append(gpa, t);
}

/// The library name for this run: `--name` if given (validated), otherwise
/// derived from the input file name. Returns null when the name is unusable
/// and the caller should exit; the reason has already been printed.
fn resolveLibName(
    gpa: std.mem.Allocator,
    opts: Cli,
    input: []const u8,
    err: *Io.Writer,
) !?[]const u8 {
    if (opts.name) |name| {
        if (validateLibName(name)) |why| {
            try err.print("zbridge: invalid --name '{s}': {s}\n", .{ name, why });
            try err.writeAll(
                \\    note: the library name becomes a Zig identifier, the generated file
                \\          names, the Go package clause and the Python package directory.
                \\
            );
            return null;
        }
        return name;
    }

    return deriveName(gpa, input) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AmbiguousLibName => {
            try err.print("zbridge: cannot derive a library name from '{s}'\n", .{input});
            try err.writeAll(
                \\    note: the file name says nothing about the library, and guessing from the
                \\          enclosing directory would make the generated output — the ABI hash,
                \\          every file name, the Go package, the Python package directory —
                \\          depend on where the project happens to be checked out.
                \\    note: pass --name <name> explicitly.
                \\
            );
            return null;
        },
    };
}

/// Shared with the build.zig front end; see `gen/names.zig`.
const validateLibName = zbridge.gen.names.validateLibName;

/// Names that say nothing about the library, so we refuse to guess.
const generic_stems = [_][]const u8{
    "c_api", "capi", "api",    "ffi",     "lib",    "root",
    "main",  "mod",  "c",      "exports", "export", "bindings",
    "index", "src",  "source",
};

fn isGeneric(s: []const u8) bool {
    for (generic_stems) |g| {
        if (std.ascii.eqlIgnoreCase(g, s)) return true;
    }
    return false;
}

/// `--name` derivation, documented in the usage text: the input file's stem,
/// and nothing else.
///
/// Deliberately does NOT walk up the path when the stem is generic. The
/// library name feeds the ABI hash, every generated file name, the Go package
/// and the Python package directory, so deriving it from an enclosing
/// directory would make the generated bytes depend on where the repository
/// happens to be checked out — `/home/alice/zcounter/src/c_api.zig` and
/// `/tmp/build/src/c_api.zig` would disagree. A generic stem is reported as
/// `error.AmbiguousLibName` so the caller passes `--name` and gets a name that
/// travels with the source.
fn deriveName(gpa: std.mem.Allocator, input_path: []const u8) error{ AmbiguousLibName, OutOfMemory }![]const u8 {
    const base = std.fs.path.basename(input_path);
    const stem = if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base;

    if (stem.len == 0 or isGeneric(stem)) return error.AmbiguousLibName;
    return sanitize(gpa, stem);
}

/// Lowercase, `[^a-z0-9_]` collapsed to `_`, never starting with a digit —
/// so the result is a legal identifier in Zig, Go, Python and C alike.
fn sanitize(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(gpa, std.ascii.toLower(c));
        } else {
            try out.append(gpa, '_');
        }
    }
    if (out.items.len == 0) return "lib";
    if (std.ascii.isDigit(out.items[0])) try out.insert(gpa, 0, '_');
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "name derivation uses the file stem and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("zpdf", try deriveName(a, "src/zpdf.zig"));
    try testing.expectEqualStrings("zpdf", try deriveName(a, "zpdf.zig"));
    try testing.expectEqualStrings("my_lib", try deriveName(a, "src/My-Lib.zig"));

    // A generic stem is refused rather than guessed at from the directory.
    try testing.expectError(error.AmbiguousLibName, deriveName(a, "c_api.zig"));
    try testing.expectError(error.AmbiguousLibName, deriveName(a, "zcounter/api.zig"));
    try testing.expectError(error.AmbiguousLibName, deriveName(a, "examples/zcounter/src/c_api.zig"));
}

test "name derivation does not depend on the absolute path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The whole point: checking the same repository out somewhere else must
    // not change the library name, because the name feeds the ABI hash and
    // every generated file name.
    try testing.expectEqualStrings("zpdf", try deriveName(a, "/home/alice/zpdf/src/zpdf.zig"));
    try testing.expectEqualStrings("zpdf", try deriveName(a, "/tmp/build/src/zpdf.zig"));
    try testing.expectEqualStrings("zpdf", try deriveName(a, "zpdf.zig"));

    // These used to yield "zcounter", "build" and "_" respectively.
    try testing.expectError(error.AmbiguousLibName, deriveName(a, "/home/alice/zcounter/src/c_api.zig"));
    try testing.expectError(error.AmbiguousLibName, deriveName(a, "/tmp/build/src/c_api.zig"));
    try testing.expectError(error.AmbiguousLibName, deriveName(a, "/src/api.zig"));
}

test "library names that would break a generated file are rejected" {
    // Empty, path traversal and separators.
    try testing.expect(validateLibName("") != null);
    try testing.expect(validateLibName("../../x") != null);
    try testing.expect(validateLibName("a/b") != null);
    try testing.expect(validateLibName("a\\b") != null);
    try testing.expect(validateLibName("..") != null);

    // Not a legal identifier: `export fn my-lib_zbridge_abi_hash()` would not
    // compile, and `package my-lib` is not valid Go.
    try testing.expect(validateLibName("my-lib") != null);
    try testing.expect(validateLibName("my lib") != null);
    try testing.expect(validateLibName("2fast") != null);

    // Keywords in the target languages.
    try testing.expect(validateLibName("range") != null);
    try testing.expect(validateLibName("lambda") != null);

    // Legal.
    try testing.expectEqual(@as(?[]const u8, null), validateLibName("zpdf"));
    try testing.expectEqual(@as(?[]const u8, null), validateLibName("_private"));
    try testing.expectEqual(@as(?[]const u8, null), validateLibName("z3"));
    try testing.expectEqual(@as(?[]const u8, null), validateLibName("my_lib"));
}

test "sanitize produces a legal identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("_3d", try sanitize(a, "3d"));
    try testing.expectEqualStrings("a_b_c", try sanitize(a, "a.b-c"));
}

test "import scanning finds every @import spelling" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src =
        \\const std = @import("std");
        \\const helper = @import("helper.zig");
        \\const zigimg = @import("zigimg");
        \\// @import("commented_out")
        \\const s = "not @import(\"a string\")";
        \\const nested = @import("sub/dir/thing.zig");
        \\
    ;
    const got = try localScanImports(a, src);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("std", got[0]);
    try testing.expectEqualStrings("helper.zig", got[1]);
    try testing.expectEqualStrings("zigimg", got[2]);
    try testing.expectEqualStrings("sub/dir/thing.zig", got[3]);
}

test "zig string escaping survives a windows path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var out: Io.Writer.Allocating = .init(arena_state.allocator());
    try out.writer.print("{f}", .{zigString("C:\\src\\a\"b")});
    try testing.expectEqualStrings("C:\\\\src\\\\a\\\"b", out.written());
}

test "target selection" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sink: Io.Writer.Allocating = .init(a);

    const got = try resolveTargets(a, "linux_x86_64,macos-arm64", &sink.writer);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(targets.Target.linux_x86_64, got[0]);
    try testing.expectEqual(targets.Target.macos_aarch64, got[1]);

    try testing.expectEqual(targets.default.len, (try resolveTargets(a, null, &sink.writer)).len);
    try testing.expectError(error.UnknownTarget, resolveTargets(a, "plan9", &sink.writer));
}

test "target selection deduplicates spellings of one target" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sink: Io.Writer.Allocating = .init(a);

    // Two spellings of the same target must not build the same library twice
    // into the same destination path.
    const got = try resolveTargets(a, "linux_x86_64,linux-amd64,x86_64-linux", &sink.writer);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(targets.Target.linux_x86_64, got[0]);
    try testing.expect(std.mem.indexOf(u8, sink.written(), "repeats target") != null);
}

test "a flag given twice is an error, not last-one-wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sink: Io.Writer.Allocating = .init(a);

    var opts: Cli = .{};
    const args = [_][:0]const u8{ "--targets", "host", "--targets", "all" };
    try testing.expectEqual(
        ParseOutcome.usage_error,
        try parseArgs(a, &args, &opts, &sink.writer),
    );
    try testing.expect(std.mem.indexOf(u8, sink.written(), "specified twice") != null);

    // The `--flag=value` spelling counts too.
    var opts2: Cli = .{};
    var sink2: Io.Writer.Allocating = .init(a);
    const args2 = [_][:0]const u8{ "--name=a", "--name=b" };
    try testing.expectEqual(
        ParseOutcome.usage_error,
        try parseArgs(a, &args2, &opts2, &sink2.writer),
    );
}
