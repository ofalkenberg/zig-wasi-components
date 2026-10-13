# Working with WASI worlds

The bundled `wasi:cli`, `wasi:http`, `wasi:io`, `wasi:filesystem`, and
related packages are not single files. Each package ships as a
directory of `.wit` files. Those files `use` types from sibling
packages.

The `gen` subcommand reads one WIT file at a time. It does not follow a
`deps/` tree. Bindings for WASI therefore need one extra step. Flatten
the world and every transitive dependency into one file. Then run
`gen` on the flattened output.

This page explains the workflow and its steps. It also shows a
component that targets `wasi:cli/run`.

## The recipe

```sh
wasm-tools component wit <wit-dir> > resolved.wit
zig_wasi_components gen resolved.wit <world-name> > bindings.zig
```

`wasm-tools component wit` walks the directory and resolves every
`use foo:bar/baz` reference.
It prints your package plus every package found under `deps/` as a
single multi-package WIT document, whether your world uses them or not.
The generator handles this block form natively.

The `<wit-dir>` argument must point at a directory. Its top level must
be the package that declares your world. Place WASI dependencies in a
`deps/` subdirectory beside that top-level file. For example:

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

`wasm-tools` finds the dependencies automatically. You do not need to
pass them explicitly.

## Worked example: a `wasi:cli` component

We will build a component that exports `wasi:cli/run`, the entry
point Wasmtime invokes when you run a component as a command.

### 1. Stage the WIT tree

The fastest way to get the WASI dependencies is to copy them from a
bundled example. We use the http-get example because it already has
the full 0.2.6 dependency tree.

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

`include` pulls in every interface that the named world imports. Your
component can therefore use `wasi:cli/stdout`, `wasi:io/streams`, and
the rest without listing each interface. The single `export` line
allows Wasmtime to call your `run` function.

### 3. Flatten and generate

```sh
wasm-tools component wit tmp/hello-wasi > tmp/hello-wasi-resolved.wit
./zig-out/bin/zig_wasi_components gen tmp/hello-wasi-resolved.wit hello-wasi \
  > tmp/hello-wasi/bindings.zig
```

The flattened file is about 135 KB, mostly doc comments.
The generated bindings come to about 230 KB.
Most of that is `wasi:filesystem` and `wasi:sockets`, which
`include wasi:cli/imports` pulls in, followed by the `wasi:io` stream
API.

Keep the resolved file *outside* the WIT package directory. If you
place it inside `tmp/hello-wasi/`, the next `wasm-tools component
embed` sees two declarations of `world hello-wasi`. One is in
`world.wit`. The other is in `resolved.wit`.

The command then fails with `duplicate item named hello-wasi`. Put
generated artifacts that duplicate WIT content outside the WIT source
tree.

### 4. Implement `run`

`wasi:cli/run` is an interface with a single `run` function.
In `wit_exports`, the interface becomes a nested struct named after its
bare name (`run`), not the fully qualified WIT path:

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

The generator emits names such as `bindings.run_run_result` and the
`wasi_cli_stdout` / `wasi_io_streams` namespaces.
It expects you to declare `wit_exports.run.run`.

Open `bindings.zig` after step 3 to confirm a name. Type definitions
are at the top. The `wit_exports` reference and `export fn` block are
near the bottom. You can also grep for a WIT identifier to find its
Zig counterpart.

For a deeper look at the bindings, see the worked guest at
`examples/http-get/component.zig`. It uses the same wasi-io /
wasi-cli surface to stream a response body to stdout.

### 5. Build and run

The easiest path is to wire this into `build.zig` with the http-get
template. See [build-integration.md](build-integration.md).

For completeness, the manual sequence is:

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

`wasm-tools component embed` accepts either the directory or the
flattened file.
`--world demo:hellowasi/hello-wasi` names the world explicitly.
You can leave it out when your package declares a single world, but
spelling it out keeps the command working once you add a second one.

## Generating bindings for just one interface

If you only need types from one WIT interface, declare a tiny world
that imports that interface. For example, this helps when you want to
inspect UDP socket bindings without building a component.

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

wasm-tools component wit tmp/udp > tmp/udp-resolved.wit
./zig-out/bin/zig_wasi_components gen tmp/udp-resolved.wit udp-only \
  > tmp/udp-bindings.zig
```

The result includes the UDP socket type, IP address structs, and the
network handle, plus the `wasi:io/poll` pollable they depend on.
It also includes host-import wrappers for every method.
No unrelated wasi-http or wasi-cli surface is included.

As in the previous section, the resolved file stays outside `tmp/udp/`.
Otherwise the next `wasm-tools component wit tmp/udp` fails with
`duplicate item named udp-only`.

## Why interface-only WIT files do not work directly

Passing an interface file to `gen` returns `WorldNotFound`.
Examples include `deps/sockets/udp.wit` and `deps/io/streams.wit`.
The generator operates on a world.
WIT interface files declare interfaces.
Only world files declare worlds.

When the file declares no worlds, the CLI lists its interfaces and
suggests running `dump` on it.
When it does declare worlds, the error lists those instead.

Even a file that contains a world usually refers to other packages.
Without flattening, `gen` fails with `error: UnknownType` as soon as
something `use`s a type from another package.
Worse, a world that only imports or exports foreign interfaces
generates without complaint, and every one of those imports and
exports is silently left out.
Always pass a world file that already inlines its dependencies, or the
multi-package output of `wasm-tools component wit`.

## What about WIT format conversion?

`wasm-tools component wit` also accepts and reprints a single
multi-package WIT file. If your WIT has no `deps/` tree and is already
flattened, pass it directly to `gen`. For example, this applies to WIT
from a component's `component-type` custom section.

The intermediate `wasm-tools` call only resolves dependencies.
