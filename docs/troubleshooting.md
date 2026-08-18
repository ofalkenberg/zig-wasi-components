# Troubleshooting

These are the errors you are most likely to hit. Each includes a plain
English translation and a concrete fix. The first section covers code
generator errors. The second covers `wasm-tools` errors. The third
covers Wasmtime and Rust host runtime failures.

## Code generator errors

### `error: world '<name>' not found in <file>`

The world name you passed does not appear in the file. The CLI prints
the full list of worlds immediately after the error. If there are no
worlds, it prints the list of interfaces. This helps you see what is
available. Two common causes are:

- **The argument is a namespaced path.** WIT worlds are referenced
  externally as `pkg:name/world`, but `gen` takes the bare
  identifier. Pass just `world`.
- **The file has only interfaces.** Interface files are not worlds.
  Use `dump` to inspect the file. Then write a world that imports the
  interface, or pick a file that already declares one.

### `error.MissingArgument`

`gen` needs three arguments: the subcommand, the file, and the world
name. The error is generic. Check the command line that you ran.

### Parse errors from the WIT file

The parser is strict about WIT 0.3-era grammar. It does not always print
the exact byte offset. It does print the failing token. There are three
common causes:

- **You forgot the `package <ns>:<name>;` line at the top.** Every
  WIT file needs one. The error usually mentions an unexpected token
  where the first real declaration begins.
- **You used a feature the parser does not know.** This is most likely
  a WIT 0.4+ grammar addition. Check whether the file works with the
  reference WIT tooling (`wasm-tools component wit`). If it does not,
  the source is the problem.
- **A `use` clause references a package that is not declared in the
  same file.** The single-file parser does not chase dependencies.
  Either preflatten with `wasm-tools component wit` or move the type
  inline.

## `wasm-tools` errors

### `failed to find import named ...`

You renamed an export in the WIT or Zig source without updating the
other side. One subtle variant occurs when a WIT name has a hyphen. The
Zig name must use underscores: `format-greeting` ↔ `format_greeting`.

Another variant occurs when you forget the
`comptime { _ = bindings; }` line in your component source. The linker
then strips the export thunks.

### `expected to find a function with signature ... but found ...`

The arity, parameter type, or return type of an export does not match
the WIT declaration. Reread the function signature in the WIT. Then
reread the corresponding `pub fn` in your `wit_exports`. WIT `u32` maps
to Zig `u32`. WIT `string` maps to Zig `[]const u8`. WIT `list<T>` maps
to Zig `[]const T`. The full table is in [bindings.md](bindings.md).

### `package '...' not found`

`wasm-tools component wit` was pointed at a directory whose dependencies
tree lacks a referenced package. For `wasi:sockets`, for example, you
also need `wasi:io` and `wasi:clocks` in `deps/`. Sockets uses pollables
from io and time types from clocks.

The simplest fix is to copy the dependencies tree from a bundled
example. `examples/http-get/wit/deps/` has a complete 0.2.6 set. For
WASI 0.3.0, there is no dependencies tree to assemble.
`examples/wasi-demo-p3/wit/cli.wit` and `wit-http/http.wit` are single,
fully resolved files. They contain all six packages inline. You can copy
them and feed them directly to `gen` and `embed`.

### `the async canonical option requires an async function type`

`wasm-tools component new` refuses an `[async-lower]` import when the
WIT function is not declared `async`. Sync WASI 0.3 functions that
return streams or futures, the `*-via-stream` family, must be lowered
synchronously. The stream handle returns immediately. Only the data
transfer is asynchronous.

The generated bindings already do the right thing. You will only see
this error if you hand-write an `@extern` with an `[async-lower]` link
name for a sync-typed WIT function. Drop the prefix.

## Wasmtime / runtime errors

### `unknown handle index <very large number>`

You returned a raw pointer where a resource handle was expected. The
pointer bits were misinterpreted as a table index. Fix: the constructor
must return a `*State`. The generator handles the `[resource-new]`
round-trip. The rest of your code should use the `*State` argument that
the binding lifts for you. See [resources.md](resources.md) for the full
pattern.

### `invalid expected discriminant`

The host expected a tagged enum, variant, option, or result. It got a
value that does not match any case. There are two causes:

- **You returned an integer where a discriminant was needed.** A WIT
  export returning `result<T, E>` has a single-`i32` flat
  representation. `0` is `Ok` and `1` is `Err`. The indirect
  representation has the discriminant byte at offset 0. Its payload
  has a fixed offset. If you write the wrong byte, the host rejects
  it. Use the typed Zig wrapper instead of computing the layout by
  hand: `return .{ .ok = x };` or `return .{ .err = e };`.
- **The Zig union(enum) tag does not line up with the WIT case
  order.** The generator preserves WIT case order. If you reorder
  cases while editing the generated source, the tags drift.

### `memory access out of bounds` immediately on a call

This usually means the indirect return area was misread. The retarea is
a fixed-size stack buffer. Its layout matches the canonical layout of
the return type. If your export returns a slice or string, allocate its
bytes through `std.heap.wasm_allocator`. You can also use another
allocator backed by `cabi_realloc`. Otherwise, the host gets a pointer
to stack memory that is released before it reads it.

The fix is to allocate every returned string or list with
`std.heap.wasm_allocator`. The greeter's `format_greeting` is the
reference example.

### The component runs but produces wrong output

Run `wasm-tools print zig-out/wasm/foo.component.wasm | less` to inspect
the textual form. The `(component ...)` section at the top lists every
exported and imported function with its full canonical type. A mismatch
between that output and your intent is almost always a WIT-to-Zig name
mapping problem.

### `wasmtime: failed to invoke <function>`

For `wasi:http`, this usually means you omitted `-S http=y` from the
Wasmtime command line. The flag enables the wasi-http implementation.
Without it, the outbound-request import is not satisfied. The first call
then traps.

### `instance export ... has the wrong type` / `function implementation is missing`

For a WASI 0.3 component, this is almost always a *version identity*
mismatch. It is not an encoding bug. Wasmtime 46 and later ship the
final `0.3.0` interfaces. Components built against final `@0.3.0` run
as-is. Components built against `@0.3.1` also run through
semver-compatible resolution. This applies to both `wasmtime run -S p3`
and `wasmtime serve -S p3,cli`.

Wasmtime 45 and earlier vendor the `0.3.0-rc-2026-03-15` interfaces.
Their shapes match final 0.3.0. However, named types such as
`error-code` carry their interface version in their type identity. A
final-`@0.3.0` component therefore fails to link every host function
whose signature mentions one.

Before suspecting the bindings, compare the version strings. On an old
runtime, fetch its vendored WIT from
`crates/wasi/src/p3/wit/deps/*.wit` in the wasmtime repository.
Regenerate the bindings from it. Then rebuild the otherwise identical
guest.

### `synchronous future.read requires the component model more async builtins feature`

The sync `stream.read` and `future.read` canon builtins sit behind their
own Wasmtime feature gate. The generated typed intrinsics and the
`wasi3` module rely on them. Run WASI 0.3 components with both flags:

```sh
wasmtime run -S p3 \
    -W component-model-async,component-model-more-async-builtins \
    --invoke 'run()' my.component.wasm
```

## Build-system surprises

### Build cache reuses stale bindings

This often happens when you edit a `.wit` file in a `deps/` directory.
The build script registered it with `addDirectoryArg` instead of listing
files individually. Use the `addWitTreeAsInputs` helper from
[build-integration.md](build-integration.md). It walks the tree during
configuration and adds each `.wit` file as an explicit input.

### `error: too few arguments` from `Writer.print`

This is a Zig-side error from your code, not this project. WIT
identifiers often contain `{` or `}`. These come from inline
tuple/struct syntax in error messages. Escape them as `{{` and `}}` in a
`std.fmt` format string. Otherwise, the compile-time format check fails.
This error also caught the CLI during error-message work.
