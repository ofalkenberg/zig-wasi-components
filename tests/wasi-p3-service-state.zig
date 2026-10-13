//! The http handler in the typed state-machine export form.

const bindings = @import("bindings");
const abi = @import("zig_wasi_components").abi;
const touch = @import("wasi-p3-touch.zig").touch;
const wht = bindings.wasi_http_types;

export fn touch_all(n: u32) usize {
    return touch(bindings, n);
}

pub const wit_exports = struct {
    pub const handler = struct {
        pub const handle = struct {
            pub const State = struct {};

            pub fn start(state: *State, taskReturn: anytype, request: wht.types.request) abi.Step {
                _ = state;
                wht.resources.request.drop(request);
                taskReturn(.{ .err = .{ .internal_error = null } });
                return .exit;
            }

            pub fn step(state: *State, event: abi.Event, p1: u32, p2: u32) abi.Step {
                _ = .{ state, event, p1, p2 };
                return .exit;
            }
        };
    };
};
