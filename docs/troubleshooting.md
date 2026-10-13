# Troubleshooting

These are the errors you're most likely to hit, with a plain English explanation and a concrete fix for each.
The first section covers code generator errors, the second covers `wasm-tools` errors, and the third covers Wasmtime and Rust host runtime failures.

## Code generator errors

### `error: world '<name>' not found in <file>`

The world name you passed doesn't appear in the file.
The CLI prints the full list of worlds immediately after the error, or the list of interfaces if there are no worlds.
That lets you see what's available.

There are two common causes:

- **The argument is a namespaced path.** WIT worlds are referenced externally as `pkg:name/world`, but `gen` takes the bare identifier.
  Pass just `world`.
- **The file has only interfaces.** Interface files aren't worlds.
  Use `dump` to inspect the file.
  Then write a world that imports the interface, or pick a file that already declares one.

### `error: MissingArgument`

`dump` needs a file, and `gen` needs a file and a world name.
Check the command line you ran.

### `error: UnexpectedToken` and other parse errors

`wasm-tools component wit <file>`

Run this to find the line.
The parser reports what went wrong, but not where; this command parses the same grammar and prints a precise location.

The most likely cause is a WIT feature the parser doesn't know yet.
If `wasm-tools` rejects the file too, the file itself is the problem.

The parser is also more lenient than `wasm-tools` in a few places.
For example, a file with no `package <ns>:<name>;` line generates bindings without complaint, and only `wasm-tools component embed` fails later with ``no `package` header was found in any WIT file for this
package``.
Add the package line.

### `error: UnknownType`

Something in the file `use`s a type from a package that isn't in the file.
The generator reads a single file and doesn't follow dependencies.
Flatten the WIT tree with `wasm-tools component wit` first, as described in [the WASI doc](wasi.md).

### The generated bindings are nearly empty

This has the same root cause as `UnknownType`, but it's quieter.
If a world imports or exports interfaces from other packages and those packages are missing from the file, you get bindings with just `cabi_realloc` in them.
Flatten the WIT first.

## `wasm-tools` errors

### `failed to find export of function ...`

`wasm-tools component new` expected an export that the core module doesn't have.
There are two common causes:

- **The `comptime { _ = bindings; }` line is missing** from your component source.
  Without it, Zig never compiles the bindings, and the module has no exports at all.
- **`bindings.zig` is stale.** You changed an export in the WIT but didn't regenerate the bindings.
  The same goes for imports, which fail with `failed to resolve import ...`.

If you renamed a function on the Zig side only, you won't get this far: the Zig build fails with `has no member named ...`.
Remember that WIT hyphens become Zig underscores: `format-greeting` is `format_greeting` in `wit_exports`.

### `type mismatch for function ...: expected ... but found ...`

The core signature of an export doesn't match the WIT you passed to `embed`.
The generated thunks always match the WIT they were generated from, so this means `bindings.zig` came from a different version of the WIT.
Regenerate it.

### `package '...' not found`

You pointed `wasm-tools component wit` at a directory whose dependencies tree is missing a referenced package.
For `wasi:sockets`, for example, you also need `wasi:io` and `wasi:clocks` in `deps/`.
Sockets uses pollables from io and time types from clocks.

The simplest fix is to copy the dependencies tree from a bundled example.
`examples/http-get/wit/deps/` has a complete 0.2.6 set.

For WASI 0.3, there's no dependencies tree to assemble.
These are single, fully resolved files, each with every package its world needs:

- `examples/wasi-demo-p3/wit/cli.wit`
- `wit-http/http.wit`

You can copy them and feed them directly to `gen` and `embed`.

### `module requires an import interface named ...` for an `@unstable` item

The generated bindings include items gated with `@unstable(feature = ...)`, such as `wasi:clocks/timezone` in WASI 0.3.2.
`wasm-tools component embed` hides those items unless the feature is enabled, so `component new` then finds a core import that isn't in the embedded world.

Pass the feature to `embed`, for example `--features clocks-timezone`, or use `--all-features`.
The host must also provide the interface.

Bindings you never call cost nothing.
Zig only emits imports for functions that are referenced.

### `the async canonical option requires an async function type`

`wasm-tools component new` refuses an `[async-lower]` import when the WIT function isn't declared `async`.
Sync WASI 0.3 functions that return streams or futures, the `*-via-stream` family, must be lowered synchronously.
The stream handle returns immediately; only the data transfer is asynchronous.

The generated bindings already do the right thing.
You'll only see this error if you write an `@extern` by hand with an `[async-lower]` link name for a sync-typed WIT function.
Drop the prefix.

## Wasmtime / runtime errors

### `unknown handle index <very large number>`

A raw pointer was used where a resource handle was expected, so the pointer bits were read as a table index.
Generated bindings never do this: the constructor thunk turns your `*State` into a handle with `[resource-new]`.

You'll only see it with glue code you've written by hand.
See [resources.md](resources.md) for the pattern the bindings follow.

### `invalid expected discriminant` and friends

Wasmtime read back a `result` whose tag byte doesn't match any case.
For an `option`, the message is `invalid option discriminant`.
For a variant or enum, it's `unexpected discriminant: N`.

The generated thunks always write valid tags, so this almost always means `bindings.zig` is stale: cases were added, removed, or reordered in the WIT, and the bindings weren't regenerated.
Regenerate them.
Never edit the generated file by hand.

### Garbage or `memory access out of bounds` in a returned string or list

An export returned a slice that no longer points at live memory.
For example:

- A slice of a local array.
- A slice of a buffer you already freed.

The host reads the bytes after your function has returned.
Return static data, or memory from an allocator such as `std.heap.wasm_allocator`.
The greeter's `format_greeting` is an example.

### The component runs but produces wrong output

`wasm-tools component wit zig-out/wasm/foo.component.wasm`

This prints the interface your component actually exports and imports, as WIT.
If that output doesn't match what you intended, the cause is usually a stale `bindings.zig` or a build against the wrong world.

### `component imports instance wasi:http/..., but a matching implementation was not found`

For a `wasi:http` client, this means you left `-S http=y` out of the Wasmtime command line.
The flag enables the wasi-http implementation.
Without it, Wasmtime refuses to instantiate the component.

### `instance export ... has the wrong type` / `function implementation is missing`

For a WASI 0.3 component, first check your `-S` flags: running without `-S p3` (or with `-S p3=n`) gives exactly this error.

If the flags are right, this is a *version identity* mismatch, not an encoding bug.
Wasmtime 46 and later link WASI 0.3.2 components directly, with both `wasmtime run -S p3` and `wasmtime serve -S p3,cli`.

Wasmtime 45 and earlier vendor the `0.3.0-rc-2026-03-15` interfaces.
Their shapes match the final release, but named types such as `error-code` carry their interface version in their type identity.
So a WASI 0.3.2 component fails to link every host function whose signature mentions one.

Before suspecting the bindings, compare the version strings.
On an old runtime, fetch its vendored WIT from `crates/wasi/src/p3/wit/deps/*.wit` in the wasmtime repository.
Regenerate the bindings from it, then rebuild the otherwise identical guest.

### `synchronous stream.write requires the component model more async builtins feature`

The message can also name:

- `stream.read`
- `future.read`
- `future.write`

The synchronous stream and future canon builtins have their own Wasmtime feature gate, and the generated typed intrinsics and the `wasi3` module rely on them.
Wasmtime refuses to load the component without it.

```sh
wasmtime run -S p3 \
    -W component-model-async,component-model-more-async-builtins \
    --invoke 'run()' my.component.wasm
```

Run WASI 0.3 components with both flags, as shown above.

## Build-system surprises

### Build cache reuses stale bindings

This often happens when you edit a `.wit` file in a `deps/` directory.
Passing the directory with `addDirectoryArg` doesn't register the files inside it.

Use the `addWitTreeAsInputs` helper from [build-integration.md](build-integration.md).
It walks the tree during configuration and adds each `.wit` file as an explicit input.
