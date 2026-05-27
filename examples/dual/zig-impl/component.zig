//! Zig sibling component for the dual demo. Same WIT as the Rust
//! one (`demo:math`/`world math`), reachable via either binding.

const std = @import("std");
const bindings = @import("bindings");

comptime {
    _ = bindings;
}

pub const wit_exports = struct {
    pub fn add(a: u32, b: u32) u32 {
        return a +% b;
    }
};
