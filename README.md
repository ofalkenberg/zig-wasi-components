# zig-wasi-components

WebAssembly Component Model support in Zig.

Given a WIT schema, this project lets you write a Zig core module.
It wraps that module into a real component (`.wasm` validated by
`wasm-tools`).
The component can call Rust hosts through the canonical ABI.
Rust hosts can call the component through the same ABI.

The build pipeline mirrors `cargo-component` for Rust.
A small code generator emits Zig source from WIT.
The component compiles to `wasm32-freestanding`.
Then `wasm-tools component embed` and `component new` turn the core
module into a component.

## Documentation

Full user-facing documentation lives in [`docs/`](docs/README.md).

Start with [getting-started](docs/getting-started.md) for prerequisites
and a runnable tour of the bundled demos.
Then read [your first component](docs/workflow.md) for a step-by-step
walkthrough of building your own component.

## Quick start

```bash
zig build demo         # builds zig-out/wasm/greeter.component.wasm
zig build dual         # builds zig-out/wasm/math.component.wasm
zig build resource     # builds zig-out/wasm/counts.component.wasm
zig build http-get     # builds zig-out/wasm/http-get.component.wasm
zig build async-basic  # builds zig-out/wasm/async-basic.component.wasm
zig build stream-demo  # builds zig-out/wasm/stream-demo.component.wasm
zig build wasi-demo    # builds zig-out/wasm/wasi-demo.component.wasm
zig build wasi-demo-p3 # builds zig-out/wasm/wasi-demo-p3.component.wasm (WASI 0.3.1)

# Run a component standalone via Wasmtime:
wasmtime run --invoke 'manhattan({x:-3, y:4})' \
  zig-out/wasm/greeter.component.wasm
# => 7

# Run the Rust↔Zig greeter demo (Rust host calls into Zig
# component; the Zig component also calls back into the host):
cargo build --release --manifest-path examples/greeter/rust-host/Cargo.toml
./examples/greeter/rust-host/target/release/host \
  zig-out/wasm/greeter.component.wasm

# Run the dual-language demo (one Rust host, two components built
# from the same WIT, one in Zig and one with cargo-component):
cargo build --release --manifest-path examples/dual/host/Cargo.toml
(cd examples/dual/rust-impl && cargo component build --release)
./examples/dual/host/target/release/dual-host \
  zig-out/wasm/math.component.wasm \
  examples/dual/rust-impl/target/wasm32-wasip1/release/math.wasm

# Run the resource demo (constructor / methods / drop lifecycle):
cargo build --release --manifest-path examples/resource/host/Cargo.toml
./examples/resource/host/target/release/counts-host \
  zig-out/wasm/counts.component.wasm

# Run the wasi:http GET example through Wasmtime directly:
wasmtime run -S http=y zig-out/wasm/http-get.component.wasm

# Run the async demo (Rust tokio host calls async Zig exports and
# the Zig guest in turn calls an async Rust import):
cargo build --release --manifest-path examples/async-basic/rust-host/Cargo.toml
./examples/async-basic/rust-host/target/release/host \
  zig-out/wasm/async-basic.component.wasm

# Run the typed-stream demo (Zig guest streams u32 and u64 values,
# the Rust host drains and verifies each readable end):
cargo build --release --manifest-path examples/stream-demo/rust-host/Cargo.toml
./examples/stream-demo/rust-host/target/release/host \
  zig-out/wasm/stream-demo.component.wasm
```

Expected output:

```
greet("Hello from Rust!") = 16
sum([1,2,3,4,5,100]) = 115
manhattan(point { x: -3, y: 4 }) = 7
format-greeting("world") = "Hi, world!"
captured logs: ["hello Hello from Rust!"]
OK: Rust ↔ Zig component interop is verified in both directions.
```

## Layout

```
src/
  wit.zig       WIT parser (WASIp3-scoped grammar)
  abi.zig       Runtime helpers (cabi_realloc backing)
  codegen.zig   Zig source generator from a parsed WIT world
  wasi.zig      `Wasi(bindings)` convenience layer for WASI 0.2
  wasi3.zig     `Wasi3(bindings)` convenience layer for WASI 0.3
  wasi_common.zig  Pieces shared by both convenience layers
  main.zig      `zig-wit dump|gen` CLI
examples/
  greeter/          Records, lists, variants, options, results, tuples,
                    flags, char, indirect params/results.
  dual/             Same WIT, one impl in Zig and one in Rust.
  resource/         A `counter` resource with the full
                    constructor/methods/drop lifecycle.
  http-get/         A wasi:http GET client. The whole wasi:http /
                    wasi:io / wasi:cli surface is fed through the
                    codegen via `wasm-tools component wit`; the
                    guest contains zero hand-written `@extern`s.
  async-basic/      Async-with-callback canonical ABI end-to-end:
                    `[async-lift]` exports (`succ`, `measure`,
                    `greet`, `promise`, `relay`) and an
                    `[async-lower]` import (`clock.tick`). The Rust
                    host uses `instantiate_async` + `run_concurrent`.
  stream-demo/      Typed `stream<T>` end-to-end: the guest streams
                    `stream<u32>` squares and `stream<u64>` Fibonacci
                    numbers through one generic producer, exercising
                    the non-byte stream path that `async-basic`'s
                    `stream<u8>` skips.
  wasi-demo/        Uses the `zig_wasi_components.wasi` convenience
                    module to exercise clocks, randomness, stdio,
                    environment, terminal probes, a filesystem
                    round-trip, a DNS lookup, and an HTTPS GET in a
                    single guest.
  wasi-demo-p3/     The same tour against WASI 0.3.1 via the
                    `zig_wasi_components.wasi3` module: stream-based
                    stdio and file I/O, async clock sleeps, a
                    `stream<directory-entry>` listing, DNS, plus a
                    `wasi:http/service@0.3.1` guest that serves real
                    requests under `wasmtime serve` and makes an
                    outbound fetch through the 0.3 http client
                    wrappers on each one.
```

## What works

The parser ingests the full WIT surface used by real WASI 0.2.x and
0.3.x packages:

- packages with `ns:name@x.y.z[-suffix]` versions, file-scope `use`
- interfaces and worlds, with `include ... with { a as b }`
- cross-package `use foo:bar/baz@1.0.0.{x, y}`
- `record`, `variant`, `enum`, `flags`, type aliases
- `resource` with constructors, methods, static methods,
  `own<T>` / `borrow<T>`
- `stream<T>`, `future<T>`, `error-context`
- `map<K, V>` (WASI 0.3.1), bound as a slice of key/value pairs
  through its canonical `list<tuple<K, V>>` despecialization
- `async` functions
- `@since(version = ...)` / `@unstable(feature = ...)` /
  `@deprecated(version = ...)` gates
- `@external-id("...")` annotations (WASI 0.3.1)
- inline interfaces in world imports/exports
- plain-named interface imports/exports (WASI 0.3.1):
  `import users: store;` and `import catalog: store;` bind the same
  interface twice under distinct names, each with its own generated
  namespace

The project has been validated against the published WIT files for the
full `wasi:cli`, `wasi:io`, `wasi:clocks`, `wasi:random`,
`wasi:sockets`, `wasi:filesystem`, and `wasi:http` set at `0.2.12`.
This includes the `exit-with-code` call and the unstable
`wasi:clocks/timezone` interface.

It has also been validated against the six final WASI `0.3.0` and
`0.3.1` packages.
Every world in those packages generates bindings that compile.
Components built from the generated `wasi:cli/command@0.3.1` and
`wasi:http/service@0.3.1` bindings pass `wasm-tools component new`
validation.
They also run end to end under wasmtime 46+.

Use `wasmtime run -S p3` for the command world.
Use `wasmtime serve -S p3,cli` for the HTTP service.
Outbound requests are included.
Wasmtime links the 0.3.1 imports against its 0.3.0 implementations
through semver-compatible resolution.

The stream and future canon intrinsics are generated for every function
that uses `stream<T>` or `future<T>`.
This includes async and sync functions.
It also includes top-level and resource methods.
Canonical-layout `lift` and `lower` helpers support compound payloads,
such as `directory-entry`.
This support makes the `wasi3` convenience layer usable from plain Zig.
It also supports the 0.3 stdio, filesystem, and HTTP APIs.

The code generator covers every WIT type in the table below.
It supports both directions.
It uses the specification's canonical memory layout for indirect
parameters and returns.
It also emits the required `cabi_realloc` and `cabi_post_*` entry
points.
The latter uses wit-component's current convention.
That naming lets wasmtime wire each function into `canon lift`.

| WIT type                                  | covered                 | demo                                             |
| ----------------------------------------- | ----------------------- | ------------------------------------------------ |
| primitives                                | ✓                       | `greeter`                                        |
| `char`                                    | ✓                       | `greeter/upper-char`                             |
| `string`                                  | ✓                       | `greeter/greet`, `format-greeting`, `log` import |
| `list<T>`                                 | ✓                       | `greeter/sum`, `total-distance`                  |
| `record`                                  | ✓                       | `greeter/manhattan`, `origin` import             |
| `variant`                                 | ✓                       | `greeter/classify`                               |
| `enum`, `flags` (≤32 labels)              | ✓                       | `greeter/perms-popcount`                         |
| `option<T>`                               | ✓                       | `greeter/maybe-double`                           |
| `result<T, E>` (return and parameter)     | ✓                       | `greeter/safe-divide`, `greeter/choose`          |
| `tuple<...>`                              | ✓                       | `greeter/pair`, `greeter/divmod`                 |
| indirect params (>16 flats)               | ✓                       | `greeter/sum-many`                               |
| indirect results (export and import)      | ✓                       | `greeter/format-greeting`, `origin` import       |
| `resource`                                | ✓                       | `resource/counter`                               |
| `stream<T>`, `future<T>`, `error-context` | ✓ (handle pass-through) | `tmp/streamworld.wit`                            |
| `async func(...)` exports                 | ✓                       | `async-basic/{succ,measure,greet,promise}`       |
| `async func(...)` imports                 | ✓                       | `async-basic/relay` (calls host's `clock.tick`)  |
| per-func `[stream-*-i]` / `[future-*-i]`  | ✓                       | `async-basic/{greet,promise}`                    |
| root async builtins (waitable-set, ...)   | ✓                       | used implicitly by async imports                 |

## What is still ahead

The canonical ABI surface that ships with WIT 0.2.x and 0.3.x is fully
covered in both directions.
The items below are corner cases.
They depend on upstream movement or lack a shipping consumer.

- **`list<T, N>` as a variant case payload** is wired through the ABI
  in every direction.
  This includes parameters, return types, record fields, and top-level
  aliases.
  It also projects to a single flat slot inside a variant arm.
  No WASIp2 or WASIp3 interface exercises the projection path.
  If you build a custom WIT that does, file an issue with the schema.
  We can then add a real demo.

- **Stream/future intrinsics for sync *exports*.** The per-function
  intrinsics namespaces are generated for imports, imported-resource
  methods, and async exports.
  A sync export or exported resource method may mention `stream<T>` or
  `future<T>`.
  It does not get an intrinsics namespace yet.
  No WASI world ships such a function.
  There is therefore no consumer to validate against.
  The async export shapes are fully supported.
  They include the eager function and typed state-machine forms.
  See [docs/bindings.md](docs/bindings.md).

- **HTTP request bodies in the `wasi3` blocking wrapper.** The 0.3
  host answers only after the request body stream is dropped.
  The body can only be written while `client.send` is in flight.
  A blocking helper cannot interleave those operations.
  Sending a body needs the state-machine async export form.
  `wasi3.http.Request` deliberately has no `body` field.
  The missing field makes this gap a compile error.

- **Flags with more than 32 labels.** The canonical-ABI specification
  caps flags at 32 labels (`assert(0 < n <= 32)` in `CanonicalABI.md`).
  We follow the specification.
  We return `error.Unsupported` past that boundary.

- **Multi-named result tuples.** WIT removed this form upstream.
  The parser rejects `func() -> (a: u32, b: string)`.
  Modern `wasm-tools` also rejects it.
  Use a `record` return type.
