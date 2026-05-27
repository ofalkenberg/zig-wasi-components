//! Canonical ABI runtime helpers.
//!
//! Pulled in by guest core modules (wasm32-freestanding) to implement
//! lifting and lowering of WIT values across the component boundary.
//! The two required exported symbols are `cabi_realloc` and
//! `cabi_post_*` (one per export — wit-component wires these as the
//! function's post-return hook).
//!
//! Filled in incrementally — see LOG.md.

const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64;

pub const MAX_FLAT_PARAMS: usize = 16;
pub const MAX_FLAT_RESULTS: usize = 1;
pub const MAX_FLAT_ASYNC_PARAMS: usize = 4;

pub const BLOCKED: u32 = 0xFFFF_FFFF;

pub const Event = enum(u32) {
    none = 0,
    subtask = 1,
    stream_read = 2,
    stream_write = 3,
    future_read = 4,
    future_write = 5,
    task_cancelled = 6,
    _,
};

pub const CallbackCode = enum(u32) {
    exit = 0,
    yield = 1,
    wait = 2,

    pub fn pack(code: CallbackCode, waitable_set_index: u32) u32 {
        return @intFromEnum(code) | (waitable_set_index << 4);
    }
};

pub const Status = enum(u32) {
    starting = 0,
    started = 1,
    returned = 2,
    start_cancelled = 3,
    return_cancelled = 4,
    _,
};

pub const CopyResult = enum(u32) {
    completed = 0,
    dropped = 1,
    cancelled = 2,
    _,
};

pub const SubtaskResult = struct {
    status: Status,
    subtask: u32,

    pub fn unpack(packed_value: u32) SubtaskResult {
        return .{
            .status = @enumFromInt(packed_value & 0xF),
            .subtask = packed_value >> 4,
        };
    }
};

pub const CopyOutcome = union(enum) {
    blocked,
    done: struct { result: CopyResult, progress: u32 },

    pub fn unpack(packed_value: u32) CopyOutcome {
        if (packed_value == BLOCKED) return .blocked;
        return .{ .done = .{
            .result = @enumFromInt(packed_value & 0xF),
            .progress = packed_value >> 4,
        } };
    }
};

pub const StreamEndsI64 = struct {
    readable: u32,
    writable: u32,

    pub fn unpack(packed_value: u64) StreamEndsI64 {
        return .{
            .readable = @truncate(packed_value),
            .writable = @truncate(packed_value >> 32),
        };
    }
};

pub const ErrorContext = enum(u32) { _ };

pub const Stream = enum(u32) { _ };

pub const Future = enum(u32) { _ };

pub const Realloc = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Realloc {
        return .{ .arena = .init(gpa) };
    }

    pub fn realloc(self: *Realloc, old_ptr: ?*anyopaque, old_size: usize, alignment: u32, new_size: usize) ?*anyopaque {
        const a = self.arena.allocator();
        if (old_ptr == null) {
            const buf = a.rawAlloc(new_size, std.mem.Alignment.fromByteUnits(alignment), @returnAddress()) orelse return null;
            return @ptrCast(buf);
        }
        const old_bytes: [*]u8 = @ptrCast(old_ptr);
        const new_bytes = a.rawAlloc(new_size, std.mem.Alignment.fromByteUnits(alignment), @returnAddress()) orelse return null;
        const copy_len = @min(old_size, new_size);
        @memcpy(new_bytes[0..copy_len], old_bytes[0..copy_len]);
        return @ptrCast(new_bytes);
    }

    pub fn reset(self: *Realloc) void {
        _ = self.arena.reset(.retain_capacity);
    }
};

/// Imports from the `$root` module that every async-using component sees.
/// These are wired by wit-component as canonical built-ins and are NOT
/// user-visible WIT functions. Declared as a comptime-gated struct so the
/// extern declarations exist only on wasm targets — host-side compilation
/// (used by unit tests of the parser/codegen) doesn't need to link against
/// the canon built-ins.
pub const root_async = if (is_wasm) struct {
    pub extern "$root" fn @"[waitable-set-new]"() callconv(.c) u32;
    pub extern "$root" fn @"[waitable-set-wait]"(set: u32, ptr: u32) callconv(.c) u32;
    pub extern "$root" fn @"[waitable-set-poll]"(set: u32, ptr: u32) callconv(.c) u32;
    pub extern "$root" fn @"[waitable-set-drop]"(set: u32) callconv(.c) void;
    pub extern "$root" fn @"[waitable-join]"(waitable: u32, set: u32) callconv(.c) void;
    pub extern "$root" fn @"[backpressure-inc]"() callconv(.c) void;
    pub extern "$root" fn @"[backpressure-dec]"() callconv(.c) void;
    pub extern "$root" fn @"[thread-yield]"() callconv(.c) u32;
    pub extern "$root" fn @"[subtask-drop]"(subtask: u32) callconv(.c) void;
    pub extern "$root" fn @"[subtask-cancel]"(subtask: u32) callconv(.c) u32;
    pub extern "$root" fn @"[context-get-0]"() callconv(.c) u32;
    pub extern "$root" fn @"[context-set-0]"(value: u32) callconv(.c) void;
    pub extern "$root" fn @"[error-context-new-utf8]"(ptr: u32, len: u32) callconv(.c) u32;
    pub extern "$root" fn @"[error-context-debug-message-utf8]"(handle: u32, out_ptr: u32) callconv(.c) void;
    pub extern "$root" fn @"[error-context-drop]"(handle: u32) callconv(.c) void;
    pub extern "[export]$root" fn @"[task-cancel]"() callconv(.c) void;
} else struct {
    pub fn @"[waitable-set-new]"() callconv(.c) u32 {
        unreachable;
    }
    pub fn @"[waitable-set-wait]"(_: u32, _: u32) callconv(.c) u32 {
        unreachable;
    }
    pub fn @"[waitable-set-poll]"(_: u32, _: u32) callconv(.c) u32 {
        unreachable;
    }
    pub fn @"[waitable-set-drop]"(_: u32) callconv(.c) void {
        unreachable;
    }
    pub fn @"[waitable-join]"(_: u32, _: u32) callconv(.c) void {
        unreachable;
    }
    pub fn @"[backpressure-inc]"() callconv(.c) void {
        unreachable;
    }
    pub fn @"[backpressure-dec]"() callconv(.c) void {
        unreachable;
    }
    pub fn @"[thread-yield]"() callconv(.c) u32 {
        unreachable;
    }
    pub fn @"[subtask-drop]"(_: u32) callconv(.c) void {
        unreachable;
    }
    pub fn @"[subtask-cancel]"(_: u32) callconv(.c) u32 {
        unreachable;
    }
    pub fn @"[context-get-0]"() callconv(.c) u32 {
        unreachable;
    }
    pub fn @"[context-set-0]"(_: u32) callconv(.c) void {
        unreachable;
    }
    pub fn @"[error-context-new-utf8]"(_: u32, _: u32) callconv(.c) u32 {
        unreachable;
    }
    pub fn @"[error-context-debug-message-utf8]"(_: u32, _: u32) callconv(.c) void {
        unreachable;
    }
    pub fn @"[error-context-drop]"(_: u32) callconv(.c) void {
        unreachable;
    }
    pub fn @"[task-cancel]"() callconv(.c) void {
        unreachable;
    }
};

/// One-shot, single-slot cleanup queue. An async export that produces
/// a `stream<T>` / `future<T>` writes into the writable end *before*
/// calling `task.return`, but the host can't read until our task
/// yields back to the runtime — and we can't drop the writable end
/// while a write is pending without tripping wasmtime's "cannot drop
/// busy stream" guard.
///
/// The user's export calls `abi.async_cleanup.schedule(<closure>)`
/// before returning. The generated `[async-lift]` then returns
/// `CALLBACK_YIELD` (instead of `EXIT`) when this slot is non-empty,
/// which causes the runtime to reschedule other tasks (the host's
/// async reader drains the stream/future), then re-enters the
/// `[callback]` export with `event = NONE`. The callback invokes
/// `abi.async_cleanup.run()`, which executes the scheduled closure
/// — typically the `[stream-drop-writable-i]<fn>` /
/// `[future-drop-writable-i]<fn>` call.
///
/// Single-slot is fine because WebAssembly is single-threaded and
/// each `[async-lift]` execution serialises on this slot. Multiple
/// pending cleanups (e.g. an export that produces two streams)
/// chain into a single closure.
pub const async_cleanup = struct {
    pub const Fn = *const fn () void;

    pub const Pending = struct {
        /// Waitable-set handle to wait on before running cleanup, or 0
        /// to just yield once and run cleanup unconditionally.
        set: u32,
        cleanup: Fn,
    };

    /// Bounded array of pending-cleanup slots. Each in-flight async
    /// task owns one slot; the slot's 1-based index is stored in the
    /// task-local `[context-set-0]` slot so `lift_outcome()` and
    /// `run()` can find the right entry from the matching
    /// `[context-get-0]`. 16 is plenty for wasmtime's
    /// component-model-async — guest tasks are serial within a single
    /// instance call, but multiple instance calls can interleave under
    /// `run_concurrent`.
    pub const MAX_PENDING = 16;
    var slots: [MAX_PENDING]?Pending = @splat(null);

    /// User-facing: schedule a cleanup for the current task. The
    /// generated `[async-lift]` reads back the matching slot via
    /// `[context-get-0]` to decide its return code (YIELD/WAIT/EXIT),
    /// and the `[callback]` runs the closure.
    ///
    /// The debug assert checks that `[context-set-0]` is free —
    /// `async_cleanup` and `StateSlots` share the same one task-
    /// local register, so they cannot be mixed within a single
    /// `[async-lift]` invocation.
    pub fn schedule(set: u32, cleanup: Fn) void {
        std.debug.assert(root_async.@"[context-get-0]"() == 0);
        for (&slots, 0..) |*s, i| if (s.* == null) {
            s.* = .{ .set = set, .cleanup = cleanup };
            root_async.@"[context-set-0]"(@intCast(i + 1));
            return;
        };
        @panic("async_cleanup: too many concurrent producers (>16)");
    }

    /// Used by the generated `[async-lift]` after `task.return`.
    /// Returns the packed `CallbackCode | (set<<4)` value the export
    /// should return: 0 (EXIT) when nothing was scheduled, 1 (YIELD)
    /// when scheduled with `set = 0`, or `2 | (set<<4)` (WAIT(set))
    /// otherwise.
    pub fn lift_outcome() i32 {
        const idx = root_async.@"[context-get-0]"();
        if (idx == 0) return 0;
        const p = slots[idx - 1] orelse return 0;
        if (p.set == 0) return 1;
        return @as(i32, @intCast(2 | (p.set << 4)));
    }

    /// Used by the generated `[callback]`. Looks up this task's
    /// pending cleanup via `[context-get-0]`, runs it, clears the
    /// slot and the context. Returns true if a cleanup was run.
    pub fn run() bool {
        const idx = root_async.@"[context-get-0]"();
        if (idx == 0) return false;
        const p = slots[idx - 1] orelse return false;
        slots[idx - 1] = null;
        root_async.@"[context-set-0]"(0);
        p.cleanup();
        return true;
    }
};

/// Typed state-machine sugar for async exports. The codegen detects
/// whether the user wrote an async export as a plain `fn` (eager
/// completion) or as a `struct { State, start, step }` (state
/// machine) and routes accordingly.
///
/// User contract for the state-machine form:
///
///     pub const greet = struct {
///         pub const State = struct { ... };
///
///         pub fn start(state: *State, taskReturn: anytype, name: []const u8) abi.Step {
///             const ends = greet_stream.new();
///             _ = greet_stream.writeAsync(ends.writable, "...");
///             taskReturn(ends.readable);  // task.return now — the host can read
///             state.* = .{ .wait_set = abi.WaitableSet.init(), .writable = ends.writable };
///             state.wait_set.join(@intFromEnum(ends.writable));
///             return .{ .wait = state.wait_set.handle };
///         }
///
///         pub fn step(state: *State, event: abi.Event, p1: u32, p2: u32) abi.Step {
///             _ = .{ event, p1, p2 };
///             abi.WaitableSet.leave(@intFromEnum(state.writable));
///             greet_stream.dropWritable(state.writable);
///             state.wait_set.deinit();
///             return .exit;
///         }
///     };
///
/// `start` is invoked once from `[async-lift]` with a freshly
/// allocated state pointer, a typed thunk over `[task-return]<fn>`,
/// and the lifted parameters. `step` is invoked from the matching
/// `[callback]` whenever the runtime re-enters the guest (with
/// `event = .none` after a `.yield`, or with a real event after a
/// `.wait`).
///
/// `abi.Step` decides the canonical-ABI return code:
///   - `.exit`       ⇒ EXIT (0). The state slot is freed.
///   - `.yield`      ⇒ YIELD (1). State is kept for the next step.
///   - `.wait = set` ⇒ WAIT(set) (2 | (set<<4)). State is kept.
///
/// `task.return` is *not* coupled to a Step variant — the user calls
/// `taskReturn(value)` directly from anywhere in start/step. This
/// matches the canonical ABI, which lets the guest hand the host its
/// result before the task finishes (the natural pattern for stream
/// and future producers that must keep the writable end alive long
/// enough for the host to read).
pub const Step = union(enum) {
    exit,
    yield,
    wait: u32,
};

/// A bounded pool of typed state slots, one per in-flight async task
/// for a given `State` type. The 1-based slot index is stashed in the
/// canonical-ABI task-local `[context-set-0]` register so the
/// matching `[callback]` can recover the same state pointer via
/// `[context-get-0]`. Sized like `async_cleanup.MAX_PENDING` (16) —
/// enough for any realistic component-model-async workload because
/// guest tasks are serial within a single instance call.
///
/// **Shared register**: `[context-set-0]` is the only task-local
/// scratch register the canonical ABI exposes, so `StateSlots(T)`
/// and `async_cleanup` both reach for it. They cannot coexist within
/// the same `[async-lift]` invocation — an export that takes the
/// state-machine shape (and therefore drives `StateSlots`) must not
/// also call `async_cleanup.schedule(...)`, and vice versa. The
/// `alloc()` debug assert below catches accidental overlap; in
/// release builds it silently overwrites whichever index was there.
pub fn StateSlots(comptime State: type) type {
    return struct {
        pub const MAX = 16;

        pub var slots: [MAX]State = undefined;
        pub var occupied: [MAX]bool = @splat(false);

        pub fn alloc() *State {
            std.debug.assert(root_async.@"[context-get-0]"() == 0);
            for (&occupied, 0..) |*o, i| if (!o.*) {
                o.* = true;
                root_async.@"[context-set-0]"(@intCast(i + 1));
                return &slots[i];
            };
            @panic("abi.StateSlots: too many concurrent state-machine tasks (>16)");
        }

        pub fn current() *State {
            const idx = root_async.@"[context-get-0]"();
            std.debug.assert(idx != 0 and idx <= MAX);
            return &slots[idx - 1];
        }

        pub fn free() void {
            const idx = root_async.@"[context-get-0]"();
            std.debug.assert(idx != 0 and idx <= MAX);
            occupied[idx - 1] = false;
            root_async.@"[context-set-0]"(0);
        }
    };
}

/// A waitable set: a host-owned multiplex over multiple stream/future/subtask
/// events that the guest can block on (`wait`) or peek (`poll`).
pub const WaitableSet = struct {
    handle: u32,

    pub fn init() WaitableSet {
        return .{ .handle = root_async.@"[waitable-set-new]"() };
    }

    pub fn deinit(self: WaitableSet) void {
        root_async.@"[waitable-set-drop]"(self.handle);
    }

    pub fn join(self: WaitableSet, waitable: u32) void {
        root_async.@"[waitable-join]"(waitable, self.handle);
    }

    pub fn leave(waitable: u32) void {
        root_async.@"[waitable-join]"(waitable, 0);
    }

    pub const Notification = struct {
        code: Event,
        p1: u32,
        p2: u32,
    };

    pub fn wait(self: WaitableSet) Notification {
        // The canonical ABI guarantees `[waitable-set-wait]` writes both
        // u32s before returning (or traps), so we can leave the slots
        // undefined — no need to zero-fill.
        var payload: [2]u32 = undefined;
        const code: Event = @enumFromInt(root_async.@"[waitable-set-wait]"(self.handle, @intCast(@intFromPtr(&payload))));
        return .{ .code = code, .p1 = payload[0], .p2 = payload[1] };
    }

    pub fn poll(self: WaitableSet) Notification {
        var payload: [2]u32 = undefined;
        const code: Event = @enumFromInt(root_async.@"[waitable-set-poll]"(self.handle, @intCast(@intFromPtr(&payload))));
        return .{ .code = code, .p1 = payload[0], .p2 = payload[1] };
    }
};

/// Yield control back to the host. Returns `true` if the task was *not*
/// cancelled (caller should keep running), `false` if it was cancelled.
pub fn threadYield() bool {
    return root_async.@"[thread-yield]"() == 0;
}

pub const StreamCopyError = error{
    StreamClosed,
    StreamFailed,
};

/// Write every element of `data` to a stream's writable end using the
/// blocking canon built-in, suspending the task until the reader has
/// accepted it all. `ns` is a generated per-function intrinsics
/// namespace (`bindings.<iface>.intrinsics_<fn>.stream<i>`).
pub fn streamWriteAll(comptime ns: type, writable: Stream, data: []const ns.T) StreamCopyError!void {
    var off: usize = 0;
    while (off < data.len) {
        switch (ns.write(writable, data[off..])) {
            .blocked => return error.StreamFailed,
            .done => |d| {
                off += d.progress;
                switch (d.result) {
                    .completed => if (d.progress == 0) return error.StreamFailed,
                    .dropped => return error.StreamClosed,
                    else => return error.StreamFailed,
                }
            },
        }
    }
}

/// Read bytes from a `stream<u8>` readable end until the writer drops
/// its end (or `max_bytes` is reached). Reads land directly in the
/// list's unused capacity, so the per-call read size grows with it.
/// Caller owns the result.
pub fn streamDrainBytes(comptime ns: type, gpa: std.mem.Allocator, readable: Stream, max_bytes: usize) (StreamCopyError || std.mem.Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (out.items.len < max_bytes) {
        try out.ensureUnusedCapacity(gpa, 4096);
        const dst = out.unusedCapacitySlice();
        const want = @min(dst.len, max_bytes - out.items.len);
        switch (ns.read(readable, dst[0..want])) {
            .blocked => return error.StreamFailed,
            .done => |d| {
                out.items.len += d.progress;
                switch (d.result) {
                    .completed => {},
                    .dropped => return out.toOwnedSlice(gpa),
                    else => return error.StreamFailed,
                }
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Block until the future resolves and return its payload lifted from
/// the canonical element layout, or null if the writable end was
/// dropped without a value.
pub fn futureAwait(comptime ns: type, handle: Future) ?ns.T {
    var buf: [ns.elem_size]u8 align(ns.elem_align) = undefined;
    return switch (ns.readRaw(handle, @intFromPtr(&buf))) {
        .blocked => null,
        .done => |d| if (d.result == .completed) ns.lift(@intFromPtr(&buf)) else null,
    };
}

/// Drop the readable + writable ends of a stream/future. Drop the handle
/// you no longer own; the other side is held by the peer.
pub const ErrorContextValue = struct {
    handle: u32,

    pub fn new(msg: []const u8) ErrorContextValue {
        return .{ .handle = root_async.@"[error-context-new-utf8]"(@intCast(@intFromPtr(msg.ptr)), @intCast(msg.len)) };
    }

    pub fn drop(self: ErrorContextValue) void {
        root_async.@"[error-context-drop]"(self.handle);
    }
};

test {
    std.testing.refAllDecls(@This());
}
