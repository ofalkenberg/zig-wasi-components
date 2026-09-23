const b = @import("bindings");
comptime {
    _ = b;
}
pub const wit_exports = struct {
    pub fn run() u32 {
        const res = b.foo.resources;
        const x = res.foo.new(1);
        defer res.foo.drop(x);
        const y = res.types.new(20);
        defer res.types.drop(y);
        const z = b.foo.make(300);
        defer res.types.drop(z);

        const r = b.types.resources.r;
        const w = b.types.make(.{ .x = 4000 });
        defer r.drop(w);

        return res.foo.get(x) + res.types.get(y) + res.types.get(z) +
            r.get(w) + b.types.types_(.{ .x = 25000 });
    }
};
