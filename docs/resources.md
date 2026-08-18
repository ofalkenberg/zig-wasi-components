# Resources

WIT resources are opaque, host-managed handles to per-instance state.
The constructor returns a fresh handle. Methods take the handle as their
first argument. The host drops the handle when it goes out of scope. The
canonical ABI represents handles as `i32` indices in a host-maintained
table.

This page covers how to implement a resource in Zig. It also explains
what the generator produces and the rules you must follow.

## A working example

`examples/resource/` defines a `counter` resource. It is the shortest
end-to-end implementation in the repo. The WIT is:

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

The Zig implementation is in `examples/resource/component.zig`:

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

The host instantiates several counters and mutates them through their
methods. It verifies their state. It then lets them drop on the way out.

## The conventions

The shape above is not optional. The generated bindings expect each of
these declarations by name.

- **`pub const State = struct { ... }`.** The concrete type your
  resource holds. The generator uses `*State` as the Zig
  representation of the resource handle on the *guest side*. The
  field layout is entirely up to you.
- **`pub fn constructor(...) *State`.** Allocates and returns a
  fresh `*State`. The generated thunk turns that pointer into a
  resource handle. It calls the host's `[resource-new]<resource>`
  import. It returns the resulting `i32` handle across the boundary.
- **`pub fn <method>(self: *State, ...)`.** A method takes its
  receiver as the first argument. The canonical ABI hands the method
  thunk the resource rep as its first core parameter. The thunk
  converts it directly into your `*State` and invokes your function.
  Static methods have no `self` argument.
- **`pub fn destructor(self: *State) void`.** The generated thunk
  calls this when the host drops a handle for the resource. This is
  your chance to free the state.

If you forget `destructor`, the resource still works. However, you leak
per-instance state whenever the host drops a handle.

## Why a `*State` pointer instead of a raw handle

Component-model resources must round-trip through the canonical ABI's
resource table. The host owns the handle. You own a pointer to the
state.

If you return your raw `*State` pointer as the constructor result,
Wasmtime treats it as a handle index. It is usually an absurdly large
integer. The next call then traps with `unknown handle index 1114112` or
similar.

The generated bindings hide this distinction. The `constructor` thunk
calls `[resource-new]<counter>(<your *State as i32>)` to mint a fresh
handle. It returns that handle to the host. For methods, the canonical
ABI passes the rep, which contains your original `*State` bits, as the
first core parameter. The thunk converts those bits back into the
pointer. You write normal Zig pointer code. The binding handles the
bookkeeping.

This pattern is the answer to the first entry in `mistakes.md`.

## Lifecycle

The host calls the constructor. You allocate a `State` and return its
pointer. The thunk wraps it in a handle and gives that handle to the
host. The host can then pass the handle to any resource method. Each
method call goes through a thunk that recovers the `*State` and invokes
your function.

Eventually, the host drops the handle. This happens when the surrounding
scope ends, the calling code frees the resource, or the component
instance shuts down. The host then calls the auto-emitted
`[resource-drop]<resource>` export. That export calls your
`destructor(self: *State)`, which must free the memory.

## Resources you import vs. resources you export

This page covers resources that your component *exports*. These are
resources that you implement. Resources you *import*, which are typed in
a `use` clause or parameter type, appear as opaque `enum(u32) { _ }`
handles in your code. You receive them as arguments, pass them to other
imports, and store them in records. You cannot dereference them. You
also should not invent handle values. The host created them and will drop
them.

If you import a resource with methods, such as a host-provided file
handle with `read` / `write` / `close`, the methods appear in a
`bindings.<interface>.resources.<resource>` namespace. Each takes the
handle as its first argument. That namespace also has a `drop` helper
when you own the handle. The wasi:http guest in `examples/http-get/` is
the largest example. It consumes more than a dozen imported resources
with their complete method surface.

## What is not yet supported

The hand-written wasi-http bindings in earlier revisions of the
http-get example are now generated automatically. Resource-bearing host
imports work in the common case. This includes tagged composite
(`variant`, `option`, `result`) parameters and results.

The one remaining corner is **multi-result returns** of the
`func() -> (a: T1, b: T2)` form on resource methods. WIT removed this
syntax, and the parser rejects it. This matches modern `wasm-tools`. Use
a `record` return type instead.

Standalone async functions on world imports and exports are fully
emitted. See `examples/async-basic/` for the end-to-end pattern. Async
*imported* resource methods are exercised by real code. WASI 0.3 makes
most `wasi:filesystem` descriptor and `wasi:sockets` socket methods
`async func`s. The `wasi3` convenience module blocks on their subtasks
in the `wasi-demo-p3` example.

Resource methods whose signatures mention `stream<T>` or `future<T>`
also get the per-function intrinsics namespaces described in
[bindings.md](bindings.md). Their namespace is
`bindings.<interface>.resources.<resource>.intrinsics_<method>`.

Async methods on resources you *export* have no consumer yet. If you
find a schema that exercises them, please open an issue with the WIT.
That lets us add a demo.
