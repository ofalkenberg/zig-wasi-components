# The CLI

`zig_wasi_components` is the binary used by build steps.
Use it directly to generate bindings for your own projects.

It has two subcommands:

- `dump` prints a parsed WIT file summary.
- `gen` emits Zig source for a selected world.

After `zig build`, the binary is at `zig-out/bin/zig_wasi_components`.
This page assumes that path is on your `PATH`.
You can also call it directly.

## Usage at a glance

```
zig_wasi_components dump <wit-file>           describe a WIT file
zig_wasi_components gen  <wit-file> <world>   emit Zig bindings to stdout
```

Both subcommands accept one `.wit` file.
The file must be self-contained.

A `use foo:bar/baz` cross-package reference must resolve within that file.
It can resolve to an existing package block.
This is the multi-package format created by `wasm-tools component wit`.
It can also resolve to a type elsewhere in that file.

The CLI does not search a `deps/` directory itself.
The [WASI doc](wasi.md) explains how to flatten a directory tree into one file.

## `dump`

`dump` parses a file and prints a short description.
Use it to confirm that the parser accepts a file.
Use it to find the world name for `gen`.

```sh
$ zig_wasi_components dump examples/greeter/greeter.wit
package demo:greeter@0.1.0
  1 world(s), 0 interface(s), 0 type(s), 0 dep(s)
  world greeter:
    import log (func)
    import origin (func)
    import label-point (func)
    export greet (func)
    export sum (func)
    ...
```

The summary lists each world with its imports and exports.
It then lists every interface.
It finally lists named cross-package dependencies that are not inlined.

Errors appear inline.
If `dump` reports a parse error, `gen` reports the same error.

## `gen`

`gen` parses the file and finds the named world.
It writes generated Zig source to stdout.
Redirect the output to a file or pipe it into a build.

```sh
zig_wasi_components gen examples/greeter/greeter.wit greeter > bindings.zig
```

The world argument is a **bare identifier**.
Use the name after the `world` keyword.
Do not include a package prefix.

For `world client`, pass `client`.
Do not pass `demo:httpget/client`.

If the world is missing, the CLI prints a friendly error.
It lists the worlds declared in the file.
If the file has no worlds, it lists interfaces instead.
The CLI exits with a non-zero status.
Build scripts can detect the failure.

```
$ zig_wasi_components gen examples/http-get/wit/deps/sockets/udp.wit udp
error: world 'udp' not found in examples/http-get/wit/deps/sockets/udp.wit
       this file declares no worlds; only interfaces and/or types.
       'gen' needs a `world <name> { … }` declaration; try `dump` to inspect the file.
       interfaces in this file:
         - udp
```

### What `gen` actually emits

The output has a fixed top-level structure:

1. A header comment that names the source package and world.
2. Standard imports: `std` and the project's `abi` module.
3. Every used world and interface type.
   The generator renders structs, unions, enums, packed structs, and aliases.
   See the [bindings doc](bindings.md) for the complete mapping.
4. `pub const imports = struct { ... }`.
   It contains a Zig wrapper for every imported world function.
   Each wrapper lowers Zig arguments to canonical flat values.
   It calls a private `@extern` declaration and lifts the result.
5. A reference to the `wit_exports` namespace.
6. The `cabi_realloc` export, backed by the arena allocator in `src/abi.zig`.
7. One `export fn <name>(...)` for every world-level export.
   Each lifts flat canonical-ABI parameters to Zig types.
   It calls `wit_exports.<name>(...)` and lowers the result.
   Results use flat slots or an indirect return area.
8. One `export fn cabi_post_<name>(...)` for every export needing a post-return hook.
   This includes strings, lists, records, variants, options, and indirect results.
9. When the world exports interfaces, a nested `pub const <iface>` namespace in every interface block.
   The output also includes `export fn <iface>#<func>` thunks.

See [bindings.md](bindings.md) for the full anatomy.
Read that page before hand-writing or maintaining bindings.

## Exit codes

- `0`: success.
- non-zero: all other outcomes, including `WorldNotFound`, parse errors, and input I/O errors.
  The CLI writes its error message to stderr.

The CLI does not support `--help` yet.
Running it without arguments prints the usage line.
It matches this page's usage heading.

## Integrating in shell scripts

The simplest pattern redirects stdout to a file:

```sh
zig_wasi_components gen world.wit my-world > bindings.zig
```

In `build.zig`, call `captureStdOut(.{ .basename = "bindings.zig" })` on the run step.
See [build-integration.md](build-integration.md) for a complete template.
