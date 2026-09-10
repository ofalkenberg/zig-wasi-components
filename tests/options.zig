const b = @import("bindings");
const abi = @import("zig_wasi_components").abi;
const api = b.test_options_api;
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub fn echo(x: b.nested) b.nested {
        return api.echo(x);
    }
    pub fn echo_deep(x: b.deep) b.deep {
        return api.echo_deep(x);
    }
    pub fn echo_complex(x: b.complex) b.complex {
        return api.echo_complex(x);
    }
    pub fn echo_list(x: []const b.nested) []const b.nested {
        return api.echo_list(x);
    }
    pub fn echo_outcomes(x: b.outcomes) b.outcomes {
        return api.echo_outcomes(x);
    }
    pub fn echo_complex_list(x: []const b.complex) []const b.complex {
        return api.echo_complex_list(x);
    }
    pub fn echo_value(x: b.value) b.value {
        return api.echo_value(x);
    }
    pub fn echo_choice(x: b.choice) b.choice {
        return api.echo_choice(x);
    }
    pub fn echo_many(x: b.many) b.many {
        return api.echo_many(x);
    }
    pub fn run() bool {
        const fixed = api.echo_fixed(.{ null, @as(?u32, null), @as(?u32, 42) });
        if (fixed[0] != null or fixed[1] == null or fixed[1].? != null or fixed[2].?.? != 42) @trap();
        const ns = api.intrinsics_inspect.future0;
        const ends = ns.new();
        var delivery: abi.FutureDelivery(ns) = undefined;
        delivery.start(ends.writable, @as(?u32, null));
        const result = api.inspect(ends.readable);
        delivery.finish();
        return result;
    }
};
