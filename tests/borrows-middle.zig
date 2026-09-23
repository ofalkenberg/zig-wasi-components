const std = @import("std");
const b = @import("bindings");
comptime {
    _ = b;
}
const R = b.test_borrows_i.resources.r;
const T = b.test_borrows_user.types;
const allocator = std.heap.wasm_allocator;
var dtors: u32 = 0;
pub const wit_exports = struct {
    pub const user = struct {
        pub fn f_record(p: T.pair) u32 {
            return R.get(p.a) + p.b;
        }
        pub fn f_list(xs: []const b.test_borrows_i.types.r) u32 {
            var t: u32 = 0;
            for (xs) |x| t += R.get(x);
            return t;
        }
        pub fn f_option(x: ?b.test_borrows_i.types.r) u32 {
            return if (x) |h| R.get(h) else 7;
        }
        pub fn f_result(x: b.user_f_result_x) u32 {
            return switch (x) {
                .ok => |h| R.get(h),
                .err => |e| e,
            };
        }
        pub fn f_tuple(x: b.user_f_tuple_x) u32 {
            return R.get(x[0]) * 100 + x[1] + R.get(x[2]);
        }
        pub fn f_variant(x: T.pick) u32 {
            return switch (x) {
                .nothing => 5,
                .one => |h| R.get(h),
                .num => |n| n,
            };
        }
        pub fn f_async(xs: []const T.pair) u32 {
            var t: u32 = 0;
            for (xs) |p| t += R.get(p.a) + p.b;
            return t;
        }
        pub fn dtor_count() u32 {
            return dtors;
        }
        pub const s = struct {
            pub const State = struct { v: u32 };
            fn createState(v: u32) *State {
                const st = allocator.create(State) catch @panic("oom");
                st.* = .{ .v = v };
                return st;
            }
            pub fn constructor(x: b.test_borrows_i.types.r) *State {
                return createState(R.get(x));
            }
            pub fn add(self: *State, x: b.test_borrows_i.types.r) u32 {
                return self.v + R.get(x);
            }
            pub fn same(self: *State, other: *State) u32 {
                return self.v * 1000 + other.v;
            }
            pub fn create(v: u32) T.s {
                return b.test_borrows_user.resources.s.new(createState(v));
            }
            pub fn consume(v: T.s) u32 {
                const st = b.test_borrows_user.resources.s.rep(v);
                const value = st.v;
                b.test_borrows_user.resources.s.drop(v);
                return value;
            }
            pub fn destructor(self: *State) void {
                dtors += 1;
                allocator.destroy(self);
            }
        };
    };
};
