const b = @import("bindings");
const allocator = @import("std").heap.wasm_allocator;
comptime {
    _ = b;
}

fn Counter() type {
    return struct {
        pub const State = struct { value: u32 };

        pub fn constructor(value: u32) *State {
            const state = allocator.create(State) catch @panic("oom");
            state.* = .{ .value = value };
            return state;
        }
        pub fn get(state: *State) u32 {
            return state.value;
        }
        pub fn destructor(state: *State) void {
            allocator.destroy(state);
        }
    };
}

pub const wit_exports = struct {
    pub const foo = struct {
        pub const foo = Counter();
        pub const types = Counter();

        pub fn make(value: u32) b.foo.types.types {
            return b.foo.resources.types.new(@This().types.constructor(value));
        }
    };
    pub const types = struct {
        pub const r = Counter();

        pub fn make(p: b.types.types.pt) b.types.types.r {
            return b.types.resources.r.new(r.constructor(p.x));
        }
        pub fn types(p: b.types.types.pt) u32 {
            return p.x * 2;
        }
    };
};
