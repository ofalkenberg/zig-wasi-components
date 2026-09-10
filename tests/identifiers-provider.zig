const b = @import("bindings");
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub const host = struct {
        pub fn @"switch"(x: b.test_identifiers_host.types.point) b.test_identifiers_host.types.point {
            return x;
        }
        pub fn widen(v: b.test_identifiers_host.types.c_int) b.test_identifiers_host.types.c_int {
            return .{ .c_long = v.c_long * 2, .c_char = v.c_char + 1 };
        }
        pub fn @"c_long"() []const u32 {
            return &.{ 3, 4, 5 };
        }
    };
};
