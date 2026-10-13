const bindings = @import("bindings");
const pair = bindings.test_fixed_lists_api.types.pair;

comptime {
    _ = bindings;
}

pub const wit_exports = struct {
    pub const api = struct {
        pub fn echo(x: pair) pair {
            return x;
        }

        pub fn echo_opt(x: ?[2]f32) ?[2]f32 {
            return x;
        }
    };
};
