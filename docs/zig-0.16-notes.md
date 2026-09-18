# Zig 0.16 API notes (verified in this repo)

0.16 moved the filesystem behind `std.Io` and reworked writers. Everything below
was compiled and run against the pinned toolchain (`zig version` → `0.16.0`), so
prefer it over anything you remember from 0.13–0.15.

## Entry point

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();       // lives as long as the process
    const io = init.io;                       // needed for ALL file I/O
    const args = try init.minimal.args.toSlice(gpa);
}
```

## Files and directories — `std.Io.Dir`, not `std.fs`

`std.fs.cwd()` is gone. Every call takes `io` as its first or second argument.

```zig
const Io = std.Io;
const cwd: Io.Dir = .cwd();

// Read a file with a 0 sentinel (what std.zig.Ast.parse needs):
const src = try cwd.readFileAllocOptions(io, path, gpa, .limited(1 << 20), .of(u8), 0);
// Plain read:
const bytes = try cwd.readFileAlloc(io, path, gpa, .limited(1 << 20));
// Write / mkdir -p / delete / iterate:
try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
try cwd.createDirPath(io, dir_path);
try cwd.deleteFile(io, path);
var dir = try cwd.openDir(io, path, .{ .iterate = true });
defer dir.close(io);
var it = dir.iterate();              // no io here
while (try it.next(io)) |entry| {}   // io here
```

Note the argument order: `readFileAlloc(dir, io, sub_path, gpa, limit)` — the
allocator comes *after* the path.

## Writers

```zig
// Build a string:
var out: Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try out.writer.print("{s}\n", .{x});
const text = out.written();     // takes *Allocating, so `out` must be `var`
const owned = try out.toOwnedSlice();

// Write to a fixed buffer:
var w: Io.Writer = .fixed(&buf);
try w.print(...);
const used = w.buffered();

// stdout/stderr:
var buf: [4096]u8 = undefined;
var fw: Io.File.Writer = .init(.stdout(), io, &buf);
try fw.interface.print("{s}", .{text});
try fw.interface.flush();   // required
```

A custom `format` method now has the signature
`pub fn format(self: T, w: *std.Io.Writer) std.Io.Writer.Error!void`.

## Collections and allocators

* `std.ArrayList(T)` is unmanaged: `var list: std.ArrayList(T) = .empty;` and
  every method takes the allocator — `list.append(gpa, x)`, `list.deinit(gpa)`,
  `list.toOwnedSlice(gpa)`.
* `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator(.{})`.
* `std.mem.trimRight/trimLeft` → `std.mem.trimEnd/trimStart`.
* `std.testing.refAllDeclsRecursive` → `refAllDecls` (non-recursive).

## `std.zig.Ast`

```zig
var tree = try std.zig.Ast.parse(gpa, source, .zig);  // source is [:0]const u8
defer tree.deinit(gpa);
if (tree.errors.len > 0) { /* render and stop */ }

for (tree.rootDecls()) |node| {
    var buf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buf, node)) |proto| {
        // proto.extern_export_inline_token -> check tree.tokenTag(tok) == .keyword_export
        // proto.visib_token               -> `pub`
        const name = tree.tokenSlice(proto.name_token.?);
        var it = proto.iterate(&tree);
        while (it.next()) |param| {
            // param.name_token, param.type_expr (?Node.Index), param.first_doc_comment
        }
        const ret = proto.ast.return_type.unwrap().?;   // OptionalIndex
    }
    if (tree.fullVarDecl(node)) |vd| {
        const decl_name = tree.tokenSlice(vd.ast.mut_token + 1);
        const init_node = vd.ast.init_node.unwrap() orelse continue;
        var cbuf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&cbuf, init_node)) |cd| {
            const is_opaque = tree.tokenTag(cd.ast.main_token) == .keyword_opaque;
        }
    }
}
```

Useful helpers: `tree.getNodeSource(node)` (exact source text of a node),
`tree.fullPtrType(node)`, `tree.tokenTag(i)`, `tree.nodeTag(node)`,
`tree.tokenLocation(0, tok)` → `.{ .line, .column, ... }` (0-based; add 1 for
display), `tree.firstToken(node)`.

`Node.OptionalIndex` needs `.unwrap()`; `Node.Index` does not.

## Building

```zig
const mod = b.addModule("name", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
const exe = b.addExecutable(.{ .name = "x", .root_module = b.createModule(.{ ... .imports = &.{.{ .name = "zbridge", .module = mod }} }) });
const lib = b.addLibrary(.{ .name = "zpdf", .linkage = .dynamic, .root_module = mod });
const t = b.addTest(.{ .root_module = mod, .filters = filters });
```

`build.zig.zon` needs a valid `.fingerprint`; if Zig rejects yours it prints the
correct value to use.

## Things confirmed broken / risky

* `zig build-lib -femit-h` fails outright: *"-femit-h is currently broken"*
  (ziglang/zig#9698). zbridge writes its own C header.
* A `-target x86_64-linux-musl -dynamic -lc` build links musl statically into
  the `.so`. Loading that into a glibc host process means two libcs in one
  process. Default to no libc; use `*-linux-gnu.2.17` when libc is needed.
