//! Takes the runtime address of every non-generic function in a set of
//! bindings.
//! Each one then keeps its core imports in the binary, so
//! `wasm-tools component new` checks all of them against the world.

const std = @import("std");

fn walk(comptime T: type, index: *u32, found: *usize) void {
    inline for (comptime std.meta.declarations(T)) |name| {
        const D = @TypeOf(@field(T, name));
        if (D == type) {
            switch (@typeInfo(@field(T, name))) {
                .@"struct", .@"union", .@"enum", .@"opaque" => walk(@field(T, name), index, found),
                else => {},
            }
        } else if (@typeInfo(D) == .@"fn" and !@typeInfo(D).@"fn".is_generic) {
            if (index.* == 0) found.* = @intFromPtr(&@field(T, name));
            index.* -%= 1;
        } else {
            _ = &@field(T, name);
        }
    }
}

pub fn touch(comptime T: type, n: u32) usize {
    var index = n;
    var found: usize = 0;
    walk(T, &index, &found);
    return found;
}
