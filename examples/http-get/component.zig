//! Zig guest component that performs an HTTP GET via wasi:http and
//! prints the response body to stdout.
//!
//! All wasi-http / wasi-io / wasi-cli bindings come from the
//! auto-generated `bindings` module (see build.zig: the WIT is
//! resolved by `wasm-tools component wit`, fed to our codegen, and
//! the result is imported here as `bindings`). The only code below
//! is the actual fetching logic written against those bindings.

const std = @import("std");
const bindings = @import("bindings");

comptime {
    _ = bindings; // pull in cabi_realloc, the wasi:cli/run export, etc.
}

const wht = bindings.wasi_http_types;
const wsh = bindings.wasi_http_outgoing_handler;
const wis = bindings.wasi_io_streams;
const wcs = bindings.wasi_cli_stdout;
const wio_err = bindings.wasi_io_error;

fn writeStdout(bytes: []const u8) void {
    const stdout = wcs.get_stdout();
    defer wis.resources.output_stream.drop(stdout);
    const r = wis.resources.output_stream.blocking_write_and_flush(stdout, bytes);
    switch (r) {
        .ok => {},
        .err => |e| switch (e) {
            .closed => {},
            .last_operation_failed => |h| wio_err.resources.@"error".drop(h),
        },
    }
}

const Target = struct {
    https: bool,
    host: []const u8,
    path: []const u8,
};

fn parseTarget(url: []const u8) ?Target {
    var rest = url;
    var https = false;
    if (std.mem.startsWith(u8, rest, "https://")) {
        https = true;
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const host = if (slash) |i| rest[0..i] else rest;
    if (host.len == 0) return null;
    const path = if (slash) |i| rest[i..] else "/";
    return .{ .https = https, .host = host, .path = path };
}

fn drainStream(gpa: std.mem.Allocator, stream: wis.types.input_stream) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        const r = wis.resources.input_stream.blocking_read(stream, 4096);
        switch (r) {
            .ok => |chunk| {
                if (chunk.len == 0) return out.toOwnedSlice(gpa);
                try out.appendSlice(gpa, chunk);
            },
            .err => |e| switch (e) {
                .closed => return out.toOwnedSlice(gpa),
                .last_operation_failed => |h| {
                    wio_err.resources.@"error".drop(h);
                    return error.StreamFailed;
                },
            },
        }
    }
}

fn fetch(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const target = parseTarget(url) orelse return error.BadUrl;

    const headers = wht.resources.fields.new();
    const req = wht.resources.outgoing_request.new(headers);
    var req_consumed = false;
    errdefer if (!req_consumed) wht.resources.outgoing_request.drop(req);

    switch (wht.resources.outgoing_request.set_authority(req, target.host)) {
        .ok => {},
        .err => return error.SetAuthorityFailed,
    }
    switch (wht.resources.outgoing_request.set_path_with_query(req, target.path)) {
        .ok => {},
        .err => return error.SetPathFailed,
    }
    const scheme: wht.types.scheme = if (target.https) .{ .HTTPS = {} } else .{ .HTTP = {} };
    switch (wht.resources.outgoing_request.set_scheme(req, scheme)) {
        .ok => {},
        .err => return error.SetSchemeFailed,
    }

    // outgoing-handler.handle(req, Some(empty-options)) → result<future, error-code>.
    const opts = wht.resources.request_options.new();
    const handle_res = wsh.handle(req, opts);
    req_consumed = true;
    const future = switch (handle_res) {
        .ok => |f| f,
        .err => return error.HandleFailed,
    };
    defer wht.resources.future_incoming_response.drop(future);

    const pollable = wht.resources.future_incoming_response.subscribe(future);
    bindings.wasi_io_poll.resources.pollable.block(pollable);
    bindings.wasi_io_poll.resources.pollable.drop(pollable);

    // future.get -> option<result<result<own<incoming-response>, error-code>, _>>.
    const get_opt = wht.resources.future_incoming_response.get(future);
    const get_outer = get_opt orelse return error.FutureNotReady;
    const inner_result = switch (get_outer) {
        .ok => |x| x,
        .err => return error.FutureUnreachable,
    };
    const response = switch (inner_result) {
        .ok => |r| r,
        .err => return error.HttpErrored,
    };
    defer wht.resources.incoming_response.drop(response);

    const status = wht.resources.incoming_response.status(response);
    var status_buf: [32]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_buf, "HTTP {d}\n", .{status}) catch "HTTP ?\n";
    writeStdout(status_line);

    const body = switch (wht.resources.incoming_response.consume(response)) {
        .ok => |b| b,
        .err => return error.ConsumeFailed,
    };
    defer wht.resources.incoming_body.drop(body);

    const stream = switch (wht.resources.incoming_body.stream(body)) {
        .ok => |s| s,
        .err => return error.NoStream,
    };
    defer wis.resources.input_stream.drop(stream);

    return drainStream(gpa, stream);
}

const default_url = "https://example.com/";

/// User-side implementation of the wasi:cli/run.run export.
/// The codegen wires this through `wasi:cli/run@0.2.6#run` to wit-component.
pub const wit_exports = struct {
    pub const run = struct {
        pub fn run() bindings.run_run_result {
            const gpa = std.heap.wasm_allocator;
            const body = fetch(gpa, default_url) catch |err| {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fetch failed: {s}\n", .{@errorName(err)}) catch "fetch failed\n";
                writeStdout(msg);
                return .{ .err = {} };
            };
            defer gpa.free(body);
            writeStdout(body);
            if (body.len == 0 or body[body.len - 1] != '\n') writeStdout("\n");
            return .{ .ok = {} };
        }
    };
};
