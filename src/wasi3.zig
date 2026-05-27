//! Reusable helpers for guest components targeting WASI 0.3.
//!
//! WASI 0.3 redesigned I/O around native component-model `stream<T>`
//! and `future<T>` values: stdio, file contents, TCP payloads and HTTP
//! bodies all travel through streams, and operations that used to hand
//! back a `pollable` now either are `async func`s (which the generated
//! bindings drive to completion for you) or return a future carrying
//! the operation's final status. This module wraps that machinery into
//! the same blocking, allocator-friendly surface `wasi.Wasi` offers
//! for WASI 0.2.
//!
//! Usage from a guest component:
//!
//! ```zig
//! const std = @import("std");
//! const bindings = @import("bindings");
//! const wasi3 = @import("zig_wasi_components").wasi3.Wasi3(bindings);
//!
//! pub const wit_exports = struct {
//!     pub const run = struct {
//!         pub fn run() bindings.run_run_result {
//!             wasi3.stdout.print("now = {d}\n", .{wasi3.clock.monotonic()}) catch {};
//!             return .{ .ok = {} };
//!         }
//!     };
//! };
//! ```
//!
//! The wrapper is generic over the bindings type so it works against
//! any world whose imports include the relevant WASI interfaces. Zig
//! only semantically analyses a generic instantiation on the paths
//! that are actually called, so importing this module does not force
//! the caller's world to include every interface — only the ones whose
//! helpers are exercised.
//!
//! Blocking model: stream reads/writes use the synchronous canonical
//! built-ins, which suspend the calling task until progress is made;
//! the host keeps running concurrently, so writing to stdout or
//! draining a file stream behaves like ordinary blocking I/O.

const std = @import("std");
const abi = @import("abi.zig");
const common = @import("wasi_common.zig");

pub fn Wasi3(comptime b: type) type {
    return struct {
        pub const bindings = b;

        pub const StreamError = common.StreamError;
        pub const FsError = common.FsError;
        pub const NetError = common.NetError;

        /// The common 0.3 write shape: pump `data` into the writable
        /// end, drop it to signal EOF, then await the operation's
        /// result future. `ns` is a generated intrinsics namespace
        /// with `stream0` (the payload) and `future1` (the result).
        fn writeViaStream(comptime ns: type, writable: abi.Stream, fut: abi.Future, data: []const u8) StreamError!ns.future1.T {
            defer ns.future1.dropReadable(fut);
            const wr = abi.streamWriteAll(ns.stream0, writable, data);
            ns.stream0.dropWritable(writable);
            try wr;
            return abi.futureAwait(ns.future1, fut) orelse error.StreamFailed;
        }

        pub const clock = struct {
            pub const Instant = b.wasi_clocks_system_clock.types.instant;

            /// Wall-clock time as seconds (signed) plus nanoseconds
            /// since the Unix epoch. Not monotonic; do not use for
            /// elapsed time.
            pub fn now() Instant {
                return b.wasi_clocks_system_clock.now();
            }

            pub fn resolution() u64 {
                return b.wasi_clocks_system_clock.get_resolution();
            }

            /// Wall-clock time as fractional seconds since the Unix epoch.
            pub fn unixSeconds() f64 {
                const t = now();
                return @as(f64, @floatFromInt(t.seconds)) +
                    @as(f64, @floatFromInt(t.nanoseconds)) * 1e-9;
            }

            /// Monotonic clock value in nanoseconds since an unspecified
            /// origin. Suitable for measuring elapsed time.
            pub fn monotonic() u64 {
                return b.wasi_clocks_monotonic_clock.now();
            }

            pub fn monotonicResolution() u64 {
                return b.wasi_clocks_monotonic_clock.get_resolution();
            }

            /// Block the current task until the given monotonic mark.
            pub fn sleepUntil(mark_ns: u64) void {
                b.wasi_clocks_monotonic_clock.wait_until(mark_ns);
            }

            pub fn sleepNanos(ns: u64) void {
                b.wasi_clocks_monotonic_clock.wait_for(ns);
            }

            pub fn sleepMillis(ms: u64) void {
                sleepNanos(ms *| std.time.ns_per_ms);
            }

            pub fn sleepSeconds(s: u64) void {
                sleepNanos(s *| std.time.ns_per_s);
            }

            /// IANA identifier of the host's configured timezone, when
            /// it exposes one. Backed by the unstable
            /// `wasi:clocks/timezone` interface.
            pub fn timezoneId() ?[]const u8 {
                return b.wasi_clocks_timezone.iana_id();
            }

            /// Nanoseconds between UTC and local time at `when`.
            pub fn utcOffset(when: Instant) ?i64 {
                return b.wasi_clocks_timezone.utc_offset(when);
            }

            pub fn timezoneDebugString() []const u8 {
                return b.wasi_clocks_timezone.to_debug_string();
            }
        };

        pub const random = common.Random(b);
        pub const terminal = common.Terminal(b);
        pub const exit = common.Exit(b);

        pub const stdout = OutputStream(b.wasi_cli_stdout);
        pub const stderr = OutputStream(b.wasi_cli_stderr);

        fn OutputStream(comptime iface: type) type {
            return struct {
                const ns = iface.intrinsics_write_via_stream;

                /// Write the given bytes and block until the host has
                /// fully accepted them and reported the outcome.
                pub fn write(data: []const u8) StreamError!void {
                    const ends = ns.stream0.new();
                    const fut = iface.write_via_stream(ends.readable);
                    return switch (try writeViaStream(ns, ends.writable, fut, data)) {
                        .ok => {},
                        .err => error.StreamFailed,
                    };
                }

                /// `std.fmt.bufPrint` into a 4 KiB stack buffer, then
                /// write. For longer output, format into your own
                /// allocator-backed buffer and call `write`.
                pub fn print(comptime fmt: []const u8, args: anytype) !void {
                    var buf: [4096]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, fmt, args);
                    return write(s);
                }
            };
        }

        pub const stdin = struct {
            /// Read stdin until EOF or `max_bytes`. Caller owns the
            /// returned slice.
            pub fn read(gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
                const ns = b.wasi_cli_stdin.intrinsics_read_via_stream;
                const pair = b.wasi_cli_stdin.read_via_stream();
                defer ns.future1.dropReadable(pair[1]);
                defer ns.stream0.dropReadable(pair[0]);
                return abi.streamDrainBytes(ns.stream0, gpa, pair[0], max_bytes);
            }
        };

        pub const environment = struct {
            var vars_cache: ?[]const struct { []const u8, []const u8 } = null;

            /// All `(name, value)` environment variables visible to the
            /// component. Cached on first call. Returned by reference;
            /// do not free.
            pub fn vars() []const struct { []const u8, []const u8 } {
                if (vars_cache) |c| return c;
                const fresh = b.wasi_cli_environment.get_environment();
                vars_cache = fresh;
                return fresh;
            }

            /// First value for `name`, or null if unset. Returned by
            /// reference; do not free.
            pub fn get(name: []const u8) ?[]const u8 {
                for (vars()) |kv| {
                    if (std.mem.eql(u8, kv[0], name)) return kv[1];
                }
                return null;
            }

            /// The POSIX-style argument vector.
            pub fn args() []const []const u8 {
                return b.wasi_cli_environment.get_arguments();
            }

            /// The initial working directory, if the host provided one.
            pub fn cwd() ?[]const u8 {
                return b.wasi_cli_environment.get_initial_cwd();
            }
        };

        pub const fs = struct {
            const fst = b.wasi_filesystem_types;
            const fsd = fst.resources.descriptor;
            const fsp = b.wasi_filesystem_preopens;

            pub const FileType = enum {
                unknown,
                block_device,
                character_device,
                directory,
                fifo,
                symbolic_link,
                regular_file,
                socket,

                fn from(t: fst.types.descriptor_type) FileType {
                    return switch (t) {
                        .block_device => .block_device,
                        .character_device => .character_device,
                        .directory => .directory,
                        .fifo => .fifo,
                        .symbolic_link => .symbolic_link,
                        .regular_file => .regular_file,
                        .socket => .socket,
                        .other => .unknown,
                    };
                }
            };

            pub const Stat = struct {
                kind: FileType,
                size: u64,
                modified_seconds: ?i64,
            };

            pub const Entry = struct {
                kind: FileType,
                name: []u8,
            };

            const Resolved = struct {
                desc: fst.types.descriptor,
                rel: []const u8,
            };

            fn resolve(path: []const u8) FsError!Resolved {
                const dirs = cachedPreopens();
                const idx, const rel = try common.resolvePreopen(dirs, path);
                return .{ .desc = dirs[idx][0], .rel = rel };
            }

            var preopens_cache: ?[]const struct { fst.types.descriptor, []const u8 } = null;

            fn cachedPreopens() []const struct { fst.types.descriptor, []const u8 } {
                if (preopens_cache) |c| return c;
                const fresh = fsp.get_directories();
                preopens_cache = fresh;
                return fresh;
            }

            const mapError = common.mapFsError;

            fn openAt(r: Resolved, open_flags: fst.types.open_flags, flags: fst.types.descriptor_flags) FsError!fst.types.descriptor {
                return switch (fsd.open_at(
                    r.desc,
                    .{ .symlink_follow = true },
                    r.rel,
                    open_flags,
                    flags,
                )) {
                    .ok => |d| d,
                    .err => |e| mapError(e),
                };
            }

            const read_only_flags: fst.types.descriptor_flags = .{
                .read = true,
                .write = false,
                .file_integrity_sync = false,
                .data_integrity_sync = false,
                .requested_write_sync = false,
                .mutate_directory = false,
            };

            const write_only_flags: fst.types.descriptor_flags = .{
                .read = false,
                .write = true,
                .file_integrity_sync = false,
                .data_integrity_sync = false,
                .requested_write_sync = false,
                .mutate_directory = false,
            };

            /// Read an entire file into a freshly-allocated slice.
            pub fn readFile(gpa: std.mem.Allocator, path: []const u8) FsError![]u8 {
                const r = try resolve(path);
                const fd = try openAt(r, .{ .create = false, .directory = false, .exclusive = false, .truncate = false }, read_only_flags);
                defer fsd.drop(fd);

                const ns = fsd.intrinsics_read_via_stream;
                const pair = fsd.read_via_stream(fd, 0);
                defer ns.future1.dropReadable(pair[1]);

                const drained = abi.streamDrainBytes(ns.stream0, gpa, pair[0], std.math.maxInt(usize));
                ns.stream0.dropReadable(pair[0]);
                const data = try drained;
                errdefer gpa.free(data);

                const res = abi.futureAwait(ns.future1, pair[1]) orelse return error.StreamFailed;
                return switch (res) {
                    .ok => data,
                    .err => |e| mapError(e),
                };
            }

            fn writeStreamTo(fd: fst.types.descriptor, data: []const u8, comptime append: bool) FsError!void {
                const ns = if (append) fsd.intrinsics_append_via_stream else fsd.intrinsics_write_via_stream;
                const ends = ns.stream0.new();
                const fut = if (append)
                    fsd.append_via_stream(fd, ends.readable)
                else
                    fsd.write_via_stream(fd, ends.readable, 0);
                return switch (try writeViaStream(ns, ends.writable, fut, data)) {
                    .ok => {},
                    .err => |e| mapError(e),
                };
            }

            /// Write `data` to `path`, replacing any existing file.
            pub fn writeFile(path: []const u8, data: []const u8) FsError!void {
                const r = try resolve(path);
                const fd = try openAt(r, .{ .create = true, .directory = false, .exclusive = false, .truncate = true }, write_only_flags);
                defer fsd.drop(fd);
                return writeStreamTo(fd, data, false);
            }

            /// Append `data` to `path`, creating the file if missing.
            pub fn appendFile(path: []const u8, data: []const u8) FsError!void {
                const r = try resolve(path);
                const fd = try openAt(r, .{ .create = true, .directory = false, .exclusive = false, .truncate = false }, write_only_flags);
                defer fsd.drop(fd);
                return writeStreamTo(fd, data, true);
            }

            /// `stat`-style metadata for the file at `path`.
            pub fn stat(path: []const u8) FsError!Stat {
                const r = try resolve(path);
                const s = switch (fsd.stat_at(r.desc, .{ .symlink_follow = true }, r.rel)) {
                    .ok => |x| x,
                    .err => |e| return mapError(e),
                };
                return .{
                    .kind = FileType.from(s.type),
                    .size = s.size,
                    .modified_seconds = if (s.data_modification_timestamp) |t| t.seconds else null,
                };
            }

            /// Quick existence probe. Returns false on any error rather
            /// than propagating it.
            pub fn exists(path: []const u8) bool {
                _ = stat(path) catch return false;
                return true;
            }

            pub fn remove(path: []const u8) FsError!void {
                const r = try resolve(path);
                switch (fsd.unlink_file_at(r.desc, r.rel)) {
                    .ok => {},
                    .err => |e| return mapError(e),
                }
            }

            pub fn mkdir(path: []const u8) FsError!void {
                const r = try resolve(path);
                switch (fsd.create_directory_at(r.desc, r.rel)) {
                    .ok => {},
                    .err => |e| return mapError(e),
                }
            }

            pub fn rmdir(path: []const u8) FsError!void {
                const r = try resolve(path);
                switch (fsd.remove_directory_at(r.desc, r.rel)) {
                    .ok => {},
                    .err => |e| return mapError(e),
                }
            }

            /// Rename `old_path` to `new_path`.
            pub fn rename(old_path: []const u8, new_path: []const u8) FsError!void {
                const ro = try resolve(old_path);
                const rn = try resolve(new_path);
                switch (fsd.rename_at(ro.desc, ro.rel, rn.desc, rn.rel)) {
                    .ok => {},
                    .err => |e| return mapError(e),
                }
            }

            /// Read directory entries from the stream in batches,
            /// lifting each from its canonical element layout.
            fn readEntriesInto(gpa: std.mem.Allocator, entries: *std.ArrayList(Entry), readable: abi.Stream) FsError!void {
                const ns = fsd.intrinsics_read_directory.stream0;
                const batch = 16;
                var buf: [batch * ns.elem_size]u8 align(ns.elem_align) = undefined;
                while (true) {
                    switch (ns.readRaw(readable, @intFromPtr(&buf), batch)) {
                        .blocked => return error.StreamFailed,
                        .done => |d| {
                            for (0..d.progress) |i| {
                                const entry = ns.lift(@intFromPtr(&buf) + i * ns.elem_size);
                                const name_dup = try gpa.dupe(u8, entry.name);
                                errdefer gpa.free(name_dup);
                                try entries.append(gpa, .{
                                    .kind = FileType.from(entry.type),
                                    .name = name_dup,
                                });
                            }
                            if (d.result != .completed) return;
                        },
                    }
                }
            }

            /// List the entries in the directory at `path`. The caller
            /// owns both the slice and every `name` field.
            pub fn listDir(gpa: std.mem.Allocator, path: []const u8) FsError![]Entry {
                const r = try resolve(path);
                const dir = try openAt(r, .{ .create = false, .directory = true, .exclusive = false, .truncate = false }, read_only_flags);
                defer fsd.drop(dir);

                const ns = fsd.intrinsics_read_directory;
                const pair = fsd.read_directory(dir);
                defer ns.future1.dropReadable(pair[1]);

                var entries: std.ArrayList(Entry) = .empty;
                errdefer {
                    for (entries.items) |e| gpa.free(e.name);
                    entries.deinit(gpa);
                }

                const rd = readEntriesInto(gpa, &entries, pair[0]);
                ns.stream0.dropReadable(pair[0]);
                try rd;

                const res = abi.futureAwait(ns.future1, pair[1]) orelse return error.StreamFailed;
                return switch (res) {
                    .ok => try entries.toOwnedSlice(gpa),
                    .err => |e| mapError(e),
                };
            }

            /// The set of `(descriptor, path)` preopens the host gave us.
            /// Cached on first call. Returned by reference; do not drop
            /// the descriptors.
            pub fn preopens() []const struct { fst.types.descriptor, []const u8 } {
                return cachedPreopens();
            }
        };

        pub const net = struct {
            const skt = b.wasi_sockets_types;
            const tcp = skt.resources.tcp_socket;
            const lookup = b.wasi_sockets_ip_name_lookup;

            pub const Ipv4 = struct { u8, u8, u8, u8 };
            pub const Ipv6 = struct { u16, u16, u16, u16, u16, u16, u16, u16 };

            pub const Address = union(enum) {
                v4: Ipv4,
                v6: Ipv6,

                fn fromRaw(ip: skt.types.ip_address) Address {
                    return switch (ip) {
                        .ipv4 => |a| .{ .v4 = a },
                        .ipv6 => |a| .{ .v6 = a },
                    };
                }

                fn toSocketRaw(self: Address, port: u16) skt.types.ip_socket_address {
                    return switch (self) {
                        .v4 => |a| .{ .ipv4 = .{ .port = port, .address = a } },
                        .v6 => |a| .{ .ipv6 = .{
                            .port = port,
                            .flow_info = 0,
                            .address = a,
                            .scope_id = 0,
                        } },
                    };
                }

                pub fn family(self: Address) skt.types.ip_address_family {
                    return switch (self) {
                        .v4 => .ipv4,
                        .v6 => .ipv6,
                    };
                }

                pub fn format(self: Address, writer: anytype) !void {
                    switch (self) {
                        .v4 => |a| try writer.print("{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }),
                        .v6 => |a| try writer.print(
                            "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}",
                            .{ a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7] },
                        ),
                    }
                }
            };

            /// Resolve `host` to a list of IP addresses. Caller owns the
            /// returned slice. Returns `error.NameUnresolvable` for
            /// non-existent names.
            pub fn resolve(gpa: std.mem.Allocator, host: []const u8) NetError![]Address {
                const raw = switch (lookup.resolve_addresses(host)) {
                    .ok => |x| x,
                    .err => |e| return switch (e) {
                        .name_unresolvable => error.NameUnresolvable,
                        .invalid_argument => error.InvalidAddress,
                        else => error.ResolveFailed,
                    },
                };
                if (raw.len == 0) return error.NameUnresolvable;
                const addrs = try gpa.alloc(Address, raw.len);
                for (raw, addrs) |ip, *a| a.* = Address.fromRaw(ip);
                return addrs;
            }

            pub const TcpStream = struct {
                socket: skt.types.tcp_socket,
                send_writable: abi.Stream,
                send_future: abi.Future,
                recv_readable: abi.Stream,
                recv_future: abi.Future,
                closed: bool = false,

                pub fn write(self: TcpStream, data: []const u8) StreamError!void {
                    return abi.streamWriteAll(tcp.intrinsics_send.stream0, self.send_writable, data);
                }

                pub fn readAll(self: TcpStream, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
                    return abi.streamDrainBytes(tcp.intrinsics_receive.stream0, gpa, self.recv_readable, max_bytes);
                }

                /// Drop the connection's streams, futures and socket.
                /// Idempotent — `defer conn.close()` plus a final
                /// `conn.close()` on the happy path will not double-drop.
                pub fn close(self: *TcpStream) void {
                    if (self.closed) return;
                    self.closed = true;
                    tcp.intrinsics_send.stream0.dropWritable(self.send_writable);
                    tcp.intrinsics_send.future1.dropReadable(self.send_future);
                    tcp.intrinsics_receive.stream0.dropReadable(self.recv_readable);
                    tcp.intrinsics_receive.future1.dropReadable(self.recv_future);
                    tcp.drop(self.socket);
                }
            };

            /// Open a TCP connection to `addr:port`, returning a
            /// blocking read/write stream pair.
            pub fn connectTcp(addr: Address, port: u16) NetError!TcpStream {
                const sock = switch (tcp.create(addr.family())) {
                    .ok => |s| s,
                    .err => return error.CreateSocketFailed,
                };
                errdefer tcp.drop(sock);

                switch (tcp.connect(sock, addr.toSocketRaw(port))) {
                    .ok => {},
                    .err => return error.ConnectFailed,
                }

                const send_ends = tcp.intrinsics_send.stream0.new();
                const send_future = tcp.send(sock, send_ends.readable);
                const recv_pair = tcp.receive(sock);

                return .{
                    .socket = sock,
                    .send_writable = send_ends.writable,
                    .send_future = send_future,
                    .recv_readable = recv_pair[0],
                    .recv_future = recv_pair[1],
                };
            }
        };

        pub const HttpError = error{
            BadUrl,
            SetAuthorityFailed,
            SetPathFailed,
            SetSchemeFailed,
            SetMethodFailed,
            HeadersFailed,
            HandleFailed,
            HttpErrored,
        } || StreamError || std.mem.Allocator.Error;

        pub const http = struct {
            const wht = b.wasi_http_types;
            const client = b.wasi_http_client;
            const req_res = wht.resources.request;
            const resp_res = wht.resources.response;
            const fields_res = wht.resources.fields;

            pub const Method = enum {
                get,
                head,
                post,
                put,
                delete,
                connect,
                options,
                trace,
                patch,

                fn lower(self: Method) wht.types.method {
                    return switch (self) {
                        inline else => |t| @unionInit(wht.types.method, @tagName(t), {}),
                    };
                }
            };

            pub const Header = common.Header;
            pub const Response = common.Response;

            pub const Request = struct {
                url: []const u8,
                method: Method = .get,
                headers: []const Header = &.{},
            };

            fn check(res: anytype, comptime e: HttpError) HttpError!void {
                return switch (res) {
                    .ok => {},
                    .err => e,
                };
            }

            /// Convenience: fetch `url` with GET and return just the
            /// response body. Caller owns the returned slice.
            pub fn get(gpa: std.mem.Allocator, url: []const u8) HttpError![]u8 {
                var resp = try fetch(gpa, .{ .url = url });
                const body = resp.body;
                resp.body = &.{};
                resp.deinit();
                return body;
            }

            /// Issue a request and read the entire response into memory.
            /// The caller must `deinit` the returned `Response`.
            ///
            /// Request bodies are not supported yet: streaming one
            /// requires interleaving body writes with the in-flight
            /// `client.send` call, which needs the state-machine async
            /// form rather than this blocking convenience wrapper.
            pub fn fetch(gpa: std.mem.Allocator, req: Request) HttpError!Response {
                const target = common.parseUrl(req.url) orelse return error.BadUrl;

                const entries = try gpa.alloc(struct { []const u8, []const u8 }, req.headers.len);
                defer gpa.free(entries);
                for (req.headers, entries) |h, *e| e.* = .{ h.name, h.value };

                const headers = switch (fields_res.from_list(entries)) {
                    .ok => |h| h,
                    .err => return error.HeadersFailed,
                };

                // request.new wants a trailers future. The host only
                // reads it while `send` is in flight, so park an async
                // write of `ok(none)` in a buffer that outlives the
                // blocking call, and reap it afterwards.
                const rn = req_res.intrinsics_new;
                const trailers = rn.future1.new();
                var trailers_buf: [rn.future1.elem_size]u8 align(rn.future1.elem_align) = undefined;
                rn.future1.lower(.{ .ok = null }, @intFromPtr(&trailers_buf));
                _ = rn.future1.writeRawAsync(trailers.writable, @intFromPtr(&trailers_buf));
                defer {
                    _ = rn.future1.cancelWrite(trailers.writable);
                    rn.future1.dropWritable(trailers.writable);
                }

                const made = req_res.new(headers, null, trailers.readable, null);
                const outgoing = made[0];
                defer rn.future2.dropReadable(made[1]);

                try check(req_res.set_method(outgoing, req.method.lower()), error.SetMethodFailed);
                try check(req_res.set_authority(outgoing, target.host), error.SetAuthorityFailed);
                try check(req_res.set_path_with_query(outgoing, target.path), error.SetPathFailed);
                const scheme: wht.types.scheme = if (target.https) .{ .HTTPS = {} } else .{ .HTTP = {} };
                try check(req_res.set_scheme(outgoing, scheme), error.SetSchemeFailed);

                const response = switch (client.send(outgoing)) {
                    .ok => |r| r,
                    .err => return error.HttpErrored,
                };

                const status = resp_res.get_status_code(response);

                var headers_out: std.ArrayList(Header) = .empty;
                errdefer {
                    for (headers_out.items) |h| {
                        gpa.free(h.name);
                        gpa.free(h.value);
                    }
                    headers_out.deinit(gpa);
                }
                {
                    const hdr_fields = resp_res.get_headers(response);
                    defer fields_res.drop(hdr_fields);
                    for (fields_res.copy_all(hdr_fields)) |kv| {
                        const name_dup = try gpa.dupe(u8, kv[0]);
                        errdefer gpa.free(name_dup);
                        const value_dup = try gpa.dupe(u8, kv[1]);
                        errdefer gpa.free(value_dup);
                        try headers_out.append(gpa, .{ .name = name_dup, .value = value_dup });
                    }
                }

                // consume-body moves the response, so it must not be
                // dropped afterwards. The `res` future lets us report a
                // processing error to the host; we never need to, so
                // its writable end is reaped unwritten.
                const cb = resp_res.intrinsics_consume_body;
                const res_pair = cb.future0.new();
                defer {
                    _ = cb.future0.cancelWrite(res_pair.writable);
                    cb.future0.dropWritable(res_pair.writable);
                }
                const body_pair = resp_res.consume_body(response, res_pair.readable);
                defer cb.future2.dropReadable(body_pair[1]);

                const drained = abi.streamDrainBytes(cb.stream1, gpa, body_pair[0], std.math.maxInt(usize));
                cb.stream1.dropReadable(body_pair[0]);
                const body = try drained;
                errdefer gpa.free(body);

                if (abi.futureAwait(cb.future2, body_pair[1])) |trailer_res| {
                    switch (trailer_res) {
                        .ok => |maybe| if (maybe) |t| fields_res.drop(t),
                        .err => return error.HttpErrored,
                    }
                }

                return .{
                    .status = status,
                    .headers = try headers_out.toOwnedSlice(gpa),
                    .body = body,
                    .gpa = gpa,
                };
            }
        };
    };
}
