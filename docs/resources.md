# Resources

WIT resources are opaque, host-managed handles to per-instance state.
The constructor returns a fresh handle; methods take the handle as
their first argument; the host drops the handle when it goes out of
scope. The canonical ABI represents handles as `i32` indices into a
table the host maintains.

This page covers how to implement a resource in Zig, what the
generator produces for it, and the rules you have to follow to stay
out of trouble.

## A working example

`examples/resource/` defines a `counter` resource and is the
shortest end-to-end implementation in the repo. The WIT:

```wit
package demo:res@0.1.0;

interface counters {
  resource counter {
    constructor(initial: u32);
    increment: func();
    add: func(n: u32);
    get: func() -> u32;
  }
}

world counts {
  export counters;
}
```

The Zig implementation in `examples/resource/component.zig`:

```zig
const std = @import("std");
const bindings = @import("bindings");

comptime {
    _ = bindings;
}

pub const wit_exports = struct {
    pub const counters = struct {
        pub const counter = struct {
            pub const State = struct { value: u32 };

            pub fn constructor(initial: u32) *State {
                const s = std.heap.wasm_allocator.create(State) catch unreachable;
                s.* = .{ .value = initial };
                return s;
            }

            pub fn increment(self: *State) void {
                self.value +%= 1;
            }

            pub fn add(self: *State, n: u32) void {
                self.value +%= n;
            }

            pub fn get(self: *State) u32 {
                return self.value;
            }

            pub fn destructor(self: *State) void {
                std.heap.wasm_allocator.destroy(self);
            }
        };
    };
};
```

Build and run it:

```sh
zig build resource
cargo build --release --manifest-path examples/resource/host/Cargo.toml
./examples/resource/host/target/release/counts-host \
  zig-out/wasm/counts.component.wasm
```

The host instantiates several counters, mutates them through their
methods, verifies their state, and lets them drop on the way out.

## The conventions

The shape above is not optional — the generated bindings expect each
of these declarations by name.

- **`pub const State = struct { ... }`.** The concrete type your
  resource holds. The generator uses `*State` as the Zig
  representation of the resource's handle on the *guest side*. The
  field layout is entirely up to you.
- **`pub fn constructor(...) *State`.** Allocates and returns a
  fresh `*State`. The generated thunk turns that pointer into a
  resource handle by calling the host's `[resource-new]<resource>`
  import and returns the resulting handle (an `i32`) across the
  boundary.
- **`pub fn <method>(self: *State, ...)`.** A method takes its
  receiver as the first argument. The canonical ABI hands the
  method thunk the resource's rep as its first core parameter; the
  thunk converts it straight back into your `*State` and invokes
  your function. Static methods have no `self` argument.
- **`pub fn destructor(self: *State) void`.** Called by the
  generated thunk when the host drops a handle for this resource.
  This is your chance to free the state.

If you forget `destructor`, the resource still works but you leak
the per-instance state every time the host drops a handle.

## Why a `*State` pointer instead of a raw handle

Component-model resources must round-trip through the canonical
ABI's resource table. The host owns the handle; you own a pointer
to the state. If you return your raw `*State` pointer across the
boundary as the constructor's result, Wasmtime treats it as a
handle index — usually some absurdly large integer — and the next
call traps with `unknown handle index 1114112` or similar.

The generated bindings hide this from you. The `constructor` thunk
calls `[resource-new]<counter>(<your *State as i32>)` to mint a
fresh handle and returns the handle to the host; on the way back in
for methods, the canonical ABI passes the rep — your original
`*State` bits — as the first core parameter and the thunk converts
it back into the pointer. You write code as if you had a normal Zig
pointer; the binding does the bookkeeping.

This pattern is the answer to the first entry in `mistakes.md`.

## Lifecycle in one paragraph

The host calls the constructor; you allocate a `State` and return
its pointer. The thunk wraps it in a handle and gives the handle to
the host. The host can now pass the handle to any method on the
resource. Each method call goes through a thunk that recovers the
`*State` and invokes your function. Eventually the host drops the
handle — when the surrounding scope ends, the resource is freed by
the calling code, or the component instance shuts down — and the
host calls the `[resource-drop]<resource>` export the bindings
auto-emit. That export calls your `destructor(self: *State)`, which
is responsible for freeing the memory.

## Resources you import vs. resources you export

This page is about resources your component *exports* — types you
implement. Resources you *import* (typed declared in a `use` clause
or as a parameter type) appear as opaque `enum(u32) { _ }` handles
in your code. You receive them as arguments, you pass them to other
imports, you store them in records — but you cannot dereference
them and you should not invent your own handle values. The host
created them and the host will drop them.

If you import a resource that has methods (e.g. a host-provided
file handle with `read` / `write` / `close`), the methods appear in
a `bindings.<interface>.resources.<resource>` namespace, each
taking the handle as its first argument (plus a `drop` helper for
when you own the handle). The wasi:http guest in
`examples/http-get/` is the largest example: it consumes more than
a dozen imported resources with their full method surface.

## What is not yet supported

The hand-written wasi-http bindings in earlier revisions of the
http-get example are now generated automatically, so resource-
bearing host imports work in the common case, including tagged
composite (`variant`, `option`, `result`) parameters and results.
The one corner left is **multi-result returns** of the
`func() -> (a: T1, b: T2)` form on resource methods: modern
`wasm-tools` rejects those at embed time anyway, and the
`@compileError` we emit for them is unreachable in shipping builds.
Use a `record` return type or a single named result instead.

Standalone async functions on world imports and exports are fully
emitted — see `examples/async-basic/` for the end-to-end pattern.
Async *imported* resource methods are exercised for real: WASI 0.3
makes most `wasi:filesystem` descriptor and `wasi:sockets` socket
methods `async func`s, and the `wasi3` convenience module drives
them (blocking on the subtask) in the `wasi-demo-p3` example.
Resource methods whose signatures mention `stream<T>` / `future<T>`
also get the per-function intrinsics namespaces described in
[bindings.md](bindings.md), at
`bindings.<interface>.resources.<resource>.intrinsics_<method>`.
Async methods on resources you *export* have no consumer yet; if
you find a real schema that exercises them, please open an issue
with the WIT so we can add a demo.
