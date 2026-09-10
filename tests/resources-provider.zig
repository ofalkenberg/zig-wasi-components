const b = @import("bindings");
const allocator = @import("std").heap.wasm_allocator;
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub const a = Interface(u32);
    pub const b = Interface(u64);
};

fn Interface(comptime T: type) type {
    return struct {
        pub const item = struct {
            pub const State = struct { value: T };
            var drop_count: u32 = 0;

            pub fn constructor(value: T) *State {
                const state = allocator.create(State) catch @panic("oom");
                state.* = .{ .value = value };
                return state;
            }
            pub fn get(state: *State) T {
                return state.value;
            }
            pub fn destructor(state: *State) void {
                drop_count += 1;
                allocator.destroy(state);
            }
        };
        pub fn drops() u32 {
            return item.drop_count;
        }
    };
}
