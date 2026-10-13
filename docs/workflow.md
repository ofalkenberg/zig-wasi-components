# Your first component

Build a component from scratch with a small WIT file and a Zig implementation.
You'll generate bindings, implement the exports, then wrap the core module as a component and run it.

You'll end up with a working `.component.wasm` that you can call from Wasmtime or load into a Rust host.

The example stays small: one function adds two integers, and another echoes a string with a prefix.

Once that works, you can add more WIT items and `wit_exports` functions.

## 1. Write the WIT

```sh
mkdir -p tmp/hello
```

You can create the directory anywhere you like.
This walkthrough uses `tmp/hello/`.

Write `tmp/hello/hello.wit`:

```wit
package demo:hello@0.1.0;

world hello {
  export add: func(a: u32, b: u32) -> u32;
  export greet: func(name: string) -> string;
}
```

This world has two exports and no imports or resources.

You need the package ID.
Our parser accepts a file without one, but `wasm-tools component embed`
then fails with ``no `package` header was found in any WIT file for
this package``.

Check the file by dumping it:

```sh
./zig-out/bin/zig_wasi_components dump tmp/hello/hello.wit
```

The output should contain one world with two `export` lines.

## 2. Generate bindings

```sh
./zig-out/bin/zig_wasi_components gen tmp/hello/hello.wit hello \
  > tmp/hello/bindings.zig
```

You'll get about 50 lines for this world.
Open it if you're curious.
Here are the parts to look for:

- `cabi_realloc`, which is exported automatically.
- `export fn add(p0: i32, p1: i32) i32`, a wrapper (called a thunk) that bitcasts two `i32` inputs to `u32`.
  It calls `_exports.add(...)` and returns the result.
- `export fn greet(p0: i32, p1: i32) i32`, a thunk that rebuilds a `[]const u8` from the canonical pointer and length.
  It calls `_exports.greet(...)`.
  It writes the returned slice pointer and length into a small static return area.
  The return area address is the single `i32` result.
- `export fn cabi_post_add` and `export fn cabi_post_greet`, which the host calls once it has read each result.
  They release the arena that holds lifted arguments such as `name`.

## 3. Implement the exports

Write `tmp/hello/component.zig`:

```zig
const std = @import("std");
const bindings = @import("bindings");

comptime {
    _ = bindings; // pull in cabi_realloc, the export thunks, ...
}

pub const wit_exports = struct {
    pub fn add(a: u32, b: u32) u32 {
        return a +% b;
    }

    pub fn greet(name: []const u8) []const u8 {
        const prefix = "Hello, ";
        const buf = std.heap.wasm_allocator.alloc(u8, prefix.len + name.len + 1) catch return prefix;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..name.len], name);
        buf[buf.len - 1] = '!';
        return buf;
    }
};
```

There are two details to watch here.

Every Zig component using generated bindings needs the `comptime { _ = bindings; }` block to pull the generated thunks into the final binary.
Without it, nothing in your code references `bindings.zig`, so Zig would never even compile it.
Your module would export only its memory and stack pointer.

The generated bindings look for your implementation in the `wit_exports` namespace.
The generator writes `const _exports = @import("root").wit_exports;` in `bindings.zig`.
Each `export fn` calls `_exports.<func_name>(...)`.

WIT hyphens become underscores, so `format-greeting` becomes `format_greeting`.

The buffer returned by `greet` comes straight from `std.heap.wasm_allocator`.
The host copies the bytes before calling `cabi_post_greet`, but nothing frees the buffer afterwards.

That's fine for a demo.
For a long-running component, reuse a buffer or free the previous result at the start of the next call.

## 4. Compile to a core wasm module

```sh
zig build-exe -fno-entry -OReleaseSmall -target wasm32-freestanding -rdynamic \
  --dep zig_wasi_components --dep bindings -Mroot=tmp/hello/component.zig \
  -Mzig_wasi_components=src/root.zig \
  --dep zig_wasi_components -Mbindings=tmp/hello/bindings.zig \
  --name hello \
  -femit-bin=tmp/hello/hello.core.wasm
```

That command is long because you're doing the work of `build.zig` by hand.
In a real project, use the template in [build-integration.md](build-integration.md).
Then this step becomes `zig build component`.

Three things to keep in mind:

- Use `-fno-entry` because component guests have no `main`.
- Use `-rdynamic` because the wasm linker otherwise drops every `export fn` from the module's exports.
  The host calls canonical-ABI thunks from outside the module, and nothing inside calls them.
- Use `--dep` and `-M` to declare the three modules:

  - `root`, your `component.zig`, depends on `bindings` and `zig_wasi_components`.
  - `bindings`, the generated file, depends on `zig_wasi_components`.
  - `zig_wasi_components` provides this project's runtime helpers.

## 5. Wrap as a component

```sh
wasm-tools component embed tmp/hello/hello.wit tmp/hello/hello.core.wasm \
  -o tmp/hello/hello.embedded.wasm
wasm-tools component new tmp/hello/hello.embedded.wasm \
  -o tmp/hello/hello.component.wasm
```

`component embed` adds the `component-type` custom section.
That section describes the interface for each wasm import and export.

`component new` rewrites the module into component-model binary format.
It connects the canonical ABI adapter functions and type definitions.

If either step rejects the module, the error tells you which import or export failed.
A common cause is a stale `bindings.zig` that no longer matches the WIT.
Regenerate it after every WIT change.

Naming mistakes in your own code show up earlier.
The thunks always export the WIT name, such as `format-greeting`, and
call `_exports.format_greeting`.
If your `wit_exports` uses a different spelling, the Zig build fails
before `wasm-tools` ever runs.

## 6. Run it

```sh
wasmtime run --invoke 'add(2, 3)' tmp/hello/hello.component.wasm
# => 5

wasmtime run --invoke 'greet("world")' tmp/hello/hello.component.wasm
# => "Hello, world!"
```

If both calls work, your component is ready to use.

## What to do next

- **Add an import.** Change the WIT to `import log: func(msg: string);`.
  Rerun `gen`.
  The bindings now contain `pub const imports = struct { ... }` with a `log` wrapper.
  Call it from your exports.
- **Add a more complex type.** Records, variants, and lists follow the same pattern.
  Declare them in WIT, regenerate bindings, and use the matching Zig type.
  See [bindings.md](bindings.md) for the complete mapping.
- **Add a resource.** See [resources.md](resources.md) for the pattern.
  `examples/resource/` is the runnable reference.
- **Move into a `build.zig`.** Manual builds become tedious.
  You can copy the template from [build-integration.md](build-integration.md).
  It automates steps 2, 4 and 5.
