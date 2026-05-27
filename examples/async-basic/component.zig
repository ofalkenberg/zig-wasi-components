//! Zig guest component implementing five `async func`s, exercising
//! both async-export shapes the codegen supports:
//!
//!   - **Eager fn form** (`succ`, `measure`, `relay`): a plain
//!     `pub fn` that returns its result directly. The generated
//!     `[async-lift]` invokes it, lowers the return value through
//!     `[task-return]`, and either EXITs (no stream/future) or
//!     yields via `abi.async_cleanup` to drain pending writes.
//!
//!   - **Typed state-machine form** (`greet`, `promise`): a
//!     `pub const fname = struct { State, start, step }`. The
//!     codegen wires `start` from `[async-lift]` and `step` from
//!     `[callback]`, passing a typed `taskReturn` thunk so the user
//!     can hand the host the readable end of the stream/future
//!     before waiting on the writable end to drain.

const std = @import("std");
const abi = @import("zig_wasi_components").abi;
const bindings = @import("bindings");

comptime {
    _ = bindings;
}

const greet_stream = bindings.intrinsics_demo_asyncdemo_kit_0_3_0_greet.stream0;
const promise_future = bindings.intrinsics_demo_asyncdemo_kit_0_3_0_promise.future0;

pub const wit_exports = struct {
    pub const kit = struct {
        pub fn succ(value: u32) u32 {
            return value +% 1;
        }

        pub fn measure(s: []const u8) u32 {
            return @intCast(s.len);
        }

        /// Stream-producing async export driven through the typed
        /// state-machine API. `start` creates the stream, kicks off
        /// the async write, calls `taskReturn` so the host can attach
        /// a reader, then asks the runtime to WAIT until the host has
        /// drained the buffered bytes. `step` runs when EVENT_STREAM_WRITE
        /// fires, drops the writable end + waitable-set, and EXITs.
        pub const greet = struct {
            pub const State = struct {
                writable: abi.Stream,
                wait_set: abi.WaitableSet,
            };

            pub fn start(state: *State, taskReturn: anytype, name: []const u8) abi.Step {
                const ends = greet_stream.new();

                var buf: [128]u8 = undefined;
                const greeting = std.fmt.bufPrint(&buf, "Hello, {s}!", .{name}) catch "Hello!";

                // Async write — returns BLOCKED until the host attaches a
                // reader, which happens after task.return publishes the
                // readable end and this start function returns `.wait`.
                _ = greet_stream.writeAsync(ends.writable, greeting);

                taskReturn(ends.readable);

                state.* = .{
                    .writable = ends.writable,
                    .wait_set = abi.WaitableSet.init(),
                };
                state.wait_set.join(@intFromEnum(ends.writable));
                return .{ .wait = state.wait_set.handle };
            }

            pub fn step(state: *State, event: abi.Event, p1: u32, p2: u32) abi.Step {
                _ = .{ event, p1, p2 };
                abi.WaitableSet.leave(@intFromEnum(state.writable));
                greet_stream.dropWritable(state.writable);
                state.wait_set.deinit();
                return .exit;
            }
        };

        /// Future-producing async export, same shape as `greet` but
        /// fulfilling a single `u32` instead of a byte stream.
        pub const promise = struct {
            pub const State = struct {
                writable: abi.Future,
                wait_set: abi.WaitableSet,
            };

            pub fn start(state: *State, taskReturn: anytype, value: u32) abi.Step {
                const ends = promise_future.new();
                const doubled = value *% 2;
                _ = promise_future.writeAsync(ends.writable, &doubled);

                taskReturn(ends.readable);

                state.* = .{
                    .writable = ends.writable,
                    .wait_set = abi.WaitableSet.init(),
                };
                state.wait_set.join(@intFromEnum(ends.writable));
                return .{ .wait = state.wait_set.handle };
            }

            pub fn step(state: *State, event: abi.Event, p1: u32, p2: u32) abi.Step {
                _ = .{ event, p1, p2 };
                abi.WaitableSet.leave(@intFromEnum(state.writable));
                promise_future.dropWritable(state.writable);
                state.wait_set.deinit();
                return .exit;
            }
        };

        /// Call the async host import `clock.tick(value)` and return
        /// the result + 1. Exercises the `[async-lower]` path: the
        /// generated wrapper blocks on a waitable-set until the host's
        /// task RETURNs, then drops the subtask handle.
        pub fn relay(value: u32) u32 {
            return bindings.demo_asyncdemo_clock.tick(value) +% 1;
        }
    };
};
