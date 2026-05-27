//! Reusable helpers for guest components targeting WASI 0.2+.
//!
//! The functions here are thin wrappers around the auto-generated
//! `bindings` module: clocks, randomness, stdio, environment, exit,
//! a small HTTP client, a filesystem layer with sandbox-aware path
//! resolution, and basic TCP + DNS. The goal is to make the common
//! cases readable without forcing the user to learn the canonical-ABI
//! resource dance.
//!
//! Usage from a guest component:
//!
//! ```zig
//! const std = @import("std");
//! const bindings = @import("bindings");
//! const wasi = @import("zig_wasi_components").wasi.Wasi(bindings);
//!
//! pub const wit_exports = struct {
//!     pub const run = struct {
//!         pub fn run() bindings.run_run_result {
//!             try wasi.stdout.print("now = {d}\n", .{wasi.clock.monotonic()});
//!             return .{ .ok = {} };
//!         }
//!     };
//! };
//! ```
//!
//! The wrapper is generic over the bindings type so it works against
//! any world whose imports include the relevant WASI interfaces. Because
//! Zig only semantically analyses a generic instantiation on the paths
//! that are actually called, importing this module does not force the
//! caller's world to include every interface — only the ones whose
//! helpers are exercised.

const std = @import("std");
const common = @import("wasi_common.zig");

pub fn Wasi(comptime b: type) type {
    return struct {
        pub const bindings = b;

        pub const clock = struct {
            pub const Datetime = b.wasi_clocks_wall_clock.types.datetime;

            /// Wall-clock time as seconds plus nanoseconds since the
            /// Unix epoch. Not monotonic; do not use for elapsed time.
            pub fn now() Datetime {
                return b.wasi_clocks_wall_clock.now();
            }

            pub fn resolution() Datetime {
                return b.wasi_clocks_wall_clock.resolution();
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
                return b.wasi_clocks_monotonic_clock.resolution();
            }

            /// Block the current task until the given monotonic instant
            /// is reached.
            pub fn sleepUntil(instant_ns: u64) void {
                const p = b.wasi_clocks_monotonic_clock.subscribe_instant(instant_ns);
                b.wasi_io_poll.resources.pollable.block(p);
                b.wasi_io_poll.resources.pollable.drop(p);
            }

            pub fn sleepNanos(ns: u64) void {
                const p = b.wasi_clocks_monotonic_clock.subscribe_duration(ns);
                b.wasi_io_poll.resources.pollable.block(p);
                b.wasi_io_poll.resources.pollable.drop(p);
            }

            pub fn sleepMillis(ms: u64) void {
                sleepNanos(ms *| std.time.ns_per_ms);
            }

            pub fn sleepSeconds(s: u64) void {
                sleepNanos(s *| std.time.ns_per_s);
            }

            pub const TimezoneDisplay = b.wasi_clocks_timezone.types.timezone_display;

            /// Timezone information for displaying a wall-clock `when` to a
            /// user: the UTC offset in seconds, an abbreviated name, and a
            /// daylight-saving flag. Backed by the unstable
            /// `wasi:clocks/timezone` interface, so the host must export it.
            pub fn timezone(when: Datetime) TimezoneDisplay {
                return b.wasi_clocks_timezone.display(when);
            }

            /// The signed UTC offset in seconds for `when`, without the rest
            /// of the `timezone` payload.
            pub fn utcOffset(when: Datetime) i32 {
                return b.wasi_clocks_timezone.utc_offset(when);
            }
        };

        pub const random = common.Random(b);

        pub const StreamError = common.StreamError;

        /// Write `data` to `stream` in 4 KiB blocking flushes.
        /// Used by stdio, the HTTP body uploader, fs.write* and TCP.
        fn blockingWriteAll(
            stream: b.wasi_io_streams.types.output_stream,
            data: []const u8,
        ) StreamError!void {
            var off: usize = 0;
            while (off < data.len) {
                const chunk_len = @min(data.len - off, 4096);
                switch (b.wasi_io_streams.resources.output_stream.blocking_write_and_flush(
                    stream,
                    data[off..][0..chunk_len],
                )) {
                    .ok => {},
                    .err => |e| switch (e) {
                        .closed => return error.StreamClosed,
                        .last_operation_failed => |err_h| {
                            b.wasi_io_error.resources.@"error".drop(err_h);
                            return error.StreamFailed;
                        },
                    },
                }
                off += chunk_len;
            }
        }

        pub const stdout = OutputStream(b.wasi_cli_stdout.get_stdout);
        pub const stderr = OutputStream(b.wasi_cli_stderr.get_stderr);

        fn OutputStream(comptime acquire: anytype) type {
            return struct {
                /// Write the given bytes to the stream and flush. Blocks
                /// until the host accepts the data.
                pub fn write(data: []const u8) StreamError!void {
                    const h = acquire();
                    defer b.wasi_io_streams.resources.output_stream.drop(h);
                    return blockingWriteAll(h, data);
                }

                /// `std.fmt.bufPrint` into a 4 KiB stack buffer, then
                /// write. For longer output, format into your own
                /// allocator-backed buffer and call `write`.
                pub fn print(comptime fmt: []const u8, args: anytype) !void {
                    var buf: [4096]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, fmt, args) catch return error.NoSpaceLeft;
                    return write(s);
                }
            };
        }

        pub const stdin = struct {
            pub fn read(gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
                const h = b.wasi_cli_stdin.get_stdin();
                defer b.wasi_io_streams.resources.input_stream.drop(h);
                return drainStream(gpa, h, max_bytes);
            }
        };

        pub const environment = struct {
            /// All `(name, value)` environment variables visible to the
            /// component. Returned by reference; do not free.
            pub fn vars() []const struct { []const u8, []const u8 } {
                return b.wasi_cli_environment.get_environment();
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
                return b.wasi_cli_environment.initial_cwd();
            }
        };

        pub const exit = common.Exit(b);

        pub const HttpError = error{
            BadUrl,
            SetAuthorityFailed,
            SetPathFailed,
            SetSchemeFailed,
            SetMethodFailed,
            BodyFailed,
            HandleFailed,
            FutureUnreachable,
            FutureNotReady,
            HttpErrored,
            ConsumeFailed,
            NoStream,
        } || StreamError || std.mem.Allocator.Error;

        const parseUrl = common.parseUrl;

        pub const http = struct {
            const wht = b.wasi_http_types;
            const wsh = b.wasi_http_outgoing_handler;

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
                        .get => .{ .get = {} },
                        .head => .{ .head = {} },
                        .post => .{ .post = {} },
                        .put => .{ .put = {} },
                        .delete => .{ .delete = {} },
                        .connect => .{ .connect = {} },
                        .options => .{ .options = {} },
                        .trace => .{ .trace = {} },
                        .patch => .{ .patch = {} },
                    };
                }
            };

            pub const Header = common.Header;
            pub const Response = common.Response;

            pub const Request = struct {
                url: []const u8,
                method: Method = .get,
                headers: []const Header = &.{},
                body: []const u8 = "",
            };

            /// Convenience: fetch `url` with GET and return just the
            /// response body. Caller owns the returned slice.
            pub fn get(gpa: std.mem.Allocator, url: []const u8) HttpError![]u8 {
                const resp = try fetch(gpa, .{ .url = url });
                for (resp.headers) |h| {
                    gpa.free(h.name);
                    gpa.free(h.value);
                }
                gpa.free(resp.headers);
                return resp.body;
            }

            /// Issue a request and read the entire response into memory.
            /// The caller must `deinit` the returned `Response`.
            pub fn fetch(gpa: std.mem.Allocator, req: Request) HttpError!Response {
                const target = parseUrl(req.url) orelse return error.BadUrl;

                const headers = wht.resources.fields.new();
                for (req.headers) |h| {
                    switch (wht.resources.fields.append(headers, h.name, h.value)) {
                        .ok => {},
                        .err => {
                            wht.resources.fields.drop(headers);
                            return error.HandleFailed;
                        },
                    }
                }

                const outgoing = wht.resources.outgoing_request.new(headers);
                var consumed = false;
                errdefer if (!consumed) wht.resources.outgoing_request.drop(outgoing);

                switch (wht.resources.outgoing_request.set_method(outgoing, req.method.lower())) {
                    .ok => {},
                    .err => return error.SetMethodFailed,
                }
                switch (wht.resources.outgoing_request.set_authority(outgoing, target.host)) {
                    .ok => {},
                    .err => return error.SetAuthorityFailed,
                }
                switch (wht.resources.outgoing_request.set_path_with_query(outgoing, target.path)) {
                    .ok => {},
                    .err => return error.SetPathFailed,
                }
                const scheme: wht.types.scheme = if (target.https) .{ .HTTPS = {} } else .{ .HTTP = {} };
                switch (wht.resources.outgoing_request.set_scheme(outgoing, scheme)) {
                    .ok => {},
                    .err => return error.SetSchemeFailed,
                }

                if (req.body.len != 0) {
                    const out_body = switch (wht.resources.outgoing_request.body(outgoing)) {
                        .ok => |body_h| body_h,
                        .err => return error.BodyFailed,
                    };
                    var body_consumed = false;
                    errdefer if (!body_consumed) wht.resources.outgoing_body.drop(out_body);

                    {
                        const out_stream = switch (wht.resources.outgoing_body.write(out_body)) {
                            .ok => |s| s,
                            .err => return error.BodyFailed,
                        };
                        defer b.wasi_io_streams.resources.output_stream.drop(out_stream);
                        try blockingWriteAll(out_stream, req.body);
                    }
                    switch (wht.resources.outgoing_body.finish(out_body, null)) {
                        .ok => {},
                        .err => return error.BodyFailed,
                    }
                    body_consumed = true;
                }

                const handle_res = wsh.handle(outgoing, null);
                consumed = true;
                const future = switch (handle_res) {
                    .ok => |f| f,
                    .err => return error.HandleFailed,
                };
                defer wht.resources.future_incoming_response.drop(future);

                const pollable = wht.resources.future_incoming_response.subscribe(future);
                b.wasi_io_poll.resources.pollable.block(pollable);
                b.wasi_io_poll.resources.pollable.drop(pollable);

                const outer = wht.resources.future_incoming_response.get(future) orelse return error.FutureNotReady;
                const inner = switch (outer) {
                    .ok => |x| x,
                    .err => return error.FutureUnreachable,
                };
                const response = switch (inner) {
                    .ok => |r| r,
                    .err => return error.HttpErrored,
                };
                defer wht.resources.incoming_response.drop(response);

                const status = wht.resources.incoming_response.status(response);

                const hdr_fields = wht.resources.incoming_response.headers(response);
                defer wht.resources.fields.drop(hdr_fields);
                const entries = wht.resources.fields.entries(hdr_fields);
                var headers_out = try gpa.alloc(Header, entries.len);
                var filled: usize = 0;
                errdefer {
                    for (headers_out[0..filled]) |h| {
                        gpa.free(h.name);
                        gpa.free(h.value);
                    }
                    gpa.free(headers_out);
                }
                for (entries) |kv| {
                    const name_dup = try gpa.dupe(u8, kv[0]);
                    errdefer gpa.free(name_dup);
                    const value_dup = try gpa.dupe(u8, kv[1]);
                    headers_out[filled] = .{ .name = name_dup, .value = value_dup };
                    filled += 1;
                }

                const body_h = switch (wht.resources.incoming_response.consume(response)) {
                    .ok => |x| x,
                    .err => return error.ConsumeFailed,
                };
                defer wht.resources.incoming_body.drop(body_h);

                const body_stream = switch (wht.resources.incoming_body.stream(body_h)) {
                    .ok => |s| s,
                    .err => return error.NoStream,
                };
                defer b.wasi_io_streams.resources.input_stream.drop(body_stream);

                const body = try drainStream(gpa, body_stream, std.math.maxInt(usize));

                return .{
                    .status = status,
                    .headers = headers_out,
                    .body = body,
                    .gpa = gpa,
                };
            }
        };

        pub const FsError = common.FsError;

        pub const fs = struct {
            const fst = b.wasi_filesystem_types;
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
                        .unknown => .unknown,
                        .block_device => .block_device,
                        .character_device => .character_device,
                        .directory => .directory,
                        .fifo => .fifo,
                        .symbolic_link => .symbolic_link,
                        .regular_file => .regular_file,
                        .socket => .socket,
                    };
                }
            };

            pub const Stat = struct {
                kind: FileType,
                size: u64,
                modified_seconds: ?u64,
            };

            pub const Entry = struct {
                kind: FileType,
                name: []u8,
            };

            const Preopen = struct {
                desc: fst.types.descriptor,
                path: []const u8,
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

            /// Read an entire file into a freshly-allocated slice.
            pub fn readFile(gpa: std.mem.Allocator, path: []const u8) FsError![]u8 {
                const r = try resolve(path);
                const fd = switch (fst.resources.descriptor.open_at(
                    r.desc,
                    .{ .symlink_follow = true },
                    r.rel,
                    .{ .create = false, .directory = false, .exclusive = false, .truncate = false },
                    .{
                        .read = true,
                        .write = false,
                        .file_integrity_sync = false,
                        .data_integrity_sync = false,
                        .requested_write_sync = false,
                        .mutate_directory = false,
                    },
                )) {
                    .ok => |d| d,
                    .err => |e| return mapError(e),
                };
                defer fst.resources.descriptor.drop(fd);

                const stream = switch (fst.resources.descriptor.read_via_stream(fd, 0)) {
                    .ok => |s| s,
                    .err => |e| return mapError(e),
                };
                defer b.wasi_io_streams.resources.input_stream.drop(stream);

                return try drainStream(gpa, stream, std.math.maxInt(usize));
            }

            fn openForWrite(
                desc: fst.types.descriptor,
                rel: []const u8,
                truncate: bool,
            ) FsError!fst.types.descriptor {
                return switch (fst.resources.descriptor.open_at(
                    desc,
                    .{ .symlink_follow = true },
                    rel,
                    .{ .create = true, .directory = false, .exclusive = false, .truncate = truncate },
                    .{
                        .read = false,
                        .write = true,
                        .file_integrity_sync = false,
                        .data_integrity_sync = false,
                        .requested_write_sync = false,
                        .mutate_directory = false,
                    },
                )) {
                    .ok => |d| d,
                    .err => |e| mapError(e),
                };
            }

            /// Write `data` to `path`, replacing any existing file.
            pub fn writeFile(path: []const u8, data: []const u8) FsError!void {
                const r = try resolve(path);
                const fd = try openForWrite(r.desc, r.rel, true);
                defer fst.resources.descriptor.drop(fd);

                const stream = switch (fst.resources.descriptor.write_via_stream(fd, 0)) {
                    .ok => |s| s,
                    .err => |e| return mapError(e),
                };
                defer b.wasi_io_streams.resources.output_stream.drop(stream);

                try blockingWriteAll(stream, data);
            }

            /// Append `data` to `path`, creating the file if missing.
            pub fn appendFile(path: []const u8, data: []const u8) FsError!void {
                const r = try resolve(path);
                const fd = try openForWrite(r.desc, r.rel, false);
                defer fst.resources.descriptor.drop(fd);

                const stream = switch (fst.resources.descriptor.append_via_stream(fd)) {
                    .ok => |s| s,
                    .err => |e| return mapError(e),
                };
                defer b.wasi_io_streams.resources.output_stream.drop(stream);

                try blockingWriteAll(stream, data);
            }

            /// `stat`-style metadata for the file at `path`.
            pub fn stat(path: []const u8) FsError!Stat {
                const r = try resolve(path);
                const s = switch (fst.resources.descriptor.stat_at(
                    r.desc,
                    .{ .symlink_follow = true },
                    r.rel,
                )) {
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
                switch (fst.resources.descriptor.unlink_file_at(r.desc, r.rel)) {
                    .ok => {},
                    .err => |e| return mapError(e),
                }
            }

            pub fn mkdir(path: []const u8) FsError!void {
                const r = try resolve(path);
                switch (fst.resources.descriptor.create_directory_at(r.desc, r.rel)) {
                    .ok => {},
                    .err => |e| return mapError(e),
                }
            }

            pub fn rmdir(path: []const u8) FsError!void {
                const r = try resolve(path);
                switch (fst.resources.descriptor.remove_directory_at(r.desc, r.rel)) {
                    .ok => {},
                    .err => |e| return mapError(e),
                }
            }

            /// Rename `old_path` to `new_path`. Both paths must resolve
            /// against the same preopen.
            pub fn rename(old_path: []const u8, new_path: []const u8) FsError!void {
                const ro = try resolve(old_path);
                const rn = try resolve(new_path);
                if (@intFromEnum(ro.desc) != @intFromEnum(rn.desc))
                    return error.FsInvalid;
                switch (fst.resources.descriptor.rename_at(ro.desc, ro.rel, rn.desc, rn.rel)) {
                    .ok => {},
                    .err => |e| return mapError(e),
                }
            }

            /// List the entries in the directory at `path`. The caller
            /// owns both the slice and every `name` field.
            pub fn listDir(gpa: std.mem.Allocator, path: []const u8) FsError![]Entry {
                const r = try resolve(path);
                const dir = switch (fst.resources.descriptor.open_at(
                    r.desc,
                    .{ .symlink_follow = true },
                    r.rel,
                    .{ .create = false, .directory = true, .exclusive = false, .truncate = false },
                    .{
                        .read = true,
                        .write = false,
                        .file_integrity_sync = false,
                        .data_integrity_sync = false,
                        .requested_write_sync = false,
                        .mutate_directory = false,
                    },
                )) {
                    .ok => |d| d,
                    .err => |e| return mapError(e),
                };
                defer fst.resources.descriptor.drop(dir);

                const stream = switch (fst.resources.descriptor.read_directory(dir)) {
                    .ok => |s| s,
                    .err => |e| return mapError(e),
                };
                defer fst.resources.directory_entry_stream.drop(stream);

                var entries: std.ArrayList(Entry) = .empty;
                errdefer {
                    for (entries.items) |e| gpa.free(e.name);
                    entries.deinit(gpa);
                }
                while (true) {
                    const next = switch (fst.resources.directory_entry_stream.read_directory_entry(stream)) {
                        .ok => |x| x,
                        .err => |e| return mapError(e),
                    };
                    const entry = next orelse break;
                    const name_dup = try gpa.dupe(u8, entry.name);
                    errdefer gpa.free(name_dup);
                    try entries.append(gpa, .{
                        .kind = FileType.from(entry.type),
                        .name = name_dup,
                    });
                }
                return try entries.toOwnedSlice(gpa);
            }

            /// The set of `(descriptor, path)` preopens the host gave us.
            /// Cached on first call. Returned by reference; do not drop
            /// the descriptors.
            pub fn preopens() []const struct { fst.types.descriptor, []const u8 } {
                return cachedPreopens();
            }
        };

        pub const NetError = common.NetError;

        pub const net = struct {
            const netw = b.wasi_sockets_network;
            const inst = b.wasi_sockets_instance_network;
            const lookup = b.wasi_sockets_ip_name_lookup;
            const tcpns = b.wasi_sockets_tcp;
            const tcp_create = b.wasi_sockets_tcp_create_socket;

            var shared_network: ?netw.types.network = null;

            /// The module-wide network authority handle. Acquired lazily
            /// the first time any `net` helper needs it and reused for
            /// the lifetime of the component, so callers never pay for
            /// per-call `instance_network` lookups.
            fn network() netw.types.network {
                if (shared_network) |n| return n;
                const fresh = inst.instance_network();
                shared_network = fresh;
                return fresh;
            }

            pub const Ipv4 = struct { u8, u8, u8, u8 };
            pub const Ipv6 = struct { u16, u16, u16, u16, u16, u16, u16, u16 };

            pub const Address = union(enum) {
                v4: Ipv4,
                v6: Ipv6,

                fn fromRaw(ip: netw.types.ip_address) Address {
                    return switch (ip) {
                        .ipv4 => |a| .{ .v4 = a },
                        .ipv6 => |a| .{ .v6 = a },
                    };
                }

                fn toSocketRaw(self: Address, port: u16) netw.types.ip_socket_address {
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

                pub fn family(self: Address) netw.types.ip_address_family {
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
                const stream = switch (lookup.resolve_addresses(network(), host)) {
                    .ok => |s| s,
                    .err => |e| return mapNetError(e),
                };
                defer lookup.resources.resolve_address_stream.drop(stream);

                const sub = lookup.resources.resolve_address_stream.subscribe(stream);
                defer b.wasi_io_poll.resources.pollable.drop(sub);

                var addrs: std.ArrayList(Address) = .empty;
                errdefer addrs.deinit(gpa);
                while (true) {
                    const next = switch (lookup.resources.resolve_address_stream.resolve_next_address(stream)) {
                        .ok => |x| x,
                        .err => |e| switch (e) {
                            .would_block => {
                                b.wasi_io_poll.resources.pollable.block(sub);
                                continue;
                            },
                            else => return mapNetError(e),
                        },
                    };
                    const ip = next orelse break;
                    try addrs.append(gpa, Address.fromRaw(ip));
                }
                if (addrs.items.len == 0) return error.NameUnresolvable;
                return try addrs.toOwnedSlice(gpa);
            }

            pub const TcpStream = struct {
                socket: tcpns.types.tcp_socket,
                input: b.wasi_io_streams.types.input_stream,
                output: b.wasi_io_streams.types.output_stream,
                closed: bool = false,

                pub fn write(self: TcpStream, data: []const u8) StreamError!void {
                    return blockingWriteAll(self.output, data);
                }

                pub fn readAll(self: TcpStream, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
                    return drainStream(gpa, self.input, max_bytes);
                }

                /// Drop the connection's streams and socket. Idempotent —
                /// `defer conn.close()` plus a final `conn.close()` on
                /// the happy path will not double-drop.
                pub fn close(self: *TcpStream) void {
                    if (self.closed) return;
                    self.closed = true;
                    b.wasi_io_streams.resources.input_stream.drop(self.input);
                    b.wasi_io_streams.resources.output_stream.drop(self.output);
                    tcpns.resources.tcp_socket.drop(self.socket);
                }
            };

            /// Open a TCP connection to `addr:port`, returning a
            /// blocking input/output stream pair.
            pub fn connectTcp(addr: Address, port: u16) NetError!TcpStream {
                const sock = switch (tcp_create.create_tcp_socket(addr.family())) {
                    .ok => |s| s,
                    .err => return error.CreateSocketFailed,
                };
                errdefer tcpns.resources.tcp_socket.drop(sock);

                switch (tcpns.resources.tcp_socket.start_connect(sock, network(), addr.toSocketRaw(port))) {
                    .ok => {},
                    .err => return error.ConnectFailed,
                }
                const sub = tcpns.resources.tcp_socket.subscribe(sock);
                defer b.wasi_io_poll.resources.pollable.drop(sub);

                const streams = while (true) {
                    b.wasi_io_poll.resources.pollable.block(sub);
                    switch (tcpns.resources.tcp_socket.finish_connect(sock)) {
                        .ok => |s| break s,
                        .err => |e| switch (e) {
                            .would_block => continue,
                            else => return error.ConnectFailed,
                        },
                    }
                };
                return .{
                    .socket = sock,
                    .input = streams[0],
                    .output = streams[1],
                };
            }

            fn mapNetError(e: netw.types.error_code) NetError {
                return switch (e) {
                    .name_unresolvable => error.NameUnresolvable,
                    .invalid_argument => error.InvalidAddress,
                    else => error.ResolveFailed,
                };
            }
        };

        pub const terminal = common.Terminal(b);

        fn drainStream(
            gpa: std.mem.Allocator,
            stream: b.wasi_io_streams.types.input_stream,
            max_bytes: usize,
        ) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            while (out.items.len < max_bytes) {
                const want: u64 = @intCast(@min(max_bytes - out.items.len, 4096));
                const r = b.wasi_io_streams.resources.input_stream.blocking_read(stream, want);
                switch (r) {
                    .ok => |chunk| {
                        if (chunk.len == 0) return out.toOwnedSlice(gpa);
                        try out.appendSlice(gpa, chunk);
                    },
                    .err => |e| switch (e) {
                        .closed => return out.toOwnedSlice(gpa),
                        .last_operation_failed => |h| {
                            b.wasi_io_error.resources.@"error".drop(h);
                            return error.StreamFailed;
                        },
                    },
                }
            }
            return out.toOwnedSlice(gpa);
        }
    };
}

test {
    _ = common;
}
