# Engineering Plan: `zbridge` — a Zig → Go/Python FFI Porting Tool

(`zbridge` is a working name — rename freely.)

## 1. Executive Summary

`zbridge` is a code-generation tool, not a library someone's end product depends on
at runtime. It contains **no domain code of its own** and defines **no schema any
developer has to maintain**. Any Zig developer, working in their own separate repo on
their own library, points `zbridge` at the Zig source file where they've written
`export fn` declarations — either by running the `zbridge` CLI directly, or by
importing `zbridge` as a Zig package dependency and calling it from their own
`build.zig` as a custom step (§5.1) — and gets back:

1. Cross-compiled shared libraries (`.so` / `.dylib` / `.dll`) for a fixed target
   matrix.
2. Generated Go bindings (loader + typed low-level calls + an editable skeleton).
3. Generated Python bindings (same shape, via `ctypes`).

The source of truth is the developer's own Zig code. `export fn` already means
"this is my public C-ABI surface" — `zbridge` reads that directly by parsing the
source with Zig's own AST (`std.zig.Ast`, the same parser `zig fmt` uses), so there
is nothing new to write, annotate, or keep in sync. Today this replaces the manual
step of hand-writing a `.go` file that imports the compiled Zig lib and maps its
structs/functions to Go by hand, one function at a time.

---

## 2. Non-Goals

* **No library code lives in this repo.** `zbridge` never contains PDF parsing,
  vector search, or any other domain logic — it only ever processes *other* people's
  Zig source.
* **No schema file.** No `schema.spec.json`, no manifest listing which functions to
  port. If it's `export fn`, it's in scope.
* **No cooperation required from the target project's `build.zig`.** `zbridge` drives
  its own `zig build-lib` invocation directly against the one input file; it doesn't
  need to understand or integrate with however the developer otherwise builds their
  project.
* **v1 is single-file.** The tool parses exactly one Zig source file per run (e.g.
  their `c_api.zig`) and does not follow `@import`s. Multi-file API surfaces are out
  of scope until a real library needs it — no speculative generality.
* **v1 targets Go and Python only.** Node/`koffi`, Rust, etc. come later, once the
  parse→validate→generate pipeline is proven on two languages.

---

## 3. How It Works (Pipeline)

```
   <library>.zig  (developer's own file, has export fn + opaque {} decls)
          │
          ▼
   1. Parse      — std.zig.Ast walks top-level decls in the one input file:
          │         collects `const X = opaque {};` handle types, then every
          │         `export fn name(args) ret`.
          ▼
   2. Validate    — each signature checked against the ABI-safe type allowlist
          │         (§4). Anything outside it is a build-time error naming the
          │         offending function — never a silent partial port.
          ▼
   3. Compile     — `zig build-lib <input> -dynamic -OReleaseFast -fstrip
          │         -target <triple>` once per target in the matrix.
          ▼
   4. Generate    — emits, per language:
                      a) loader.{go,py}         — generic, identical every run
                      b) <lib>_ffi_gen.{go,py}  — mechanical 1:1 typed calls,
                                                   regenerated and overwritten
                                                   every run, marked DO NOT EDIT
                      c) <lib>.{go,py}          — idiomatic skeleton, generated
                                                   ONCE (never overwritten once
                                                   it exists — see §6), with
                                                   `// TODO` markers for the
                                                   parts that need a human
```

---

## 4. Supported ABI-Safe Type Subset

This allowlist is the actual contract. If a developer's `export fn` only uses these
shapes, `zbridge` can port it automatically. Anything else is flagged, not silently
mangled.

| Zig shape | Treated as | Go | Python |
| :--- | :--- | :--- | :--- |
| `const X = opaque {};` used as `?*X` / `*X` | Opaque handle | `*X` wrapper struct holding `uintptr` | `class X` wrapping `c_void_p` |
| `u8..u64`, `i8..i64` | Integer | matching sized Go int | matching `ctypes.c_*` |
| `f32`, `f64` | Float | `float32`/`float64` | `c_float`/`c_double` |
| `bool` | Boolean | `bool` | `c_bool` |
| `void` | No return / no-op arg | — | — |
| `[*]const u8` immediately followed by a `usize` len param | Byte buffer in | `[]byte` | `bytes`/`bytearray` |
| `[*]u8` + `usize` len (out param) | Byte buffer out | `[]byte` (pre-sized by caller) | `bytearray` (pre-sized) |

Mechanical-tier codegen detail: `unsafe.SliceData` on a non-nil, zero-length Go slice
isn't guaranteed to return nil, so the generated call site always guards it —
`var ptr *byte; if len(data) > 0 { ptr = unsafe.SliceData(data) }` — rather than
passing whatever `SliceData` happens to return for the empty case.

Not supported in v1 (flagged by the validator, not guessed at): structs passed by
value, slices of anything but `u8`, tagged unions, error unions as a return type,
multi-level pointers. A library that needs these has to expose a narrower `export fn`
shim in its own `c_api.zig` first — that's a cost paid once, by the library author,
not by `zbridge`.

---

## 5. Two Front Ends, One Core

Parse → validate → compile → generate (§3) is implemented once, as a plain Zig
module with no CLI or build-system concerns baked in. Two thin front ends call into
it. **§5.2 is the primary, recommended path** — it hands module resolution to the
developer's own build graph for free, so any `export fn` that reaches into a named
`build.zig.zon` dependency (as opposed to a plain relative `@import("root.zig")`,
which resolves fine on its own) just works. §5.1 exists for one-off/scripted use.

### 5.1 CLI

```bash
zbridge port \
  --input src/c_api.zig \
  --targets linux-x86_64-musl,linux-aarch64-musl,macos-aarch64,macos-x86_64,windows-x86_64-gnu \
  --out-go bindings/go \
  --out-python bindings/python
```

Raw `zig build-lib <input> -dynamic -target <triple>` only works when `<input>`'s
imports are plain relative files (`@import("root.zig")`) — those resolve from the
filesystem with no build graph needed. It breaks the moment `<input>` (transitively)
imports a **named package** from the developer's `build.zig.zon`, since only a build
graph knows how to resolve that name. So the CLI never shells out to `zig build-lib`
directly: it generates a throwaway `build.zig` that declares the input as a shared
library module, re-declares whatever dependencies are present in the target
project's own `build.zig.zon`, and drives compilation through `zig build` against
that generated file. Same compile output either way — the CLI just does, on the
fly, what §5.2 gets for free.

### 5.2 `build.zig` integration

A developer who'd rather wire generation into their own `zig build` graph adds
`zbridge` as a dependency in `build.zig.zon` and calls it directly from their
`build.zig`:

```zig
const zbridge = @import("zbridge");

pub fn build(b: *std.Build) void {
    // ...their normal build graph...
    zbridge.addPortStep(b, .{
        .input = b.path("src/c_api.zig"),
        .targets = &.{ .linux_x86_64_musl, .macos_aarch64, .windows_x86_64_gnu },
        .out_go = b.path("bindings/go"),
        .out_python = b.path("bindings/python"),
    });
}
```

This registers a `zig build port` step, so generation participates in their normal
build/CI without shelling out to a separate binary. Both front ends produce
byte-identical output for the same input — the CLI exists for one-off/scripted use,
the `build.zig` integration for developers who want it as a standing part of their
project's build.

Re-running generation (either front end) after adding a new `export fn`:
* Recompiles all targets.
* Regenerates `loader.{go,py}` and `<lib>_ffi_gen.{go,py}` unconditionally.
* Adds the new function's stub to `<lib>.{go,py}` **without** touching hand-written
  code already there for existing functions (see §6 for how that's kept safe).

---

## 6. Generated Output Layout & the Regeneration Problem

The core risk in any generator that produces editable output: the second run
clobbers the first run's hand edits. `zbridge` avoids this by splitting output into
two tiers with different lifecycles:

* **Mechanical tier — `<lib>_ffi_gen.go` / `_ffi_gen.py`, plus `loader.go`/`loader.py`:**
  Pure 1:1 typed calls (`purego.RegisterLibFunc` / `ctypes` `argtypes`/`restype`) and
  the embed/cache/dlopen boilerplate. No judgment calls live here, so it is safe to
  fully regenerate and overwrite on every run. Header comment: `// Code generated by
  zbridge. DO NOT EDIT.`
* **Skeleton tier — `<lib>.go` / `<lib>.py`:**
  The idiomatic, hand-editable wrapper: a struct/class per opaque handle, `Close()`
  + finalizer (Go) or context manager + `__del__` (Python), one method stub per
  exported function with a `// TODO: <what a human still needs to decide>` comment
  (error translation, naming, higher-level ergonomics). Generated **only if the file
  doesn't already exist**. When a new `export fn` is added on a later run, `zbridge`
  appends a new stub method for it into the existing file rather than rewriting the
  whole file — existing hand-written methods are left untouched. `--force` overwrites
  the skeleton tier entirely, for when a developer wants a clean regenerate.

---

## 7. Implementation Roadmap

### Phase 1: Zig Source Parser & Validator
* Walk one file's top-level declarations with `std.zig.Ast`.
* Collect `opaque {}` type declarations by name.
* Collect every `export fn`: name, parameter names + resolved types, return type.
* Run each signature through the §4 allowlist; collect all violations and fail with
  every offending function named at once (not one-at-a-time).

### Phase 2: Cross-Compile Driver
* Fixed target matrix (same list carried over from the earlier single-library plan):
  `x86_64-linux-musl`, `aarch64-linux-musl`, `aarch64-macos`, `x86_64-macos`,
  `x86_64-windows-gnu`.
* Shell out to `zig build-lib <input> -dynamic -target <triple> -OReleaseFast -fstrip`
  per target; fail loudly (naming the target) rather than skipping a target that
  didn't build.
* Same macOS caveat as before: this only works cross-compiled because the input file
  can't link a macOS framework (it's a single Zig source file with no system
  dependencies) — document this constraint, don't build around it prematurely.

### Phase 3: Go Generator
* `loader.go` template: GOOS/GOARCH detection, `//go:embed`, cache dir extraction,
  checksum check, `Dlopen`/`LoadLibrary`.
* `<lib>_ffi_gen.go`: one `purego.RegisterLibFunc` call per exported function, using
  the types resolved in Phase 1.
* `<lib>.go` skeleton: struct per opaque handle wrapping the raw pointer, `Close()`
  + `runtime.SetFinalizer`, one stub method per function calling into the `_ffi_gen`
  layer, `// TODO` where judgment is needed.

### Phase 4: Python Generator
* Same shape as Phase 3, targeting `ctypes`: `loader.py` picks the right binary by
  `platform.system()`/`platform.machine()`; `<lib>_ffi_gen.py` sets `argtypes`/
  `restype` per function; `<lib>.py` skeleton wraps the handle in a class with
  `__enter__`/`__exit__`/`__del__`.

### Phase 5: CLI & Regeneration Safety
* Wire `zbridge port` end-to-end across Phases 1–4.
* Implement the append-don't-overwrite behavior for the skeleton tier (§6).
* `--force` flag, `--dry-run` flag (validate + show what would be generated, compile
  and write nothing).

### Phase 6 (later): Additional Languages
* Node via `koffi`, following the same two-tier generation pattern. Not started
  until Go and Python are both proven against a real third-party library.

---

## 8. Critical Pitfalls & Safeguards

| Pitfall | Risk | Mitigation |
| :--- | :--- | :--- |
| **Regeneration clobbers hand edits** | Developer edits `<lib>.go`, re-runs `zbridge`, loses their changes. | Two-tier output (§6): only the mechanical tier is unconditionally overwritten; the skeleton tier is generated once and then appended-to, never rewritten, without `--force`. |
| **macOS cross-compile needs the SDK for frameworks** | A `export fn` that (transitively) pulls in a macOS framework fails to cross-compile from Linux/Windows. | Input file must have zero system framework dependencies — document as a hard requirement of "portable" for this tool, not something to work around. |
| **Type resolution across files** | A `export fn` referencing a type from another file can't be resolved by a single-file parser. | v1 requires the whole exported surface (opaque types + export fns) in one file — same discipline as the earlier `c_api.zig` convention. If it becomes a real limitation, revisit as a v2 multi-file resolver, not upfront. |
| **Silent partial ports** | A function using an unsupported shape (e.g. a struct by value) gets skipped without the developer noticing. | Validator fails the whole run and names every offending function; it never silently drops one. |
| **Windows DLL file locking** | Windows locks open DLL files, preventing in-place overwrite by the loader. | Loader appends the binary hash to the cache filename (`lib_v1_<hash>.dll`), same as the earlier plan. |
| **Stale cached binary vs. newer SDK code** | A cached native binary from an old run answers calls from newer generated wrapper code that expects a different signature. | Loader embeds a version/hash check baked in at generation time; mismatch is a hard error, not a silent miscall. |

---

## 9. End-to-End Flow: Author to End User

Five distinct actors, five distinct responsibilities. `zbridge` only ever does step 3.

1. **You build and release `zbridge`.** One repo, no domain code, versioned and
   tagged like any other tool (mirrors the release process already used for `sigi`:
   pin the version in `build.zig.zon`, tag, CI builds and publishes the CLI binary
   for each platform). This is a one-time (well, ongoing-maintenance) project, not
   per-library work.

2. **A library author writes a Zig library in their own repo** (e.g. `zpdf`, or
   anything from the §10 fit list below) — `export fn`s and `opaque {}` handles in
   one file, same as any Zig library, no `zbridge`-specific code required to write
   the library itself.

3. **They run `zbridge`** — CLI (§5.1) or `build.zig` integration (§5.2) — against
   that file. Out comes: cross-compiled binaries, the mechanical binding tier, and a
   skeleton tier with `// TODO`s.

4. **They fill in the skeleton.** The mechanical tier needs nothing (it's already
   complete, typed, correct). The skeleton tier's TODOs get resolved either by hand
   (idiomatic naming, error translation, doc comments) or, for the mechanical parts,
   automatically by `zbridge` itself — nothing here requires *tool* changes, just
   the author's own edits to already-generated code.

5. **They publish the result themselves**, using normal Go/Python tooling —
   `zbridge` has no role in this step and never touches GitHub, PyPI, or any
   registry. Concretely: `bindings/go/` becomes (or is pushed to) `github.com/
   <author>/zpdf-go`, tagged as a Go module; `bindings/python/` becomes a `zpdf`
   wheel on PyPI. Both already embed the precompiled Zig binaries from step 3, so
   publishing them is exactly like publishing any other Go module or Python package
   — `zbridge` never appears again after generation.

6. **An end user consumes it with zero Zig awareness.** `go get github.com/<author>/
   zpdf-go` or `pip install zpdf` — they get a normal-looking Go/Python library. No
   Zig toolchain, no C compiler, no knowledge that `purego`/`ctypes` is loading a
   precompiled native binary underneath. That opacity is the entire point.

---

## 10. Appendix: What Kinds of Libraries This Actually Fits

The type-safety allowlist in §4 isn't arbitrary — it's the same "raw data in, raw
data/status out" boundary that made sense for hand-written FFI in the first place.
Libraries whose public API can be expressed entirely in opaque handles, primitives,
and byte buffers port cleanly through `zbridge`; libraries that need to expose rich
structured data, callbacks into the host runtime, or async/event-loop integration
will hit the validator and need a narrower C-ABI shim written by hand first (or
don't fit this tool at all).

**Good fits:** file format parsers/encoders (PDF, image codecs, archives/compression),
embedded key-value stores and vector indexes, order-matching/market-data engines,
hashing and cryptography primitives, parsers/lexers/rule engines — anything
compute-heavy that already speaks in bytes, numbers, and opaque handles.

**Poor fits:** ORMs, HTTP routers/web frameworks, dependency injection containers,
async schedulers/task queues — these need to integrate with the host language's
runtime (reflection, event loops, goroutines/asyncio) in ways no C-ABI boundary can
express, so the validator would reject most of their surface anyway.
