# The CLI

`zig_wasi_components` is the single binary the build steps invoke and
the one you call directly when generating bindings for your own
projects. It exposes two subcommands: `dump`, which prints a summary
of a parsed WIT file, and `gen`, which emits Zig source for a chosen
world.

After running `zig build`, the binary lives at
`zig-out/bin/zig_wasi_components`. The rest of this page assumes you
have it on your `PATH` or call it via that path.

## Usage at a glance

```
zig_wasi_components dump <wit-file>           describe a WIT file
zig_wasi_components gen  <wit-file> <world>   emit Zig bindings to stdout
```

Both subcommands take a single `.wit` file as input. The file must be
self-contained: any `use foo:bar/baz` cross-package reference must
either resolve to a package block already present in the same file
(the multi-package format produced by `wasm-tools component wit`) or
to a type defined elsewhere in the same file. The CLI does not chase
a `deps/` directory by itself. The [WASI doc](wasi.md) shows how to
preflatten a directory tree into a single file.

## `dump`

`dump` parses the file and prints a short description of what it
contains. Useful for two things: confirming the parser accepts your
file at all, and figuring out the right world name to pass to `gen`
when you forget.

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

The summary lists every world declared in the file with its imports
and exports, then every interface, then every cross-package
dependency that was named but not inlined. Errors are surfaced
inline; if `dump` rejects the file with a parse error, `gen` will
reject it the same way.

## `gen`

`gen` parses the file, locates the named world, and writes the
generated Zig source to stdout. Redirect to a file or pipe into your
build:

```sh
zig_wasi_components gen examples/greeter/greeter.wit greeter > bindings.zig
```

The world argument is a **bare identifier** — the name as it appears
after the `world` keyword, with no package prefix. If your WIT
declares `world client`, the argument is `client`, not
`demo:httpget/client`.

If the world is not found, the CLI prints a friendly error that
lists every world the file does contain (and, if there are none,
every interface). The exit status is non-zero so build scripts
notice.

```
$ zig_wasi_components gen examples/http-get/wit/deps/sockets/udp.wit udp
error: world 'udp' not found in examples/http-get/wit/deps/sockets/udp.wit
       this file declares no worlds — only interfaces and/or types.
       'gen' needs a `world <name> { … }` declaration; try `dump` to inspect the file.
       interfaces in this file:
         - udp
```

### What `gen` actually emits

The output has a fixed top-level structure, always in this order:

1. A header comment naming the source package and world.
2. The standard imports (`std`, the project's `abi` module).
3. Every type declared in the world or in any used interface,
   rendered as Zig structs, unions, enums, packed structs, or type
   aliases. See the [bindings doc](bindings.md) for the full type
   mapping.
4. `pub const imports = struct { ... }` containing one Zig wrapper
   for each function the world *imports*. Each wrapper packs its
   Zig-typed arguments into the canonical flat representation,
   calls a private `@extern` declaration, and lifts the result back.
5. A reference to your `wit_exports` namespace.
6. The `cabi_realloc` export, backed by the arena allocator in
   `src/abi.zig`.
7. One `export fn <name>(...)` per world-level export, each lifting
   flat canonical-ABI parameters into Zig types, calling
   `wit_exports.<name>(...)`, and lowering the result back into
   flat slots or the indirect return area.
8. One `export fn cabi_post_<name>(...)` per export that needs a
   post-return hook (anything returning a string, list, record,
   variant, option, or result through the indirect return area).
9. If the world exports interfaces, a nested `pub const <iface>`
   namespace inside a per-interface block, and the corresponding
   `export fn <iface>#<func>` thunks.

The full anatomy is in [bindings.md](bindings.md). If you intend to
hand-write or maintain bindings, that page is the one to read in
detail.

## Exit codes

- `0` — success.
- non-zero — anything else, including `WorldNotFound`, parse
  errors, or I/O errors reading the input. The error message goes
  to stderr.

The CLI does not have a `--help` flag yet. Running it with no
arguments prints the usage line, which is the same as the heading
of this page.

## Integrating in shell scripts

The simplest pattern is to redirect stdout to a file:

```sh
zig_wasi_components gen world.wit my-world > bindings.zig
```

Inside `build.zig` the same effect is achieved with
`captureStdOut(.{ .basename = "bindings.zig" })` on the run step.
See [build-integration.md](build-integration.md) for a complete
template.
