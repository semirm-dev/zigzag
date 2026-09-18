# `zbridge` — Detailed Implementation Steps

Companion to [`universal_zig_engine_sdk_pipeline_plan.md`](universal_zig_engine_sdk_pipeline_plan.md).
The plan defines *what* and *why*; this file defines *how, in which order, and how we
know each step is done*. Target toolchain: **Zig 0.16.0** (pinned via
`minimum_zig_version` in `build.zig.zon`).

---

## 0. Decisions this document makes on top of the plan

These fix contradictions or gaps in the plan. Confirm or reject them before starting;
the steps below assume they are accepted.

| # | Decision | Why |
| :--- | :--- | :--- |
| D1 | **All compilation goes through `std.Build`** (`b.addLibrary(.{ .linkage = .dynamic })`), never raw `zig build-lib`. | The plan says three different things (§3 and Phase 2 say `zig build-lib`; §5.1 says "never shells out to `zig build-lib`"). One compile path means both front ends produce the same output. |
| D2 | **The CLI supports only self-contained inputs** (relative `@import`s). Named package imports are supported only through the `build.zig` integration. | The CLI can't reliably "re-declare dependencies from `build.zig.zon`": the zon lists packages, but the `@import("name")` → `dep.module("x")` mapping lives in the developer's `build.zig`, which the CLI can't read. The CLI detects named imports and fails with "use the build.zig integration". |
| D3 | **Generated code is never hand-edited.** Output has three layers: raw FFI (`_ffi_gen`), an idiomatic wrapper that is also generated and overwritten (`<lib>_gen`), and user code in separate files the tool never touches. `zbridge init` writes the user files once. | The plan's "append new stubs into an existing hand-edited file" is the hardest and most fragile part of the design. Appending is trivial in Go, but in Python the methods have to go *inside* a class body, which means parsing user-edited code. The protobuf/sqlc model (generated file + separate user file in the same package, or a Python subclass) avoids that entirely. |
| D4 | **Linux binaries don't link libc by default.** If the library needs libc, the target becomes `x86_64-linux-gnu.2.17` / `aarch64-linux-gnu.2.17` (manylinux2014-compatible) instead of musl. | A `-dynamic` musl build with `-lc` links musl *statically into the .so*. When that .so is loaded into a glibc host (almost every Go/Python process), the process ends up with two libcs (two mallocs, two sets of TLS). That can seem to work and then fail later. With no libc, the .so has no dependencies. Tested on the Zig 0.16 install here: the no-libc musl .so loads and runs through ctypes. |
| D5 | **Ship a vertical slice before building breadth.** Milestone 1 runs one `i32 add(i32, i32)` all the way to a passing Go test and Python test on all 3 OSes. After that, widen the type support. | The riskiest unknowns are loader, embed, dlopen and CI matrix, not the parser. Building every phase in full before anything runs end to end hides integration bugs until the end. |
| D6 | **Header generation is our job, not Zig's.** | Tested: `zig build-lib -femit-h` on 0.16 fails with *"-femit-h is currently broken"* (ziglang/zig#9698). We also emit a `.h` as a bonus target because it's nearly free once we have the IR. |
| D7 | **Handle lifecycle comes from naming conventions, not annotations.** For handle `Foo`, a `export fn *_{destroy,free,deinit,close}(*Foo) void` is its destructor; `export fn *_{new,create,init,open}(...) ?*Foo` is a constructor. If nothing matches, generation still succeeds and prints a warning. | The idiomatic layer (`Close()` / context manager) needs this. The plan's promise of no schema is kept. |

Allowlist additions to plan §4 (all trivially ABI-safe and needed by almost every
real C API):

* `usize`/`isize` → Go `uintptr`/`int` (via cast), Python `c_size_t`/`c_ssize_t`.
* `c_int`, `c_uint`, `c_long`, `c_ulong` → platform C types. Note `c_long` is 32-bit on Windows.
  `c_char` is **rejected**: C `char` is unsigned on aarch64 and signed on x86_64, both of
  which zbridge builds for, so it would mean two different things in one set of bindings.
* `[*:0]const u8` (C string in) → Go `string`, Python `str` (utf-8 encoded).
* `*T` / `?*T` where `T` is an integer, float or bool → single out-param. Go returns it as an extra result; Python uses `byref`.
* `enum(uN)` with explicit tag type → Go named int type plus consts; Python `IntEnum`. **Phase 7**, not v1.

Still rejected in v1: structs by value, `extern struct` pointers, callbacks,
error unions, `u128`, `anyopaque` other than through a declared `opaque {}`.

---

## 1. Repository layout (target end state)

```
zigzag/
├── build.zig                  # builds zbridge CLI + exposes addPortStep (D1)
├── build.zig.zon
├── src/
│   ├── main.zig               # CLI front end (argument parsing only)
│   ├── build_api.zig          # addPortStep, re-exported from build.zig
│   ├── core/
│   │   ├── ir.zig             # Api, Handle, Function, Param, Type — pure data
│   │   ├── parse.zig          # std.zig.Ast → IR (no validation)
│   │   ├── validate.zig       # IR → []Diagnostic (allowlist, pairing, conventions)
│   │   ├── abi_hash.zig       # stable hash of the IR
│   │   ├── targets.zig        # target matrix ↔ triples ↔ (GOOS,GOARCH) ↔ (py system, machine)
│   │   └── diagnostics.zig    # file:line:col rendering, like zig's own errors
│   ├── gen/
│   │   ├── writer.zig         # indentation-aware code emitter
│   │   ├── go.zig
│   │   ├── python.zig
│   │   └── c_header.zig
│   └── templates/             # static loader bodies, @embedFile'd
│       ├── loader.go.tmpl
│       └── loader.py.tmpl
├── test/
│   ├── parse/                 # *.zig inputs + expected IR (JSON) snapshots
│   ├── validate/              # *.zig inputs + expected diagnostics text
│   └── golden/                # input → full expected generated tree
└── examples/
    └── zcounter/              # tiny real library used by e2e CI
        ├── build.zig          # uses zbridge via path dependency (dogfoods §5.2)
        ├── src/c_api.zig
        ├── go_test/           # consumer Go module: go test ./...
        └── py_test/           # consumer: pytest
```

The core (`core/` + `gen/`) never touches `std.process`, argv, or `std.Build`. Both
front ends go through **one** function:

```zig
pub fn generate(gpa, io, input_path, source, options) !GenerateResult
// GenerateResult = { api: Ir.Api, files: []OutFile{ path, bytes, tier } } | diagnostics
```

Compilation is **not** in the core (D1). It belongs to the build graph.

---

## 2. Milestone 1 — Walking skeleton (vertical slice)

Goal: `examples/zcounter` has one function `export fn zc_add(a: i32, b: i32) i32`. Go
and Python tests call it successfully on Linux x86_64, macOS arm64 and Windows x86_64
in CI. Everything is deliberately hardcoded. The point is to prove the ends connect.

1. **Scaffold** `build.zig` / `build.zig.zon` (name `zbridge`, `minimum_zig_version = "0.16.0"`), a `zbridge` exe, and a `zig build test` step.
2. **Minimal parser**: `std.zig.Ast.parse(gpa, source, .zig)`, iterate `tree.rootDecls()`, and use `tree.fullFnProto(&buf, node)` for any node whose `extern_export_inline_token` is the `export` keyword. Record name, params (name + type token slice) and return type, with only `i32` understood.
3. **Minimal Go gen**: hardcode `loader.go` for the host platform only. `_ffi_gen.go` has `var zc_add func(int32, int32) int32` and `purego.RegisterLibFunc(&zc_add, lib, "zc_add")`.
4. **Minimal Python gen**: `ctypes.CDLL(path)`, `argtypes`, `restype`.
5. **Compile via build graph** (D1): in `examples/zcounter/build.zig`, `b.addLibrary` for the host target. Install the lib into the Go and Python output dirs.
6. **CI** (`.github/workflows/ci.yml`): matrix `ubuntu-latest`, `ubuntu-24.04-arm`, `macos-14`, `windows-latest`. Steps: setup Zig 0.16 → `zig build test` → `cd examples/zcounter && zig build port` → `go test ./...` in `go_test/` → `pytest` in `py_test/`.

**Done when:** all four CI legs are green. Expect to learn things here (purego quirks
on Windows, macOS dylib paths, pytest discovery) that change later steps. Update this
doc when you do.

---

## 3. Phase 1 — Parser & IR

### 3.1 IR (`core/ir.zig`)
```zig
pub const Type = union(enum) {
    void, bool,
    int: struct { bits: u16, signed: bool },   // u8..u64, i8..i64
    usize, isize,
    c_int: CIntKind,                            // c_int, c_uint, c_long, ...
    float: enum { f32, f64 },
    handle: struct { name: []const u8, optional: bool, is_const: bool },
    many_u8: struct { is_const: bool, sentinel_zero: bool }, // [*]u8, [*]const u8, [*:0]const u8
    out_prim: struct { child: *const Type, optional: bool },  // *T for primitive T
    unsupported: struct { src: []const u8 },    // kept, not dropped — validator reports it
};
pub const Param = struct { name: []const u8, ty: Type, loc: Loc };
pub const Function = struct { name: []const u8, params: []Param, ret: Type, doc: ?[]const u8, loc: Loc };
pub const Handle = struct { name: []const u8, doc: ?[]const u8, loc: Loc };
pub const Api = struct { lib_name: []const u8, handles: []Handle, functions: []Function };
```
The parser **never fails on an unknown type**. It produces `.unsupported`, and the
validator reports every problem at once (plan §7 Phase 1).

### 3.2 Parse steps (`core/parse.zig`)
1. Read the file and parse it with `Ast.parse(.., .zig)`. If `tree.errors.len > 0`, render them with `tree.renderError` and stop.
2. **Pass 1, handles:** for each root `var_decl` (`tree.fullVarDecl`) where `init_node` is a container decl (`tree.fullContainerDecl`) whose main token is the `opaque` keyword, record a `Handle`. Accept both `pub` and non-`pub`.
3. **Pass 1b, type aliases:** record `const Name = <type expr>;` where the RHS is a primitive or a pointer to a known handle, so `const Ctx = *Engine;` resolves. Only one level of aliasing, and only in the same file.
4. **Pass 2, functions:** for each root fn decl with the `export` token: name, params (via `full.FnProto.iterate`), return type node, and `///` doc comments (walk tokens backwards from the first token while the tag is `.doc_comment`).
5. **Type resolution** `resolveType(node) Type`, by node tag:
   * `.identifier` → primitive table (`i32`, `usize`, `c_int`, `bool`, …) → alias table → handle table → otherwise `.unsupported`.
   * `.optional_type` → resolve child. Allowed only around handle and out-param pointers.
   * `ptr_type*` nodes → `tree.fullPtrType`: check `size` (`.one` vs `.many`), `const_token`, `sentinel`, then the child.
   * Anything else (`error_union`, `array_type`, container literals, calls) → `.unsupported` with the source slice.
6. Reject `export var` / `export const`: data exports are a clear diagnostic, not silently skipped.
7. Record `Loc { line, column }` from `tree.tokenLocation(0, token)` everywhere, for diagnostics.

### 3.3 Tests
Snapshot tests in `test/parse/`: `foo.zig` next to `foo.ir.json`. The IR is serialized
with `std.json.Stringify` so a diff shows what changed. Cover at minimum: `pub export fn`,
doc comments, aliases, `?*const Handle`, `callconv` noise, comments between params,
an input with syntax errors, and an empty file.

---

## 4. Phase 2 — Validator

`core/validate.zig`: `validate(api) []Diagnostic`. Each diagnostic has a
`{ severity, loc, fn_name, message, hint }`. Rules:

1. **Unsupported type** in a param or return → error, naming the function, the param and the Zig source text. The hint is "wrap it in a narrower export fn shim" (plan §4).
2. **Buffer pairing:** every `[*]const u8` / `[*]u8` must be followed immediately by a `usize` param. The pair collapses into one logical `bytes_in` / `bytes_out` param. An unpaired `[*]` is an error; a sentinel `[*:0]` needs no length.
3. **Many-pointer as return type** → error. Ownership would be undefined.
4. **Handle references** must name a declared `opaque {}`. Pointers to undeclared types are errors.
5. **Name collisions** after case conversion (Go `CamelCase`, Python `snake_case`) and against target-language keywords (`type`, `func`, `range`, `def`, `class`, `lambda`, …) → error with a rename hint. Parameter names get an automatic suffix (`type_`) instead of an error.
6. **Lifecycle conventions** (D7) → warnings only: a handle with no destructor, or with more than one destructor candidate.
7. **Empty API** (zero export fns) → error.

Rendering follows Zig's own format so editors can link it:
`src/c_api.zig:12:5: error: zpdf_open: parameter 'opts' has unsupported type 'Options' (struct by value)`.
The exit code is non-zero if there is any error. `--dry-run` stops after this step.

Tests: one `.zig` per rule under `test/validate/`, each with an expected `.txt` of
rendered diagnostics.

---

## 5. Phase 3 — Target matrix & compile (build graph)

### 5.1 `core/targets.zig`
One table, used everywhere:

| id | Zig triple (no libc / libc) | Go GOOS/GOARCH | Python `system()`/`machine()` | file |
| :--- | :--- | :--- | :--- | :--- |
| `linux_x86_64` | `x86_64-linux-musl` / `x86_64-linux-gnu.2.17` | linux/amd64 | Linux / x86_64 | `lib<n>.so` |
| `linux_aarch64` | `aarch64-linux-musl` / `aarch64-linux-gnu.2.17` | linux/arm64 | Linux / aarch64 | `lib<n>.so` |
| `macos_aarch64` | `aarch64-macos.11.0` | darwin/arm64 | Darwin / arm64 | `lib<n>.dylib` |
| `macos_x86_64` | `x86_64-macos.11.0` | darwin/amd64 | Darwin / x86_64 | `lib<n>.dylib` |
| `windows_x86_64` | `x86_64-windows-gnu` | windows/amd64 | Windows / AMD64 | `<n>.dll` |

`link_libc: bool` is an option on the port step (D4). Pin minimum OS versions
explicitly so binaries don't silently require the build machine's OS version.

### 5.2 `addPortStep` (`src/build_api.zig`), the primary path
```zig
pub const PortOptions = struct {
    name: []const u8,                        // library base name
    root_source_file: std.Build.LazyPath,    // their c_api.zig
    imports: []const Import = &.{},          // named deps, resolved per target
    targets: []const Target = &targets.default,
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
    link_libc: bool = false,
    out_go: ?std.Build.LazyPath = null,
    out_python: ?std.Build.LazyPath = null,
    out_c_header: ?std.Build.LazyPath = null,
    go_module_path: ?[]const u8 = null,      // e.g. "github.com/me/zpdf-go"
};
pub const Import = struct { name: []const u8, dependency: []const u8, module: []const u8 };
```
Steps:
1. Build the `zbridge` generator exe for the **host** (`b.graph.host`) from zbridge's own dependency. Add a `Run` step: `zbridge generate --input <file> --abi-out <tmp>/abi.json --emit ...`. Use `addFileArg` / `addOutputDirectoryArg` so the build system caches it correctly.
2. For each target: `b.createModule(.{ .root_source_file = <generated root>, .target = b.resolveTargetQuery(q), .optimize, .strip = true, .link_libc })`. For each `Import`, call `b.dependency(dep, .{ .target, .optimize }).module(module)` and `addImport(name, ...)`. This is what makes named packages work (D2).
3. **Generated root module:** a small file produced by the generator:
   ```zig
   comptime { _ = @import("zbridge_input"); }
   export fn <lib>_zbridge_abi_hash() u64 { return 0x<hash>; }
   ```
   The user's file is attached as module `zbridge_input`, so its relative imports still resolve. The extra export lets the loader check the ABI at load time (plan §8 "stale cached binary").
   **Verify early:** export fns in an imported file are emitted when that file is only referenced through `_ = @import(...)`. If they aren't, fall back to using the user file as the root and passing the hash through `b.addOptions`.
4. `b.addLibrary(.{ .linkage = .dynamic, .name, .root_module })` per target, then install into `<out_go>/native/<id>/` and `<out_python>/<pkg>/_native/<id>/` with `b.addInstallFileWithDir` / `addWriteFiles` + `addUpdateSourceFiles` (the output lives in the source tree, so it can be committed for `go get`).
5. Register `b.step("port", ...)` that depends on everything above. A failure in any target fails the step and names the target (Zig already reports it that way).

### 5.3 CLI (`src/main.zig`)
`zbridge port --input … --targets … --out-go … --out-python … [--link-libc] [--force] [--dry-run]`
1. Parse and validate (Phases 1–2). If the input or any file it imports relatively contains an `@import("<non-.zig name>")` other than `std`/`builtin`, stop with D2's message. Scan imports with the same AST pass, following relative imports only.
2. Write a throwaway project into the cache dir: `build.zig` + `build.zig.zon` whose only dependency is zbridge itself (a path dep pointing at the running binary's own package dir, shipped in release archives), calling `addPortStep` with absolute paths.
3. Run `zig build port` there (`std.process.Child`) and stream its output.

Both front ends therefore run identical code, which makes byte-identical output
(plan §5.2) true by construction.

`zbridge generate` is the internal subcommand the build step calls (parse →
validate → write generated sources). It is public but documented as low-level.

---

## 6. Phase 4 — Code-emission infrastructure

1. `gen/writer.zig`: wraps `*std.Io.Writer` with `indent()`/`dedent()`/`line(fmt, args)`/`blank()`. All generators use it. No string concatenation.
2. Deterministic output: stable ordering (source order), no timestamps, `\n` line endings everywhere, trailing newline. The header states the zbridge version and ABI hash only.
3. Naming helpers (`snakeToCamel`, `snakeToPascal`, strip the common library prefix `zpdf_` → `Open`) plus keyword tables per language. Shared across generators and covered by unit tests.
4. `core/abi_hash.zig`: FNV-1a/xxhash over a canonical text form of the IR (names + types, **not** doc comments or param names), so doc edits don't break a binary.

---

## 7. Phase 5 — Go generator

Output for `name = "zpdf"`, `go_module_path = "github.com/me/zpdf-go"`:

```
bindings/go/
├── go.mod                       # written once if absent; requires github.com/ebitengine/purego
├── native/<target-id>/lib…      # compiled binaries (Phase 3)
├── embed_linux_amd64.go         # //go:build linux && amd64   //go:embed native/linux_x86_64/libzpdf.so
├── embed_…go                    # one per target — only the matching binary is embedded (!)
├── loader_gen.go                # template: extract → cache → dlopen → ABI check
├── zpdf_ffi_gen.go              # raw purego bindings
├── zpdf_gen.go                  # idiomatic layer (D3), regenerated
└── zpdf.go                      # user file, written by `zbridge init` only if absent
```

Steps:
1. **Per-platform embed files.** A single `//go:embed native/*` would put every platform's binary into every user's executable. Build tags keep only the matching one. An unsupported GOOS/GOARCH gets `embed_other.go` (`//go:build !(...)`), which makes `Load()` return a clear "platform not supported" error instead of a link failure.
2. **`loader_gen.go`** (template + substituted consts):
   * On first use (`sync.Once`), hash the embedded bytes (sha256, first 16 hex chars) and write them to `os.UserCacheDir()/zbridge/<lib>/<version>-<hash>/<file>` via temp file + rename (atomic; safe under concurrent processes). Skip the write if the file exists and the hash matches (plan §8, Windows locking).
   * Open it: `purego.Dlopen(path, RTLD_NOW|RTLD_LOCAL)` on unix; `syscall.LoadLibrary` on Windows (purego exposes `RegisterLibFunc` over a `uintptr` handle on both).
   * Call `<lib>_zbridge_abi_hash` and compare it to the generated const. On mismatch, return an error.
   * Env override `ZPDF_LIB_PATH` to load a locally built lib. This is essential for library authors while developing.
3. **`_ffi_gen.go`:** one `var <name> func(...)` per export, registered in `init`-free `bind(lib uintptr)` called by the loader. Type map: ints → sized Go ints, `usize` → `uintptr`, `bool` → `bool`, handle → `uintptr`, buffer pair → `*byte, uintptr`, cstring → `*byte`, out-prim → `*T`.
4. **`_gen.go` (idiomatic):**
   * `type Foo struct{ h uintptr }` per handle. Constructors return `(*Foo, error)` (nil handle → `ErrNull`), `Close()` is idempotent (zeroes `h`), and `runtime.SetFinalizer` is a safety net only.
   * Methods: a first param of `*Foo` becomes a method. Byte buffers become `[]byte` with the empty-slice guard from plan §4. C strings become `string`: append `\x00` to a copy and use `runtime.KeepAlive`. Out-prims become extra return values.
   * Every call is followed by `runtime.KeepAlive(receiver)` so the finalizer can't run mid-call.
   * Zig `///` docs become Go doc comments.
5. **`zbridge init`** writes `zpdf.go` containing only `package zpdf` and a comment that explains where custom code goes.
6. **Tests:** golden-file tests for all generated files, plus `go vet` and `gofmt -l` on the golden output in CI (they must report nothing).

---

## 8. Phase 6 — Python generator

```
bindings/python/
├── pyproject.toml               # written once if absent (hatchling; see step 5)
└── zpdf/
    ├── __init__.py              # user file (init only): `from ._gen import *`
    ├── _native/<target-id>/lib… # compiled binaries
    ├── _loader_gen.py
    ├── _ffi_gen.py
    ├── _gen.py                  # idiomatic layer (D3)
    └── py.typed
```

1. **`_loader_gen.py`:** map `(platform.system(), platform.machine().lower())` to a target id. Normalize `amd64`/`x86_64` and `arm64`/`aarch64`. Load with `ctypes.CDLL(str(path))`. No extraction to a cache dir: a wheel is already unpacked on disk. Check the ABI hash. The `ZPDF_LIB_PATH` override works the same as in Go.
2. **`_ffi_gen.py`:** set `argtypes`/`restype` for every function. Handles use `c_void_p`, and every function returning a handle **must** set `restype = c_void_p`, because the ctypes default of `c_int` truncates 64-bit pointers. Test this explicitly.
3. **`_gen.py`:** a class per handle with `close()`, `__enter__`/`__exit__`, `__del__` → `close()` (guarded against interpreter shutdown), `bytes` / `bytearray` / `memoryview` accepted for buffer-in, cstr via `.encode()`, and out-prims returned as a tuple. Include type hints and docstrings from `///`.
4. User extension is by subclassing or adding functions in `__init__.py` (D3).
5. **Packaging** (optional in v1, but decide now): generate `pyproject.toml` plus a tiny `hatch_build.py` that, when `ZBRIDGE_TARGET=<id>` is set, includes only that target's binary and sets the wheel platform tag (`manylinux2014_x86_64`, `macosx_11_0_arm64`, `win_amd64`, …). Without it you get one fat `py3-none-any` wheel, which works but is non-standard. A mapping table from target id to wheel tag lives in `targets.zig`.
6. **Tests:** golden files, `python -m py_compile` and `ruff check` on the golden output, and pytest in the e2e example.

---

## 9. Phase 7 — Hardening & release

1. **C header generator** (D6): `<lib>.h` with `typedef struct Foo Foo;`, `stdint.h`/`stdbool.h`/`stddef.h` types and include guards. It's cheap, and it lets anyone use the library from C, C#, Swift and others.
2. **`enum(uN)` support** (allowlist addition).
3. **Stale-output cleanup:** list files in the output dirs with the `_gen` suffix that the current run didn't produce (for example a removed target) and delete them. Only those files, never user files. Report each removal.
4. **`--dry-run`**: print the file list with `create` / `overwrite` / `unchanged` per file, and write nothing.
5. **Error-path e2e tests:** an input with 3 unsupported functions must report all 3 in one run. A binary with a mismatched ABI hash must fail at load time in both Go and Python.
6. **Release pipeline:** on tag, CI builds `zbridge` for the same 5 targets (with Zig this is a trivial cross-compile) and attaches the archives to a GitHub release. Document the `zig fetch --save git+https://…#<tag>` usage for §5.2.
7. **Docs:** README quickstart (one screen), a supported-types table (generated from the same table the validator uses, so it can't drift), and the "portable input" rules (no macOS frameworks, one-file API surface, libc choice).

---

## 10. Later (v2, not planned in detail)

* **Multi-file API surface.** Instead of extending the AST resolver, have the generator produce a tiny Zig program that `@import`s the user module and walks `@typeInfo` at comptime to emit the IR as JSON. That resolves types across files and packages for free. The cost is that exported decls must be `pub` so `@typeInfo(...).decls` can see them.
* Node (`koffi`), Rust, C# (P/Invoke). Each is a new `gen/*.zig` over the same IR.
* `extern struct` by pointer, and library-allocated buffers with a paired free fn.

---

## 11. Verification gate (every PR)

```
zig build test                       # unit + parse/validate snapshots + golden gen
zig build                            # zbridge exe builds
(cd examples/zcounter && zig build port && git diff --exit-code bindings/)  # regenerated output is committed & stable
(cd examples/zcounter/go_test && go vet ./... && go test ./...)
(cd examples/zcounter/py_test && pytest -q)
```
In CI this runs across the 4-OS matrix from Milestone 1. Golden files are updated
with `zig build test -Dupdate-golden`. The diff shows up in review, never silently.

---

## 12. Suggested order & rough size

| Step | Depends on | Size |
| :--- | :--- | :--- |
| M1 walking skeleton + CI | — | 2–3 days |
| Phase 1 parser + IR | M1 | 2 days |
| Phase 2 validator | P1 | 1–2 days |
| Phase 3 targets + `addPortStep` + CLI | P1 | 3 days |
| Phase 4 emitter infra | P1 | 0.5 day |
| Phase 5 Go gen | P2, P4 | 3 days |
| Phase 6 Python gen | P2, P4 | 2 days |
| Phase 7 hardening/release | all | 3 days |

Phases 5 and 6 can run in parallel once the IR is frozen, and so can Phase 3 and
Phase 2. Freeze `ir.zig` at the end of Phase 1 and treat changes to it as
cross-team changes.

---

## 13. As built

Written after the implementation landed, so the plan above doesn't read as if it
were still the whole truth. Everything here was verified by running it.

**Assumptions that held.** `export fn`s in a module reached only through
`comptime { _ = @import("zbridge_input"); }` really are emitted into the shared
library (`nm -D` on the example shows all seven exports plus the ABI hash
function, with no libc dependency), so the `b.addOptions` fallback in §5.2 was
never needed. D1 is fully implemented: `zbridge port` writes a throwaway project
into `.zig-cache/zbridge/` and drives `zig build port` through the same
`addPortStep` the build integration uses.

**Where the output differs from §7 and §8.**

* The Go loader is three files, not one. purego's `Dlopen` is build-tagged
  unix-only (`dlfcn.go` covers darwin/freebsd/linux/netbsd), so Windows goes
  through `syscall.LoadLibrary`; one file cannot compile for both. Hence
  `loader_gen.go` + `loader_unix_gen.go` + `loader_windows_gen.go`.
  `purego.RegisterLibFunc` also *panics* on a missing symbol, so the loader
  recovers it into an error.
* `c_long`/`c_ulong` get build-tagged type aliases in
  `ctypes_{other,windows}_gen.go`, emitted only when those types appear. C
  `long` is 32-bit on Windows and pointer-sized elsewhere, so no single Go type
  is correct for both.
* Generated Go doc comments are normalized before they are written: gofmt
  rewrites `*` bullets into `-`, so a Zig `///` comment copied verbatim would
  otherwise fail the `gofmt -l` gate through no fault of the library author.
* The CLI gained `--out-zig` (the build step needs the glue root as a build
  artifact), `--input-display` (the banner must not embed an absolute path, or
  the determinism gate fails on every other machine), `--go-package`,
  `--python-package`, `--no-go`, `--no-python`.
* `PortOptions` gained `zbridge_dependency`, `python_package`, `go_package` and
  `input_display`; `PortStep` exposes `generate`, `glue_dir` and `libraries`.

**go.mod and go.sum.** purego's version and the `go` directive are paired in
`gen.GoOptions` because purego v0.11.0 requires Go 1.25.0 and would not build
against the `go 1.23` directive. The defaults are v0.9.0 and 1.23, chosen so the
*published* bindings work for the widest range of consumers. zbridge cannot
write `go.sum` (that means resolving and hashing modules over the network), so a
library author runs `go mod tidy` once and commits it.

**Test layout.** Tests live next to the code they cover, with fixtures under
`src/**/testdata/`, rather than in the top-level `test/` tree sketched in §1.
`@embedFile` cannot reach outside the module root, and keeping a generator's
goldens beside it makes the pair obvious.

**Known gaps.** `*const T` for a scalar is rejected rather than treated as a
read-only in-pointer, because `ir.Type.out_ptr` has no `is_const` and silently
turning an input into an extra return value would be worse than refusing.
`ir.Type.unsupported` carries only the offending source text, so a diagnostic
cannot say *why* a type is unsupported ("struct by value") without a reason tag
on the IR. Neither is worth an IR change yet.

---

## 14. Review round (post-implementation)

Two read-only reviews — one on the generated FFI code, one on the core
pipeline — found bugs that the test suite did not. Recorded here because the
pattern is worth keeping: everything below passed CI before it was found.

**Memory safety, in the generated bindings.**

* A handle with *several* destructor-shaped names had none of them folded into
  `Close()`, and each was still emitted as an ordinary method — so calling one
  freed the native object and left the wrapper holding a live dangling pointer.
  Now every candidate consumes the handle.
* Python wrapped a handle returned by a non-constructor in an *owning* object,
  so garbage-collecting a borrowed pointer called the destructor on a library's
  own singleton. Go already refused to do this; Python now matches.
* The Go loader accepted a cached library on a **size** match, although the
  hash in the path came from the embedded bytes and nothing ever hashed the
  file on disk. Anyone able to write a same-size file into a shared cache
  directory got it `dlopen`ed. It now verifies the contents.
* Go had no closed-handle or nil guard where Python raised, so a call after
  `Close()` passed 0 into a non-optional `*T`. Both now consult
  `ir.HandleRef.optional`: non-optional panics/raises, optional forwards null.

**The "never silently port what we don't understand" promise.**

* `*align(64) u32`, `*volatile`, `*allowzero` and `addrspace` were parsed and
  dropped; `callconv(.naked)` was ignored and called as C; `anytype` and
  C-variadics produced diagnostics naming `'x'` or `'('`. All now rejected with
  a message quoting what the user wrote.
* `export fn` nested in a container, and `@export(...)`, were invisible — the
  `.so` would carry symbols the bindings never mentioned. Now an error.
* The C header generator emitted `/* unsupported: X */ void*` where Go and
  Python both refused, with a test locking the behaviour in. Now it refuses too.
* `c_char` was accepted and mapped, though C `char` is unsigned on aarch64 and
  signed on x86_64 — both targets we ship. Rejected outright; the allowlist
  never included it.

**Everything else.** A user scaffold was overwritten without `--force` when it
was merely unreadable (`catch null` conflating "absent" with "can't read it").
`port --dry-run` wrote files. `--name` was uninterpolated into a Zig
identifier, a package name and a path, so `--name ../../x` escaped the output
root. The ABI hash changed when two functions were reordered or an opaque type
renamed, invalidating good binaries. `pruneStale` was dead code whose glob
would have matched a user's own `*_gen.go`; it was deleted rather than wired up.

**What the reviews found clean**, having traced it rather than assumed it: Go
pointer rules and `runtime.KeepAlive` placement (checked against purego's own
implementation), the empty-slice `unsafe.SliceData` guard, finalizer-vs-call
races, ctypes temporary lifetimes, the `restype` truncation trap, ABI
enforcement in both languages, extraction atomicity, parser lifetimes,
determinism of the generated bytes, and the parser/validator handshake over
`ptr, len` pairs.
