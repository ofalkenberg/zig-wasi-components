# Documentation

`zig-wasi-components` is a WIT-to-Zig code generator together with the
small runtime needed to turn a plain Zig module into a real WebAssembly
component. If you can write the code that implements your world, this
project takes care of the canonical-ABI lifting and lowering, the
`cabi_realloc` plumbing, and the wrapping into a `.component.wasm` that
Wasmtime or any other component-model runtime will accept.

The docs are split into ten short, focused pages. Most users will not
need to read them in order; pick whichever entry point matches your
situation.

## Start here

- [Getting started](getting-started.md) — what to install, how to build
  the bundled demos, and what success looks like.
- [The CLI](cli.md) — reference for `zig_wasi_components dump` and `gen`,
  the only two subcommands.
- [Your first component](workflow.md) — a walkthrough that takes a fresh
  `.wit` file all the way to a runnable component.

## Reference

- [Generated bindings](bindings.md) — the shape of the file `gen`
  produces, the `wit_exports` convention your code follows, and the full
  WIT-to-Zig type mapping table.
- [Resources](resources.md) — how to implement a `resource` type
  (constructor, methods, destructor) and the lifecycle rules the
  canonical ABI imposes.
- [WASI worlds](wasi.md) — how to work with multi-file WIT trees, why
  flattening with `wasm-tools component wit` matters, and how to target
  `wasi:cli`, `wasi:http`, and friends.
- [The `wasi` convenience module](wasi-module.md) — the
  `zig_wasi_components.wasi` namespace that wraps clocks, randomness,
  stdio, environment and HTTP into idiomatic Zig calls, and its
  `wasi3` counterpart for the stream-based WASI 0.3 interfaces.
- [Build-system integration](build-integration.md) — wiring the codegen
  + `wasm-tools` pipeline into your own `build.zig`, with a complete
  template you can copy.

## When things go wrong

- [Troubleshooting](troubleshooting.md) — the error messages you are
  most likely to hit, what they actually mean, and how to fix them.
- [Limitations](limitations.md) — what is intentionally not yet
  implemented, and why. Read this before opening an issue.

## What this project is, in one paragraph

The build pipeline is the same one `cargo-component` uses for Rust.
`zig_wasi_components gen world.wit <world-name>` reads a parsed WIT
schema and emits a single Zig file (`bindings.zig`) with: typed `extern`
declarations for everything the world imports, `export` thunks that
unpack canonical-ABI flat arguments and call back into your `wit_exports`
namespace, the `cabi_realloc` + `cabi_post_*` symbols the host needs,
and Zig-side struct, union, and enum definitions for every WIT type.
You compile that file together with your implementation against
`wasm32-freestanding`, hand the resulting core module to
`wasm-tools component embed` + `wasm-tools component new`, and out the
far end comes a component that interoperates with Rust hosts, Wasmtime
CLI invocations, or anything else that speaks the component model.
