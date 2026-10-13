const bindings = @import("bindings");
const touch = @import("wasi-p3-touch.zig").touch;

export fn touch_all(n: u32) usize {
    return touch(bindings, n);
}

pub const wit_exports = struct {
    pub const run = struct {
        pub fn run() bindings.run_run_result {
            return .{ .ok = {} };
        }
    };
};
