# Working with WASI worlds

The bundled `wasi:cli`, `wasi:http`, `wasi:io`, `wasi:filesystem`, and
related packages are not single files. Each package ships as a
directory of `.wit` files that `use` types from sibling packages. The
`gen` subcommand reads one WIT file at a time and does not chase a
`deps/` tree by itself, so binding against WASI takes one extra step:
flatten the world plus every transitive dependency into a single file,
then run `gen` on the flattened output.

This page covers the full workflow, why each step is there, and the
specific case of writing a component that targets `wasi:cli/run`.

## The recipe

```sh
wasm-tools component wit <wit-dir> > resolved.wit
zig_wasi_components gen resolved.wit <world-name> > bindings.zig
```

`wasm-tools component wit` walks the directory, resolves every
`use foo:bar/baz` reference, and prints the world together with every
package it transitively depends on as a single multi-package WIT
document. The generator handles that block form natively.

The `<wit-dir>` argument must point at a directory whose top level is
the package that declares your world. WASI deps go in a `deps/`
subdirectory next to that top-level file. For example:

```
my-component/
  wit/
    world.wit            <- declares your package and world
    deps/
      cli/...            <- verbatim copy of wasi:cli
      io/...
      clocks/...
      ...
```

`wasm-tools` finds the deps automatically — you do not need to pass
them explicitly.

## Worked example: a `wasi:cli` component

We will build a component that exports `wasi:cli/run`, the entry
point Wasmtime invokes when you run a component as a command.

### 1. Stage the WIT tree

The fastest way to get the WASI deps is to copy them from one of the
bundled examples. We will use the http-get example as the source
because it already has the full 0.2.6 deps tree.

```sh
mkdir -p tmp/hello-wasi
cp -r examples/http-get/wit/deps tmp/hello-wasi/deps
```

### 2. Declare your world

Create `tmp/hello-wasi/world.wit`:

```wit
package demo:hellowasi;

world hello-wasi {
  include wasi:cli/imports@0.2.6;
  export wasi:cli/run@0.2.6;
}
```

`include` pulls in every interface the named world imports, so your
component will see `wasi:cli/stdout`, `wasi:io/streams`, and the rest
without having to list them one by one. The single `export` line is
the contract that lets Wasmtime call your `run` function.

### 3. Flatten and generate

```sh
wasm-tools component wit tmp/hello-wasi > tmp/hello-wasi-resolved.wit
./zig-out/bin/zig_wasi_components gen tmp/hello-wasi-resolved.wit hello-wasi \
  > tmp/hello-wasi/bindings.zig
```

The flattened file is about 50KB and the generated bindings are
larger. Most of the surface is the wasi-io stream API and the
wasi-clocks pollable plumbing both pulled in transitively.

Note the resolved file lives *outside* the WIT package directory.
If you place it inside `tmp/hello-wasi/`, the next `wasm-tools
component embed` will see two declarations of `world hello-wasi`
(one in `world.wit`, one in `resolved.wit`) and bail out with
`duplicate item named hello-wasi`. Generated artefacts that
duplicate WIT content always belong somewhere else than the WIT
source tree.

### 4. Implement `run`

A `wasi:cli/run` export is a method on the `run` interface, so the
function name in `wit_exports` is namespaced by the interface's
bare name (`run`), not by its fully qualified WIT path:

```zig
const std = @import("std");
const bindings = @import("bindings");

comptime {
    _ = bindings;
}

pub const wit_exports = struct {
    pub const run = struct {
        pub fn run() bindings.run_run_result {
            const stdout = bindings.wasi_cli_stdout.get_stdout();
            defer bindings.wasi_io_streams.resources.output_stream.drop(stdout);
            _ = bindings.wasi_io_streams.resources.output_stream
                .blocking_write_and_flush(stdout, "hello from zig\n");
            return .{ .ok = {} };
        }
    };
};
```

The exact names — `bindings.run_run_result`, the nested
`wit_exports.run.run`, the `wasi_cli_stdout` /
`wasi_io_streams` module paths — are what the generator emits.
Open `bindings.zig` after step 3 if you need to confirm a name:
type definitions are at the top, the `wit_exports` reference and
`export fn` block are near the bottom, and you can grep for any
WIT identifier to find its Zig counterpart.

For a deeper look at what these bindings look like, the existing
`examples/http-get/component.zig` is a worked guest that uses the
same wasi-io / wasi-cli surface for streaming a response body to
stdout.

### 5. Build and run

The easiest path is to wire this into your `build.zig` following
the http-get template — see [build-integration.md](build-integration.md).
The manual sequence, for completeness, is:

```sh
zig build-exe -fno-entry -OReleaseSmall -target wasm32-freestanding -rdynamic \
  --dep zig_wasi_components --dep bindings -Mroot=tmp/hello-wasi/component.zig \
  -Mzig_wasi_components=src/root.zig \
  --dep zig_wasi_components -Mbindings=tmp/hello-wasi/bindings.zig \
  --name hello-wasi \
  -femit-bin=tmp/hello-wasi/hello.core.wasm

wasm-tools component embed tmp/hello-wasi tmp/hello-wasi/hello.core.wasm \
  --world demo:hellowasi/hello-wasi \
  -o tmp/hello-wasi/hello.embedded.wasm
wasm-tools component new tmp/hello-wasi/hello.embedded.wasm \
  -o tmp/hello-wasi/hello.component.wasm

wasmtime run tmp/hello-wasi/hello.component.wasm
# => hello from zig
```

`wasm-tools component embed` takes the *directory* (not the
flattened resolved file) and a `--world demo:hellowasi/hello-wasi`
selector so it knows which world out of which package to embed.

## Generating bindings for just one interface

If you only need types from one WIT interface — say, you want to
inspect what UDP socket bindings look like without building the
component — declare a tiny world that imports only that interface.

```sh
mkdir -p tmp/udp
cp -r examples/http-get/wit/deps tmp/udp/deps

cat > tmp/udp/world.wit <<'EOF'
package local:udp-demo;

world udp-only {
    import wasi:sockets/udp@0.2.6;
    import wasi:sockets/udp-create-socket@0.2.6;
    import wasi:sockets/network@0.2.6;
    import wasi:sockets/instance-network@0.2.6;
}
EOF

wasm-tools component wit tmp/udp > tmp/udp/resolved.wit
./zig-out/bin/zig_wasi_components gen tmp/udp/resolved.wit udp-only \
  > tmp/udp/bindings.zig
```

The result has the UDP socket type, the IP address structs, the
network handle, and host-import wrappers for every method, with no
unrelated wasi-http or wasi-cli surface dragged in.

## Why interface-only WIT files do not work directly

The error you get if you try to feed `gen` an interface file
(`wasi/sockets/udp.wit`, `wasi/io/streams.wit`, etc.) is
`WorldNotFound`, because `gen` operates on a world. WIT interface
files declare interfaces; only world files declare worlds. The CLI
prints an explicit error listing the available worlds and
interfaces, and suggests using `dump` to inspect the file.

Even if the file did contain a world, the interface depends on
`wasi:io` types that are not in the same file. Without the
flattening step you would hit type-not-found errors in the
generator. Always pass either a world file that already inlines its
deps, or the multi-package output of `wasm-tools component wit`.

## What about WIT format conversion?

`wasm-tools component wit` also accepts a single multi-package WIT
file as input and reprints it. If your WIT does not have a `deps/`
tree but is already in flattened form (for example, fetched from a
component's `component-type` custom section), you can feed it
directly to `gen` without flattening. The intermediate `wasm-tools`
call is only there to do the dep resolution.
