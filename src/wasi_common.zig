//! Bindings-independent pieces shared by the `wasi` (WASI 0.2) and
//! `wasi3` (WASI 0.3) convenience modules. Everything here is either
//! pure code or generic only over the generated bindings namespaces
//! whose shapes did not change between the two WASI generations.

const std = @import("std");
const abi = @import("abi.zig");

pub const StreamError = abi.StreamCopyError;

pub const FsError = error{
    NotPreopened,
    FsAccess,
    FsExists,
    FsNotFound,
    FsIsDirectory,
    FsNotDirectory,
    FsNotEmpty,
    FsInvalid,
    FsIo,
    FsReadOnly,
    FsNoSpace,
    FsTooLarge,
    FsLoop,
    FsOther,
} || StreamError || std.mem.Allocator.Error;

pub const NetError = error{
    ResolveFailed,
    NameUnresolvable,
    ConnectFailed,
    CreateSocketFailed,
    InvalidAddress,
} || StreamError || std.mem.Allocator.Error;

/// Map a generated `wasi:filesystem` `error-code` (0.2 enum or 0.3
/// variant — the tag set below exists in both) onto `FsError`.
pub fn mapFsError(e: anytype) FsError {
    return switch (e) {
        .access, .not_permitted => error.FsAccess,
        .exist => error.FsExists,
        .no_entry => error.FsNotFound,
        .is_directory => error.FsIsDirectory,
        .not_directory => error.FsNotDirectory,
        .not_empty => error.FsNotEmpty,
        .invalid, .invalid_seek, .name_too_long => error.FsInvalid,
        .io, .interrupted, .pipe, .bad_descriptor => error.FsIo,
        .read_only => error.FsReadOnly,
        .insufficient_space, .quota => error.FsNoSpace,
        .file_too_large => error.FsTooLarge,
        .loop => error.FsLoop,
        else => error.FsOther,
    };
}

/// Fill `buf` by repeatedly calling a host `get-*-bytes(max_len)`
/// import until it stops producing.
pub fn fillFromHost(comptime get_bytes: anytype, buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const chunk = get_bytes(@intCast(buf.len - off));
        if (chunk.len == 0) break;
        const n = @min(chunk.len, buf.len - off);
        @memcpy(buf[off..][0..n], chunk[0..n]);
        off += n;
    }
}

/// Resolve `path` against the longest matching preopen in `dirs` (a
/// slice of `(descriptor, path)` tuples as returned by
/// `wasi:filesystem/preopens.get-directories()`). Returns the index of
/// the winning preopen plus the remaining (relative) tail.
/// Matching ignores repeated slashes, `.` components and trailing slashes.
/// `..` is left for the host to resolve.
/// `error.NotPreopened` is returned when no preopen prefix matches.
pub fn resolvePreopen(dirs: anytype, path: []const u8) error{NotPreopened}!struct { usize, []const u8 } {
    if (dirs.len == 0) return error.NotPreopened;

    var best: ?usize = null;
    var best_len: usize = 0;
    for (dirs, 0..) |p, i| {
        const prefix_len = matchedPrefix(path, p[1]) orelse continue;
        if (best == null or prefix_len > best_len) {
            best = i;
            best_len = prefix_len;
        }
    }
    const idx = best orelse return error.NotPreopened;
    var rel = path[best_len..];
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) rel = ".";
    return .{ idx, rel };
}

/// Return the end of the matching prefix in `path`, or null.
/// A "." preopen matches any relative path without consuming it.
fn matchedPrefix(path: []const u8, prefix: []const u8) ?usize {
    const path_absolute = path.len > 0 and path[0] == '/';
    const prefix_absolute = prefix.len > 0 and prefix[0] == '/';
    if (path_absolute != prefix_absolute) return null;

    var path_it = std.mem.tokenizeScalar(u8, path, '/');
    var prefix_it = std.mem.tokenizeScalar(u8, prefix, '/');
    var consumed: usize = 0;
    while (nextComponent(&prefix_it)) |want| {
        const got = nextComponent(&path_it) orelse return null;
        if (!std.mem.eql(u8, want, got)) return null;
        consumed = path_it.index;
    }
    return consumed;
}

fn nextComponent(it: *std.mem.TokenIterator(u8, .scalar)) ?[]const u8 {
    while (it.next()) |component| {
        if (!std.mem.eql(u8, component, ".")) return component;
    }
    return null;
}

/// HTTP support types shared by both convenience modules.
pub const Header = struct { name: []const u8, value: []const u8 };

pub const Response = struct {
    status: u16,
    headers: []Header,
    body: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.gpa.free(self.body);
        for (self.headers) |h| {
            self.gpa.free(h.name);
            self.gpa.free(h.value);
        }
        self.gpa.free(self.headers);
    }
};

pub const ParsedUrl = struct {
    https: bool,
    host: []const u8,
    path: []const u8,
};

/// Split an HTTP or HTTPS URL for `wasi:http`, omitting userinfo and fragments.
pub fn parseUrl(url: []const u8) ?ParsedUrl {
    const sep = std.mem.find(u8, url, "://") orelse return null;
    const scheme = url[0..sep];
    const https = if (std.ascii.eqlIgnoreCase(scheme, "https"))
        true
    else if (std.ascii.eqlIgnoreCase(scheme, "http"))
        false
    else
        return null;
    var rest = url[sep + 3 ..];
    if (std.mem.findScalar(u8, rest, '#')) |i| rest = rest[0..i];
    const authority_end = std.mem.findAny(u8, rest, "/?") orelse rest.len;
    var host = rest[0..authority_end];
    if (std.mem.findScalarLast(u8, host, '@')) |i| host = host[i + 1 ..];
    if (host.len == 0) return null;
    // `set-path-with-query` accepts a query without a leading path.
    const path = if (authority_end == rest.len) "/" else rest[authority_end..];
    return .{ .https = https, .host = host, .path = path };
}

/// Copy a slice of lifted tuples into `gpa`-owned memory, deep-copying
/// every `[]const u8` field. Lifted import results live in the
/// cabi_realloc arena, which is reset when the last live export task
/// exits — anything cached across export calls must own stable copies.
pub fn dupeTuplesStable(gpa: std.mem.Allocator, fresh: anytype) @TypeOf(fresh) {
    const T = @typeInfo(@TypeOf(fresh)).pointer.child;
    const info = @typeInfo(T).@"struct";
    const stable = gpa.alloc(T, fresh.len) catch @panic("oom");
    for (fresh, stable) |src, *dst| {
        dst.* = src;
        inline for (info.field_names, info.field_types) |name, FT| {
            if (comptime FT == []const u8)
                @field(dst, name) = gpa.dupe(u8, @field(src, name)) catch @panic("oom");
        }
    }
    return stable;
}

/// `wasi:random` kept the same shape across 0.2 and 0.3, so one
/// generic serves both convenience modules.
pub fn Random(comptime b: type) type {
    return struct {
        /// Fill `buf` with cryptographically secure random bytes.
        pub fn bytes(buf: []u8) void {
            fillFromHost(b.wasi_random_random.get_random_bytes, buf);
        }

        /// Allocate `len` cryptographically secure random bytes.
        /// The caller owns the returned slice.
        pub fn alloc(gpa: std.mem.Allocator, len: usize) ![]u8 {
            const out = try gpa.alloc(u8, len);
            errdefer gpa.free(out);
            bytes(out);
            return out;
        }

        /// Cryptographically secure random `u64`.
        pub fn int() u64 {
            return b.wasi_random_random.get_random_u64();
        }

        /// Insecure pseudo-random bytes. Do not use for anything
        /// security-sensitive.
        pub const insecure = struct {
            pub fn bytes(buf: []u8) void {
                fillFromHost(b.wasi_random_insecure.get_insecure_random_bytes, buf);
            }
            pub fn int() u64 {
                return b.wasi_random_insecure.get_insecure_random_u64();
            }
        };
    };
}

/// `wasi:cli` terminal probes, identical across 0.2 and 0.3.
pub fn Terminal(comptime b: type) type {
    return struct {
        fn probe(comptime acquire: anytype, comptime drop: anytype) bool {
            const maybe = acquire();
            if (maybe) |h| {
                drop(h);
                return true;
            }
            return false;
        }

        pub fn isStdoutTty() bool {
            return probe(
                b.wasi_cli_terminal_stdout.get_terminal_stdout,
                b.wasi_cli_terminal_output.resources.terminal_output.drop,
            );
        }
        pub fn isStderrTty() bool {
            return probe(
                b.wasi_cli_terminal_stderr.get_terminal_stderr,
                b.wasi_cli_terminal_output.resources.terminal_output.drop,
            );
        }
        pub fn isStdinTty() bool {
            return probe(
                b.wasi_cli_terminal_stdin.get_terminal_stdin,
                b.wasi_cli_terminal_input.resources.terminal_input.drop,
            );
        }
    };
}

/// `wasi:cli/exit`, identical across 0.2 and 0.3.
pub fn Exit(comptime b: type) type {
    return struct {
        pub fn success() noreturn {
            b.wasi_cli_exit.exit(.{ .ok = {} });
            unreachable;
        }
        pub fn failure() noreturn {
            b.wasi_cli_exit.exit(.{ .err = {} });
            unreachable;
        }

        /// Exit reporting an explicit 8-bit status code to the host,
        /// where 0 conventionally means success.
        pub fn withCode(code: u8) noreturn {
            b.wasi_cli_exit.exit_with_code(code);
            unreachable;
        }
    };
}

test "parseUrl handles common shapes" {
    {
        const p = parseUrl("https://example.com/").?;
        try std.testing.expect(p.https);
        try std.testing.expectEqualStrings("example.com", p.host);
        try std.testing.expectEqualStrings("/", p.path);
    }
    {
        const p = parseUrl("http://host:8080/a/b?c=1").?;
        try std.testing.expect(!p.https);
        try std.testing.expectEqualStrings("host:8080", p.host);
        try std.testing.expectEqualStrings("/a/b?c=1", p.path);
    }
    {
        const p = parseUrl("https://h").?;
        try std.testing.expectEqualStrings("h", p.host);
        try std.testing.expectEqualStrings("/", p.path);
    }
    {
        const p = parseUrl("HTTP://user:pw@host:1/p?q#frag").?;
        try std.testing.expect(!p.https);
        try std.testing.expectEqualStrings("host:1", p.host);
        try std.testing.expectEqualStrings("/p?q", p.path);
    }
    {
        const p = parseUrl("http://example.com?q=1").?;
        try std.testing.expectEqualStrings("example.com", p.host);
        try std.testing.expectEqualStrings("?q=1", p.path);
    }
    {
        const p = parseUrl("http://example.com#top").?;
        try std.testing.expectEqualStrings("example.com", p.host);
        try std.testing.expectEqualStrings("/", p.path);
    }
    {
        const p = parseUrl("http://[::1]:8080/x").?;
        try std.testing.expectEqualStrings("[::1]:8080", p.host);
        try std.testing.expectEqualStrings("/x", p.path);
    }
    try std.testing.expect(parseUrl("ftp://x/") == null);
    try std.testing.expect(parseUrl("https:///a") == null);
    try std.testing.expect(parseUrl("http://?q") == null);
}

test "resolvePreopen picks longest prefix and normalises" {
    const dirs = [_]struct { u32, []const u8 }{
        .{ 1, "/tmp" },
        .{ 2, "/tmp/deep" },
        .{ 3, "." },
    };
    {
        const idx, const rel = try resolvePreopen(dirs[0..], "/tmp/deep/x.txt");
        try std.testing.expectEqual(@as(usize, 1), idx);
        try std.testing.expectEqualStrings("x.txt", rel);
    }
    {
        const idx, const rel = try resolvePreopen(dirs[0..], "/tmp");
        try std.testing.expectEqual(@as(usize, 0), idx);
        try std.testing.expectEqualStrings(".", rel);
    }
    {
        const idx, const rel = try resolvePreopen(dirs[0..], "relative/file");
        try std.testing.expectEqual(@as(usize, 2), idx);
        try std.testing.expectEqualStrings("relative/file", rel);
    }
    try std.testing.expectError(error.NotPreopened, resolvePreopen(dirs[0..2], "/etc/passwd"));
    try std.testing.expectError(error.NotPreopened, resolvePreopen(dirs[0..2], "/tmpfoo"));
    {
        const idx, const rel = try resolvePreopen(dirs[0..], "//tmp/./deep//x.txt");
        try std.testing.expectEqual(@as(usize, 1), idx);
        try std.testing.expectEqualStrings("x.txt", rel);
    }
}

test "resolvePreopen ignores trailing slashes on preopen names" {
    const dirs = [_]struct { u32, []const u8 }{
        .{ 1, "/data/" },
        .{ 2, "/" },
    };
    {
        const idx, const rel = try resolvePreopen(dirs[0..], "/data");
        try std.testing.expectEqual(@as(usize, 0), idx);
        try std.testing.expectEqualStrings(".", rel);
    }
    {
        const idx, const rel = try resolvePreopen(dirs[0..], "/data/a/b");
        try std.testing.expectEqual(@as(usize, 0), idx);
        try std.testing.expectEqualStrings("a/b", rel);
    }
    {
        const idx, const rel = try resolvePreopen(dirs[0..], "/etc/x");
        try std.testing.expectEqual(@as(usize, 1), idx);
        try std.testing.expectEqualStrings("etc/x", rel);
    }
    try std.testing.expectError(error.NotPreopened, resolvePreopen(dirs[0..], "rel"));
}

test "dupeTuplesStable deep-copies string fields" {
    const gpa = std.testing.allocator;
    const Pair = struct { u32, []const u8 };
    var name_buf = "hello".*;
    const fresh = [_]Pair{ .{ 7, &name_buf }, .{ 9, "static" } };
    const stable = dupeTuplesStable(gpa, @as([]const Pair, &fresh));
    defer {
        for (stable) |p| gpa.free(p[1]);
        gpa.free(stable);
    }
    name_buf = "XXXXX".*;
    try std.testing.expectEqual(@as(u32, 7), stable[0][0]);
    try std.testing.expectEqualStrings("hello", stable[0][1]);
    try std.testing.expectEqualStrings("static", stable[1][1]);
}
