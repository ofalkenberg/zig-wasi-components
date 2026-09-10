const b = @import("bindings");
comptime {
    _ = b;
}

pub const wit_exports = struct {
    pub const first = struct {
        pub fn echo(x: b.test_scopes_first.types.item) b.test_scopes_first.types.item {
            return x;
        }
    };
    pub const renamed = struct {
        pub fn echo(x: b.test_scopes_second.types.item) b.test_scopes_second.types.item {
            return x;
        }
    };
    pub const api = struct {
        pub fn echo(x: ?b.test_scopes_api.types.value) ?b.test_scopes_api.types.value {
            return x;
        }
        pub fn echo_list(x: []const b.test_scopes_api.types.value) []const b.test_scopes_api.types.value {
            return x;
        }
    };
    pub fn top_echo(x: b.top) b.top {
        return x;
    }
    pub const inline_api = struct {
        pub fn echo(x: b.inline_api.types.renamed) b.inline_api.types.renamed {
            return x;
        }
        pub fn local_echo(x: b.inline_api.types.local) b.inline_api.types.local {
            return x;
        }
    };
};
