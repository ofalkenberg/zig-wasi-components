# Your first component

This page builds a component from scratch.
You will write a small WIT file and generate bindings.
You will implement its exports in Zig.
You will then wrap the core module as a component and run it.

By the end, you will have a working `.component.wasm`.
You can invoke it from Wasmtime or load it into a Rust host.

The example is intentionally small.
One function adds two integers.
Another echoes a string with a prefix.

Once this loop works, add more WIT items and `wit_exports` functions.

## 1. Write the WIT

Create a directory anywhere you like.
This walkthrough uses `tmp/hello/`.

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

This world has two exports.
It has no imports or resources.
The package ID is required.
Without it, `wasm-tools component embed` fails with an unhelpful error.

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

The output is about 60 lines for this world.
Open it if you are curious.
The important parts follow:

- `cabi_realloc`, which is exported automatically.
- `export fn add(p0: i32, p1: i32) i32`, a thunk that bitcasts two `i32` inputs to `u32`.
  It calls `exports.add(...)` and returns the result.
- `export fn greet(p0: i32, p1: i32) i32`, a thunk that rebuilds a `[]const u8` from the canonical pointer and length.
  It calls `exports.greet(...)`.
  It writes the returned slice pointer and length into a small return area.
  The return area address is the single `i32` result.
- `export fn cabi_post_greet(_r: i32)`, which the host invokes after lifting the string.
  The guest can then reclaim memory if needed.

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

Two details matter here.

The `comptime { _ = bindings; }` block pulls generated thunks into the final binary.
Without it, the linker sees `add` and `greet` as dead code.
It strips them.
Every Zig component using generated bindings needs this line.

The `wit_exports` namespace is the generated bindings contract.
The generator emits `const exports = @import("root").wit_exports;` near the top of `bindings.zig`.
Each `export fn` calls `exports.<func_name>(...)`.
WIT hyphens become underscores.
For example, `format-greeting` becomes `format_greeting`.

Memory returned by `greet` uses the canonical-ABI arena behind `cabi_realloc`.
The host copies the bytes before calling `cabi_post_greet`.
You do not need to keep the buffer.

## 4. Compile to a core wasm module

```sh
zig build-exe -fno-entry -OReleaseSmall -target wasm32-freestanding -rdynamic \
  --dep zig_wasi_components --dep bindings -Mroot=tmp/hello/component.zig \
  -Mzig_wasi_components=src/root.zig \
  --dep zig_wasi_components -Mbindings=tmp/hello/bindings.zig \
  --name hello \
  -femit-bin=tmp/hello/hello.core.wasm
```

The command is long because it performs `build.zig` work manually.
Use build-system integration in a real project.
See [build-integration.md](build-integration.md) for a clean template.
With that template, this step becomes `zig build hello`.

Three details matter.

Use `-fno-entry` because component guests have no `main`.
Use `-rdynamic` because the wasm linker otherwise removes every unused `export fn`.
The host reaches canonical-ABI thunks externally.
No internal call reaches them.

The `--dep` and `-M` flags declare three modules:

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
It wires the canonical ABI adapter functions and type definitions.

If a step rejects the module, its error names the failing import or export.
A common cause is a WIT and implementation mismatch.
For example, Zig may export `format_greeting` while WIT declares `format-greeting`.
The CLI changes WIT hyphens to Zig underscores.
Generated bindings will not compile if you skip that change.

## 6. Run it

```sh
wasmtime run --invoke 'add(2, 3)' tmp/hello/hello.component.wasm
# => 5

wasmtime run --invoke 'greet("world")' tmp/hello/hello.component.wasm
# => "Hello, world!"
```

If both invocations work, you have a fully functional component.

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
  [build-integration.md](build-integration.md) includes a copy-pasteable template.
  It automates steps 4 and 5.
