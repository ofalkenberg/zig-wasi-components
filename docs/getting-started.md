# Getting started

This page covers what you need installed, how to build the bundled
examples, and what their output should look like. If everything in here
works, you have a working toolchain and can move on to
[your first component](workflow.md).

## What you need

- **Zig 0.17.0-dev** (specifically `0.17.0-dev.639+284ab0ad8` or newer).
  The project tracks Zig master and uses APIs from the new `Io`
  namespace, unmanaged `ArrayList`, and the `std.process.Init` entry
  point. An older compiler will not parse `src/main.zig`.
- **`wasm-tools`** on your `PATH`. The `embed`, `new`, and `wit`
  subcommands are invoked by the build script. Install with
  `cargo install wasm-tools` if you do not already have it.
- **Wasmtime**, if you want to actually run the components. Any 24+
  release will do; the `http-get` demo needs 32+ for the `wasi:http`
  outbound surface.
- **A Rust toolchain** is only needed for the demos that have a Rust
  host (`greeter`, `dual`, `resource`, `async-basic`, `stream-demo`).
  It is not needed to build or use the codegen itself.
- **`cargo-component`**, additionally, for the Rust half of the
  `dual` demo. Install with `cargo install cargo-component`.

## Build the codegen CLI

```sh
zig build
```

This produces `zig-out/bin/zig_wasi_components`, the CLI used by every
other build step (and the one you will use directly when generating
bindings for your own projects). Running it with no arguments prints a
short usage line; see the [CLI reference](cli.md) for full details.

## Run the unit tests

```sh
zig build test
```

The parser and codegen each have their own test module. Both run in
parallel; expect a couple of seconds total. Tests cover every WIT type
the codegen knows how to lift and lower in both directions, plus a
catalog of edge cases (indirect parameter areas, fixed-length lists,
resource methods with more than 16 flat params, and so on).

If a parser test fails, the most likely cause is an upstream WIT grammar
addition that has not been ported yet — check the WASIp3 spec.

## Build the bundled examples

Eight example components ship in `examples/`. Each demonstrates a
different slice of the canonical ABI.

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

You can run any one of them in isolation. None of the eight steps depend
on each other, and `zig build` with no argument will not build any of
them (so the default build stays fast).

### The greeter demo

The greeter is the most thorough type-coverage example. It exercises
records, lists, variants, options, results, tuples, flags, indirect
parameters, indirect results, both directions of `char` and `string`,
and a host-provided `log` import the guest calls back into.

The greeter has host-provided imports (`log`, `origin`,
`label-point`), so running it standalone with
`wasmtime run --invoke` does not work — Wasmtime refuses to start a
component with unsatisfied imports. Use the bundled Rust host
instead, which provides those imports and exercises every export:

```sh
cargo build --release --manifest-path examples/greeter/rust-host/Cargo.toml
./examples/greeter/rust-host/target/release/host \
  zig-out/wasm/greeter.component.wasm
```

The Rust host prints one line per export with the result, and
finishes with `OK — Rust ↔ Zig component interop (both directions)
verified.` If you see that line, you have a working component.

### The dual demo

`dual` is the smallest possible end-to-end test: a one-function `math`
world with `export add: func(a: u32, b: u32) -> u32`. The same WIT
compiles to two interchangeable components — one written in Zig, one
written in Rust with `cargo-component`. A single Rust host loads
whichever you point it at.

```sh
cargo build --release --manifest-path examples/dual/host/Cargo.toml
(cd examples/dual/rust-impl && cargo component build --release)

./examples/dual/host/target/release/dual-host \
  zig-out/wasm/math.component.wasm \
  examples/dual/rust-impl/target/wasm32-wasip1/release/math.wasm
```

The host calls `add(2, 3)` against both components and verifies they
both answer `5`. This is the test that proves the Zig binding is wire-
compatible with the canonical Rust binding for the same WIT.

### The resource demo

`resource` is the lifecycle test for WIT resources. It defines a
`counter` resource with a constructor, two methods, an accessor, and an
implicit destructor:

```wit
resource counter {
  constructor(initial: u32);
  increment: func();
  add: func(n: u32);
  get: func() -> u32;
}
```

The Zig implementation lives in `examples/resource/component.zig` and
fits on one screen. The Rust host creates a few counters, mutates them,
verifies their state, and lets the implicit `drop` run as they go out
of scope. See [the resources doc](resources.md) for the full
implementation pattern.

### The http-get demo

This is the largest example. The component reaches out to
`https://example.com/`, streams the response body, and writes it to
stdout — all via generated `wasi:http`, `wasi:io`, and `wasi:cli`
bindings.

```sh
zig build http-get
wasmtime run -S http=y zig-out/wasm/http-get.component.wasm
```

The first wasm-tools call resolves the world plus every transitive dep
from `examples/http-get/wit/deps/` into a single multi-package WIT file,
which is then handed to `zig_wasi_components gen`. The output is a
~30KB `bindings.zig` covering the entire wasi-0.2.6 surface needed by
`world client`. See [the WASI doc](wasi.md) for the toolchain pattern.

### The async-basic demo

`async-basic` exercises the async-with-callback canonical ABI in both
directions. The Zig guest exports four `async func` bindings (`succ`,
`measure`, `greet`, `promise`) that go through the full
`[async-lift]` / `[callback]` / `[task-return]` machinery, and a
fifth (`relay`) that calls an async host import via `[async-lower]`.
A tokio-based Rust host drives the whole thing:

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

The host instantiates the component with `instantiate_async`, runs
its calls under `run_concurrent`, and attaches stream and future
consumers to drain the `greet` and `promise` results. If that line
prints, async export *and* async import paths are wired correctly.

### The stream-demo demo

`async-basic` already returns a `stream<u8>`, but bytes take the
canonical ABI's fast path. `stream-demo` is the example for typed,
non-byte streams: the guest exports `squares -> stream<u32>` and
`fibonacci -> stream<u64>`, both built from one generic producer, so
the same machinery has to lift four- and eight-byte elements.

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

The Rust host drains both readable ends with a single generic
`Collector<T>` that reads typed items straight out of the
component-model `Source<T>`.

### The wasi-demo demo

`wasi-demo` drives the [`wasi` convenience module](wasi-module.md)
against a real `wasi:cli/command@0.2.6` world: clocks, randomness,
stdio, environment, terminal probes, a filesystem round-trip, a DNS
lookup, and a live HTTPS GET, all in one guest.

```sh
zig build wasi-demo
wasmtime run \
    -S http=y -S allow-ip-name-lookup \
    --env HOME=/home/user --dir /tmp \
    zig-out/wasm/wasi-demo.component.wasm hello world
```

### The wasi-demo-p3 demo

`wasi-demo-p3` is the same tour against the final
`wasi:cli/command@0.3.0` world via the `wasi3` module: stream-based
stdio and file I/O, async clock sleeps, a `stream<directory-entry>`
listing, and DNS. The step also compile-checks an http guest against
`wasi:http/service@0.3.0` and validates both components with
`wasm-tools component new`.

```sh
zig build wasi-demo-p3
```

Released wasmtimes still vendor the March 2026 release candidate of
the WASI 0.3 packages, so the final-`@0.3.0` component does not link
against them yet — see [the `wasi` module doc](wasi-module.md) for
the details and the run command to use once a runtime ships the
final packages.

## Where to next

- Pick a WIT file you want to bind, even something tiny, and follow
  [your first component](workflow.md). It is the most direct path to
  understanding how everything fits together.
- If you intend to host the resulting components in Rust, the
  Rust-side code in `examples/greeter/rust-host/` and
  `examples/resource/host/` is good shape to copy.
