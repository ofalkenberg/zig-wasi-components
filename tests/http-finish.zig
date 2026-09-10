const b = @import("bindings");
const std = @import("std");
const wasi = @import("zig_wasi_components").wasi.Wasi(b);
comptime {
    _ = b;
}

pub const wit_exports = struct {
    pub const run = struct {
        pub fn run() b.run_run_result {
            // Finishing a short body fails before outgoing-handler.handle
            // sends the request. The error must not double-drop the body.
            var response = wasi.http.fetch(std.heap.wasm_allocator, .{
                .url = "http://127.0.0.1:1/",
                .headers = &.{.{ .name = "content-length", .value = "2" }},
                .body = "x",
            }) catch |err| {
                if (err != error.BodyFailed) @trap();
                return .{ .ok = {} };
            };
            response.deinit();
            @trap();
        }
    };
};
