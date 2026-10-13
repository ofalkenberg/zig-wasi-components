# Getting started

Build and run the bundled examples to check your setup.
This page covers the tools you'll need and the output you should see.

Once these steps work, your toolchain is ready.
Then you can build [your first component](workflow.md).

## What you need

- **Zig master**, `0.17.0-dev.2119+1bc892110` or newer.
  The project tracks Zig master and uses the new `Io` namespace, unmanaged `ArrayList`, and `std.process.Init`.
  An older compiler won't build it.
- **`wasm-tools`** on your `PATH`.
  The build script calls the `embed`, `new`, and `wit` subcommands.
  Install it with `cargo install wasm-tools` if needed.
- **Wasmtime** to run components.
  Wasmtime 47 or newer runs everything on this page and the regression tests.
  If you're stuck on an older release, keep these minimum versions in mind:

  - `wasmtime run --invoke`, used in the [first component](workflow.md) guide, needs 33 or newer.
  - `wasi-demo-p3` needs 46 or newer.

  The Rust hosts embed their own copy of Wasmtime, so they don't care which CLI you have installed.
- **A Rust toolchain** only for demos with a Rust host.
  You don't need it to build or use the code generator.
  The demos that need it are:

  - `greeter`
  - `dual`
  - `resource`
  - `async-basic`
  - `stream-demo`
- **`cargo-component`** for the Rust half of the `dual` demo.
  Install it with `cargo install cargo-component`.

## Build the codegen CLI

```sh
zig build
```

This produces `zig-out/bin/zig_wasi_components`.
The example build steps use it to generate their bindings, and you'll use it for your own projects too.

Running it without arguments prints a short usage message.
See the [CLI reference](cli.md) for details.

## Run the unit tests

```sh
zig build test
```

Two test binaries run in parallel.
One covers the CLI, and the other covers the library:

- parser
- code generator
- ABI runtime
- WASI helpers

Expect them to take a few seconds.

The code generator tests check the generated source for every major WIT construct, in both directions.
They also cover edge cases such as indirect parameter areas, fixed-length lists, and resource methods with more than 16 flat parameters.

To compile and run the component regressions too, you'll need these on PATH:

- Zig
- Python 3
- `wasm-tools`
- Wasmtime 47 or newer

```sh
zig build test-components
```

This builds the fixtures for `tests/components.py` in Debug and ReleaseSmall.
It checks generated bindings, component validation, and runtime values across
component boundaries.
See [the regression notes](../tests/README.md) for the reproduced failures and
coverage limits.

## Build the bundled examples

You'll find eight example components in `examples/`.
Each shows a different canonical-ABI feature.

```sh
zig build demo         # zig-out/wasm/greeter.component.wasm
zig build dual         # zig-out/wasm/math.component.wasm
zig build resource     # zig-out/wasm/counts.component.wasm
zig build http-get     # zig-out/wasm/http-get.component.wasm
zig build async-basic  # zig-out/wasm/async-basic.component.wasm
zig build stream-demo  # zig-out/wasm/stream-demo.component.wasm
zig build wasi-demo    # zig-out/wasm/wasi-demo.component.wasm
zig build wasi-demo-p3 # zig-out/wasm/wasi-demo-p3.component.wasm
                       # and zig-out/wasm/wasi-http-check.component.wasm
```

You can run each example on its own.
None of the eight build steps depends on another.
`zig build` without an argument doesn't build them, so the default build stays fast.

### The greeter demo

The greeter covers the most types:

- records
- lists
- variants
- options
- results
- tuples
- flags

It also tests indirect parameters and results, plus both directions for `char` and `string`.
The guest calls a `log` import provided by the host.

The greeter needs three imports from its host:

- `log`
- `origin`
- `label-point`

It can't run on its own with `wasmtime run --invoke` because Wasmtime refuses to start components with unsatisfied imports.
Use the bundled Rust host instead.

```sh
cargo build --release --manifest-path examples/greeter/rust-host/Cargo.toml
./examples/greeter/rust-host/target/release/host \
  zig-out/wasm/greeter.component.wasm
```

The Rust host supplies those imports, calls every export, and prints one line for each result.
It ends with `OK: Rust <-> Zig component interop (both directions) verified.`
That line confirms a working component.

### The dual demo

`dual` is the smallest end-to-end test.
Its `math` world has one function: `export add: func(a: u32, b: u32) -> u32`.

The same WIT produces two interchangeable components: one in Zig and one in Rust with `cargo-component`.
The same Rust host can load either one.

```sh
cargo build --release --manifest-path examples/dual/host/Cargo.toml
(cd examples/dual/rust-impl && cargo component build --release)

./examples/dual/host/target/release/dual-host \
  zig-out/wasm/math.component.wasm \
  examples/dual/rust-impl/target/wasm32-wasip1/release/math.wasm
```

The host calls `add(2, 3)` on both components and checks that both return `5`.
That confirms the Zig and Rust bindings use the same wire format for the same WIT.

### The resource demo

`resource` tests the lifecycle of WIT resources.
It defines a `counter` resource with a constructor, two methods, an accessor, and an implicit destructor.

```wit
resource counter {
  constructor(initial: u32);
  increment: func();
  add: func(n: u32);
  get: func() -> u32;
}
```

The Zig implementation is in `examples/resource/component.zig`.
It fits on one screen.

The Rust host creates two counters, mutates them, and verifies their state.
It then drops both handles, which runs the Zig destructor.
See [the resources doc](resources.md) for the full pattern.

### The http-get demo

```sh
zig build http-get
wasmtime run -S http=y zig-out/wasm/http-get.component.wasm
```

The component requests `https://example.com/` and prints the status line and response body.
It talks to the host through generated bindings, with no hand-written glue:

- `wasi:http`
- `wasi:io`
- `wasi:cli`

The first `wasm-tools` call resolves the world and all its dependencies, including their dependencies, from `examples/http-get/wit/deps/`.
It puts all the packages in one WIT file and passes that file to `zig_wasi_components gen`.

The result is a roughly 350 KB `bindings.zig` file.
It covers the WASI 0.2.6 interfaces that `world client` needs.
See [the WASI doc](wasi.md) for this toolchain pattern.

### The async-basic demo

`async-basic` exercises the async-with-callback canonical ABI in both directions.
The Zig guest exports five `async func` functions:

- `succ`
- `measure`
- `greet`
- `promise`
- `relay`

They use the complete `[async-lift]`, `[callback]`, and `[task-return]` flow.
`relay` also calls the async host import `tick` through `[async-lower]`.
A Rust host using tokio runs the example.

```sh
zig build async-basic
cargo build --release --manifest-path examples/async-basic/rust-host/Cargo.toml
./examples/async-basic/rust-host/target/release/host \
  zig-out/wasm/async-basic.component.wasm
```

Expect a six-line transcript:

```
succ(41) = 42
measure("hello async") = 11
relay(7) = 71 (host tick -> 70, guest +1 -> 71)
greet("wasmtime") -> "Hello, wasmtime!"
promise(21) -> 42
OK
```

The host creates the component instance with `instantiate_async` and runs calls under `run_concurrent`.
It attaches stream and future consumers to read everything from `greet` and `promise`.
This output confirms that both async exports and async imports work.

### The stream-demo demo

`async-basic` already returns a `stream<u8>`, which the host reads directly as bytes.
`stream-demo` shows how typed, non-byte streams work.

The guest has two exports:

- `squares -> stream<u32>`
- `fibonacci -> stream<u64>`

Both use one generic producer.
This tests lifting four-byte and eight-byte elements.

```sh
zig build stream-demo
cargo build --release --manifest-path examples/stream-demo/rust-host/Cargo.toml
./examples/stream-demo/rust-host/target/release/host \
  zig-out/wasm/stream-demo.component.wasm
```

Expect:

```
squares(8)    -> [1, 4, 9, 16, 25, 36, 49, 64]
fibonacci(10) -> [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
OK
```

The Rust host drains both readable ends with one generic `Collector<T>`.
It reads typed items directly from the component-model `Source<T>`.

### The wasi-demo demo

`wasi-demo` uses the [`wasi` convenience module](wasi-module.md).
Its world includes the real `wasi:cli/command@0.2.6` world, plus the `wasi:http` client imports.
One guest tries all of these:

- clocks
- randomness
- stdio
- environment
- terminal probes
- a filesystem round trip
- a DNS lookup
- a live HTTPS GET

```sh
zig build wasi-demo
wasmtime run \
    -S http=y -S allow-ip-name-lookup \
    --env HOME=/home/user --dir /tmp \
    zig-out/wasm/wasi-demo.component.wasm hello world
```

### The wasi-demo-p3 demo

`wasi-demo-p3` does much the same through the `wasi3` module.
It targets the final `wasi:cli/command@0.3.2` world.
It covers:

- stream-based stdio
- file I/O
- async clock sleeps
- a `stream<directory-entry>` listing
- DNS

The same step builds a second guest, an HTTP service for `wasi:http/service@0.3.2` that makes its own outbound request.
Both components are validated with `wasm-tools component new`.

```sh
zig build wasi-demo-p3
```

Wasmtime 46 and later run the demo without changes.
See [the `wasi` module doc](wasi-module.md) for the run command.

Wasmtime 45 and earlier can't link a WASI 0.3.2 component.

## Where to next

- Pick a WIT file to bind, even a tiny one.
  Follow [your first component](workflow.md).
  It's the most direct walkthrough of the whole process.
- Rust hosts can copy the structure in `examples/greeter/rust-host/` or `examples/resource/host/`.
