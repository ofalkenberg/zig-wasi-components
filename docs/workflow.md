# Your first component

This page walks through building a component from scratch: writing a
small WIT, generating bindings, implementing the exports in Zig,
wrapping the core module into a component, and running it. By the end
you will have a working `.component.wasm` you can invoke from
Wasmtime or load into a Rust host.

The example we will build is intentionally tiny — a single function
that takes two integers and returns their sum, plus one that echoes a
string back with a prefix. Once the loop is in place, scaling it up
is just a matter of adding more WIT items and more `wit_exports`
functions.

## 1. Write the WIT

Create a fresh directory anywhere you like. We will use
`tmp/hello/` for this walkthrough.

```sh
mkdir -p tmp/hello
```

Write `tmp/hello/hello.wit`:

```wit
package demo:hello@0.1.0;

world hello {
  export add: func(a: u32, b: u32) -> u32;
  export greet: func(name: string) -> string;
}
```

Two exports, no imports, no resources. The package id is required —
omitting it makes `wasm-tools component embed` fail with an
unhelpful error.

Sanity-check the file by dumping it:

```sh
./zig-out/bin/zig_wasi_components dump tmp/hello/hello.wit
```

You should see one world with two `export` lines.

## 2. Generate bindings

```sh
./zig-out/bin/zig_wasi_components gen tmp/hello/hello.wit hello \
  > tmp/hello/bindings.zig
```

The output is about 60 lines for this world. Open it if you are
curious — the relevant parts are:

- `cabi_realloc`, exported automatically.
- `export fn add(p0: i32, p1: i32) i32` — a thunk that bitcasts its
  two `i32` inputs to `u32`, calls `exports.add(...)`, and returns
  the result.
- `export fn greet(p0: i32, p1: i32) i32` — a thunk that
  reconstructs a `[]const u8` from the pointer and length pair the
  canonical ABI passes in, calls `exports.greet(...)`, and writes
  the returned slice's pointer and length into a small return area
  whose address is the single `i32` return value.
- `export fn cabi_post_greet(_r: i32)` — invoked by the host after
  it has lifted the string out, so the guest can reclaim the
  memory if it wants to.

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

Two things worth understanding here:

The `comptime { _ = bindings; }` block is what pulls the generated
thunks into the final binary. Without it, the export functions
`add` and `greet` are dead code from the linker's point of view and
get stripped. Every Zig component that uses generated bindings
needs this line.

The `wit_exports` namespace is the contract the generated bindings
expect. The generator emits `const exports = @import("root").wit_exports;`
near the top of `bindings.zig`, and each `export fn` calls
`exports.<func_name>(...)`. WIT names with hyphens are converted to
underscores (`format-greeting` becomes `format_greeting`).

The memory returned from `greet` lives in the canonical-ABI arena
backed by `cabi_realloc`. The host copies the bytes out before
calling `cabi_post_greet`, so you do not need to retain the buffer
yourself.

## 4. Compile to a core wasm module

```sh
zig build-exe -fno-entry -OReleaseSmall -target wasm32-freestanding -rdynamic \
  --dep zig_wasi_components --dep bindings -Mroot=tmp/hello/component.zig \
  -Mzig_wasi_components=src/root.zig \
  --dep zig_wasi_components -Mbindings=tmp/hello/bindings.zig \
  --name hello \
  -femit-bin=tmp/hello/hello.core.wasm
```

The command is long because we are doing manually what `build.zig`
normally does for you. In a real project you should use the
build-system integration — see [build-integration.md](build-integration.md)
for a clean template. Once that template is in place, this step
becomes `zig build hello`.

Three flags worth understanding. `-fno-entry` because component
guest modules do not have a `main`. `-rdynamic` because the wasm
linker would otherwise strip every `export fn` as unused — there
are no internal callers, only the canonical-ABI thunks the host
will reach. The chain of `--dep`/`-M` flags declares three modules:
`root` (your `component.zig`) depending on both `bindings` and
`zig_wasi_components`; `bindings` (the generated file) depending on
`zig_wasi_components`; and `zig_wasi_components` itself (this
project's runtime helpers).

## 5. Wrap as a component

```sh
wasm-tools component embed tmp/hello/hello.wit tmp/hello/hello.core.wasm \
  -o tmp/hello/hello.embedded.wasm
wasm-tools component new tmp/hello/hello.embedded.wasm \
  -o tmp/hello/hello.component.wasm
```

`component embed` adds the `component-type` custom section that
tells `component new` which interface every wasm import and export
belongs to. `component new` then rewrites the module into the
component-model binary format, with the canonical ABI's adapter
functions and type definitions all wired up.

If either step rejects the module, the error message names the
exact import or export that failed. The most common cause is a
mismatch between the WIT and the implementation — for example, you
exported `format_greeting` in Zig but the WIT calls it
`format-greeting`. The CLI converts WIT hyphens to underscores in
Zig names; if you skipped that, the generated bindings will not
compile.

## 6. Run it

```sh
wasmtime run --invoke 'add(2, 3)' tmp/hello/hello.component.wasm
# => 5

wasmtime run --invoke 'greet("world")' tmp/hello/hello.component.wasm
# => "Hello, world!"
```

If both invocations work, you have a fully functional component.

## What to do next

- **Add an import.** Change the WIT to `import log: func(msg: string);`
  and rerun `gen`. The bindings now have a `pub const imports = struct { ... }`
  block with a `log` wrapper you can call from your exports.
- **Add a more complex type.** Records, variants, and lists all work
  the same way — declare them in the WIT, regenerate, and use the
  matching Zig type. The full mapping is in [bindings.md](bindings.md).
- **Add a resource.** See [resources.md](resources.md) for the
  pattern; the `examples/resource/` directory is the runnable
  reference.
- **Move into a `build.zig`.** Doing all of the above by hand gets
  old fast. [build-integration.md](build-integration.md) has a
  copy-pasteable template that handles all of step 4 and step 5
  automatically.
