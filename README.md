# zig-wasi-components

WebAssembly Component Model support in Zig. Given a WIT schema, this
project lets you write a Zig core module and have it wrapped into a
real component (`.wasm` validated by `wasm-tools`), able to call into
— and be called by — Rust hosts through the canonical ABI.

The build pipeline mirrors what `cargo-component` does for Rust: a
small code generator emits Zig source from WIT, the user's component
compiles that to `wasm32-freestanding`, and `wasm-tools component
embed` + `component new` turn the core module into a component.

## Documentation

Full user-facing documentation lives in [`docs/`](docs/README.md).
Start with [getting-started](docs/getting-started.md) for prerequisites
and a runnable tour of the bundled demos, then [your first
component](docs/workflow.md) for a step-by-step walkthrough of
building your own.

## Quick start

```bash
zig build demo         # builds zig-out/wasm/greeter.component.wasm
zig build dual         # builds zig-out/wasm/math.component.wasm
zig build resource     # builds zig-out/wasm/counts.component.wasm
zig build http-get     # builds zig-out/wasm/http-get.component.wasm
zig build async-basic  # builds zig-out/wasm/async-basic.component.wasm
zig build stream-demo  # builds zig-out/wasm/stream-demo.component.wasm
zig build wasi-demo    # builds zig-out/wasm/wasi-demo.component.wasm
zig build wasi-demo-p3 # builds zig-out/wasm/wasi-demo-p3.component.wasm (WASI 0.3.0)

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
# from the same WIT — one in Zig, one with cargo-component):
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
OK — Rust ↔ Zig component interop (both directions) verified.
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
  wasi-demo-p3/     The same tour against WASI 0.3.0 via the
                    `zig_wasi_components.wasi3` module: stream-based
                    stdio and file I/O, async clock sleeps, a
                    `stream<directory-entry>` listing, DNS — plus a
                    compile-checked `wasi:http/service@0.3.0` guest
                    driving the 0.3 http client wrappers.
```

## What works

The parser ingests the full WIT surface used by real WASI 0.2.x /
0.3.x packages:

- packages with `ns:name@x.y.z[-suffix]` versions, file-scope `use`
- interfaces and worlds, with `include ... with { a as b }`
- cross-package `use foo:bar/baz@1.0.0.{x, y}`
- `record`, `variant`, `enum`, `flags`, type aliases
- `resource` with constructors, methods, static methods,
  `own<T>` / `borrow<T>`
- `stream<T>`, `future<T>`, `error-context`
- `async` functions and named result tuples
- `@since(version = ...)` / `@unstable(feature = ...)` /
  `@deprecated(version = ...)` gates
- inline interfaces in world imports/exports

It has been validated against the published WIT files of the full
`wasi:cli`, `wasi:io`, `wasi:clocks`, `wasi:random`, `wasi:sockets`,
`wasi:filesystem` and `wasi:http` set at `0.2.12`, including the new
`exit-with-code` call and the unstable `wasi:clocks/timezone`
interface, and against the six final WASI `0.3.0` packages: every
world in them generates bindings that compile, and components built
from the generated `wasi:cli/command@0.3.0` and
`wasi:http/service@0.3.0` bindings pass `wasm-tools component new`
validation (the command world also runs under `wasmtime -S p3`).
The stream/future canon intrinsics are generated for *every*
function that traffics in `stream<T>` / `future<T>` — async or sync,
top-level or resource method — with canonical-layout `lift`/`lower`
helpers for compound payloads such as `directory-entry`, which is
what makes the `wasi3` convenience layer (and the 0.3 stdio/fs/http
APIs generally) usable from plain Zig.

The codegen covers every WIT type listed in the table below in
both directions, using the spec's canonical memory layout for
indirect parameters and indirect returns, plus the obligatory
`cabi_realloc` / `cabi_post_*` entry points (the latter named per
wit-component's current convention so wasmtime actually wires it
into each `canon lift`).

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

The canonical-ABI surface that ships with WIT 0.2.x / 0.3.x is fully
covered in both directions; the items below are corner cases that
either depend on upstream movement or have no shipping consumer yet.

- **`list<T, N>` as a variant case payload** is wired through the
  ABI in every direction now (parameter, return type, record field,
  top-level alias, *and* projected to a single flat slot inside a
  variant arm). No WASIp2/p3 interface exercises the projection
  path; if you build a custom WIT that does, file an issue with the
  schema so we can add a real demo.
- **Stream/future intrinsics for sync *exports*.** The
  per-function intrinsics namespaces are generated for imports,
  imported-resource methods, and async exports. A *sync* export
  (or an exported resource method) whose signature mentions
  `stream<T>` / `future<T>` does not get one yet — no WASI world
  ships such a function, so there is no consumer to validate
  against. The async export shapes themselves (eager fn form and
  typed state-machine form) are fully supported; see
  [docs/bindings.md](docs/bindings.md).
- **HTTP request bodies in the `wasi3` blocking wrapper.** The 0.3
  host only answers once the request body stream is dropped, but
  the body can only be written while `client.send` is in flight —
  a blocking helper cannot interleave the two. Sending a body
  needs the state-machine async export form;
  `wasi3.http.Request` deliberately has no `body` field so the gap
  is a compile error.
- **Flags with more than 32 labels.** The canonical-ABI spec caps
  flags at 32 labels (`assert(0 < n <= 32)` in `CanonicalABI.md`).
  We follow the spec and return `error.Unsupported` past that
  boundary.
- **Multi-named result tuples.** Modern `wasm-tools` rejects these
  at embed time; the `@compileError` we emit for them is
  unreachable in any working build.
