//! `zig-wit` CLI: parse a WIT file and print a summary of the AST.
//!
//! Will eventually grow into a code-generator (`zig-wit gen world.wit
//! -o bindings.zig`). For now it is enough to demonstrate the parser.

const std = @import("std");
const Io = std.Io;

const lib = @import("zig_wasi_components");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.print(
            \\Usage:
            \\  {0s} dump <wit-file>           describe a WIT file
            \\  {0s} gen  <wit-file> <world>   emit Zig bindings to stdout
            \\
        , .{args[0]});
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "dump")) {
        if (args.len < 3) return error.MissingArgument;
        const src = try Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(16 * 1024 * 1024));
        const pkg = try lib.wit.parse(arena, src);
        try out.print("package {s}:{s}", .{ pkg.namespace, pkg.name });
        if (pkg.version) |v| try out.print("@{s}", .{v.text});
        try out.print("\n", .{});
        try out.print("  {d} world(s), {d} interface(s), {d} type(s), {d} dep(s)\n", .{
            pkg.worlds.len, pkg.interfaces.len, pkg.types.len, pkg.deps.len,
        });
        for (pkg.worlds) |wld| {
            try out.print("  world {s}:\n", .{wld.name});
            for (wld.externs) |e| {
                try out.print("    {s} {s} ({s})\n", .{
                    @tagName(e.kind), e.name, @tagName(e.body),
                });
            }
        }
        for (pkg.deps) |d| {
            try out.print("  dep {s}:{s}", .{ d.namespace, d.name });
            if (d.version) |v| try out.print("@{s}", .{v.text});
            try out.print(" — {d} world(s), {d} interface(s), {d} type(s)\n", .{
                d.worlds.len, d.interfaces.len, d.types.len,
            });
            for (d.interfaces) |i| try out.print("    interface {s} (resources: {d}, funcs: {d})\n", .{
                i.name,
                blk: {
                    var c: usize = 0;
                    for (i.types) |t| if (t.body == .resource) {
                        c += 1;
                    };
                    break :blk c;
                },
                i.funcs.len,
            });
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "gen")) {
        if (args.len < 4) return error.MissingArgument;
        const src = try Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(16 * 1024 * 1024));
        const pkg = try lib.wit.parse(arena, src);
        const wanted = args[3];
        const wld = blk: {
            for (pkg.worlds) |wld| {
                if (std.mem.eql(u8, wld.name, wanted)) break :blk wld;
            }

            var err_buf: [4096]u8 = undefined;
            var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
            const err = &err_w.interface;
            defer err.flush() catch {};

            try err.print("error: world '{s}' not found in {s}\n", .{ wanted, args[2] });
            if (pkg.namespace.len != 0 or pkg.name.len != 0) {
                try err.print("       package {s}:{s}", .{ pkg.namespace, pkg.name });
                if (pkg.version) |v| try err.print("@{s}", .{v.text});
                try err.print("\n", .{});
            }

            if (std.mem.indexOfScalar(u8, wanted, '/') != null or
                std.mem.indexOfScalar(u8, wanted, ':') != null)
            {
                try err.print(
                    "       the world argument is a bare identifier (e.g. 'client'), not a namespaced path.\n",
                    .{},
                );
            }

            if (pkg.worlds.len == 0) {
                try err.print(
                    "       this file declares no worlds — only interfaces and/or types.\n" ++
                        "       'gen' needs a `world <name> {{ … }}` declaration; try `dump` to inspect the file.\n",
                    .{},
                );
                if (pkg.interfaces.len != 0) {
                    try err.print("       interfaces in this file:\n", .{});
                    for (pkg.interfaces) |i| try err.print("         - {s}\n", .{i.name});
                }
            } else {
                try err.print("       available worlds in this file:\n", .{});
                for (pkg.worlds) |w| try err.print("         - {s}\n", .{w.name});
            }
            return error.WorldNotFound;
        };
        const code = try lib.codegen.generateWorld(arena, pkg, wld, .{});
        try out.writeAll(code);
        return;
    }
    try out.print("unknown command: {s}\n", .{cmd});
    return error.UnknownCommand;
}

test {
    std.testing.refAllDecls(@This());
}
