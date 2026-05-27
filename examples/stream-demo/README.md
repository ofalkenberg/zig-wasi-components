# stream-demo

A Zig component whose only job is to hand the host typed `stream<T>`
values and prove they round-trip end to end. It exports two async
functions:

```wit
squares:   async func(count: u32) -> stream<u32>;
fibonacci: async func(count: u32) -> stream<u64>;
```

`squares(n)` streams the first `n` perfect squares, `fibonacci(n)`
streams the first `n` Fibonacci numbers. The included Rust host calls
both, drains each readable end into a `Vec`, and checks the values.

```
zig build stream-demo
cargo run --manifest-path examples/stream-demo/rust-host/Cargo.toml \
    -- zig-out/wasm/stream-demo.component.wasm
```

Output:

```
squares(8)    -> [1, 4, 9, 16, 25, 36, 49, 64]
fibonacci(10) -> [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
OK
```

## How it differs from the other examples

`async-basic` already moves a `stream<u8>` ("Hello, <name>!") from the
guest to the host, but bytes take the canonical ABI's fast path: a
`stream<u8>` is just a flat buffer the host can read with `as_direct`.
This example deliberately picks `u32` and `u64` instead, so the same
generic `stream<T>` machinery has to lift four- and eight-byte elements
one at a time. Nothing here is special-cased to bytes — on the guest
side the only difference between the two functions is the element type
they hand to `StreamProducer`.

## How the guest works

Both exports use the typed state-machine shape the codegen wires up for
stream-producing async functions. `StreamProducer(ns, produce)` in
[`component.zig`](component.zig) is generic over the per-function
intrinsics namespace (`bindings.intrinsics_…_squares.stream0` and its
`fibonacci` twin), so the two exports share one body:

1. `start` mints a stream with `ns.new()`, fills a buffer that lives in
   the task's `State`, and kicks off a single async `ns.writeAsync`. The
   write blocks because no reader is attached yet.
2. It calls `taskReturn` to publish the readable end to the host, then
   parks the task on a waitable set joined to the writable end.
3. Once the host has drained every element the runtime fires
   `EVENT_STREAM_WRITE`; `step` drops the writable end and the task
   exits.

Keeping the payload buffer inside `State` (rather than on `start`'s
stack) is what makes the deferred async write sound: the slice handed to
`writeAsync` has to stay valid until `step` runs.

## How the host works

[`rust-host/src/main.rs`](rust-host/src/main.rs) attaches a generic
`Collector<T>` to each readable end. Its `poll_consume` reads the whole
pending write into a `Vec<T>` with the typed `Source::read`; when the
guest drops its writable end the next poll sees nothing remaining and
reports the stream dropped. The same `Collector` drains both the `u32`
and the `u64` stream.

## Layout

```
world.wit              the two-function `numbers` interface
component.zig          the Zig guest (one generic StreamProducer)
rust-host/             wasmtime host that drains and verifies both streams
```
