//! Runtime coverage for the http side of `wasi3` against the real
//! `wasi:http/service@0.3.0` world. `handle` answers every request
//! with a body-less 200 whose headers report the outcome of an
//! outbound `wasi3.http.fetch` — so one `curl` against
//! `wasmtime serve -S p3,cli` exercises request drop, the client
//! wrappers (request construction, trailers delivery, consume-body),
//! and response construction with a parked trailers write that is
//! reaped after the task returns.

const std = @import("std");
const bindings = @import("bindings");
const abi = @import("zig_wasi_components").abi;
const wasi3 = @import("zig_wasi_components").wasi3.Wasi3(bindings);

comptime {
    _ = bindings;
}

const wht = bindings.wasi_http_types;
const resp_res = wht.resources.response;
const rn = resp_res.intrinsics_new;
const gpa = std.heap.wasm_allocator;

// The parked trailers write resolves only after the host has received
// the response, i.e. after `handle` returns — and concurrent requests
// share this instance, so every in-flight response carries its own
// delivery state, handed to the cleanup callback as its context.
const TrailersCleanup = struct {
    delivery: abi.FutureDelivery(rn.future1),
    set: abi.WaitableSet,
};

fn cleanupTrailers(ctx: ?*anyopaque) void {
    const c: *TrailersCleanup = @ptrCast(@alignCast(ctx.?));
    c.delivery.reap();
    c.set.deinit();
    gpa.destroy(c);
}

pub const wit_exports = struct {
    pub const handler = struct {
        pub fn handle(request: wht.types.request) bindings.handler_handle_result {
            // `/bad` swaps in an unparseable authority, driving fetch's
            // error path (request drop + parked-write abandon) instead
            // of its success path — the response must still arrive.
            const path = wht.resources.request.get_path_with_query(request);
            const want_bad = path != null and std.mem.eql(u8, path.?, "/bad");
            wht.resources.request.drop(request);

            var status_buf: [16]u8 = undefined;
            var len_buf: [16]u8 = undefined;
            var upstream: []const u8 = "error";
            var upstream_len: []const u8 = "0";
            if (wasi3.http.fetch(gpa, .{
                .url = if (want_bad) "http://exa mple.com/ bad" else "http://example.com/",
                .method = .get,
                .headers = &.{.{ .name = "accept", .value = "text/html" }},
            })) |resp| {
                var owned = resp;
                upstream = std.fmt.bufPrint(&status_buf, "{d}", .{owned.status}) catch "?";
                upstream_len = std.fmt.bufPrint(&len_buf, "{d}", .{owned.body.len}) catch "?";
                owned.deinit();
            } else |_| {}

            const c = gpa.create(TrailersCleanup) catch
                return .{ .err = .{ .internal_error = "oom" } };

            const headers = switch (wht.resources.fields.from_list(&.{
                .{ "x-upstream-status", upstream },
                .{ "x-upstream-bytes", upstream_len },
            })) {
                .ok => |h| h,
                .err => {
                    gpa.destroy(c);
                    return .{ .err = .{ .internal_error = "fields" } };
                },
            };

            const trailers = rn.future1.new();
            c.delivery.start(trailers.writable, .{ .ok = null });

            const made = resp_res.new(headers, null, trailers.readable);
            rn.future2.dropReadable(made[1]);

            if (c.delivery.pending) {
                c.set = abi.WaitableSet.init();
                c.set.join(@intFromEnum(c.delivery.writable));
                abi.async_cleanup.schedule(c.set.handle, &cleanupTrailers, c);
            } else {
                // Write already resolved: dispose inline, no callback
                // round-trip needed.
                c.delivery.reap();
                gpa.destroy(c);
            }

            return .{ .ok = made[0] };
        }
    };
};
