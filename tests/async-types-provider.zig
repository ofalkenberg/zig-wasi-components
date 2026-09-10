const b = @import("bindings");
const abi = @import("zig_wasi_components").abi;
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub const api = struct {
        pub fn nested() abi.Stream {
            const ns = b.intrinsics_test_async_types_api_nested.stream1;
            const ends = ns.new();
            ns.dropWritable(ends.writable);
            return ends.readable;
        }
        pub fn repeated(a: abi.Stream, c: abi.Stream) abi.Stream {
            const ns = b.intrinsics_test_async_types_api_repeated;
            ns.stream0.dropReadable(a);
            ns.stream1.dropReadable(c);
            const ends = ns.stream2.new();
            ns.stream2.dropWritable(ends.writable);
            return ends.readable;
        }
        pub fn signal(x: abi.Future) bool {
            const ns = b.intrinsics_test_async_types_api_signal.future0;
            defer ns.dropReadable(x);
            return abi.futureAwait(ns, x) != null;
        }
    };
};
