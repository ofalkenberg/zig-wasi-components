//! Demo guest component. Wires the generated `bindings` module to
//! user-supplied implementations of the `greeter` world's exports.

const std = @import("std");
const bindings = @import("bindings");

comptime {
    _ = bindings; // pull in cabi_* entry points
}

pub const wit_exports = struct {
    pub fn greet(name: []const u8) u32 {
        // Round-trip through the host-provided log import so the
        // demo also exercises Zig → host calls.
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "hello {s}", .{name}) catch name;
        bindings.imports.log(msg);
        return @intCast(name.len);
    }
    pub fn sum(xs: []const u32) u32 {
        var total: u32 = 0;
        for (xs) |x| total +%= x;
        return total;
    }
    pub fn manhattan(p: bindings.point) u32 {
        const ax: u32 = @intCast(if (p.x < 0) -p.x else p.x);
        const ay: u32 = @intCast(if (p.y < 0) -p.y else p.y);
        return ax + ay;
    }

    /// Returns a string allocated into the canonical-ABI realloc arena.
    /// The bytes live in linear memory until `cabi_post_*` runs.
    pub fn format_greeting(name: []const u8) []const u8 {
        const prefix = "Hi, ";
        const total = prefix.len + name.len + 1;
        const buf = std.heap.wasm_allocator.alloc(u8, total) catch return prefix;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..name.len], name);
        buf[total - 1] = '!';
        return buf;
    }

    pub fn classify(n: i32) bindings.outcome {
        if (n == 0) return .{ .ok_empty = {} };
        if (n > 0) return .{ .ok_value = @intCast(n) };
        return .{ .fail = "negative" };
    }

    pub fn maybe_double(n: u32) bindings.maybe_double_result {
        if (n > 100) return null;
        return n *% 2;
    }

    pub fn safe_divide(a: u32, b: u32) bindings.safe_divide_result {
        if (b == 0) return .{ .err = "division by zero" };
        return .{ .ok = a / b };
    }

    pub fn pair(n: u32) bindings.pair_result {
        return .{ n, n *% 2 };
    }

    pub fn upper_char(c: u21) u21 {
        if (c >= 'a' and c <= 'z') return c - 32;
        return c;
    }

    pub fn sum_many(
        a0: u32,
        a1: u32,
        a2: u32,
        a3: u32,
        a4: u32,
        a5: u32,
        a6: u32,
        a7: u32,
        a8: u32,
        a9: u32,
        a10: u32,
        a11: u32,
        a12: u32,
        a13: u32,
        a14: u32,
        a15: u32,
        a16: u32,
    ) u32 {
        return a0 +% a1 +% a2 +% a3 +% a4 +% a5 +% a6 +% a7 +% a8 +%
            a9 +% a10 +% a11 +% a12 +% a13 +% a14 +% a15 +% a16;
    }

    pub fn total_distance(points: []const bindings.point) u32 {
        var total: u32 = 0;
        for (points) |p| {
            const ax: u32 = @intCast(if (p.x < 0) -p.x else p.x);
            const ay: u32 = @intCast(if (p.y < 0) -p.y else p.y);
            total +%= ax + ay;
        }
        return total;
    }

    pub fn perms_popcount(p: bindings.perms) u32 {
        var n: u32 = 0;
        if (p.read) n += 1;
        if (p.write) n += 1;
        if (p.exec) n += 1;
        return n;
    }

    pub fn divmod(a: u32, b: u32) bindings.divmod_result {
        return .{ a / b, a % b };
    }

    pub fn choose(r: bindings.choose_r, fallback: u32) u32 {
        return switch (r) {
            .ok => |s| if (s.len > 0) @intCast(s[0]) else fallback,
            .err => |v| v,
        };
    }

    pub fn distance_from_origin(p: bindings.point) u32 {
        const o = bindings.imports.origin();
        const dx: u32 = @intCast(if (p.x > o.x) p.x - o.x else o.x - p.x);
        const dy: u32 = @intCast(if (p.y > o.y) p.y - o.y else o.y - p.y);
        const label = bindings.imports.label_point(p);
        bindings.imports.log(label);
        return dx + dy;
    }
};
