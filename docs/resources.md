# Resources

WIT resources let you work with per-instance state through opaque handles that the host manages.
The constructor returns a fresh handle, and methods take it as their first argument.
Whoever owns the handle drops it when they're done.

The canonical ABI represents handles as `i32` indices in a table the host maintains.
This page shows you how to implement a resource in Zig, what the generator produces, and which rules you need to follow.

## A working example

`examples/resource/` defines a `counter` resource.
It's the shortest end-to-end implementation in the repo.
Here's the WIT:

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

The host creates two counters and changes them through their methods.
It checks that they hold 17 and 150, then drops both handles with `resource_drop`, which runs the Zig `destructor`.

## The conventions

The generated bindings look up these declarations by name.
`State` and one function per WIT member are required.
`destructor` is optional.

- **`pub const State = struct { ... }`.** The concrete type your resource holds.
  The generator uses `*State` as the Zig representation of the resource handle on the *guest side*.
  The field layout is up to you.
- **`pub fn constructor(...) *State`.** Allocates and returns a fresh `*State`.
  The generated thunk turns that pointer into a resource handle by calling the host's `[resource-new]<resource>` import.
  It returns the resulting `i32` handle across the boundary.
- **`pub fn <method>(self: *State, ...)`.** A method takes its receiver as the first argument.
  The canonical ABI passes the resource rep to the method thunk as its first core parameter, and the thunk converts it directly into your `*State` and calls your function.
  Static methods have no `self` argument.
- **`pub fn destructor(self: *State) void`.** The generated thunk calls this when an owning handle for the resource is dropped.
  This is where you free the state.

Leave out `destructor`, and the resource still works, but you leak the state behind every dropped handle.
You won't get a warning.

## Why a `*State` pointer instead of a raw handle

Component-model resources must round-trip through the canonical ABI's resource table.
The host owns the handle.
You own a pointer to the state.

If you return your raw `*State` pointer as the constructor result, Wasmtime treats it as a handle index.
That's usually an absurdly large integer.
The next call then traps with `unknown handle index 1114112` or something similar.

The generated bindings handle this for you.
The `constructor` thunk calls `[resource-new]<counter>(<your *State as i32>)` to create a fresh handle and returns it to the host.

For methods, the canonical ABI passes the rep, which contains your original `*State` bits, as the first core parameter.
The thunk converts those bits back into the pointer.
You write normal Zig pointer code, and the binding handles the bookkeeping.

## Lifecycle

The host calls the constructor, and you allocate a `State` and return its pointer.
The thunk wraps it in a handle and gives that handle to the host.

The host can then pass the handle to any resource method.
Each method call goes through a thunk that recovers the `*State` and calls your function.

Eventually, the owner drops the handle.
On the host side, that's an explicit call: Wasmtime's `ResourceAny` isn't dropped automatically, so a Rust host must call `resource_drop`.
Inside your component, you use the `drop` helper described below.

The runtime then calls the generated `[dtor]<resource>` export, which calls your `destructor(self: *State)` to free the memory.

## Handles to your own resource

Constructors and method receivers are converted for you, but you can also pass a resource as a plain parameter or result.
A `borrow<counter>` parameter arrives as `*State`, like `self` does.
An `own<counter>` is a real handle (`types.counter`), and the interface struct in the bindings has helpers to work with it.

Here `allocState` stands for your own allocation code:

```zig
const helpers = bindings.demo_res_counters.resources.counter;

pub fn create(value: u32) bindings.demo_res_counters.types.counter {
    return helpers.new(allocState(value));
}

pub fn consume(c: bindings.demo_res_counters.types.counter) u32 {
    const value = helpers.rep(c).value;
    helpers.drop(c);
    return value;
}
```

Handles aren't reference counted.
Every handle `new` returns is an independent owner of its state, and dropping any one of them runs `destructor`.

Create a second handle for a state that already has one, and you'll get a double free (or a use after free through the other handle).
If several handles must share one state, keep your own reference count in `State` and free only when it reaches zero.

When the world exports the interface under a name (`export main: counters;`), the helpers live in `resources_<name>` instead (`resources_main.counter`).
There's one namespace per export because each export has its own handle table.

You don't get these helpers when the world also imports the same interface:

- `import counters; export counters;`
- `import counters; export main: counters;`

In that case, only constructors and method receivers get the conversion.

## Resources you import vs. resources you export

This page covers resources that your component *exports*, which means you implement them.
Resources you *import*, which are typed in a `use` clause or parameter type, appear as opaque `enum(u32) { _ }` handles in your code.

You can:

- Receive them as arguments.
- Pass them to other imports.
- Store them in records.

You can't dereference them, and you shouldn't invent handle values.
The host created them and will drop them.

If you import a resource with methods, they appear in a `bindings.<interface>.resources.<resource>` namespace.
For example, a file handle provided by the host might have these methods:

- `read`
- `write`
- `close`

Each method takes the handle as its first argument.
That namespace also has a `drop` helper for handles you own.
The wasi:http guest in `examples/http-get/` is the largest example, with ten imported resources.

A `borrow<T>` of an imported resource that your export receives is only valid for the duration of the call.
The generated thunk drops it after your function returns, as the canonical ABI requires, so don't keep it around.

The one exception is the state-machine form of an async export.
The thunk can't know when you're done, so drop each borrowed parameter yourself before calling `taskReturn`.

## Async and streams

Async methods on *imported* resources work like any other async import: the wrapper blocks until the host completes the call.
WASI 0.3 relies on this heavily.
These methods are `async func`s:

- Most `wasi:filesystem` descriptor methods.
- TCP `connect`.
- UDP `send` / `receive`.

The `wasi3` convenience module calls them in the `wasi-demo-p3` example.

Methods of *imported* resources whose signatures mention `stream<T>` or `future<T>` also get the per-function intrinsics namespaces described in [bindings.md](bindings.md).
Their namespace is `bindings.<interface>.resources.<resource>.intrinsics_<method>`, named after the WIT method even when the method itself got an `_` suffix (a constructor's is `intrinsics_constructor`).
Members of resources you export don't get them yet.

Async methods on resources you *export* are currently lifted as plain synchronous functions.
See [limitations.md](limitations.md).
