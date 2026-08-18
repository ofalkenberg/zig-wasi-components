# Getting started

This page lists the required tools.
It explains how to build the bundled examples.
It also shows what their output should look like.

If these steps work, your toolchain works.
You can then continue to [your first component](workflow.md).

## What you need

- **Zig 0.17.0-dev** (specifically `0.17.0-dev.639+284ab0ad8` or newer).
  The project tracks Zig master.
  It uses the new `Io` namespace, unmanaged `ArrayList`, and `std.process.Init`.
  An older compiler cannot parse `src/main.zig`.
- **`wasm-tools`** on your `PATH`.
  The build script invokes the `embed`, `new`, and `wit` subcommands.
  Install it with `cargo install wasm-tools` if needed.
- **Wasmtime** to run components.
  Any 24+ release works.
  The `http-get` demo needs 32+ for `wasi:http` outbound support.
- **A Rust toolchain** only for demos with a Rust host.
  These are `greeter`, `dual`, `resource`, `async-basic`, and `stream-demo`.
  It is not needed to build or use the code generator.
- **`cargo-component`** for the Rust half of the `dual` demo.
  Install it with `cargo install cargo-component`.

## Build the codegen CLI

```sh
zig build
```

This produces `zig-out/bin/zig_wasi_components`.
Every other build step uses this CLI.
You will also use it directly for bindings in your own projects.

Running it without arguments prints a short usage line.
See the [CLI reference](cli.md) for details.

## Run the unit tests

```sh
zig build test
```

The parser and code generator each have a test module.
They run in parallel.
Expect the tests to take a few seconds.

Tests cover every WIT type that the code generator lifts and lowers.
They cover both directions.
They also cover edge cases, including indirect parameter areas and fixed-length lists.
Resource methods with more than 16 flat parameters are covered too.

A parser failure often means an upstream WIT grammar addition needs porting.
Check the WASIp3 specification.

## Build the bundled examples

Eight example components ship in `examples/`.
Each demonstrates a different canonical-ABI feature.

```sh
zig build demo         # zig-out/wasm/greeter.component.wasm
zig build dual         # zig-out/wasm/math.component.wasm
zig build resource     # zig-out/wasm/counts.component.wasm
zig build http-get     # zig-out/wasm/http-get.component.wasm
zig build async-basic  # zig-out/wasm/async-basic.component.wasm
zig build stream-demo  # zig-out/wasm/stream-demo.component.wasm
zig build wasi-demo    # zig-out/wasm/wasi-demo.component.wasm
zig build wasi-demo-p3 # zig-out/wasm/wasi-demo-p3.component.wasm
```

Run each example independently.
None of the eight build steps depends on another.
`zig build` without an argument does not build them.
The default build therefore stays fast.

### The greeter demo

The greeter provides the most thorough type coverage.
It exercises records, lists, variants, options, results, tuples, and flags.
It also covers indirect parameters and results.
Both `char` and `string` directions are tested.
The guest calls a host-provided `log` import.

The greeter imports `log`, `origin`, and `label-point` from its host.
It cannot run standalone with `wasmtime run --invoke`.
Wasmtime refuses to start components with unsatisfied imports.
Use the bundled Rust host instead.
It supplies those imports and exercises every export.

```sh
cargo build --release --manifest-path examples/greeter/rust-host/Cargo.toml
./examples/greeter/rust-host/target/release/host \
  zig-out/wasm/greeter.component.wasm
```

The Rust host prints one line for every export result.
It ends with `OK: Rust ↔ Zig component interop (both directions) verified.`
That line confirms a working component.

### The dual demo

`dual` is the smallest end-to-end test.
Its `math` world has one function: `export add: func(a: u32, b: u32) -> u32`.

The same WIT produces two interchangeable components.
One uses Zig.
The other uses Rust with `cargo-component`.
One Rust host loads either component.

```sh
cargo build --release --manifest-path examples/dual/host/Cargo.toml
(cd examples/dual/rust-impl && cargo component build --release)

./examples/dual/host/target/release/dual-host \
  zig-out/wasm/math.component.wasm \
  examples/dual/rust-impl/target/wasm32-wasip1/release/math.wasm
```

The host calls `add(2, 3)` on both components.
It verifies that both return `5`.
This confirms that Zig bindings are wire-compatible with Rust bindings for the same WIT.

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
The Rust host creates counters, mutates them, and verifies their state.
It then lets each implicit `drop` run at the end of the resource's scope.
See [the resources doc](resources.md) for the full pattern.

### The http-get demo

This is the largest example.
The component requests `https://example.com/`.
It streams the response body to stdout.
It uses generated `wasi:http`, `wasi:io`, and `wasi:cli` bindings.

```sh
zig build http-get
wasmtime run -S http=y zig-out/wasm/http-get.component.wasm
```

The first `wasm-tools` call resolves the world and every transitive dependency.
It reads dependencies from `examples/http-get/wit/deps/`.
It creates one multi-package WIT file.
`zig_wasi_components gen` receives that file.

The result is a roughly 30 KB `bindings.zig` file.
It covers the wasi-0.2.6 surface needed by `world client`.
See [the WASI doc](wasi.md) for this toolchain pattern.

### The async-basic demo

`async-basic` exercises the async-with-callback canonical ABI in both directions.
The Zig guest exports four `async func` bindings: `succ`, `measure`, `greet`, and `promise`.
They use the complete `[async-lift]`, `[callback]`, and `[task-return]` flow.
A fifth function, `relay`, calls an async host import through `[async-lower]`.
A tokio-based Rust host drives the example.

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
relay(7) = 71 (host tick → 70, guest +1 → 71)
greet("wasmtime") -> "Hello, wasmtime!"
promise(21) -> 42
OK
```

The host instantiates the component with `instantiate_async`.
It runs calls under `run_concurrent`.
It attaches stream and future consumers to drain `greet` and `promise`.
This output confirms that async export and import paths work.

### The stream-demo demo

`async-basic` already returns a `stream<u8>`.
Bytes use the canonical ABI fast path.
`stream-demo` demonstrates typed, non-byte streams instead.

The guest exports `squares -> stream<u32>` and `fibonacci -> stream<u64>`.
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
It targets a real `wasi:cli/command@0.2.6` world.
One guest exercises clocks, randomness, stdio, environment, and terminal probes.
It also performs a filesystem round trip, DNS lookup, and live HTTPS GET.

```sh
zig build wasi-demo
wasmtime run \
    -S http=y -S allow-ip-name-lookup \
    --env HOME=/home/user --dir /tmp \
    zig-out/wasm/wasi-demo.component.wasm hello world
```

### The wasi-demo-p3 demo

`wasi-demo-p3` covers the same features through the `wasi3` module.
It targets the final `wasi:cli/command@0.3.1` world.
It covers stream-based stdio, file I/O, and async clock sleeps.
It also lists a `stream<directory-entry>` and performs DNS.

The build also checks an HTTP guest against `wasi:http/service@0.3.1`.
It validates both components with `wasm-tools component new`.

```sh
zig build wasi-demo-p3
```

Wasmtime 46 and later implement the final WASI 0.3.0 interfaces.
They link 0.3.1 imports through semver-compatible resolution.
The demo runs without changes.
See [the `wasi` module doc](wasi-module.md) for the run command.

Wasmtime 45 and earlier only vendor the March 2026 release candidate.
They cannot link a final-0.3.x component.

## Where to next

- Pick a WIT file to bind, even a tiny one.
  Follow [your first component](workflow.md).
  It gives the most direct explanation of the full workflow.
- Rust hosts can copy the structure in `examples/greeter/rust-host/` or `examples/resource/host/`.
