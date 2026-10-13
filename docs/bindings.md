# Generated bindings

Everything `zig_wasi_components gen` generates lives in a single Zig file.
By convention, that file is `bindings.zig`.

Here's what's in that file, what your code needs to provide, and how every
WIT type maps to Zig.

## File layout

You rarely need to read the generated file, but it helps to know where
things are.
From top to bottom:

1. **A header** naming the source package and world.
   Any edits you make by hand are lost the next time you regenerate.
2. **World-level types**, plus named aliases for composite types in
   your export signatures (see [synthetic types](#synthetic-result-types)
   below).
3. **One struct per imported interface**, named after its full path:
   `wasi:cli/stdout` becomes `bindings.wasi_cli_stdout`.
   It contains the interface's `types`, its `resources` helpers, and a Zig
   wrapper for each function.
   An exported interface that defines types or resources gets a struct
   too, containing just those.
4. **`bindings.imports`**, with a wrapper for each function the world
   imports directly.
5. **The glue you never call**: `cabi_realloc`, one `export fn` per
   exported function, and the `cabi_post_*` hooks the host calls after
   reading each result.
   Each `export fn` lifts the canonical-ABI arguments into Zig types,
   calls your function in `wit_exports`, and lowers the result.

Resource types are opaque handles, `enum(u32) { _ }`, in the interface's
`types` (for example `bindings.demo_res_counters.types.counter`).
The matching `resources.counter` namespace has the helpers:

- For a resource you import: the constructor, methods, and `drop`.
- For one you export: `new`, `rep`, and `drop`.

See [resources.md](resources.md).

## The `wit_exports` contract

Your code must export a single declaration:

```zig
pub const wit_exports = struct {
    // one Zig function per exported WIT function
};
```

This declaration must be visible from the root source file, the file you
pass as the wasm exe entry point.
The generated bindings find it through `@import("root").wit_exports`.

Here's how WIT export names map to Zig function names:

- WIT hyphens become Zig underscores: `format-greeting` becomes
  `format_greeting`.
- Functions in an exported interface go inside a struct named after
  the interface: `export wasi:cli/run@0.2.6;` expects
  `wit_exports.run.run`.
- Method-receiver functions on resources go inside a nested struct.
  `interface counters { resource counter { increment: func(); } }`
  expects `wit_exports.counters.counter.increment(self: *State)`.
- The `wit_exports.<iface>.<resource>.constructor(...)` function
  returns a `*State`.
  The generated code turns it into a handle for the host, and turns
  the handle back into your `*State` for every method call.
  See [resources.md](resources.md).

The generated bindings don't see anything else in your root file,
including helpers, allocators, and comptime blocks.

## The required comptime pull-in

Every Zig component built against generated bindings needs this line:

```zig
comptime { _ = bindings; }
```

Nothing in your code references `bindings.zig` otherwise, because
nothing in `wit_exports` *calls* the thunks.
Those wrappers only exist for the wasm import/export side.

Without the pull-in, Zig never compiles the file, and the resulting
core module exports nothing but its memory and stack pointer.

## WIT to Zig type mapping

This is the complete mapping, and the generator handles it in both
directions.
Any type in the table can appear in:

- a parameter
- a return type
- a record field
- a variant payload
- a list element

| WIT                                | Zig                                              | Notes                                                                                                                                                                     |
| ---------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bool`                             | `bool`                                           |                                                                                                                                                                           |
| `s8` `s16` `s32` `s64`             | `i8` `i16` `i32` `i64`                           |                                                                                                                                                                           |
| `u8` `u16` `u32` `u64`             | `u8` `u16` `u32` `u64`                           |                                                                                                                                                                           |
| `f32` `f64`                        | `f32` `f64`                                      |                                                                                                                                                                           |
| `char`                             | `u21`                                            | Unicode scalar value. Incoming values are checked (surrogates and values past `0x10FFFF` trap); outgoing ones are not.                                                    |
| `string`                           | `[]const u8`                                     | UTF-8. Memory in the canonical-ABI arena.                                                                                                                                 |
| `list<T>`                          | `[]const T`                                      | Slice. Memory in the canonical-ABI arena.                                                                                                                                 |
| `list<T, N>`                       | `[N]T`                                           | Fixed-length, by-value array.                                                                                                                                             |
| `tuple<A, B, ...>`                 | `struct { A, B, ... }`                           | Anonymous tuple struct.                                                                                                                                                   |
| `map<K, V>`                        | `[]const struct { K, V }`                        | Pair slice. This is the canonical `list<tuple<K, V>>` despecialization. All pairs are passed through. The consumer applies the spec's duplicate-key rule (last one wins). |
| `option<T>`                        | `?T`                                             | Zig nullable.                                                                                                                                                             |
| `result<T, E>`                     | `union(enum) { ok: T, err: E }`                  | Named per-function in export signatures (e.g. `safe_divide_result`). Import wrappers use the anonymous union.                                                             |
| `result<_, E>`                     | `union(enum) { ok: void, err: E }`               | Same shape with empty ok arm.                                                                                                                                             |
| `result<T, _>`                     | `union(enum) { ok: T, err: void }`               | Same shape with empty err arm.                                                                                                                                            |
| `record { x: u32, y: u32 }`        | `struct { x: u32, y: u32 }`                      | Field order preserved; hyphens in names become underscores.                                                                                                               |
| `variant { a, b(u32), c(string) }` | `union(enum) { a: void, b: u32, c: []const u8 }` |                                                                                                                                                                           |
| `enum { red, green, blue }`        | `enum(u8) { red, green, blue }`                  | Backing width is the smallest that fits.                                                                                                                                  |
| `flags { read, write, exec }`      | `packed struct(u8) { read: bool, ... }`          | Backing width chosen to fit. Max 32 labels.                                                                                                                               |
| `resource foo` (imported)          | `enum(u32) { _ }`                                | Opaque handle. Methods live in an interface-named namespace.                                                                                                              |
| `resource foo` (exported)          | `enum(u32) { _ }`                                | Same handle type. Your `*State` appears in method receivers, `borrow<foo>` parameters and the constructor's return. See [resources.md](resources.md).                     |
| `own<foo>`                         | `foo` (the handle enum)                          | Same Zig type as the bare resource name. For a resource you export, convert with `<iface>.resources.foo.new/rep/drop` (`resources_<name>` for a named export).            |
| `borrow<foo>`                      | `foo`, or `*State` if you export `foo`           | A borrow of your own resource arrives as its state. Borrows of imported resources are dropped by the thunk once your function returns.                                    |
| `stream<T>` `future<T>`            | `abi.Stream`, `abi.Future`                       | 4-byte handle. Imports and async exports that mention one get per-payload operations. See the intrinsics section below.                                                   |
| `error-context`                    | `abi.ErrorContext`                               | Opaque 4-byte handle.                                                                                                                                                     |

### Synthetic result types

When an exported function returns an `option`, `result` or `tuple`
(or a list or map of results), the generator gives the return type a
name: `<function_name>_result`.
Parameters of those kinds get `<function_name>_<param_name>`.

Inside an exported interface, the interface name goes first, as in
`run_run_result`.
Records and variants already have names, so they don't need one.

```wit
export safe-divide: func(a: u32, b: u32) -> result<u32, string>;
```

```zig
pub const safe_divide_result = union(enum) { ok: u32, err: []const u8 };

pub fn safe_divide(a: u32, b: u32) safe_divide_result {
    // ...
}
```

Zig gives every `union(enum)` declaration its own type, so use the alias
to match the return type the bindings expect.
It also makes your code easier to read.

### Doc comments

Doc comments from the WIT (`/// ...`) carry over to the generated
types and import wrappers, so they show up in your editor.
Doc comments on functions the world imports directly
(`import log: func(...)`) are still lost.
Other comments don't carry over.

## Calling an import from your code

Call imports through the generated `bindings.imports` namespace:

```zig
const bindings = @import("bindings");

pub const wit_exports = struct {
    pub fn greet(name: []const u8) u32 {
        bindings.imports.log("about to greet");
        return @intCast(name.len);
    }
};
```

The wrapper functions in `imports` take Zig types, so that's what you
pass in.
The wrapper handles canonical-ABI lowering, then lifts the host's result
back to Zig types.

`async func` imports work the same way and block until they're done.
The wrapper lowers the call through `[async-lower]`.
If the host doesn't finish immediately, the wrapper parks the subtask in
a waitable-set and waits for the result.

From your code, an async import is just a function call.

A few member names belong to the generated namespaces:

- `types`, `resources`, and `intrinsics_*` inside an interface
- `drop` inside a resource
- `new` inside a resource that has a constructor

An import whose WIT name would take one of them gets an `_` appended,
so `types: func()` is called as `bindings.<iface>.types_()`.

A `[]const u8` or `[]const T` returned from an import lives in the
`cabi_realloc` arena, like the arguments your exports receive.
The arena is reset once the last export call in flight completes, so
these slices stay valid until your export returns.
Copy anything you want to keep across calls.

## Returning strings and lists

When an export returns a string, a list, or anything else that doesn't
fit in a single value, the thunk writes the result into a small
static buffer and hands its address to the host.
For a string or list, that buffer holds a pointer to the memory your
function returned, and the host reads it after your function is done.

So that memory must outlive the call.
Return static data or allocated memory, never a slice of a local array.

Once the host has copied the result, it calls `cabi_post_<name>`.
That hook frees the call's arguments and import results, but it knows
nothing about the memory your function returned.
If you allocated it with `std.heap.wasm_allocator`, nothing frees it
for you.

Reuse a buffer, or free the previous result at the start of the next
call.

## Async exports: eager vs. state-machine

Async exports come in two flavors.
The bindings pick one per export, depending on whether your
`wit_exports` declaration is a function or a struct.

### Eager fn form

This is the default.
Write the export as a plain function that returns the result type.
The bindings call it and send the result to the host as soon as it
returns.

```zig
pub const wit_exports = struct {
    pub const kit = struct {
        pub fn succ(value: u32) u32 {
            return value +% 1;
        }
    };
};
```

If your export produces a `stream<T>` or `future<T>`, it may need to
keep the writable end alive until the host drains it.
Register a cleanup closure with `abi.async_cleanup.schedule(set, fn, ctx)`
from inside the function.

The generated `[callback]` runs the closure when the waitable-set fires.
It then re-evaluates `lift_outcome()`, so the closure can chain another step.

`ctx` is an opaque pointer passed back to the closure.
Concurrent tasks can interleave inside one instance.
For example, `wasmtime serve` can handle simultaneous requests.

Everything the cleanup touches must live behind `ctx`, usually in a
small heap allocation that the closure frees.
Don't use file-scope globals.

See `examples/wasi-demo-p3/http-check.zig` for the pattern.
That example also delivers a response-trailers future with `abi.FutureDelivery`.

### Typed state-machine form

Use this form when an export needs multiple steps or an explicit
per-task state struct, or when `task.return` must run somewhere other
than the function's natural return.
Write the export as a struct.
This one comes from `examples/async-basic/component.zig`:

```zig
const abi = @import("zig_wasi_components").abi;
const greet_stream = bindings.intrinsics_demo_asyncdemo_kit_0_3_0_greet.stream0;

pub const wit_exports = struct {
    pub const kit = struct {
        pub const greet = struct {
            pub const State = struct {
                writable: abi.Stream,
                wait_set: abi.WaitableSet,
                buf: [128]u8,
            };

            pub fn start(state: *State, taskReturn: anytype, name: []const u8) abi.Step {
                const ends = greet_stream.new();
                state.writable = ends.writable;
                state.wait_set = abi.WaitableSet.init();

                const greeting = std.fmt.bufPrint(&state.buf, "Hello, {s}!", .{name}) catch "Hello!";
                _ = greet_stream.writeAsync(ends.writable, greeting);
                taskReturn(ends.readable);

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

The bindings keep one `State` per call in flight.
`start` runs when the call begins, and `step` runs each time the
waitable set you're waiting on fires.
Return:

- `.{ .wait = set }` to keep waiting
- `.yield` to let other tasks run
- `.exit` when you're done

Call `taskReturn` with the result whenever it's ready.
For a stream, that's usually in `start`, so the host can attach a
reader before you wait for the write to finish.
Its parameter can be `anytype`, or spelled out as
`*const fn (R) void`.

## Stream and future intrinsics

The canonical ABI ties stream and future operations to the function
where they appear.
Each `canon stream.read` and related intrinsic is declared per function
and per occurrence.
Link names look like `[stream-new-0]<fn>`.

The generator creates every intrinsic for each imported function or
imported resource method whose signature mentions a `stream<T>` or
`future<T>`, sync or async, and for each async export.
WASI 0.3 uses the sync import case heavily, for example
`read-via-stream: func() -> tuple<stream<u8>, future<...>>`.
Synchronous exports and the methods of resources you export don't get
intrinsics yet.

See [limitations.md](limitations.md).

You'll find the intrinsics in a namespace next to the function's wrapper:

- interface imports: `bindings.<iface>.intrinsics_<fn>`, where
  `<iface>` is the mangled name such as `wasi_cli_stdout`
- functions the world imports directly:
  `bindings.imports.intrinsics_<fn>`
- imported resource methods:
  `bindings.<iface>.resources.<res>.intrinsics_<method>`
- async exports: a file-scope `bindings.intrinsics_<full_export_path>`
  (e.g. `intrinsics_demo_asyncdemo_kit_0_3_0_greet`), or
  `bindings.intrinsics_<fn>` for a function the world exports directly

Inside, each stream or future occurrence in the signature gets a
`streamN` or `futureN` sub-namespace, for example `stream0` and `future1`.
They're numbered across parameters and results.
Each namespace contains:

- `T`: the payload type (`void` for a bare `stream` or `future`)
- `elem_size`, `elem_align`: the payload's *canonical* layout, emitted
  only when there's a payload
- `new() Ends`: creates a fresh readable/writable pair
- `read` / `write` / `readAsync` / `writeAsync`: typed wrappers.
  Reads take `[]T` or `*T`, writes take `[]const T` or `*const T`.
  They're generated **only for scalar payloads**, whose Zig and canonical layouts are bit-identical:

  - bools
  - ints
  - floats
  - char
  - enums
  - flags
  - handles

- `readRaw` / `writeRaw` / `readRawAsync` / `writeRawAsync`: raw
  address-based variants that are always generated.
  Pair them with `lift(base)` or `lower(value, base)` (present when there's a
  payload) to move compound payloads through a canonical-layout staging buffer.
  Examples include:

  - strings
  - records
  - payload-carrying variants

- `cancelRead` / `cancelWrite` / `dropReadable` / `dropWritable`

For common pump loops, `abi` has helpers that work with any bindings.
They take one of these namespaces as a comptime parameter:

- `abi.streamWriteAll(ns, writable, data)`
- `abi.streamDrainBytes(ns, gpa, readable, max)`
- `abi.futureAwait(ns, handle)`

The `wasi3` convenience module is built on these helpers and the raw
intrinsics.

## What `gen` does not emit

A few parts of the canonical ABI aren't covered yet.
The main one is stream and future operations for synchronous exports.
The full list, with workarounds, is in [limitations.md](limitations.md).
