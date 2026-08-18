# Documentation

`zig-wasi-components` is a WIT-to-Zig code generator.
It also provides a small runtime for WebAssembly components.

Together, they turn a plain Zig module into a real WebAssembly component.
Implement your world in Zig, and this project handles the canonical ABI.
It also handles `cabi_realloc` plumbing and component wrapping.
The result is a `.component.wasm` accepted by Wasmtime and other component-model runtimes.

The docs have ten short, focused pages.
You do not need to read them in order.
Choose the entry point that matches your situation.

## Start here

- [Getting started](getting-started.md): install the tools, build bundled demos, and check the expected results.
- [The CLI](cli.md): reference for `zig_wasi_components dump` and `gen`.
  These are the only two subcommands.
- [Your first component](workflow.md): take a new `.wit` file to a runnable component.

## Reference

- [Generated bindings](bindings.md): the file that `gen` produces.
  It covers the `wit_exports` convention and the complete WIT-to-Zig mapping.
- [Resources](resources.md): implement a `resource` type.
  It covers constructors, methods, destructors, and canonical-ABI lifecycle rules.
- [WASI worlds](wasi.md): work with multi-file WIT trees.
  It explains flattening with `wasm-tools component wit` and targets such as `wasi:cli` and `wasi:http`.
- [The `wasi` convenience module](wasi-module.md): use `zig_wasi_components.wasi` for idiomatic Zig calls.
  It covers clocks, randomness, stdio, environment, HTTP, and the stream-based `wasi3` counterpart.
- [Build-system integration](build-integration.md): add the codegen and `wasm-tools` pipeline to `build.zig`.
  It includes a complete template.

## When things go wrong

- [Troubleshooting](troubleshooting.md): common error messages, their meanings, and fixes.
- [Limitations](limitations.md): intentionally unsupported features and their rationale.
  Read it before opening an issue.

## What this project is, in one paragraph

The build pipeline matches the one that `cargo-component` uses for Rust.
`zig_wasi_components gen world.wit <world-name>` reads a parsed WIT schema.
It emits one Zig file, usually named `bindings.zig`.

That file contains the following items:

- Typed `extern` declarations for every world import.
- `export` thunks that unpack canonical-ABI arguments and call `wit_exports`.
- The `cabi_realloc` and `cabi_post_*` symbols required by the host.
- Zig structs, unions, and enums for every WIT type.

Compile that file and your implementation for `wasm32-freestanding`.
Pass the core module to `wasm-tools component embed` and `wasm-tools component new`.
The result interoperates with Rust hosts, Wasmtime CLI calls, and other component-model runtimes.
