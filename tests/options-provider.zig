const b = @import("bindings");
const abi = @import("zig_wasi_components").abi;
const t = b.test_options_api.types;
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub const api = struct {
        pub fn echo(x: t.nested) t.nested {
            return x;
        }
        pub fn echo_deep(x: t.deep) t.deep {
            return x;
        }
        pub fn echo_complex(x: t.complex) t.complex {
            return x;
        }
        pub fn echo_list(x: []const t.nested) []const t.nested {
            return x;
        }
        pub fn echo_outcomes(x: t.outcomes) t.outcomes {
            return x;
        }
        pub fn echo_complex_list(x: []const t.complex) []const t.complex {
            return x;
        }
        pub fn echo_value(x: t.value) t.value {
            return x;
        }
        pub fn echo_choice(x: t.choice) t.choice {
            return x;
        }
        pub fn echo_many(x: t.many) t.many {
            return x;
        }
        pub fn echo_fixed(x: t.fixed) t.fixed {
            return x;
        }
        pub fn inspect(x: abi.Future) bool {
            const ns = b.intrinsics_test_options_api_inspect.future0;
            defer ns.dropReadable(x);
            const result = abi.futureAwait(ns, x) orelse return false;
            return result != null and result.? == null;
        }
    };
};
