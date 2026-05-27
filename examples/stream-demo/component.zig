//! Zig guest component that produces two typed streams:
//!
//!   - `squares(count) -> stream<u32>` emits the first `count` perfect
//!     squares (1, 4, 9, ...).
//!   - `fibonacci(count) -> stream<u64>` emits the first `count`
//!     Fibonacci numbers (0, 1, 1, 2, 3, 5, ...).
//!
//! Both are `async func`s implemented in the typed state-machine form the
//! codegen wires up for stream-producing exports. `start` mints the stream,
//! buffers the whole payload inside the task's `State`, kicks off a single
//! async `stream.write`, hands the readable end back through `task.return`,
//! and parks the task on a waitable set. When the host has drained every
//! element the runtime fires `EVENT_STREAM_WRITE`, `step` runs, drops the
//! writable end, and the task exits.
//!
//! The point of the example is the element type: `squares` moves four-byte
//! `u32`s and `fibonacci` moves eight-byte `u64`s through the exact same
//! generic `stream<T>` machinery. Nothing here is special-cased to bytes.

const std = @import("std");
const abi = @import("zig_wasi_components").abi;
const bindings = @import("bindings");

comptime {
    _ = bindings;
}

const squares_stream = bindings.intrinsics_demo_streams_numbers_0_3_0_squares.stream0;
const fibonacci_stream = bindings.intrinsics_demo_streams_numbers_0_3_0_fibonacci.stream0;

/// Largest stream we are willing to materialize in a task slot. The host
/// only ever asks for a handful, so a small fixed bound keeps the per-task
/// state cheap while staying well clear of `u32`-square / `u64`-Fibonacci
/// overflow.
const max_elems = 64;

/// Shared state-machine body for a stream of scalar `Elem`s. `produce`
/// fills the caller's buffer with the first elements; everything else —
/// minting the stream, the single async write, `task.return`, and the
/// drain handshake — is identical across element types.
fn StreamProducer(comptime ns: type, comptime produce: fn (buf: []ns.T) void) type {
    return struct {
        const Elem = ns.T;

        pub const State = struct {
            writable: abi.Stream,
            wait_set: abi.WaitableSet,
            buf: [max_elems]Elem,
        };

        pub fn start(state: *State, taskReturn: anytype, count: u32) abi.Step {
            const ends = ns.new();

            const data = state.buf[0..@min(count, max_elems)];
            produce(data);

            // Buffer lives in `State`, so the slice handed to the async
            // write stays valid until `step` drops the writable end.
            _ = ns.writeAsync(ends.writable, data);

            taskReturn(ends.readable);

            state.writable = ends.writable;
            state.wait_set = abi.WaitableSet.init();
            state.wait_set.join(@intFromEnum(ends.writable));
            return .{ .wait = state.wait_set.handle };
        }

        pub fn step(state: *State, event: abi.Event, p1: u32, p2: u32) abi.Step {
            _ = .{ event, p1, p2 };
            abi.WaitableSet.leave(@intFromEnum(state.writable));
            ns.dropWritable(state.writable);
            state.wait_set.deinit();
            return .exit;
        }
    };
}

fn produceSquares(buf: []u32) void {
    for (buf, 1..) |*slot, i| slot.* = @intCast(i * i);
}

fn produceFibonacci(buf: []u64) void {
    var a: u64 = 0;
    var b: u64 = 1;
    for (buf) |*slot| {
        slot.* = a;
        const next = a + b;
        a = b;
        b = next;
    }
}

pub const wit_exports = struct {
    pub const numbers = struct {
        pub const squares = StreamProducer(squares_stream, produceSquares);
        pub const fibonacci = StreamProducer(fibonacci_stream, produceFibonacci);
    };
};
