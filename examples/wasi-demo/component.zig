//! Exercises the `wasi` convenience module from `zig-wasi-components`.
//!
//! Builds against the standard `wasi:cli/command` world (plus the
//! outbound HTTP imports) and walks through clocks, randomness, env
//! vars, stdio and an HTTP GET in a few dozen lines.

const std = @import("std");
const bindings = @import("bindings");
const wasi = @import("zig_wasi_components").wasi.Wasi(bindings);

comptime {
    _ = bindings;
}

const default_url = "https://example.com/";

pub const wit_exports = struct {
    pub const run = struct {
        pub fn run() bindings.run_run_result {
            doRun() catch |err| {
                wasi.stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
                return .{ .err = {} };
            };
            return .{ .ok = {} };
        }
    };
};

fn doRun() !void {
    const gpa = std.heap.wasm_allocator;

    try wasi.stdout.print("=== wasi convenience demo ===\n", .{});

    const wall = wasi.clock.now();
    try wasi.stdout.print(
        "wall clock: {d}.{d:0>9} (unix seconds={d:.6})\n",
        .{ wall.seconds, wall.nanoseconds, wasi.clock.unixSeconds() },
    );

    const t0 = wasi.clock.monotonic();

    var rnd: [16]u8 = undefined;
    wasi.random.bytes(&rnd);
    try wasi.stdout.print("16 random bytes: ", .{});
    for (rnd) |byte| try wasi.stdout.print("{x:0>2}", .{byte});
    try wasi.stdout.print("\n", .{});
    try wasi.stdout.print("random u64: {d}\n", .{wasi.random.int()});

    wasi.clock.sleepMillis(50);
    const elapsed = wasi.clock.monotonic() - t0;
    try wasi.stdout.print(
        "slept for ~50ms; monotonic delta = {d} ns ({d:.2} ms)\n",
        .{ elapsed, @as(f64, @floatFromInt(elapsed)) / 1e6 },
    );

    try wasi.stdout.print("argv ({d}):\n", .{wasi.environment.args().len});
    for (wasi.environment.args(), 0..) |arg, i|
        try wasi.stdout.print("  [{d}] {s}\n", .{ i, arg });

    if (wasi.environment.get("HOME")) |home|
        try wasi.stdout.print("HOME = {s}\n", .{home})
    else
        try wasi.stdout.print("HOME is unset\n", .{});

    if (wasi.environment.cwd()) |cwd|
        try wasi.stdout.print("cwd = {s}\n", .{cwd});

    try wasi.stdout.print(
        "tty? stdout={any} stderr={any} stdin={any}\n",
        .{ wasi.terminal.isStdoutTty(), wasi.terminal.isStderrTty(), wasi.terminal.isStdinTty() },
    );

    try wasi.stdout.print("\n--- preopens ---\n", .{});
    for (wasi.fs.preopens()) |p|
        try wasi.stdout.print("  {s}\n", .{p[1]});

    const scratch_dir = blk: {
        const preopens = wasi.fs.preopens();
        if (preopens.len > 0) break :blk preopens[0][1];
        break :blk "/";
    };
    var path_buf: [128]u8 = undefined;
    const test_path = try std.fmt.bufPrint(&path_buf, "{s}/wasi-demo.txt", .{scratch_dir});

    try wasi.fs.writeFile(test_path, "hello from the wasi convenience module\n");
    try wasi.stdout.print("wrote {s}\n", .{test_path});

    const read_back = try wasi.fs.readFile(gpa, test_path);
    defer gpa.free(read_back);
    try wasi.stdout.print("read back ({d} bytes): {s}", .{ read_back.len, read_back });

    const meta = try wasi.fs.stat(test_path);
    try wasi.stdout.print(
        "stat: kind={s} size={d} mtime={?d}\n",
        .{ @tagName(meta.kind), meta.size, meta.modified_seconds },
    );

    const entries = try wasi.fs.listDir(gpa, scratch_dir);
    defer {
        for (entries) |e| gpa.free(e.name);
        gpa.free(entries);
    }
    try wasi.stdout.print("listDir({s}): {d} entries\n", .{ scratch_dir, entries.len });
    for (entries[0..@min(entries.len, 5)]) |e|
        try wasi.stdout.print("  {s} ({s})\n", .{ e.name, @tagName(e.kind) });

    try wasi.fs.remove(test_path);
    try wasi.stdout.print("removed {s}\n", .{test_path});

    try wasi.stdout.print("\n--- DNS lookup of example.com ---\n", .{});
    const ips = try wasi.net.resolve(gpa, "example.com");
    defer gpa.free(ips);
    for (ips) |ip| {
        var fmt_buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&fmt_buf);
        ip.format(&w) catch {};
        try wasi.stdout.print("  {s}\n", .{w.buffered()});
    }

    try wasi.stdout.print("\nGET {s}\n", .{default_url});
    var resp = try wasi.http.fetch(gpa, .{ .url = default_url });
    defer resp.deinit();
    try wasi.stdout.print(
        "status = {d} ({d} bytes, {d} headers)\n",
        .{ resp.status, resp.body.len, resp.headers.len },
    );
    for (resp.headers) |h|
        try wasi.stdout.print("  {s}: {s}\n", .{ h.name, h.value });
    try wasi.stdout.print("\n--- body (first 200 bytes) ---\n", .{});
    const preview = resp.body[0..@min(resp.body.len, 200)];
    try wasi.stdout.write(preview);
    if (resp.body.len > 0 and preview[preview.len - 1] != '\n')
        try wasi.stdout.print("\n", .{});
}
