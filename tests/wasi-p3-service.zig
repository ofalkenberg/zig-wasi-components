const bindings = @import("bindings");
const touch = @import("wasi-p3-touch.zig").touch;
const wht = bindings.wasi_http_types;

export fn touch_all(n: u32) usize {
    return touch(bindings, n);
}

pub const wit_exports = struct {
    pub const handler = struct {
        pub fn handle(request: wht.types.request) bindings.handler_handle_result {
            wht.resources.request.drop(request);
            return .{ .err = .{ .internal_error = null } };
        }
    };
};
