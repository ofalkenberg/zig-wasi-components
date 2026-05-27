//! Demo guest for the `wasi3` convenience module against the real
//! WASI 0.3.0 `wasi:cli/command` world: environment, randomness,
//! clocks (including an async-import sleep), terminal probes, a
//! filesystem round-trip through stream-based descriptors, a
//! directory listing lifted from a `stream<directory-entry>`, and a
//! DNS lookup. Run it with:
//!
//!   wasmtime run -S p3 \
//!     -W component-model-async,component-model-more-async-builtins \
//!     --dir . --invoke 'run()' zig-out/wasm/wasi-demo-p3.component.wasm

const std = @import("std");
const bindings = @import("bindings");
const wasi3 = @import("zig_wasi_components").wasi3.Wasi3(bindings);

comptime {
    _ = bindings;
}

pub const wit_exports = struct {
    pub const run = struct {
        pub fn run() bindings.run_run_result {
            demo() catch |e| {
                wasi3.stderr.print("wasi-demo-p3 failed: {t}\n", .{e}) catch {};
                return .{ .err = {} };
            };
            return .{ .ok = {} };
        }
    };
};

fn demo() !void {
    const gpa = std.heap.wasm_allocator;

    try wasi3.stdout.print("args: {d}\n", .{wasi3.environment.args().len});

    var rnd: [8]u8 = undefined;
    wasi3.random.bytes(&rnd);
    try wasi3.stdout.print("random bytes: {x}\n", .{rnd});

    const t = wasi3.clock.now();
    try wasi3.stdout.print("unix time: {d}.{d:0>9}\n", .{ t.seconds, t.nanoseconds });

    const m0 = wasi3.clock.monotonic();
    wasi3.clock.sleepMillis(10);
    const elapsed_ms = (wasi3.clock.monotonic() - m0) / std.time.ns_per_ms;
    try wasi3.stdout.print("slept 10ms, measured {d}ms\n", .{elapsed_ms});

    try wasi3.stdout.print("stdout is a tty: {}\n", .{wasi3.terminal.isStdoutTty()});

    try wasi3.fs.writeFile("p3-demo.txt", "hello, stream-based filesystem\n");
    try wasi3.fs.appendFile("p3-demo.txt", "appended line\n");
    const content = try wasi3.fs.readFile(gpa, "p3-demo.txt");
    defer gpa.free(content);
    try wasi3.stdout.print("read back {d} bytes\n", .{content.len});

    const st = try wasi3.fs.stat("p3-demo.txt");
    try wasi3.stdout.print("stat: kind={t} size={d}\n", .{ st.kind, st.size });

    const entries = try wasi3.fs.listDir(gpa, ".");
    defer {
        for (entries) |e| gpa.free(e.name);
        gpa.free(entries);
    }
    try wasi3.stdout.print("cwd has {d} entries\n", .{entries.len});

    try wasi3.fs.rename("p3-demo.txt", "p3-demo-renamed.txt");
    try wasi3.fs.remove("p3-demo-renamed.txt");
    try wasi3.stdout.print("fs round-trip ok\n", .{});

    if (wasi3.net.resolve(gpa, "localhost")) |addrs| {
        defer gpa.free(addrs);
        try wasi3.stdout.print("localhost resolves to {d} address(es)\n", .{addrs.len});
    } else |_| {
        try wasi3.stdout.print("dns lookup unavailable\n", .{});
    }

    try wasi3.stdout.write("done\n");
}
