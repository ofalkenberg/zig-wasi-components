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
/// Trailing/leading slashes in the user path are normalised;
/// `error.NotPreopened` is returned when no preopen prefix matches.
pub fn resolvePreopen(dirs: anytype, path: []const u8) error{NotPreopened}!struct { usize, []const u8 } {
    if (dirs.len == 0) return error.NotPreopened;

    const is_absolute = path.len > 0 and path[0] == '/';
    var best: ?usize = null;
    var best_len: usize = 0;
    for (dirs, 0..) |p, i| {
        const prefix_len = matchedPrefix(path, p[1], is_absolute) orelse continue;
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

/// Length of `prefix` consumed from `path` if `prefix` is a
/// directory-aligned prefix, else null. A preopen named "." (the
/// common `wasmtime --dir .` case) matches every relative input path
/// with a zero-byte consumption so the rest is forwarded as-is.
fn matchedPrefix(path: []const u8, prefix: []const u8, is_absolute: bool) ?usize {
    if (std.mem.eql(u8, prefix, ".")) {
        return if (is_absolute) null else 0;
    }
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len == prefix.len) return prefix.len;
    if (prefix.len > 0 and prefix[prefix.len - 1] == '/') return prefix.len;
    if (path[prefix.len] == '/') return prefix.len;
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

pub fn parseUrl(url: []const u8) ?ParsedUrl {
    var rest = url;
    var https = false;
    if (std.mem.startsWith(u8, rest, "https://")) {
        https = true;
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const host = if (slash) |i| rest[0..i] else rest;
    if (host.len == 0) return null;
    const path = if (slash) |i| rest[i..] else "/";
    return .{ .https = https, .host = host, .path = path };
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
    try std.testing.expect(parseUrl("ftp://x/") == null);
    try std.testing.expect(parseUrl("https:///a") == null);
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
}
