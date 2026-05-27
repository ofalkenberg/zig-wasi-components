//! Compile-only coverage for the `wasi3.http` client wrappers against
//! the real `wasi:http/service@0.3.0` world. No released runtime ships
//! the final wasi:http 0.3.0 interfaces yet (wasmtime 45/47-dev still
//! vendor the March RC), so this guest is built but not executed; the
//! build step compiles it to an object to keep the http path honest.

const std = @import("std");
const bindings = @import("bindings");
const wasi3 = @import("zig_wasi_components").wasi3.Wasi3(bindings);

comptime {
    _ = bindings;
}

pub const wit_exports = struct {
    pub const handler = struct {
        pub fn handle(request: bindings.wasi_http_types.types.request) bindings.handler_handle_result {
            bindings.wasi_http_types.resources.request.drop(request);

            const gpa = std.heap.wasm_allocator;
            var resp = wasi3.http.fetch(gpa, .{
                .url = "http://example.com/upstream",
                .method = .get,
                .headers = &.{.{ .name = "accept", .value = "text/plain" }},
            }) catch return .{ .err = .{ .HTTP_request_denied = {} } };
            resp.deinit();

            const body = wasi3.http.get(gpa, "http://example.com/") catch
                return .{ .err = .{ .HTTP_request_denied = {} } };
            gpa.free(body);

            return .{ .err = .{ .HTTP_request_denied = {} } };
        }
    };
};
