const b = @import("bindings");
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub fn run() u64 {
        const a = b.test_resources_a;
        const c = b.test_resources_b;
        const x = a.resources.item.new(17);
        const y = c.resources.item.new(4294967297);
        const result = a.resources.item.get(x) + c.resources.item.get(y);
        a.resources.item.drop(x);
        c.resources.item.drop(y);
        if (a.drops() != 1 or c.drops() != 1) @trap();
        return result;
    }
};
