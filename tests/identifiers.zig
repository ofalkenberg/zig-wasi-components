const b = @import("bindings");
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub fn @"switch"(x: u32, y: ?u32) ?u32 {
        return if (y) |value| x + value else null;
    }
    pub fn run() u32 {
        const p = b.test_identifiers_host.@"switch"(.{ .@"align" = 17, .@"volatile" = 25 });
        const widened = b.test_identifiers_host.widen(.{ .c_long = 1000, .c_char = 7 });
        var total = p.@"align" + p.@"volatile" + widened.c_long + widened.c_char;
        for (b.test_identifiers_host.c_long()) |value| total += value;
        return total;
    }
};
