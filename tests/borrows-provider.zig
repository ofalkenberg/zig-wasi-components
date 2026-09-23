const b = @import("bindings");
comptime {
    _ = b;
}
const allocator = @import("std").heap.wasm_allocator;
pub const wit_exports = struct {
    pub const i = struct {
        pub const r = struct {
            pub const State = struct { v: u32 };
            pub fn constructor(v: u32) *State {
                const s = allocator.create(State) catch @panic("oom");
                s.* = .{ .v = v };
                return s;
            }
            pub fn get(s: *State) u32 {
                return s.v;
            }
            pub fn destructor(s: *State) void {
                allocator.destroy(s);
            }
        };
    };
};
