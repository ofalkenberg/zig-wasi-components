# Documentation

`zig-wasi-components` turns WIT into Zig bindings.
It also includes a small runtime for WebAssembly components.

Write your world in a plain Zig module, and the generator and runtime turn it into a real WebAssembly component.
They handle the canonical ABI, `cabi_realloc`, and component wrapping for you.
The result is a standard `.component.wasm` that Wasmtime can run and Rust hosts can load.

These ten short pages each cover one topic.
You don't need to read them in order.
Start with whichever one you need.

## Start here

- [Getting started](getting-started.md): install the tools, build bundled demos, and check the expected results.
- [The CLI](cli.md): reference for `zig_wasi_components dump` and `gen`.
  These are the only two subcommands.
- [Your first component](workflow.md): take a new `.wit` file to a runnable component.

## Reference

- [Generated bindings](bindings.md): what's in the file that `gen` produces.
  It covers the `wit_exports` convention and the complete WIT-to-Zig mapping.
- [Resources](resources.md): implement a `resource` type.
  It covers constructors, methods, destructors, and canonical-ABI lifecycle rules.
- [WASI worlds](wasi.md): work with WIT trees spread across multiple files.
  It explains flattening with `wasm-tools component wit` and targets such as `wasi:cli` and `wasi:http`.
- [The `wasi` convenience module](wasi-module.md): use `zig_wasi_components.wasi` for idiomatic Zig calls.
  It covers clocks, randomness, stdio, environment, files, DNS, TCP, HTTP, and the stream-based `wasi3` counterpart.
- [Build-system integration](build-integration.md): add the codegen and `wasm-tools` pipeline to `build.zig`.
  It includes a complete template.

## When things go wrong

- [Troubleshooting](troubleshooting.md): common error messages, what they mean, and how to fix them.
- [Limitations](limitations.md): known gaps and why they remain.
  Read it before opening an issue.

## What this project is, in one paragraph

The build works the same way as `cargo-component` does for Rust.
`zig_wasi_components gen world.wit <world-name>` parses a WIT file and writes one Zig file, usually named `bindings.zig`.

Here's what's in that file:

- Zig structs, unions, and enums for every WIT type.
- Typed Zig wrappers for every import, sync or async.
- `export` thunks that unpack canonical-ABI arguments and call your `wit_exports`.
- The `cabi_realloc` and `cabi_post_*` symbols the host needs.
- Stream and future operations for the functions that use them.

Compile that file and your implementation for `wasm32-freestanding`.
Pass the core module to `wasm-tools component embed` and `wasm-tools component new`.
You can use the result with Rust hosts and the Wasmtime CLI.
