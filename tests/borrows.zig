const b = @import("bindings");
comptime {
    _ = b;
}
const R = b.test_borrows_i.resources.r;
const U = b.test_borrows_user;
const S = U.resources.s;

var results: [16]u32 = undefined;
var len: usize = 0;

fn push(value: u32) void {
    results[len] = value;
    len += 1;
}

pub const wit_exports = struct {
    pub fn run() []const u32 {
        len = 0;
        const h1 = R.new(1);
        const h2 = R.new(20);

        push(U.f_record(.{ .a = h1, .b = 3 }));
        push(U.f_list(&.{ h1, h2, h1 }));
        push(U.f_option(h2));
        push(U.f_option(null));
        push(U.f_result(.{ .ok = h2 }));
        push(U.f_result(.{ .err = 9 }));
        push(U.f_tuple(.{ h1, 4, h2 }));
        push(U.f_variant(.{ .one = h2 }));
        push(U.f_variant(.{ .num = 11 }));
        push(U.f_async(&.{ .{ .a = h1, .b = 2 }, .{ .a = h2, .b = 3 } }));

        const s1 = S.new(h1);
        push(S.add(s1, h2));
        const s2 = S.create(300);
        push(S.same(s1, s2));
        push(S.consume(s2));
        push(U.dtor_count());
        S.drop(s1);
        push(U.dtor_count());

        R.drop(h1);
        R.drop(h2);
        return results[0..len];
    }
};
