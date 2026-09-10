const b = @import("bindings");
const abi = @import("zig_wasi_components").abi;
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub fn run() bool {
        const api = b.test_async_types_api;
        const nested = api.nested();
        const outer = api.intrinsics_nested.stream1;
        defer outer.dropReadable(nested);
        var buf: [outer.elem_size]u8 align(outer.elem_align) = undefined;
        const read = outer.readRaw(nested, @intFromPtr(&buf), 1);
        if (read != .done or read.done.result != .dropped or read.done.progress != 0) @trap();

        const ns = api.intrinsics_repeated;
        const a = ns.stream0.new();
        const c = ns.stream1.new();
        ns.stream0.dropWritable(a.writable);
        ns.stream1.dropWritable(c.writable);
        const result = api.repeated(a.readable, c.readable);
        defer ns.stream2.dropReadable(result);
        var values: [1]u64 = undefined;
        const repeated = ns.stream2.read(result, &values);
        if (repeated != .done or repeated.done.result != .dropped or repeated.done.progress != 0) @trap();

        const future = api.intrinsics_signal.future0;
        const ends = future.new();
        var delivery: abi.FutureDelivery(future) = undefined;
        delivery.start(ends.writable, {});
        const signalled = api.signal(ends.readable);
        delivery.finish();
        return signalled;
    }
};
