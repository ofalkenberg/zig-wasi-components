# Generated bindings

Everything `zig_wasi_components gen` emits lives in a single Zig file
(by convention `bindings.zig`). This page documents what is in that
file, the contract it expects your code to satisfy, and the full
mapping from WIT types to Zig types.

## File layout

The output always follows the same top-to-bottom order, regardless of
the world. Knowing the order is enough to navigate any generated file
without reading it linearly.

1. **Header comment.** Names the source package and world. The
   second line warns that hand-edits will be lost when the file
   regenerates.
2. **Standard imports.** `std` and `abi` (the runtime helper module
   from this project, used to back `cabi_realloc`).
3. **Type definitions.** Every type referenced by the world —
   records, variants, enums, flags, type aliases, plus the
   synthetic types that result from inline returns like
   `func() -> result<u32, string>`. Doc comments from the WIT are
   preserved.
4. **`pub const imports = struct { ... }`.** One Zig wrapper for
   each world-level import. Each wrapper has a Zig-friendly
   signature, packs its arguments into the canonical flat
   representation, calls a private `@extern` pointer, and lifts the
   result back into Zig types.
5. **`const exports = @import("root").wit_exports;`.** The line
   that hooks the generated thunks to your implementation. Your
   root source file must declare `pub const wit_exports = struct { ... }`.
6. **`cabi_realloc`.** The single allocator function the host calls
   when it needs to write data into the guest's memory. Backed by
   a bump arena from `src/abi.zig`.
7. **`export fn <name>(...)`** per world-level function export.
   Each lifts canonical-ABI flat parameters into Zig types, calls
   `exports.<name>(...)`, and lowers the return value back. If the
   return value needs more than one flat slot, the thunk writes it
   into an indirect return area whose address is the single
   returned `i32`.
8. **`export fn cabi_post_<name>(...)`** for any export that
   returns a string, list, or other type that needs post-return
   cleanup. The host calls this after it has finished reading the
   return data.
9. **Per-interface namespaces.** If the world exports an
   `interface`, the generator emits a nested `pub const <iface>`
   inside `wit_exports` (your code), plus per-export thunks with
   the canonical name `<iface>#<func>`.

For resources, the type itself is rendered as a Zig enum-backed
handle (`pub const counter = enum(u32) { _ };`), and there is a
nested `resources.counter` namespace with the constructor, methods,
and `drop` helper. See [resources.md](resources.md).

## The `wit_exports` contract

Your code must export a single declaration:

```zig
pub const wit_exports = struct {
    // one Zig function per exported WIT function
};
```

This declaration must be visible from the root source file (the file
you pass as the entry point of the wasm exe). The generated bindings
reach it via `@import("root").wit_exports`.

The mapping from WIT export names to Zig function names is:

- WIT hyphens become Zig underscores: `format-greeting` →
  `format_greeting`.
- Method-receiver functions on resources go inside a nested struct.
  `interface counters { resource counter { increment: func(); } }`
  expects `wit_exports.counters.counter.increment(self: *State)`.
- The `wit_exports.<resource>.constructor(...)` function returns a
  Zig pointer (typically `*State`); the generated code mints a
  handle from it via the host's `[resource-new]<resource>` import,
  and method thunks receive the rep back as their first core
  parameter and convert it straight into the `*State`. Do not
  return a raw `usize` and do not store the handle yourself — see
  [resources.md](resources.md).

Anything else in your root file (helpers, allocators, comptime
blocks) is invisible to the generated bindings.

## The required comptime pull-in

Every Zig component built against generated bindings needs this line:

```zig
comptime { _ = bindings; }
```

It forces the linker to keep the export functions (`add`, `greet`,
`cabi_realloc`, etc.) even though nothing in your `wit_exports`
*calls* them — they exist solely to be called from the wasm
import/export side. Without the pull-in, the linker strips them and
the resulting core module has no exports.

## WIT to Zig type mapping

This is the complete table. Anything in this table can appear in a
parameter, a return type, a record field, a variant payload, or a
list element, and the generator will do the right thing in both
directions.

| WIT                                  | Zig                                       | Notes                                                            |
| ------------------------------------ | ----------------------------------------- | ---------------------------------------------------------------- |
| `bool`                               | `bool`                                    |                                                                  |
| `s8` `s16` `s32` `s64`               | `i8` `i16` `i32` `i64`                    |                                                                  |
| `u8` `u16` `u32` `u64`               | `u8` `u16` `u32` `u64`                    |                                                                  |
| `f32` `f64`                          | `f32` `f64`                               |                                                                  |
| `char`                               | `u21`                                     | Unicode scalar value, unchecked.                                 |
| `string`                             | `[]const u8`                              | UTF-8. Memory in the canonical-ABI arena.                        |
| `list<T>`                            | `[]const T`                               | Slice. Memory in the canonical-ABI arena.                        |
| `list<T, N>`                         | `[N]T`                                    | Fixed-length, by-value array.                                    |
| `tuple<A, B, ...>`                   | `struct { A, B, ... }`                    | Anonymous tuple struct.                                          |
| `option<T>`                          | `?T`                                      | Zig nullable.                                                    |
| `result<T, E>`                       | `union(enum) { ok: T, err: E }`           | Named per-function (e.g. `safe_divide_result`).                  |
| `result<_, E>`                       | `union(enum) { ok: void, err: E }`        | Same shape with empty ok arm.                                    |
| `result<T, _>`                       | `union(enum) { ok: T, err: void }`        | Same shape with empty err arm.                                   |
| `record { x: u32, y: u32 }`          | `struct { x: u32, y: u32 }`               | Field order preserved; field names hyphen→underscore.            |
| `variant { a, b(u32), c(string) }`   | `union(enum) { a: void, b: u32, c: []const u8 }` |                                                          |
| `enum { red, green, blue }`          | `enum(u8) { red, green, blue }`           | Backing width is the smallest that fits.                         |
| `flags { read, write, exec }`        | `packed struct(u8) { read: bool, ... }`   | Backing width chosen to fit. Max 32 labels.                      |
| `resource foo` (imported)            | `enum(u32) { _ }`                         | Opaque handle. Methods live in an interface-named namespace.     |
| `resource foo` (exported)            | `*State` you define                       | Implementation pattern in [resources.md](resources.md).          |
| `own<foo>`                           | `foo` (the handle enum)                   | Same Zig type as the bare resource name.                         |
| `borrow<foo>`                        | `foo` (the handle enum)                   | Same Zig type as `own<foo>`; semantics differ host-side.         |
| `stream<T>` `future<T>`              | `abi.Stream`, `abi.Future`                | 4-byte handle. Per-payload ops are generated for every function  |
|                                      |                                           | whose signature mentions one — see the intrinsics section below. |
| `error-context`                      | `abi.ErrorContext`                        | Opaque 4-byte handle.                                            |

### Synthetic result types

When a WIT function returns an `option`, `result`, `variant`,
`tuple`, or `record`, the generator emits a named type for the return
value rather than an anonymous one. The name is
`<function_name>_result` (or `<function_name>_<param_name>` for
composite parameters that also need naming):

```wit
export safe-divide: func(a: u32, b: u32) -> result<u32, string>;
```

```zig
pub const safe_divide_result = union(enum) { ok: u32, err: []const u8 };

pub fn safe_divide(a: u32, b: u32) safe_divide_result {
    // ...
}
```

This avoids deeply nested anonymous types when functions return
composites of composites, and makes the implementation side easier
to read.

### Doc comments

Doc comments from the WIT (`/// ...`) are emitted verbatim as Zig
doc comments on the corresponding type or function. Block comments
(`/* */`) and ordinary line comments (`//`) are dropped — the parser
treats them as trivia.

## Calling an import from your code

Imports are reached through the generated `bindings.imports`
namespace:

```zig
const bindings = @import("bindings");

pub const wit_exports = struct {
    pub fn greet(name: []const u8) u32 {
        bindings.imports.log("about to greet");
        return @intCast(name.len);
    }
};
```

The wrapper functions in `imports` have Zig-typed signatures. You
pass Zig types in, the wrapper handles the canonical-ABI lowering,
the host responds, and the result is lifted back to Zig types.

`async func` imports get the same blocking shape: the wrapper lowers
the call through `[async-lower]`, and if the host does not complete
it immediately, parks the subtask in a waitable-set and waits until
it returns. From your code an async import is just a function call.

The lifetime of any `[]const u8` or `[]const T` returned from an
import is the rest of the current call into your component — the
host writes it into the guest's `cabi_realloc` arena. If you need it
to survive past the next host call, copy it.

## Inside the indirect return area

For exports that return composites, the thunk allocates a small
stack buffer (`var _retarea: [N]u8 align(A) = undefined;`), writes
the canonical-ABI representation of your return value into it, and
returns `&_retarea` as a single `i32`. The host reads the bytes out
of the guest's memory.

For exports that return slices (strings or lists), the same buffer
holds a pointer-length pair where the pointer references memory the
host can read via `memory.read`. That memory is whatever your
`wit_exports.<name>(...)` returned — usually something you allocated
out of `std.heap.wasm_allocator` (which sits on top of `cabi_realloc`).

`cabi_post_<name>` is called after the host has read everything. It
does nothing in the current arena-based implementation, but the
hooks are emitted so that a future move to a tracking allocator can
free per-call without breaking the ABI.

## Async exports: eager vs. state-machine

Async exports come in two flavors. The codegen picks between them
per-export at comptime by looking at whether `exports.<name>` is a
function or a struct type.

### Eager fn form

The default. You write the export as a plain function returning the
result type; the generated `[async-lift]` invokes it, calls
`[task-return]` with the lowered result, and ends with
`abi.async_cleanup.lift_outcome()`.

```zig
pub const wit_exports = struct {
    pub const kit = struct {
        pub fn succ(value: u32) u32 {
            return value +% 1;
        }
    };
};
```

If your export produces a `stream<T>` or `future<T>` and needs to
keep the writable end alive until the host has drained it, register
a cleanup closure with `abi.async_cleanup.schedule(set, fn)` from
inside the function. The generated `[callback]` runs the closure
when the waitable-set fires and re-evaluates `lift_outcome()` so the
closure itself can chain another step.

### Typed state-machine form

For exports that need multiple steps, an explicit per-task state
struct, or to call `task.return` from a point other than the
function's natural return, write the export as a struct:

```zig
pub const wit_exports = struct {
    pub const kit = struct {
        pub const greet = struct {
            pub const State = struct {
                writable: abi.Stream,
                wait_set: abi.WaitableSet,
            };

            pub fn start(state: *State, taskReturn: anytype, name: []const u8) abi.Step {
                const ends = greet_stream.new();
                _ = greet_stream.writeAsync(ends.writable, "...");
                taskReturn(ends.readable);
                state.* = .{ .writable = ends.writable, .wait_set = abi.WaitableSet.init() };
                state.wait_set.join(@intFromEnum(ends.writable));
                return .{ .wait = state.wait_set.handle };
            }

            pub fn step(state: *State, event: abi.Event, p1: u32, p2: u32) abi.Step {
                _ = .{ event, p1, p2 };
                abi.WaitableSet.leave(@intFromEnum(state.writable));
                greet_stream.dropWritable(state.writable);
                state.wait_set.deinit();
                return .exit;
            }
        };
    };
};
```

The codegen allocates a typed slot from `abi.StateSlots(State)`,
stashes its 1-based index in `[context-set-0]`, dispatches `start`
from `[async-lift]` and `step` from `[callback]`, and routes the
returned `abi.Step` (`.exit`, `.yield`, `.wait = set`) to the
matching `CallbackCode`. `taskReturn` is a generated typed thunk
over `[task-return]<fn>`; you can use `anytype` (the compiler will
infer the function pointer type) or spell it out as
`*const fn (R) void`.

## Stream and future intrinsics

The canonical ABI ties stream/future operations to the function they
appear in: each `canon stream.read` etc. is declared per-function,
per-occurrence, with link names like `[stream-new-0]<fn>`. The
generator emits all of them for every function whose signature
mentions a `stream<T>` or `future<T>` — async or sync, top-level or
resource method. WASI 0.3 leans on the sync case heavily
(`read-via-stream: func() -> tuple<stream<u8>, future<...>>`), so
this is not an async-only feature.

They surface as a namespace named after the function, placed next to
its wrapper:

- imports: `bindings.<iface>.intrinsics_<fn>`
- imported resource methods:
  `bindings.<iface>.resources.<res>.intrinsics_<method>`
- async exports: a file-scope `bindings.intrinsics_<full_export_path>`
  (e.g. `intrinsics_demo_asyncdemo_kit_0_3_0_greet`)

Inside, each stream/future occurrence in the signature gets a
`streamN` / `futureN` sub-namespace (`stream0`, `future1`, ...,
numbered across params then results) containing:

- `T`, `elem_size`, `elem_align` — the payload type and its
  *canonical* layout
- `new() Ends` — mints a fresh readable/writable pair
- `read` / `write` / `readAsync` / `writeAsync` — typed wrappers
  taking `*T` / `[]const T`, emitted **only for scalar payloads**
  (bools, ints, floats, char, enums, flags, handles), where the Zig
  and canonical layouts are bit-identical
- `readRaw` / `writeRaw` / `readRawAsync` / `writeRawAsync` — raw
  address-based variants, always emitted; pair them with `lift(base)`
  / `lower(value, base)` to move compound payloads (strings, records,
  payload-carrying variants) through a canonical-layout staging buffer
- `cancelRead` / `cancelWrite` / `dropReadable` / `dropWritable`

For the common pump loops, `abi` has bindings-agnostic helpers that
take one of these namespaces as a comptime parameter:
`abi.streamWriteAll(ns, writable, data)`,
`abi.streamDrainBytes(ns, gpa, readable, max)`, and
`abi.futureAwait(ns, handle)`. The `wasi3` convenience module and the
`async-basic` example are built entirely on this surface.

## What `gen` does not emit

The WIT 0.2.x / 0.3.x canonical-ABI surface is fully covered in both
directions — tagged composite parameters lower, async exports and
imports emit `[async-lift]` / `[async-lower]` thunks, and the
per-function `[stream-*-i]` / `[future-*-i]` ops above are wired up
for sync and async functions alike. A small set of corners is
intentionally left out:

- **Multi-result returns on imports and resource methods.** Modern
  `wasm-tools` rejects `func() -> (a: T1, b: T2, …)` at embed time,
  so the `@compileError` we emit for them is unreachable in any
  working build. Use a `record` return type or a single result.
- **Flags with more than 32 labels.** The canonical-ABI spec caps
  flags at 32 labels (`assert(0 < n <= 32)` in `CanonicalABI.md`).
  We follow the spec and return `error.Unsupported` past that
  boundary. See [limitations.md](limitations.md).
