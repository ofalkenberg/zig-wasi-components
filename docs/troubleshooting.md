# Troubleshooting

The errors you are most likely to hit, with translations into plain
English and concrete fixes. The first section covers errors from the
code generator; the second covers errors from the wasm-tools steps;
the third covers runtime failures from Wasmtime or a Rust host.

## Code generator errors

### `error: world '<name>' not found in <file>`

The world name you passed does not appear in the file. The CLI
prints the full list of worlds (and, if there are none, the list of
interfaces) immediately after the error so you can see what is
available. Two common causes:

- **The argument is a namespaced path.** WIT worlds are referenced
  externally as `pkg:name/world`, but `gen` takes the bare
  identifier — just `world`.
- **The file has only interfaces.** Interface files are not worlds.
  Use `dump` to inspect, then either write a world that imports the
  interface or pick a file that already declares one.

### `error.MissingArgument`

`gen` needs three arguments: the subcommand, the file, and the
world name. The error is generic; look at the command line you
actually ran.

### Parse errors from the WIT file

The parser is strict about WIT 0.3-era grammar. The exact byte
offset of the error is not always printed, but the failing token is.
Three categories of cause:

- **You forgot the `package <ns>:<name>;` line at the top.** Every
  WIT file needs one. The error usually mentions an unexpected
  token at the position where the first real declaration begins.
- **You used a feature the parser does not know.** Most likely a
  WIT 0.4+ grammar addition. Check whether your file works with the
  reference WIT tooling (`wasm-tools component wit`); if it does
  not, the source is the problem.
- **A `use` clause references a package that is not declared in the
  same file.** The single-file parser does not chase deps. Either
  preflatten with `wasm-tools component wit` or move the type
  inline.

## `wasm-tools` errors

### `failed to find import named ...`

You renamed an export in the WIT or in the Zig source without
updating the other side. The most subtle variant is when a WIT
name has a hyphen — the Zig name must use underscores
(`format-greeting` ↔ `format_greeting`). The other variant is when
you forgot the `comptime { _ = bindings; }` line in your component
source, so the linker stripped the export thunks.

### `expected to find a function with signature ... but found ...`

The arity, parameter type, or return type of one of your exports
does not match what the WIT declares. Reread the function signature
in the WIT, then reread the corresponding `pub fn` in your
`wit_exports`. WIT `u32` → Zig `u32`, WIT `string` → Zig
`[]const u8`, WIT `list<T>` → Zig `[]const T`. The full table is in
[bindings.md](bindings.md).

### `package '...' not found`

`wasm-tools component wit` was pointed at a directory whose deps
tree is missing a referenced package. For `wasi:sockets`, for
example, you need `wasi:io` and `wasi:clocks` in `deps/` as well
because sockets uses pollables from io and time types from clocks.
The simplest fix is to copy the deps tree from one of the bundled
examples (`examples/http-get/wit/deps/`) which has a complete
0.2.6 set. For WASI 0.3.0 there is no deps tree to assemble:
`examples/wasi-demo-p3/wit/cli.wit` and `wit-http/http.wit` are
single fully-resolved files (all six packages inline) you can copy
and feed to `gen` and `embed` directly.

### `the async canonical option requires an async function type`

`wasm-tools component new` refuses an `[async-lower]` import of a
WIT function that is *not* declared `async`. The sync functions in
WASI 0.3 that return streams or futures (the `*-via-stream` family)
must be lowered synchronously — the stream handle comes back
immediately; only the data transfer is asynchronous. The generated
bindings already do the right thing; you will only see this if you
hand-write an `@extern` with an `[async-lower]` link name against a
sync-typed WIT function. Drop the prefix.

## Wasmtime / runtime errors

### `unknown handle index <very large number>`

You returned a raw pointer where a resource handle was expected.
The pointer bits were misinterpreted as a table index. Fix: the
constructor must return a `*State` (the generator handles the
`[resource-new]` round-trip), and the rest of your code should use
the `*State` argument the binding lifts for you. See
[resources.md](resources.md) for the full pattern.

### `invalid expected discriminant`

The host expected a tagged enum (variant, option, or result) and
got a value that does not match any case. Two causes:

- **You returned an integer where a discriminant was needed.** A
  WIT export returning `result<T, E>` has a single-`i32` flat
  representation where `0` is `Ok` and `1` is `Err`; the indirect
  representation has the discriminant byte at offset 0 and the
  payload at a fixed offset. If you wrote out the wrong byte, the
  host rejects it. Fix: use the typed Zig wrapper (`return .{ .ok = x };`
  or `return .{ .err = e };`) instead of computing the layout by
  hand.
- **The Zig union(enum) tag does not line up with the WIT case
  order.** The generator preserves WIT case order. If you reorder
  cases when reading the generated source and rewrite by hand, the
  tags drift.

### `memory access out of bounds` immediately on a call

Usually the indirect return area being misread. The retarea is a
stack buffer of fixed size matching the canonical layout of the
return type. If you returned a slice or string from your export
but did not allocate the bytes through `std.heap.wasm_allocator`
(or some other allocator backed by `cabi_realloc`), the pointer
the host receives points into stack memory that has already been
released by the time the host reads it.

Fix: allocate any returned string or list out of
`std.heap.wasm_allocator`. The greeter's `format_greeting` is the
reference example.

### The component runs but produces wrong output

Run `wasm-tools print zig-out/wasm/foo.component.wasm | less` to
inspect the textual form. The `(component ...)` section at the top
lists every exported and imported function with its full canonical
type. A mismatch between what is there and what you intended is
almost always a WIT-to-Zig name mapping problem.

### `wasmtime: failed to invoke <function>`

For `wasi:http`, this is usually missing `-S http=y` on the
Wasmtime command line. The flag enables the wasi-http
implementation; without it, the outbound-request import is not
satisfied and the very first call traps.

### `instance export ... has the wrong type` / `function implementation is missing`

On a WASI 0.3 component this is almost always a *version identity*
mismatch, not an encoding bug. Released wasmtimes (up to and
including 47) vendor the `0.3.0-rc-2026-03-15` interfaces — the
shapes are identical to final 0.3.0, but named types such as
`error-code` carry their interface's version in their type
identity, so a component built against final `@0.3.0` fails to
link every host function whose signature mentions one. Before
suspecting your bindings, diff the version strings: fetch
wasmtime's vendored WIT (`crates/wasi/src/p3/wit/deps/*.wit` in
the wasmtime repo), regenerate bindings from it, and rebuild the
otherwise-identical guest. Once a runtime ships the final
packages, the original component links as-is.

### `synchronous future.read requires the component model more async builtins feature`

The sync `stream.read` / `future.read` canon builtins (which the
generated typed intrinsics and the `wasi3` module rely on) sit
behind their own Wasmtime feature gate. Run WASI 0.3 components
with both flags:

```sh
wasmtime run -S p3 \
    -W component-model-async,component-model-more-async-builtins \
    --invoke 'run()' my.component.wasm
```

## Build-system surprises

### Build cache reuses stale bindings

Most often happens when you edit a `.wit` file that lives inside a
`deps/` directory the build script registered with
`addDirectoryArg` rather than file-by-file. The fix is the
`addWitTreeAsInputs` helper from
[build-integration.md](build-integration.md): walk the tree at
configure time and add every `.wit` as an explicit input.

### `error: too few arguments` from `Writer.print`

A Zig-side error from your own code, not from this project. WIT
identifiers often contain `{` or `}` (from inline tuple/struct
syntax in error messages), and forgetting to escape those as `{{`
and `}}` in a `std.fmt` format string trips the compile-time format
check. Mentioning this here because it caught the CLI itself
during error-message work.
