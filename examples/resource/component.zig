//! Resource demo: a `counter` resource exposed through an
//! interface, with constructor, methods, and an implicit
//! destructor wired up to free the per-counter state.

const std = @import("std");
const bindings = @import("bindings");

comptime {
    _ = bindings;
}

pub const wit_exports = struct {
    pub const counters = struct {
        pub const counter = struct {
            pub const State = struct { value: u32 };

            pub fn constructor(initial: u32) *State {
                const s = std.heap.wasm_allocator.create(State) catch unreachable;
                s.* = .{ .value = initial };
                return s;
            }

            pub fn increment(self: *State) void {
                self.value +%= 1;
            }

            pub fn add(self: *State, n: u32) void {
                self.value +%= n;
            }

            pub fn get(self: *State) u32 {
                return self.value;
            }

            pub fn destructor(self: *State) void {
                std.heap.wasm_allocator.destroy(self);
            }
        };
    };
};
