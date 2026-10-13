# The CLI

Build steps use the `zig_wasi_components` binary.
You can also run it directly to generate bindings for your own projects.

It has two subcommands:

- `dump` parses a WIT file and prints a summary.
- `gen` generates Zig source for the world you choose.

After `zig build`, the binary is at `zig-out/bin/zig_wasi_components`.
This page assumes that path is on your `PATH`.
You can also use the full path.

## Usage at a glance

```
zig_wasi_components dump <wit-file>           describe a WIT file
zig_wasi_components gen  <wit-file> <world>   emit Zig bindings to stdout
```

Both subcommands accept one `.wit` file.
The file must be self-contained.

A `use foo:bar/baz` reference to another package must resolve within that
file, either to an existing package block or to a type elsewhere in the file.
The package-block form is the multi-package format that
`wasm-tools component wit` creates.

The CLI doesn't search a `deps/` directory itself.
The [WASI doc](wasi.md) explains how to flatten a directory tree into one file.

## `dump`

```sh
$ zig_wasi_components dump examples/greeter/greeter.wit
package demo:greeter@0.1.0
  1 world(s), 0 interface(s), 0 dep(s)
  world greeter:
    import log (func)
    import origin (func)
    import label-point (func)
    export greet (func)
    export sum (func)
    ...
```

`dump` parses the file and prints a short description.
Use it to check that the parser accepts your file or to find the world
name for `gen`.

The summary lists each world with its imports and exports.
For a multi-package file, such as the output of
`wasm-tools component wit`, it also lists the other packages and their
interfaces.

If the file doesn't parse, `dump` prints an error name such as
`error: UnexpectedToken`, without a location.
Run `wasm-tools component wit` on the file to find the line.
`gen` uses the same parser, so it fails the same way.

## `gen`

```sh
zig_wasi_components gen examples/greeter/greeter.wit greeter > bindings.zig
```

`gen` parses the file, finds the named world, and writes generated Zig
source to stdout.
You can redirect that output to a file, as above, or pipe it into a build.

The world argument is a **bare identifier**.
Use the name after the `world` keyword.
Don't include a package prefix.

For `world client`, pass `client`.
Don't pass `demo:httpget/client`.

```
$ zig_wasi_components gen examples/http-get/wit/deps/sockets/udp.wit udp
error: world 'udp' not found in examples/http-get/wit/deps/sockets/udp.wit
       this file declares no worlds, only interfaces and/or types.
       'gen' needs a `world <name> { ... }` declaration; try `dump` to inspect the file.
       interfaces in this file:
         - udp
```

If the world is missing, the CLI prints a friendly error and lists the
worlds declared in the file.
If there are no worlds, it lists interfaces instead.

A world argument containing `:` or `/` also gets a reminder that it
must be a bare identifier.
The CLI exits with a non-zero status, so build scripts can detect the failure.

`gen` needs everything the world refers to in the same file.
A `use` of a type from a missing package fails with
`error: UnknownType`, but an imported or exported interface that is
missing is silently left out of the bindings.
If the generated file is suspiciously small, check that you passed the
flattened WIT (see [the WASI doc](wasi.md)).

### What `gen` actually emits

The output starts with the WIT types, then a namespace for each imported
interface with Zig wrappers for its functions.
Functions the world imports directly live in `bindings.imports`.
At the bottom, you'll find the glue the host calls:

- `cabi_realloc`
- one `export fn` per exported function, forwarding to your `wit_exports`
- the `cabi_post_*` hooks

See [bindings.md](bindings.md) for the full layout and the WIT-to-Zig
type mapping.

## Exit codes

- `0`: success, and running without arguments.
- non-zero: everything else, including:

  - a missing world
  - missing arguments
  - an unknown subcommand
  - parse errors
  - unreadable files

  Errors go to stderr.

The CLI doesn't support `--help` yet.
Running it without arguments prints the usage shown at the top of this
page.

## Integrating in shell scripts

```sh
zig_wasi_components gen world.wit my-world > bindings.zig
```

The simplest approach is to redirect stdout to a file, as above.

In `build.zig`, call `captureStdOut(.{ .basename = "bindings.zig" })` on the run step.
See [build-integration.md](build-integration.md) for a complete template.
