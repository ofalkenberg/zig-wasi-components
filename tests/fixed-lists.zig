//! Fixed-length lists as variant payloads join with scalar arms in the
//! flat representation, so each element is projected to its own slot.
//! Wasmtime's `--invoke` cannot parse `list<T, N>` values, so the guest
//! drives the round trips itself.

const std = @import("std");
const bindings = @import("bindings");
const api = bindings.test_fixed_lists_api;
const pair = api.types.pair;

comptime {
    _ = bindings;
}

fn same(a: pair, b: pair) bool {
    return switch (a) {
        .single => |v| b == .single and b.single == v,
        .quad => |v| b == .quad and std.mem.eql(u32, &v, &b.quad),
        .wide => |v| b == .wide and std.mem.eql(u64, &v, &b.wide),
        .mixed => |v| b == .mixed and
            v[0][0] == b.mixed[0][0] and std.mem.eql(u8, v[0][1], b.mixed[0][1]) and
            v[1][0] == b.mixed[1][0] and std.mem.eql(u8, v[1][1], b.mixed[1][1]),
    };
}

pub const wit_exports = struct {
    pub fn run() bool {
        const cases = [_]pair{
            .{ .single = 0xdeadbeef },
            .{ .quad = .{ 1, 0xffffffff } },
            .{ .wide = .{ 1 << 40, 0, 0xffffffffffffffff } },
            .{ .mixed = .{ .{ 7, "seven" }, .{ 255, "" } } },
        };
        for (cases) |c| {
            if (!same(c, api.echo(c))) return false;
        }
        const some = api.echo_opt(.{ 1.5, -2.25 }) orelse return false;
        if (some[0] != 1.5 or some[1] != -2.25) return false;
        return api.echo_opt(null) == null;
    }
};
