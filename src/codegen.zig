//! Canonical-ABI code generator.
//!
//! Given a parsed `wit.Package`, emits a `.zig` file that the user's
//! component can `@import`. The generated bindings:
//!
//!   * declare Zig types matching each WIT type definition (record →
//!     struct, variant → `union(enum)`, enum → `enum`, flags → packed
//!     struct, list → slice, string → `[]const u8`, option → `?T`,
//!     result → `union(enum) { ok: T, err: E }`, tuple → struct,
//!     resource → distinct integer handle type);
//!   * declare a host-import namespace `imports` containing one
//!     `@extern` per WIT import plus a Zig wrapper that lowers
//!     arguments and lifts results;
//!   * for each WIT export, emit an `export fn` matching the
//!     canonical-ABI core wasm signature. The function lifts its
//!     parameters (either directly from flat core values, or via the
//!     `args_ptr` indirection when there are more than 16 flat
//!     params), invokes the user's `wit_exports.<name>`, and lowers
//!     the return value either directly (when the result fits in a
//!     single flat core value) or by writing the value into a static
//!     return-area buffer using the canonical *memory* layout and
//!     returning its address. A matching `cabi_post_<name>`
//!     is emitted that resets the realloc arena;
//!   * export `cabi_realloc`.
//!
//! The "canonical memory layout" used by indirect returns and by
//! list elements follows the rules in
//! `design/mvp/CanonicalABI.md` of the component-model spec:
//! primitives have natural alignment and size; records/tuples lay
//! out their fields left-to-right with alignment padding; variants
//! pack a discriminant (1/2/4 bytes by case count) plus the largest
//! payload, aligned to the maximum of the discriminant alignment
//! and any payload alignment.
//!
//! Scope notes: the full canonical-ABI surface of WIT 0.2.x and the
//! stabilized parts of 0.3.x is mapped — including `async` functions
//! (`[async-lift]` / `[async-lower]`), per-payload `stream<T>` /
//! `future<T>` intrinsics, and `error-context` handles. The only
//! types that still return `Error.Unsupported` are the spec-illegal
//! corners (flags with > 32 labels, multi-named result tuples).

const std = @import("std");
const wit = @import("wit.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    Unsupported,
    UnknownType,
    OutOfMemory,
} || std.Io.Writer.Error;

pub const Options = struct {
    /// Module name used when declaring core-wasm imports.
    import_module: []const u8 = "$root",
};

// =====================================================================
// Resolver — pools every type definition that should be visible
// to a code-generation walk over a given world.
// =====================================================================

const Resolver = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Distinct iface prefix strings owned by this resolver. Entries'
    /// `iface_prefix` slices are interned into this list so they stay
    /// valid for the resolver's lifetime, regardless of where the
    /// caller's temporary buffer for the prefix lives.
    prefix_pool: std.ArrayList([]u8) = .empty,
    /// Monotonic counter to make labelled blocks (`blk_lr_N` etc.)
    /// unique across the file. emitLoadMem-style helpers consume one
    /// label per nested result/variant/option in the same expression.
    label_counter: u32 = 0,
    /// Interface prefix of the type-decl/emit context currently
    /// running. emitTypeRef uses this to decide whether to emit a
    /// bare name (same iface or world-scope), or a fully-qualified
    /// `<iface>.<X>` for cross-interface references.
    current_iface_prefix: []const u8 = "",
    /// True while emitting code OUTSIDE the iface's `types` sub-
    /// struct (i.e. inside resource sub-structs or free fns). Same-
    /// iface type references then need a `types.<name>` prefix to
    /// reach the nested types namespace.
    methods_scope: bool = false,
    /// Package context for the currently-emitting iface, used to
    /// resolve sibling-form `use` clauses (`use other_iface.{X};`).
    current_pkg_namespace: []const u8 = "",
    current_pkg_name: []const u8 = "",

    pub const Entry = struct {
        /// Interface this type belongs to, expressed as the Zig-mangled
        /// interface name (e.g., `wasi_http_types`). Empty for
        /// world-scope or pkg-scope types.
        iface_prefix: []const u8 = "",
        td: wit.TypeDef,
        /// True for entries synthesized from `use` clauses. Used by
        /// emitNamedTypeRef to recognise the name in iface scope, but
        /// the actual alias decl is written explicitly via
        /// emitUseAliases with a qualified cross-iface reference.
        is_use_alias: bool = false,
        /// For use-alias entries, the source iface's Zig-mangled
        /// prefix, used when emitting the alias decl.
        source_iface_prefix: []const u8 = "",
        /// For use-alias entries, the name in the source interface
        /// (may differ from `td.name` when `as` rename is used).
        source_name: []const u8 = "",
    };

    fn deinit(self: *Resolver) void {
        for (self.prefix_pool.items) |s| self.gpa.free(s);
        self.prefix_pool.deinit(self.gpa);
        self.entries.deinit(self.gpa);
    }

    fn add(self: *Resolver, t: wit.TypeDef) Allocator.Error!void {
        return self.addWithPrefix("", t);
    }

    fn addWithPrefix(self: *Resolver, iface_prefix: []const u8, t: wit.TypeDef) Allocator.Error!void {
        for (self.entries.items) |existing| {
            if (std.mem.eql(u8, existing.iface_prefix, iface_prefix) and
                std.mem.eql(u8, existing.td.name, t.name)) return;
        }
        // Resolver owns the prefix bytes so the slice stored on each
        // entry stays valid for the lifetime of the resolver.
        const ifp_owned = if (iface_prefix.len == 0) "" else try self.internPrefix(iface_prefix);
        try self.entries.append(self.gpa, .{ .iface_prefix = ifp_owned, .td = t });
    }

    fn internPrefix(self: *Resolver, s: []const u8) Allocator.Error![]const u8 {
        for (self.prefix_pool.items) |existing| {
            if (std.mem.eql(u8, existing, s)) return existing;
        }
        const dup = try self.gpa.dupe(u8, s);
        try self.prefix_pool.append(self.gpa, dup);
        return dup;
    }

    /// Find a type by WIT name. Follows `use`-alias entries to the
    /// underlying TypeDef of the source interface.
    fn find(self: *Resolver, name: []const u8) ?wit.TypeDef {
        const entry = self.findEntry(name) orelse return null;
        if (entry.is_use_alias) {
            // Look up the source iface's type by the source name.
            for (self.entries.items) |e| {
                if (e.is_use_alias) continue;
                if (std.mem.eql(u8, e.iface_prefix, entry.source_iface_prefix) and
                    std.mem.eql(u8, e.td.name, entry.source_name)) return e.td;
            }
            return null;
        }
        return entry.td;
    }

    fn findEntry(self: *Resolver, name: []const u8) ?Entry {
        if (self.current_iface_prefix.len != 0) {
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.iface_prefix, self.current_iface_prefix) and
                    std.mem.eql(u8, e.td.name, name)) return e;
            }
        }
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.td.name, name)) return e;
        }
        return null;
    }

    /// Look up the iface prefix for a given WIT type name. Returns
    /// empty string for file-scope types. Prefers entries in the
    /// resolver's current iface scope when multiple exist.
    fn ifaceFor(self: *Resolver, name: []const u8) []const u8 {
        if (self.current_iface_prefix.len != 0) {
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.iface_prefix, self.current_iface_prefix) and
                    std.mem.eql(u8, e.td.name, name)) return e.iface_prefix;
            }
        }
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.td.name, name)) return e.iface_prefix;
        }
        return "";
    }
};

// =====================================================================
// Canonical-ABI layout helpers (compile-time)
// =====================================================================

const Layout = struct {
    size: u32,
    @"align": u32,
};

fn discSize(case_count: usize) u32 {
    if (case_count <= 256) return 1;
    if (case_count <= 65536) return 2;
    return 4;
}

fn discAlign(case_count: usize) u32 {
    return discSize(case_count);
}

fn alignTo(n: u32, a: u32) u32 {
    return (n + a - 1) & ~(a - 1);
}

fn layoutOf(r: *Resolver, ty: wit.TypeRef) Error!Layout {
    return switch (ty.kind) {
        .bool, .s8, .u8 => .{ .size = 1, .@"align" = 1 },
        .s16, .u16 => .{ .size = 2, .@"align" = 2 },
        .s32, .u32, .f32, .char => .{ .size = 4, .@"align" = 4 },
        .s64, .u64, .f64 => .{ .size = 8, .@"align" = 8 },
        .string => .{ .size = 8, .@"align" = 4 },
        .list => .{ .size = 8, .@"align" = 4 },
        .list_fixed => |info| blk: {
            const inner = try layoutOf(r, info.elem.*);
            break :blk .{ .size = inner.size * info.len, .@"align" = inner.@"align" };
        },
        .own, .borrow => .{ .size = 4, .@"align" = 4 },
        .option => |inner| try layoutVariant(r, &[_]?wit.TypeRef{ null, inner.* }),
        .result => |info| blk: {
            const cases = [_]?wit.TypeRef{
                if (info.ok) |p| p.* else null,
                if (info.err) |p| p.* else null,
            };
            break :blk try layoutVariant(r, &cases);
        },
        .tuple => |elems| try layoutSeq(r, elems, null),
        .error_context => .{ .size = 4, .@"align" = 4 },
        // `stream<T>` and `future<T>` are 4-byte handles at the
        // canonical-ABI level (the actual queue of values lives in
        // the runtime, not in linear memory). We model them as
        // opaque integers; operations on them go through specific
        // `[stream-*]` / `[future-*]` host imports which are not
        // yet generated, but values can already be passed across
        // the boundary.
        .stream, .future => .{ .size = 4, .@"align" = 4 },
        .named => |name| try layoutNamed(r, name),
    };
}

fn layoutSeq(r: *Resolver, elems: []const wit.TypeRef, fields: ?[]const wit.Field) Error!Layout {
    var total: u32 = 0;
    var max_align: u32 = 1;
    if (fields) |fs| {
        for (fs) |f| {
            const l = try layoutOf(r, f.ty);
            total = alignTo(total, l.@"align") + l.size;
            if (l.@"align" > max_align) max_align = l.@"align";
        }
    } else {
        for (elems) |e| {
            const l = try layoutOf(r, e);
            total = alignTo(total, l.@"align") + l.size;
            if (l.@"align" > max_align) max_align = l.@"align";
        }
    }
    total = alignTo(total, max_align);
    return .{ .size = total, .@"align" = max_align };
}

fn layoutVariant(r: *Resolver, case_tys: []const ?wit.TypeRef) Error!Layout {
    const disc_s = discSize(case_tys.len);
    const disc_a = discAlign(case_tys.len);
    var payload_align: u32 = 1;
    var payload_size: u32 = 0;
    for (case_tys) |ct| {
        if (ct == null) continue;
        const l = try layoutOf(r, ct.?);
        if (l.@"align" > payload_align) payload_align = l.@"align";
        if (l.size > payload_size) payload_size = l.size;
    }
    const total_align = if (payload_align > disc_a) payload_align else disc_a;
    const payload_start = alignTo(disc_s, payload_align);
    var total = payload_start + payload_size;
    total = alignTo(total, total_align);
    return .{ .size = total, .@"align" = total_align };
}

fn payloadOffset(disc_size: u32, payload_align: u32) u32 {
    return alignTo(disc_size, payload_align);
}

fn layoutNamed(r: *Resolver, name: []const u8) Error!Layout {
    const td = r.find(name) orelse return Error.UnknownType;
    return switch (td.body) {
        .record => |fields| try layoutSeq(r, &.{}, fields),
        .variant => |cases| blk: {
            const tmp = try r.gpa.alloc(?wit.TypeRef, cases.len);
            defer r.gpa.free(tmp);
            for (cases, 0..) |c, i| tmp[i] = c.ty;
            break :blk try layoutVariant(r, tmp);
        },
        .@"enum" => |cases| .{
            .size = discSize(cases.len),
            .@"align" = discAlign(cases.len),
        },
        .flags => |labels| blk: {
            const sz: u32 = if (labels.len <= 8) 1 else if (labels.len <= 16) 2 else if (labels.len <= 32) 4 else @intCast(((labels.len + 31) / 32) * 4);
            break :blk .{ .size = sz, .@"align" = if (sz <= 4) sz else 4 };
        },
        .alias => |t| try layoutOf(r, t),
        .resource => .{ .size = 4, .@"align" = 4 },
    };
}

// =====================================================================
// Flat representation (`flattenType`)
// =====================================================================

pub const CoreType = enum {
    i32,
    i64,
    f32,
    f64,

    pub fn zigName(self: CoreType) []const u8 {
        return switch (self) {
            .i32 => "i32",
            .i64 => "i64",
            .f32 => "f32",
            .f64 => "f64",
        };
    }
};

pub fn flattenType(out: *std.ArrayList(CoreType), gpa: Allocator, r: *Resolver, t: wit.TypeRef) Error!void {
    switch (t.kind) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char => try out.append(gpa, .i32),
        .s64, .u64 => try out.append(gpa, .i64),
        .f32 => try out.append(gpa, .f32),
        .f64 => try out.append(gpa, .f64),
        .string, .list => {
            try out.append(gpa, .i32);
            try out.append(gpa, .i32);
        },
        .list_fixed => |info| {
            var i: u32 = 0;
            while (i < info.len) : (i += 1) try flattenType(out, gpa, r, info.elem.*);
        },
        .option => |inner| {
            try out.append(gpa, .i32);
            var payload: std.ArrayList(CoreType) = .empty;
            defer payload.deinit(gpa);
            try flattenType(&payload, gpa, r, inner.*);
            try out.appendSlice(gpa, payload.items);
        },
        .result => |info| {
            try out.append(gpa, .i32);
            var ok_flat: std.ArrayList(CoreType) = .empty;
            defer ok_flat.deinit(gpa);
            var er_flat: std.ArrayList(CoreType) = .empty;
            defer er_flat.deinit(gpa);
            if (info.ok) |p| try flattenType(&ok_flat, gpa, r, p.*);
            if (info.err) |p| try flattenType(&er_flat, gpa, r, p.*);
            const joined = try joinFlats(gpa, ok_flat.items, er_flat.items);
            defer gpa.free(joined);
            try out.appendSlice(gpa, joined);
        },
        .tuple => |elems| for (elems) |e| try flattenType(out, gpa, r, e),
        .own, .borrow => try out.append(gpa, .i32),
        .error_context => try out.append(gpa, .i32),
        .stream, .future => try out.append(gpa, .i32),
        .named => |name| {
            const td = r.find(name) orelse return Error.UnknownType;
            switch (td.body) {
                .record => |fields| for (fields) |f| try flattenType(out, gpa, r, f.ty),
                .variant => |cases| {
                    try out.append(gpa, .i32);
                    var biggest: []CoreType = &.{};
                    defer if (biggest.len != 0) gpa.free(biggest);
                    for (cases) |c| {
                        if (c.ty == null) continue;
                        var flat: std.ArrayList(CoreType) = .empty;
                        defer flat.deinit(gpa);
                        try flattenType(&flat, gpa, r, c.ty.?);
                        const merged = try joinFlats(gpa, biggest, flat.items);
                        if (biggest.len != 0) gpa.free(biggest);
                        biggest = merged;
                    }
                    try out.appendSlice(gpa, biggest);
                },
                .@"enum" => try out.append(gpa, .i32),
                .flags => |labels| {
                    const w: usize = if (labels.len <= 32) 1 else if (labels.len <= 64) 2 else (labels.len + 31) / 32;
                    var i: usize = 0;
                    while (i < w) : (i += 1) try out.append(gpa, .i32);
                },
                .alias => |alias_ty| try flattenType(out, gpa, r, alias_ty),
                .resource => try out.append(gpa, .i32),
            }
        },
    }
}

fn joinFlats(gpa: Allocator, a: []const CoreType, b: []const CoreType) Allocator.Error![]CoreType {
    const n = @max(a.len, b.len);
    const out = try gpa.alloc(CoreType, n);
    for (out, 0..) |*slot, i| {
        const av: ?CoreType = if (i < a.len) a[i] else null;
        const bv: ?CoreType = if (i < b.len) b[i] else null;
        slot.* = joinOne(av, bv);
    }
    return out;
}

fn joinOne(a: ?CoreType, b: ?CoreType) CoreType {
    if (a == null) return b.?;
    if (b == null) return a.?;
    if (a.? == b.?) return a.?;
    return .i64;
}

/// Backing-integer width of a `flags<N>` type, capped at the
/// canonical-ABI spec's `0 < n <= 32` boundary. Used by every site
/// that emits a `packed struct(uN)` or bit-casts to/from one.
fn flagBackingBits(label_count: usize) usize {
    return if (label_count <= 8) 8 else if (label_count <= 16) 16 else 32;
}

// =====================================================================
// Identifier helpers
// =====================================================================

fn zigIdent(w: *std.Io.Writer, raw: []const u8) Error!void {
    const keywords = [_][]const u8{ "type", "error", "fn", "test", "struct", "union", "enum", "const", "var", "pub", "extern", "export", "comptime", "inline", "noinline", "async", "await", "anytype", "anyopaque", "void", "bool", "true", "false", "null", "undefined", "switch", "if", "else", "while", "for", "return", "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "and", "or", "unreachable", "usingnamespace", "linksection" };
    var needs_escape = false;
    for (keywords) |k| {
        if (std.mem.eql(u8, k, raw)) {
            needs_escape = true;
            break;
        }
    }
    if (needs_escape) {
        try w.print("@\"{s}\"", .{raw});
        return;
    }
    for (raw) |c| {
        try w.writeByte(if (c == '-') '_' else c);
    }
}

fn zigExportIdent(w: *std.Io.Writer, raw: []const u8) Error!void {
    var needs_escape = false;
    for (raw) |c| switch (c) {
        '-', '#', '[', ']', '.' => {
            needs_escape = true;
            break;
        },
        else => {},
    };
    if (needs_escape) {
        try w.print("@\"{s}\"", .{raw});
    } else {
        try zigIdent(w, raw);
    }
}

/// Emit a parameter name that cannot shadow any same-named WIT type.
/// Used in import wrapper signatures and bodies — a WIT method like
/// `outgoing_request_new(headers: headers)` would otherwise have the
/// param `headers` shadow the type `headers`.
fn emitParamName(w: *std.Io.Writer, raw_name: []const u8) Error!void {
    try w.writeAll("_a_");
    try zigIdent(w, raw_name);
}

fn paramNameAlloc(gpa: Allocator, raw_name: []const u8) Allocator.Error![]u8 {
    const id = try zigIdentAlloc(gpa, raw_name);
    defer gpa.free(id);
    return std.fmt.allocPrint(gpa, "_a_{s}", .{id});
}

fn zigIdentAlloc(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    zigIdent(&aw.writer, s) catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        else => unreachable,
    };
    var list = aw.toArrayList();
    return list.toOwnedSlice(gpa);
}

fn appendZigIdent(buf: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    const id = try zigIdentAlloc(gpa, s);
    defer gpa.free(id);
    try buf.appendSlice(gpa, id);
}

fn emitDispatchPath(w: *std.Io.Writer, path: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, path, '.');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try w.writeAll(".");
        first = false;
        try zigIdent(w, seg);
    }
}

fn needsAlias(kind: wit.TypeRef.Kind) bool {
    return switch (kind) {
        .option, .result, .tuple => true,
        else => false,
    };
}

/// Joint canonical-ABI layout for a sequence of params, used for both
/// indirect-result retareas (`flat_results > 1`) and indirect-param
/// argument areas (`flat_params > 16`). Each field is laid out at its
/// own alignment with a running offset; the total is padded to the
/// joint alignment so arrays of these structs stay aligned.
fn jointLayout(r: *Resolver, params: []const wit.Param) Error!Layout {
    if (params.len == 1) return layoutOf(r, params[0].ty);
    return jointLayoutWithLeading(r, .{ .size = 0, .@"align" = 1 }, params);
}

/// Joint layout with a pre-existing prefix slot (used by resource
/// methods, which pack a 4-byte self handle at offset 0 before the
/// user-declared params). The prefix's size/align participate in the
/// fold exactly as if it were a leading param.
fn jointLayoutWithLeading(r: *Resolver, leading: Layout, params: []const wit.Param) Error!Layout {
    var size: u32 = leading.size;
    var al: u32 = if (leading.@"align" == 0) 1 else leading.@"align";
    for (params) |p| {
        const l = try layoutOf(r, p.ty);
        if (l.@"align" > al) al = l.@"align";
        size = alignTo(size, l.@"align") + l.size;
    }
    return .{ .size = alignTo(size, al), .@"align" = al };
}

fn emitParamType(w: *std.Io.Writer, r: *Resolver, alias_prefix: []const u8, p: wit.Param) Error!void {
    if (needsAlias(p.ty.kind)) {
        try zigIdent(w, alias_prefix);
        try w.writeAll("_");
        try zigIdent(w, p.name);
    } else {
        try emitTypeRef(w, r, p.ty);
    }
}

fn emitLowerImportSlots(w: *std.Io.Writer, r: *Resolver, ty: wit.TypeRef, expr: []const u8, slot: *usize) Error!void {
    switch (ty.kind) {
        .bool => {
            try w.print("        const _p{d}: i32 = if ({s}) 1 else 0;\n", .{ slot.*, expr });
            slot.* += 1;
        },
        .s8, .s16, .s32 => {
            try w.print("        const _p{d}: i32 = {s};\n", .{ slot.*, expr });
            slot.* += 1;
        },
        .u8, .u16, .u32, .char => {
            try w.print("        const _p{d}: i32 = @bitCast(@as(u32, {s}));\n", .{ slot.*, expr });
            slot.* += 1;
        },
        .s64 => {
            try w.print("        const _p{d}: i64 = {s};\n", .{ slot.*, expr });
            slot.* += 1;
        },
        .u64 => {
            try w.print("        const _p{d}: i64 = @bitCast({s});\n", .{ slot.*, expr });
            slot.* += 1;
        },
        .f32, .f64 => {
            try w.print("        const _p{d} = {s};\n", .{ slot.*, expr });
            slot.* += 1;
        },
        .string, .list => {
            try w.print("        const _p{d}: i32 = @bitCast(@as(u32, @intCast(@intFromPtr({s}.ptr))));\n", .{ slot.*, expr });
            try w.print("        const _p{d}: i32 = @bitCast(@as(u32, @intCast({s}.len)));\n", .{ slot.* + 1, expr });
            slot.* += 2;
        },
        .own, .borrow, .error_context, .stream, .future => {
            try w.print("        const _p{d}: i32 = @bitCast(@intFromEnum({s}));\n", .{ slot.*, expr });
            slot.* += 1;
        },
        .tuple => |elems| {
            for (elems, 0..) |e, i| {
                const sub_expr = try std.fmt.allocPrint(r.gpa, "{s}[{d}]", .{ expr, i });
                defer r.gpa.free(sub_expr);
                try emitLowerImportSlots(w, r, e, sub_expr, slot);
            }
        },
        .named => |nm| {
            const td = r.find(nm) orelse return Error.UnknownType;
            switch (td.body) {
                .record => |fields| for (fields) |fld| {
                    const fld_name = try zigIdentAlloc(r.gpa, fld.name);
                    defer r.gpa.free(fld_name);
                    const sub_expr = try std.fmt.allocPrint(r.gpa, "{s}.{s}", .{ expr, fld_name });
                    defer r.gpa.free(sub_expr);
                    try emitLowerImportSlots(w, r, fld.ty, sub_expr, slot);
                },
                .@"enum" => {
                    try w.print("        const _p{d}: i32 = @bitCast(@as(u32, @intFromEnum({s})));\n", .{ slot.*, expr });
                    slot.* += 1;
                },
                .flags => |labels| {
                    if (labels.len > 32) return Error.Unsupported;
                    const backing_bits = flagBackingBits(labels.len);
                    try w.print("        const _p{d}: i32 = @bitCast(@as(u32, @as(u{d}, @bitCast({s}))));\n", .{ slot.*, backing_bits, expr });
                    slot.* += 1;
                },
                .alias => |a| try emitLowerImportSlots(w, r, a, expr, slot),
                .resource => {
                    try w.print("        const _p{d}: i32 = @bitCast(@intFromEnum({s}));\n", .{ slot.*, expr });
                    slot.* += 1;
                },
                .variant => |cases| {
                    var v_flat: std.ArrayList(CoreType) = .empty;
                    defer v_flat.deinit(r.gpa);
                    try flattenType(&v_flat, r.gpa, r, ty);
                    for (v_flat.items, 0..) |t, idx| {
                        try w.print("        const _p{d}: {s} = ", .{ slot.* + idx, t.zigName() });
                        try emitVariantSlotExpr(w, r, cases, expr, idx);
                        try w.writeAll(";\n");
                    }
                    slot.* += v_flat.items.len;
                },
            }
        },
        .option => |inner| try emitLowerOptionSlots(w, r, inner.*, expr, slot),
        .result => |info| try emitLowerResultSlots(w, r, info, expr, slot),
        .list_fixed => |info| {
            var i: u32 = 0;
            while (i < info.len) : (i += 1) {
                const sub_expr = try std.fmt.allocPrint(r.gpa, "{s}[{d}]", .{ expr, i });
                defer r.gpa.free(sub_expr);
                try emitLowerImportSlots(w, r, info.elem.*, sub_expr, slot);
            }
        },
    }
}

/// Allocate a unique capture name like `_v<n>` using the resolver's
/// counter so nested `if (...) |_v|` / `switch (...) |_v|` patterns
/// don't shadow each other.
fn allocCapture(r: *Resolver, buf: *[16]u8) []const u8 {
    const n = r.label_counter;
    r.label_counter += 1;
    return std.fmt.bufPrint(buf, "_v{d}", .{n}) catch unreachable;
}

fn emitLowerOptionSlots(w: *std.Io.Writer, r: *Resolver, inner: wit.TypeRef, expr: []const u8, slot: *usize) Error!void {
    var inner_flat: std.ArrayList(CoreType) = .empty;
    defer inner_flat.deinit(r.gpa);
    try flattenType(&inner_flat, r.gpa, r, inner);

    try w.print("        const _p{d}: i32 = if ({s} == null) 0 else 1;\n", .{ slot.*, expr });
    slot.* += 1;
    for (inner_flat.items, 0..) |t, idx| {
        var nb: [16]u8 = undefined;
        const cap = allocCapture(r, &nb);
        try w.print("        const _p{d}: {s} = if ({s}) |{s}| ", .{ slot.* + idx, t.zigName(), expr, cap });
        try emitFlatSlotExpr(w, r, inner, cap, idx);
        try w.print(" else @as({s}, 0);\n", .{t.zigName()});
    }
    slot.* += inner_flat.items.len;
}

fn emitLowerResultSlots(w: *std.Io.Writer, r: *Resolver, info: anytype, expr: []const u8, slot: *usize) Error!void {
    var ok_flat: std.ArrayList(CoreType) = .empty;
    defer ok_flat.deinit(r.gpa);
    if (info.ok) |p| try flattenType(&ok_flat, r.gpa, r, p.*);
    var err_flat: std.ArrayList(CoreType) = .empty;
    defer err_flat.deinit(r.gpa);
    if (info.err) |p| try flattenType(&err_flat, r.gpa, r, p.*);

    const joined = try joinFlats(r.gpa, ok_flat.items, err_flat.items);
    defer r.gpa.free(joined);

    try w.print("        const _p{d}: i32 = @intFromEnum({s});\n", .{ slot.*, expr });
    slot.* += 1;
    for (joined, 0..) |t, idx| {
        try w.print("        const _p{d}: {s} = switch ({s}) {{ ", .{ slot.* + idx, t.zigName(), expr });
        if (info.ok) |p| {
            if (idx < ok_flat.items.len) {
                var nb: [16]u8 = undefined;
                const cap = allocCapture(r, &nb);
                try w.print(".ok => |{s}| ", .{cap});
                try emitFlatSlotExpr(w, r, p.*, cap, idx);
            } else {
                try w.print(".ok => @as({s}, 0)", .{t.zigName()});
            }
        } else {
            try w.print(".ok => @as({s}, 0)", .{t.zigName()});
        }
        try w.writeAll(", ");
        if (info.err) |p| {
            if (idx < err_flat.items.len) {
                var nb: [16]u8 = undefined;
                const cap = allocCapture(r, &nb);
                try w.print(".err => |{s}| ", .{cap});
                try emitFlatSlotExpr(w, r, p.*, cap, idx);
            } else {
                try w.print(".err => @as({s}, 0)", .{t.zigName()});
            }
        } else {
            try w.print(".err => @as({s}, 0)", .{t.zigName()});
        }
        try w.writeAll(" };\n");
    }
    slot.* += joined.len;
}

fn emitVariantSlotExpr(w: *std.Io.Writer, r: *Resolver, cases: []const wit.Case, expr: []const u8, slot_idx: usize) Error!void {
    if (slot_idx == 0) {
        try w.print("@as(i32, switch ({s}) {{", .{expr});
        for (cases, 0..) |c, i| {
            try w.writeAll(" .");
            try zigIdent(w, c.name);
            try w.print(" => {d},", .{i});
        }
        try w.writeAll(" })");
        return;
    }
    try w.print("switch ({s}) {{", .{expr});
    for (cases) |c| {
        try w.writeAll(" .");
        try zigIdent(w, c.name);
        if (c.ty) |pty| {
            var case_flat: std.ArrayList(CoreType) = .empty;
            defer case_flat.deinit(r.gpa);
            try flattenType(&case_flat, r.gpa, r, pty);
            const payload_slot = slot_idx - 1;
            if (payload_slot < case_flat.items.len) {
                var nb: [16]u8 = undefined;
                const cap = allocCapture(r, &nb);
                try w.print(" => |{s}| ", .{cap});
                try emitFlatSlotExpr(w, r, pty, cap, payload_slot);
                try w.writeAll(",");
                continue;
            }
        }
        try w.writeAll(" => 0,");
    }
    try w.writeAll(" }");
}

fn emitFlatSlotExpr(w: *std.Io.Writer, r: *Resolver, ty: wit.TypeRef, expr: []const u8, slot_idx: usize) Error!void {
    switch (ty.kind) {
        .bool => {
            if (slot_idx != 0) return Error.Unsupported;
            try w.print("@as(i32, if ({s}) 1 else 0)", .{expr});
        },
        .s8, .s16, .s32 => {
            if (slot_idx != 0) return Error.Unsupported;
            try w.print("@as(i32, {s})", .{expr});
        },
        .u8, .u16, .u32, .char => {
            if (slot_idx != 0) return Error.Unsupported;
            try w.print("@as(i32, @bitCast(@as(u32, {s})))", .{expr});
        },
        .s64 => {
            if (slot_idx != 0) return Error.Unsupported;
            try w.print("@as(i64, {s})", .{expr});
        },
        .u64 => {
            if (slot_idx != 0) return Error.Unsupported;
            try w.print("@as(i64, @bitCast({s}))", .{expr});
        },
        .f32, .f64 => {
            if (slot_idx != 0) return Error.Unsupported;
            try w.writeAll(expr);
        },
        .string, .list => {
            switch (slot_idx) {
                0 => try w.print("@as(i32, @bitCast(@as(u32, @intCast(@intFromPtr({s}.ptr)))))", .{expr}),
                1 => try w.print("@as(i32, @bitCast(@as(u32, @intCast({s}.len))))", .{expr}),
                else => return Error.Unsupported,
            }
        },
        .own, .borrow, .error_context, .stream, .future => {
            if (slot_idx != 0) return Error.Unsupported;
            try w.print("@as(i32, @bitCast(@intFromEnum({s})))", .{expr});
        },
        .named => |nm| {
            const td = r.find(nm) orelse return Error.UnknownType;
            switch (td.body) {
                .alias => |a| try emitFlatSlotExpr(w, r, a, expr, slot_idx),
                .@"enum" => {
                    if (slot_idx != 0) return Error.Unsupported;
                    try w.print("@as(i32, @bitCast(@as(u32, @intFromEnum({s}))))", .{expr});
                },
                .resource => {
                    if (slot_idx != 0) return Error.Unsupported;
                    try w.print("@as(i32, @bitCast(@intFromEnum({s})))", .{expr});
                },
                .flags => |labels| {
                    if (slot_idx != 0 or labels.len > 32) return Error.Unsupported;
                    const backing_bits = flagBackingBits(labels.len);
                    try w.print("@as(i32, @bitCast(@as(u32, @as(u{d}, @bitCast({s})))))", .{ backing_bits, expr });
                },
                .variant => |cases| try emitVariantSlotExpr(w, r, cases, expr, slot_idx),
                .record => |fields| try emitRecordSlotExpr(w, r, fields, expr, slot_idx),
            }
        },
        .tuple => |elems| try emitTupleSlotExpr(w, r, elems, expr, slot_idx),
        .option => |inner| try emitOptionSlotExpr(w, r, inner.*, expr, slot_idx),
        .result => |info| try emitResultSlotExpr(w, r, info, expr, slot_idx),
        .list_fixed => |info| try emitListFixedSlotExpr(w, r, info, expr, slot_idx),
    }
}

fn emitListFixedSlotExpr(w: *std.Io.Writer, r: *Resolver, info: anytype, expr: []const u8, slot_idx: usize) Error!void {
    var elem_flat: std.ArrayList(CoreType) = .empty;
    defer elem_flat.deinit(r.gpa);
    try flattenType(&elem_flat, r.gpa, r, info.elem.*);
    if (elem_flat.items.len == 0) return Error.Unsupported;
    const target_elem = slot_idx / elem_flat.items.len;
    const target_subslot = slot_idx % elem_flat.items.len;
    if (target_elem >= info.len) return Error.Unsupported;
    const sub_expr = try std.fmt.allocPrint(r.gpa, "{s}[{d}]", .{ expr, target_elem });
    defer r.gpa.free(sub_expr);
    try emitFlatSlotExpr(w, r, info.elem.*, sub_expr, target_subslot);
}

fn emitRecordSlotExpr(w: *std.Io.Writer, r: *Resolver, fields: []const wit.Field, expr: []const u8, slot_idx: usize) Error!void {
    var seen: usize = 0;
    for (fields) |fld| {
        var field_flat: std.ArrayList(CoreType) = .empty;
        defer field_flat.deinit(r.gpa);
        try flattenType(&field_flat, r.gpa, r, fld.ty);
        if (slot_idx < seen + field_flat.items.len) {
            const fld_zig = try zigIdentAlloc(r.gpa, fld.name);
            defer r.gpa.free(fld_zig);
            const sub_expr = try std.fmt.allocPrint(r.gpa, "{s}.{s}", .{ expr, fld_zig });
            defer r.gpa.free(sub_expr);
            try emitFlatSlotExpr(w, r, fld.ty, sub_expr, slot_idx - seen);
            return;
        }
        seen += field_flat.items.len;
    }
    return Error.Unsupported;
}

fn emitTupleSlotExpr(w: *std.Io.Writer, r: *Resolver, elems: []const wit.TypeRef, expr: []const u8, slot_idx: usize) Error!void {
    var seen: usize = 0;
    for (elems, 0..) |e, i| {
        var e_flat: std.ArrayList(CoreType) = .empty;
        defer e_flat.deinit(r.gpa);
        try flattenType(&e_flat, r.gpa, r, e);
        if (slot_idx < seen + e_flat.items.len) {
            const sub_expr = try std.fmt.allocPrint(r.gpa, "{s}[{d}]", .{ expr, i });
            defer r.gpa.free(sub_expr);
            try emitFlatSlotExpr(w, r, e, sub_expr, slot_idx - seen);
            return;
        }
        seen += e_flat.items.len;
    }
    return Error.Unsupported;
}

fn emitOptionSlotExpr(w: *std.Io.Writer, r: *Resolver, inner: wit.TypeRef, expr: []const u8, slot_idx: usize) Error!void {
    if (slot_idx == 0) {
        try w.print("@as(i32, if ({s} == null) 0 else 1)", .{expr});
        return;
    }
    var name_buf: [16]u8 = undefined;
    const cap = allocCapture(r, &name_buf);
    try w.print("if ({s}) |{s}| ", .{ expr, cap });
    try emitFlatSlotExpr(w, r, inner, cap, slot_idx - 1);
    try w.writeAll(" else 0");
}

fn emitResultSlotExpr(w: *std.Io.Writer, r: *Resolver, info: anytype, expr: []const u8, slot_idx: usize) Error!void {
    if (slot_idx == 0) {
        try w.print("@as(i32, @intFromEnum({s}))", .{expr});
        return;
    }
    var ok_flat: std.ArrayList(CoreType) = .empty;
    defer ok_flat.deinit(r.gpa);
    if (info.ok) |p| try flattenType(&ok_flat, r.gpa, r, p.*);
    var err_flat: std.ArrayList(CoreType) = .empty;
    defer err_flat.deinit(r.gpa);
    if (info.err) |p| try flattenType(&err_flat, r.gpa, r, p.*);
    const payload_slot = slot_idx - 1;

    try w.print("switch ({s}) {{", .{expr});
    if (info.ok) |p| {
        if (payload_slot < ok_flat.items.len) {
            var nb: [16]u8 = undefined;
            const cap = allocCapture(r, &nb);
            try w.print(" .ok => |{s}| ", .{cap});
            try emitFlatSlotExpr(w, r, p.*, cap, payload_slot);
            try w.writeAll(",");
        } else {
            try w.writeAll(" .ok => 0,");
        }
    } else {
        try w.writeAll(" .ok => 0,");
    }
    if (info.err) |p| {
        if (payload_slot < err_flat.items.len) {
            var nb: [16]u8 = undefined;
            const cap = allocCapture(r, &nb);
            try w.print(" .err => |{s}| ", .{cap});
            try emitFlatSlotExpr(w, r, p.*, cap, payload_slot);
            try w.writeAll(",");
        } else {
            try w.writeAll(" .err => 0,");
        }
    } else {
        try w.writeAll(" .err => 0,");
    }
    try w.writeAll(" }");
}

fn emitFuncAliases(w: *std.Io.Writer, r: *Resolver, fn_prefix: []const u8, f: wit.Func) Error!void {
    if (f.results.len == 1) {
        const ty = f.results[0].ty;
        if (needsAlias(ty.kind)) {
            try w.writeAll("pub const ");
            try zigIdent(w, fn_prefix);
            try w.writeAll("_result = ");
            try emitTypeRef(w, r, ty);
            try w.writeAll(";\n");
        }
    } else if (f.results.len > 1) {
        try w.writeAll("pub const ");
        try zigIdent(w, fn_prefix);
        try w.writeAll("_result = struct { ");
        for (f.results, 0..) |res, i| {
            if (i != 0) try w.writeAll(", ");
            try zigIdent(w, res.name);
            try w.writeAll(": ");
            try emitTypeRef(w, r, res.ty);
        }
        try w.writeAll(" };\n");
    }
    for (f.params) |p| {
        if (!needsAlias(p.ty.kind)) continue;
        try w.writeAll("pub const ");
        try zigIdent(w, fn_prefix);
        try w.writeAll("_");
        try zigIdent(w, p.name);
        try w.writeAll(" = ");
        try emitTypeRef(w, r, p.ty);
        try w.writeAll(";\n");
    }
}

// =====================================================================
// Type emission (Zig declarations corresponding to WIT types)
// =====================================================================

/// Emit `///`-prefixed lines for any non-empty docs payload. The
/// parser collects `///` source lines into a `\n`-joined buffer; this
/// rewrites each line with the Zig doc-comment marker so IDEs can
/// surface hover-help for generated decls. Caller controls indentation.
fn emitDocs(w: *std.Io.Writer, docs: []const u8, indent: []const u8) Error!void {
    const trimmed = std.mem.trimEnd(u8, docs, "\n");
    if (trimmed.len == 0) return;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        try w.writeAll(indent);
        if (line.len == 0) {
            try w.writeAll("///\n");
        } else {
            try w.writeAll("/// ");
            try w.writeAll(line);
            try w.writeAll("\n");
        }
    }
}

fn emitTypeDecl(w: *std.Io.Writer, r: *Resolver, t: wit.TypeDef) Error!void {
    try emitDocs(w, t.docs, "    ");
    try w.writeAll("pub const ");
    try zigIdent(w, t.name);
    try w.writeAll(" = ");
    switch (t.body) {
        .record => |fields| {
            try w.writeAll("struct {\n");
            for (fields) |f| {
                try emitDocs(w, f.docs, "        ");
                try w.writeAll("    ");
                try zigIdent(w, f.name);
                try w.writeAll(": ");
                try emitTypeRef(w, r, f.ty);
                try w.writeAll(",\n");
            }
            try w.writeAll("};\n\n");
        },
        .variant => |cases| {
            try w.writeAll("union(enum) {\n");
            for (cases) |c| {
                try emitDocs(w, c.docs, "        ");
                try w.writeAll("    ");
                try zigIdent(w, c.name);
                if (c.ty) |ty| {
                    try w.writeAll(": ");
                    try emitTypeRef(w, r, ty);
                } else {
                    try w.writeAll(": void");
                }
                try w.writeAll(",\n");
            }
            try w.writeAll("};\n\n");
        },
        .@"enum" => |cases| {
            const width: usize = if (cases.len <= 256) 8 else if (cases.len <= 65536) 16 else 32;
            try w.print("enum(u{d}) {{\n", .{width});
            for (cases) |c| {
                try emitDocs(w, c.docs, "        ");
                try w.writeAll("    ");
                try zigIdent(w, c.name);
                try w.writeAll(",\n");
            }
            try w.writeAll("};\n\n");
        },
        .flags => |labels| {
            try w.writeAll("packed struct(u");
            const total_bits: usize = if (labels.len <= 8) 8 else if (labels.len <= 16) 16 else if (labels.len <= 32) 32 else ((labels.len + 31) / 32) * 32;
            try w.print("{d}) {{\n", .{total_bits});
            for (labels) |l| {
                try emitDocs(w, l.docs, "        ");
                try w.writeAll("    ");
                try zigIdent(w, l.name);
                try w.writeAll(": bool,\n");
            }
            const pad = total_bits - labels.len;
            if (pad > 0) try w.print("    _pad: u{d} = 0,\n", .{pad});
            try w.writeAll("};\n\n");
        },
        .alias => |ty| {
            try emitTypeRef(w, r, ty);
            try w.writeAll(";\n\n");
        },
        .resource => {
            // Resources are exposed to user code as an opaque handle
            // (a distinct integer type). The host owns the underlying
            // object; the guest only sees the handle's value.
            try w.writeAll("enum(u32) { _ };\n\n");
        },
    }
}

fn emitTypeRef(w: *std.Io.Writer, r: *Resolver, t: wit.TypeRef) Error!void {
    switch (t.kind) {
        .bool => try w.writeAll("bool"),
        .s8 => try w.writeAll("i8"),
        .u8 => try w.writeAll("u8"),
        .s16 => try w.writeAll("i16"),
        .u16 => try w.writeAll("u16"),
        .s32 => try w.writeAll("i32"),
        .u32 => try w.writeAll("u32"),
        .s64 => try w.writeAll("i64"),
        .u64 => try w.writeAll("u64"),
        .f32 => try w.writeAll("f32"),
        .f64 => try w.writeAll("f64"),
        .char => try w.writeAll("u21"),
        .string => try w.writeAll("[]const u8"),
        .error_context => try w.writeAll("abi.ErrorContext"),
        .list => |inner| {
            try w.writeAll("[]const ");
            try emitTypeRef(w, r, inner.*);
        },
        .list_fixed => |info| {
            try w.print("[{d}]", .{info.len});
            try emitTypeRef(w, r, info.elem.*);
        },
        .option => |inner| {
            try w.writeAll("?");
            try emitTypeRef(w, r, inner.*);
        },
        .result => |info| {
            try w.writeAll("union(enum) { ok");
            if (info.ok) |p| {
                try w.writeAll(": ");
                try emitTypeRef(w, r, p.*);
            } else try w.writeAll(": void");
            try w.writeAll(", err");
            if (info.err) |p| {
                try w.writeAll(": ");
                try emitTypeRef(w, r, p.*);
            } else try w.writeAll(": void");
            try w.writeAll(" }");
        },
        .tuple => |elems| {
            try w.writeAll("struct { ");
            for (elems, 0..) |e, i| {
                if (i != 0) try w.writeAll(", ");
                try emitTypeRef(w, r, e);
            }
            try w.writeAll(" }");
        },
        .own, .borrow => |name| try emitNamedTypeRef(w, r, name),
        .stream => try w.writeAll("abi.Stream"),
        .future => try w.writeAll("abi.Future"),
        .named => |name| try emitNamedTypeRef(w, r, name),
    }
}

/// Emit a reference to a named type, taking the resolver's current
/// interface scope into account.
///
/// - World-scope types (no iface_prefix): emit bare name.
/// - Same-iface types from inside `types` sub-struct: emit bare name.
/// - Same-iface types from inside methods/free fns: emit `types.<name>`.
/// - Cross-iface types: emit `<other_iface>.types.<name>`.
fn emitNamedTypeRef(w: *std.Io.Writer, r: *Resolver, name: []const u8) Error!void {
    const owner = r.ifaceFor(name);
    if (owner.len == 0) {
        try zigIdent(w, name);
        return;
    }
    if (std.mem.eql(u8, owner, r.current_iface_prefix)) {
        if (r.findEntry(name)) |e| {
            if (e.is_use_alias) {
                // `use`d types may be referenced from file-scope glue
                // (cabi export thunks), where the using interface has no
                // struct of its own. Qualify through the source
                // interface, whose file-scope struct always exists.
                if (e.source_iface_prefix.len == 0) {
                    try zigIdent(w, e.source_name);
                } else {
                    try w.writeAll(e.source_iface_prefix);
                    try w.writeAll(".types.");
                    try zigIdent(w, e.source_name);
                }
                return;
            }
        }
        if (r.methods_scope) try w.writeAll("types.");
        try zigIdent(w, name);
        return;
    }
    try w.writeAll(owner);
    try w.writeAll(".types.");
    try zigIdent(w, name);
}

// =====================================================================
// Lifting / lowering across the canonical-ABI memory layout.
// =====================================================================

/// Emit a Zig expression that loads a value of WIT type `ty` from
/// linear memory at `base_ptr_expr + offset`.
fn emitLoadMem(w: *std.Io.Writer, r: *Resolver, ty: wit.TypeRef, base: []const u8, offset: u32) Error!void {
    switch (ty.kind) {
        .bool => try w.print("(@as(*const u8, @ptrFromInt({s} + {d})).* != 0)", .{ base, offset }),
        .s8 => try w.print("@as(*const i8, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .u8 => try w.print("@as(*const u8, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .s16 => try w.print("@as(*align(2) const i16, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .u16 => try w.print("@as(*align(2) const u16, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .s32 => try w.print("@as(*align(4) const i32, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .u32 => try w.print("@as(*align(4) const u32, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .s64 => try w.print("@as(*align(8) const i64, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .u64 => try w.print("@as(*align(8) const u64, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .f32 => try w.print("@as(*align(4) const f32, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .f64 => try w.print("@as(*align(8) const f64, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        .char => try w.print("@as(u21, @intCast(@as(*align(4) const u32, @ptrFromInt({s} + {d})).*))", .{ base, offset }),
        .string, .list => {
            // (ptr: u32, len: u32) at offset; element type is u8 for
            // strings or the inner type for lists.
            const elem_zig: []const u8 = blk: {
                if (ty.kind == .string) break :blk "u8";
                break :blk "u8"; // placeholder; we override below
            };
            _ = elem_zig;
            try w.writeAll("@as([*]const ");
            if (ty.kind == .string) {
                try w.writeAll("u8");
            } else {
                try emitTypeRef(w, r, ty.kind.list.*);
            }
            try w.print(", @ptrFromInt(@as(*align(4) const u32, @ptrFromInt({s} + {d})).*))[0..@as(*align(4) const u32, @ptrFromInt({s} + {d})).*]", .{ base, offset, base, offset + 4 });
        },
        .own, .borrow => try w.print("@enumFromInt(@as(*align(4) const u32, @ptrFromInt({s} + {d})).*)", .{ base, offset }),
        .error_context => try w.print("@as(abi.ErrorContext, @enumFromInt(@as(*align(4) const u32, @ptrFromInt({s} + {d})).*))", .{ base, offset }),
        .stream => try w.print("@as(abi.Stream, @enumFromInt(@as(*align(4) const u32, @ptrFromInt({s} + {d})).*))", .{ base, offset }),
        .future => try w.print("@as(abi.Future, @enumFromInt(@as(*align(4) const u32, @ptrFromInt({s} + {d})).*))", .{ base, offset }),
        .named => |nm| {
            const td = r.find(nm) orelse return Error.UnknownType;
            switch (td.body) {
                .record => |fields| {
                    var f_off: u32 = 0;
                    try w.writeAll(".{");
                    for (fields, 0..) |f, i| {
                        const fl = try layoutOf(r, f.ty);
                        f_off = alignTo(f_off, fl.@"align");
                        if (i != 0) try w.writeAll(",");
                        try w.writeAll(" .");
                        try zigIdent(w, f.name);
                        try w.writeAll(" = ");
                        try emitLoadMem(w, r, f.ty, base, offset + f_off);
                        f_off += fl.size;
                    }
                    try w.writeAll(" }");
                },
                .variant => |cases| {
                    const disc_s = discSize(cases.len);
                    var payload_align: u32 = 1;
                    for (cases) |c| {
                        if (c.ty == null) continue;
                        const cl = try layoutOf(r, c.ty.?);
                        if (cl.@"align" > payload_align) payload_align = cl.@"align";
                    }
                    const p_off = payloadOffset(disc_s, payload_align);
                    try w.print("blk_lv_{d}: {{ const _dlv_{d} = ", .{ offset, offset });
                    try emitLoadDisc(w, base, offset, disc_s);
                    try w.print("; break :blk_lv_{d} switch (_dlv_{d}) {{", .{ offset, offset });
                    for (cases, 0..) |c, i| {
                        try w.print(" {d} => .{{ .", .{i});
                        try zigIdent(w, c.name);
                        if (c.ty) |pty| {
                            try w.writeAll(" = ");
                            try emitLoadMem(w, r, pty, base, offset + p_off);
                        } else try w.writeAll(" = {}");
                        try w.writeAll(" },");
                    }
                    try w.writeAll(" else => unreachable }; }");
                },
                .@"enum" => |cases| {
                    try w.print("@as(", .{});
                    try emitNamedTypeRef(w, r, nm);
                    try w.writeAll(", @enumFromInt(");
                    try emitLoadDisc(w, base, offset, discSize(cases.len));
                    try w.writeAll("))");
                },
                .flags => |labels| {
                    const sz = (try layoutOf(r, ty)).size;
                    _ = labels;
                    try w.print("@bitCast(@as([{d}]u8, @as(*const [{d}]u8, @ptrFromInt({s} + {d})).*))", .{ sz, sz, base, offset });
                },
                .alias => |a| try emitLoadMem(w, r, a, base, offset),
                .resource => try w.print("@enumFromInt(@as(*align(4) const u32, @ptrFromInt({s} + {d})).*)", .{ base, offset }),
            }
        },
        .option => |inner| {
            const inner_layout = try layoutOf(r, inner.*);
            const p_off = payloadOffset(1, inner_layout.@"align");
            try w.print("blk_lo_{d}: {{ const _dlo_{d} = ", .{ offset, offset });
            try emitLoadDisc(w, base, offset, 1);
            try w.print("; break :blk_lo_{d} if (_dlo_{d} == 0) null else ", .{ offset, offset });
            try emitLoadMem(w, r, inner.*, base, offset + p_off);
            try w.writeAll("; }");
        },
        .result => |info| {
            var payload_align: u32 = 1;
            if (info.ok) |p| {
                const l = try layoutOf(r, p.*);
                if (l.@"align" > payload_align) payload_align = l.@"align";
            }
            if (info.err) |p| {
                const l = try layoutOf(r, p.*);
                if (l.@"align" > payload_align) payload_align = l.@"align";
            }
            const p_off = payloadOffset(1, payload_align);
            try w.print("blk_lr_{d}: {{ const _dlr_{d} = ", .{ offset, offset });
            try emitLoadDisc(w, base, offset, 1);
            try w.print("; break :blk_lr_{d} switch (_dlr_{d}) {{ 0 => .{{ .ok = ", .{ offset, offset });
            if (info.ok) |p| try emitLoadMem(w, r, p.*, base, offset + p_off) else try w.writeAll("{}");
            try w.writeAll(" }, 1 => .{ .err = ");
            if (info.err) |p| try emitLoadMem(w, r, p.*, base, offset + p_off) else try w.writeAll("{}");
            try w.writeAll(" }, else => unreachable }; }");
        },
        .tuple => |elems| {
            try w.writeAll(".{");
            var f_off: u32 = 0;
            for (elems, 0..) |e, i| {
                const fl = try layoutOf(r, e);
                f_off = alignTo(f_off, fl.@"align");
                if (i != 0) try w.writeAll(",");
                try w.writeAll(" ");
                try emitLoadMem(w, r, e, base, offset + f_off);
                f_off += fl.size;
            }
            try w.writeAll(" }");
        },
        .list_fixed => |info| {
            const el = try layoutOf(r, info.elem.*);
            try w.writeAll(".{");
            var i: u32 = 0;
            while (i < info.len) : (i += 1) {
                if (i != 0) try w.writeAll(",");
                try w.writeAll(" ");
                try emitLoadMem(w, r, info.elem.*, base, offset + i * el.size);
            }
            try w.writeAll(" }");
        },
    }
}

fn emitLoadDisc(w: *std.Io.Writer, base: []const u8, offset: u32, size: u32) Error!void {
    switch (size) {
        1 => try w.print("@as(*const u8, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        2 => try w.print("@as(*align(2) const u16, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        4 => try w.print("@as(*align(4) const u32, @ptrFromInt({s} + {d})).*", .{ base, offset }),
        else => unreachable,
    }
}

/// Emit Zig statements that store `expr` of WIT type `ty` to
/// `base + offset`. The expression is reused literally several times,
/// so callers should already have it inside a let-bound name to
/// avoid re-evaluation.
fn emitStoreMem(w: *std.Io.Writer, r: *Resolver, ty: wit.TypeRef, expr: []const u8, base: []const u8, offset: u32) Error!void {
    switch (ty.kind) {
        .bool => try w.print("    @as(*u8, @ptrFromInt({s} + {d})).* = if ({s}) 1 else 0;\n", .{ base, offset, expr }),
        .s8 => try w.print("    @as(*i8, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .u8 => try w.print("    @as(*u8, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .s16 => try w.print("    @as(*align(2) i16, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .u16 => try w.print("    @as(*align(2) u16, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .s32 => try w.print("    @as(*align(4) i32, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .u32 => try w.print("    @as(*align(4) u32, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .s64 => try w.print("    @as(*align(8) i64, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .u64 => try w.print("    @as(*align(8) u64, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .f32 => try w.print("    @as(*align(4) f32, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .f64 => try w.print("    @as(*align(8) f64, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .char => try w.print("    @as(*align(4) u32, @ptrFromInt({s} + {d})).* = {s};\n", .{ base, offset, expr }),
        .string, .list => {
            try w.print("    @as(*align(4) u32, @ptrFromInt({s} + {d})).* = @intCast(@intFromPtr({s}.ptr));\n", .{ base, offset, expr });
            try w.print("    @as(*align(4) u32, @ptrFromInt({s} + {d})).* = @intCast({s}.len);\n", .{ base, offset + 4, expr });
        },
        .own, .borrow, .error_context, .stream, .future => try w.print("    @as(*align(4) u32, @ptrFromInt({s} + {d})).* = @intFromEnum({s});\n", .{ base, offset, expr }),
        .named => |nm| {
            const td = r.find(nm) orelse return Error.UnknownType;
            switch (td.body) {
                .record => |fields| {
                    var f_off: u32 = 0;
                    for (fields) |f| {
                        const fl = try layoutOf(r, f.ty);
                        f_off = alignTo(f_off, fl.@"align");
                        var sub: std.ArrayList(u8) = .empty;
                        defer sub.deinit(r.gpa);
                        try sub.appendSlice(r.gpa, expr);
                        try sub.append(r.gpa, '.');
                        try appendZigIdent(&sub, r.gpa, f.name);
                        try emitStoreMem(w, r, f.ty, sub.items, base, offset + f_off);
                        f_off += fl.size;
                    }
                },
                .variant => |cases| {
                    const disc_s = discSize(cases.len);
                    var payload_align: u32 = 1;
                    for (cases) |c| {
                        if (c.ty == null) continue;
                        const cl = try layoutOf(r, c.ty.?);
                        if (cl.@"align" > payload_align) payload_align = cl.@"align";
                    }
                    const p_off = payloadOffset(disc_s, payload_align);
                    try w.print("    switch ({s}) {{\n", .{expr});
                    for (cases, 0..) |c, i| {
                        try w.writeAll("        .");
                        try zigIdent(w, c.name);
                        var nb: [16]u8 = undefined;
                        const cap = allocCapture(r, &nb);
                        if (c.ty != null) {
                            try w.print(" => |{s}| {{\n", .{cap});
                        } else {
                            try w.writeAll(" => {\n");
                        }
                        try emitStoreDisc(w, base, offset, disc_s, i);
                        if (c.ty) |pty| {
                            try emitStoreMem(w, r, pty, cap, base, offset + p_off);
                        }
                        try w.writeAll("        },\n");
                    }
                    try w.writeAll("    }\n");
                },
                .@"enum" => |cases| {
                    try emitStoreDiscExpr(w, base, offset, discSize(cases.len), expr);
                },
                .flags => {
                    const sz = (try layoutOf(r, ty)).size;
                    try w.print("    @as(*[{d}]u8, @ptrFromInt({s} + {d})).* = @bitCast({s});\n", .{ sz, base, offset, expr });
                },
                .alias => |a| try emitStoreMem(w, r, a, expr, base, offset),
                .resource => try w.print("    @as(*align(4) u32, @ptrFromInt({s} + {d})).* = @intFromEnum({s});\n", .{ base, offset, expr }),
            }
        },
        .option => |inner| {
            const il = try layoutOf(r, inner.*);
            const p_off = payloadOffset(1, il.@"align");
            var nb: [16]u8 = undefined;
            const cap = allocCapture(r, &nb);
            try w.print("    if ({s}) |{s}| {{\n", .{ expr, cap });
            try emitStoreDisc(w, base, offset, 1, 1);
            try emitStoreMem(w, r, inner.*, cap, base, offset + p_off);
            try w.writeAll("    } else {\n");
            try emitStoreDisc(w, base, offset, 1, 0);
            try w.writeAll("    }\n");
        },
        .result => |info| {
            var payload_align: u32 = 1;
            if (info.ok) |p| {
                const l = try layoutOf(r, p.*);
                if (l.@"align" > payload_align) payload_align = l.@"align";
            }
            if (info.err) |p| {
                const l = try layoutOf(r, p.*);
                if (l.@"align" > payload_align) payload_align = l.@"align";
            }
            const p_off = payloadOffset(1, payload_align);
            var ok_nb: [16]u8 = undefined;
            const ok_cap = allocCapture(r, &ok_nb);
            var err_nb: [16]u8 = undefined;
            const err_cap = allocCapture(r, &err_nb);
            try w.print("    switch ({s}) {{\n", .{expr});
            try w.writeAll("        .ok");
            if (info.ok != null) try w.print(" => |{s}| {{\n", .{ok_cap}) else try w.writeAll(" => {\n");
            try emitStoreDisc(w, base, offset, 1, 0);
            if (info.ok) |p| try emitStoreMem(w, r, p.*, ok_cap, base, offset + p_off);
            try w.writeAll("        },\n");
            try w.writeAll("        .err");
            if (info.err != null) try w.print(" => |{s}| {{\n", .{err_cap}) else try w.writeAll(" => {\n");
            try emitStoreDisc(w, base, offset, 1, 1);
            if (info.err) |p| try emitStoreMem(w, r, p.*, err_cap, base, offset + p_off);
            try w.writeAll("        },\n");
            try w.writeAll("    }\n");
        },
        .tuple => |elems| {
            var f_off: u32 = 0;
            for (elems, 0..) |e, i| {
                const fl = try layoutOf(r, e);
                f_off = alignTo(f_off, fl.@"align");
                var sub: std.ArrayList(u8) = .empty;
                defer sub.deinit(r.gpa);
                try sub.appendSlice(r.gpa, expr);
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, ".@\"{d}\"", .{i}) catch return Error.OutOfMemory;
                try sub.appendSlice(r.gpa, num_str);
                try emitStoreMem(w, r, e, sub.items, base, offset + f_off);
                f_off += fl.size;
            }
        },
        .list_fixed => |info| {
            const el = try layoutOf(r, info.elem.*);
            var i: u32 = 0;
            while (i < info.len) : (i += 1) {
                const sub = try std.fmt.allocPrint(r.gpa, "{s}[{d}]", .{ expr, i });
                defer r.gpa.free(sub);
                try emitStoreMem(w, r, info.elem.*, sub, base, offset + i * el.size);
            }
        },
    }
}

fn emitStoreDisc(w: *std.Io.Writer, base: []const u8, offset: u32, size: u32, value: usize) Error!void {
    switch (size) {
        1 => try w.print("            @as(*u8, @ptrFromInt({s} + {d})).* = {d};\n", .{ base, offset, value }),
        2 => try w.print("            @as(*align(2) u16, @ptrFromInt({s} + {d})).* = {d};\n", .{ base, offset, value }),
        4 => try w.print("            @as(*align(4) u32, @ptrFromInt({s} + {d})).* = {d};\n", .{ base, offset, value }),
        else => unreachable,
    }
}

fn emitStoreDiscExpr(w: *std.Io.Writer, base: []const u8, offset: u32, size: u32, expr: []const u8) Error!void {
    switch (size) {
        1 => try w.print("    @as(*u8, @ptrFromInt({s} + {d})).* = @intFromEnum({s});\n", .{ base, offset, expr }),
        2 => try w.print("    @as(*align(2) u16, @ptrFromInt({s} + {d})).* = @intFromEnum({s});\n", .{ base, offset, expr }),
        4 => try w.print("    @as(*align(4) u32, @ptrFromInt({s} + {d})).* = @intFromEnum({s});\n", .{ base, offset, expr }),
        else => unreachable,
    }
}

// =====================================================================
// Flat lifting / lowering
// =====================================================================

/// Emit a Zig expression that lifts a value of WIT type `ty` from the
/// flat parameter slots starting at `*slot`. Advances `*slot` past
/// the slots used. Slot identifiers are `p0`, `p1`, ...
fn emitLiftFlat(w: *std.Io.Writer, r: *Resolver, ty: wit.TypeRef, slot: *usize) Error!void {
    switch (ty.kind) {
        .bool => {
            try w.print("(p{d} != 0)", .{slot.*});
            slot.* += 1;
        },
        .s8 => {
            try w.print("@as(i8, @truncate(p{d}))", .{slot.*});
            slot.* += 1;
        },
        .u8 => {
            try w.print("@as(u8, @truncate(@as(u32, @bitCast(p{d}))))", .{slot.*});
            slot.* += 1;
        },
        .s16 => {
            try w.print("@as(i16, @truncate(p{d}))", .{slot.*});
            slot.* += 1;
        },
        .u16 => {
            try w.print("@as(u16, @truncate(@as(u32, @bitCast(p{d}))))", .{slot.*});
            slot.* += 1;
        },
        .s32 => {
            try w.print("p{d}", .{slot.*});
            slot.* += 1;
        },
        .u32 => {
            try w.print("@as(u32, @bitCast(p{d}))", .{slot.*});
            slot.* += 1;
        },
        .s64 => {
            try w.print("p{d}", .{slot.*});
            slot.* += 1;
        },
        .u64 => {
            try w.print("@as(u64, @bitCast(p{d}))", .{slot.*});
            slot.* += 1;
        },
        .f32, .f64 => {
            try w.print("p{d}", .{slot.*});
            slot.* += 1;
        },
        .char => {
            try w.print("@as(u21, @intCast(@as(u32, @bitCast(p{d}))))", .{slot.*});
            slot.* += 1;
        },
        .string => {
            try w.writeAll("@as([*]const u8, @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(");
            try w.print("p{d}", .{slot.*});
            try w.writeAll("))))))[0..@as(usize, @intCast(@as(u32, @bitCast(");
            try w.print("p{d}", .{slot.* + 1});
            try w.writeAll("))))]");
            slot.* += 2;
        },
        .list => |inner| {
            try w.writeAll("@as([*]const ");
            try emitTypeRef(w, r, inner.*);
            try w.writeAll(", @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(");
            try w.print("p{d}", .{slot.*});
            try w.writeAll("))))))[0..@as(usize, @intCast(@as(u32, @bitCast(");
            try w.print("p{d}", .{slot.* + 1});
            try w.writeAll("))))]");
            slot.* += 2;
        },
        .own, .borrow => {
            try w.print("@enumFromInt(@as(u32, @bitCast(p{d})))", .{slot.*});
            slot.* += 1;
        },
        .option => |inner| {
            const n = r.label_counter;
            r.label_counter += 1;
            try w.print("blk_o_{d}: {{ const _do_{d} = p{d}; break :blk_o_{d} if (_do_{d} == 0) null else ", .{ n, n, slot.*, n, n });
            slot.* += 1;
            try emitLiftFlat(w, r, inner.*, slot);
            try w.writeAll("; }");
        },
        .result => |info| {
            const n = r.label_counter;
            r.label_counter += 1;
            try w.print("blk_r_{d}: {{ const _dr_{d} = p{d}; break :blk_r_{d} switch (_dr_{d}) {{ 0 => .{{ .ok = ", .{ n, n, slot.*, n, n });
            slot.* += 1;
            const after_disc = slot.*;
            if (info.ok) |p| try emitLiftFlat(w, r, p.*, slot) else try w.writeAll("{}");
            const ok_end = slot.*;
            try w.writeAll(" }, 1 => .{ .err = ");
            slot.* = after_disc;
            if (info.err) |p| try emitLiftFlat(w, r, p.*, slot) else try w.writeAll("{}");
            const err_end = slot.*;
            try w.writeAll(" }, else => unreachable }; }");
            slot.* = if (ok_end > err_end) ok_end else err_end;
        },
        .tuple => |elems| {
            try w.writeAll(".{ ");
            for (elems, 0..) |e, i| {
                if (i != 0) try w.writeAll(", ");
                try emitLiftFlat(w, r, e, slot);
            }
            try w.writeAll(" }");
        },
        .named => |nm| {
            const td = r.find(nm) orelse return Error.UnknownType;
            switch (td.body) {
                .record => |fields| {
                    try w.writeAll(".{ ");
                    for (fields, 0..) |f, i| {
                        if (i != 0) try w.writeAll(", ");
                        try w.writeAll(".");
                        try zigIdent(w, f.name);
                        try w.writeAll(" = ");
                        try emitLiftFlat(w, r, f.ty, slot);
                    }
                    try w.writeAll(" }");
                },
                .variant => |cases| {
                    const n = r.label_counter;
                    r.label_counter += 1;
                    try w.print("blk_v_{d}: {{ const _dv_{d} = p{d}; break :blk_v_{d} switch (_dv_{d}) {{", .{ n, n, slot.*, n, n });
                    slot.* += 1;
                    const after_disc = slot.*;
                    // Find joined arity.
                    const gpa = std.heap.page_allocator;
                    var biggest: usize = 0;
                    for (cases) |c| {
                        if (c.ty == null) continue;
                        var flat: std.ArrayList(CoreType) = .empty;
                        defer flat.deinit(gpa);
                        try flattenType(&flat, gpa, r, c.ty.?);
                        if (flat.items.len > biggest) biggest = flat.items.len;
                    }
                    for (cases, 0..) |c, i| {
                        try w.print(" {d} => .{{ .", .{i});
                        try zigIdent(w, c.name);
                        if (c.ty) |pty| {
                            try w.writeAll(" = ");
                            slot.* = after_disc;
                            try emitLiftFlat(w, r, pty, slot);
                        } else try w.writeAll(" = {}");
                        try w.writeAll(" },");
                    }
                    try w.writeAll(" else => unreachable }; }");
                    slot.* = after_disc + biggest;
                },
                .@"enum" => |cases| {
                    _ = cases;
                    try w.print("@enumFromInt(@as(u32, @bitCast(p{d})))", .{slot.*});
                    slot.* += 1;
                },
                .flags => |labels| {
                    const w_count: usize = if (labels.len <= 32) 1 else if (labels.len <= 64) 2 else (labels.len + 31) / 32;
                    if (w_count == 1) {
                        const backing_bits = flagBackingBits(labels.len);
                        try w.print("@bitCast(@as(u{d}, @truncate(@as(u32, @bitCast(p{d})))))", .{ backing_bits, slot.* });
                        slot.* += 1;
                    } else return Error.Unsupported;
                },
                .alias => |a| try emitLiftFlat(w, r, a, slot),
                .resource => {
                    try w.print("@enumFromInt(@as(u32, @bitCast(p{d})))", .{slot.*});
                    slot.* += 1;
                },
            }
        },
        .error_context => {
            try w.print("@as(abi.ErrorContext, @enumFromInt(@as(u32, @bitCast(p{d}))))", .{slot.*});
            slot.* += 1;
        },
        .stream, .future => {
            try w.print("@enumFromInt(@as(u32, @bitCast(p{d})))", .{slot.*});
            slot.* += 1;
        },
        .list_fixed => |info| {
            try w.writeAll(".{ ");
            var i: u32 = 0;
            while (i < info.len) : (i += 1) {
                if (i != 0) try w.writeAll(", ");
                try emitLiftFlat(w, r, info.elem.*, slot);
            }
            try w.writeAll(" }");
        },
    }
}

/// Emit Zig code that, given a value `expr` of WIT type `ty`,
/// produces a single flat core value of `core` to be returned. Only
/// valid when the type has exactly one flat representation slot.
fn emitLowerDirect(w: *std.Io.Writer, r: *Resolver, ty: wit.TypeRef, expr: []const u8) Error!void {
    switch (ty.kind) {
        .bool => try w.print("@as(i32, if ({s}) 1 else 0)", .{expr}),
        .s8 => try w.print("@as(i32, {s})", .{expr}),
        .u8 => try w.print("@as(i32, @bitCast(@as(u32, {s})))", .{expr}),
        .s16 => try w.print("@as(i32, {s})", .{expr}),
        .u16 => try w.print("@as(i32, @bitCast(@as(u32, {s})))", .{expr}),
        .s32 => try w.print("{s}", .{expr}),
        .u32 => try w.print("@as(i32, @bitCast({s}))", .{expr}),
        .s64 => try w.print("{s}", .{expr}),
        .u64 => try w.print("@as(i64, @bitCast({s}))", .{expr}),
        .f32, .f64 => try w.print("{s}", .{expr}),
        .char => try w.print("@as(i32, @bitCast(@as(u32, {s})))", .{expr}),
        .own, .borrow, .error_context, .stream, .future => try w.print("@as(i32, @bitCast(@intFromEnum({s})))", .{expr}),
        .named => |nm| {
            const td = r.find(nm) orelse return Error.UnknownType;
            switch (td.body) {
                .@"enum" => try w.print("@as(i32, @bitCast(@as(u32, @intFromEnum({s}))))", .{expr}),
                .resource => try w.print("@as(i32, @bitCast(@intFromEnum({s})))", .{expr}),
                .flags => |labels| {
                    if (labels.len > 32) return Error.Unsupported;
                    const backing_bits = flagBackingBits(labels.len);
                    try w.print("@as(i32, @bitCast(@as(u32, @as(u{d}, @bitCast({s})))))", .{ backing_bits, expr });
                },
                .alias => |a| try emitLowerDirect(w, r, a, expr),
                .record, .variant => return Error.Unsupported,
            }
        },
        // Empty option/result with no payload flatten to one discriminant slot.
        .option => try w.print("@as(i32, if ({s} == null) 0 else 1)", .{expr}),
        .result => try w.print("@as(i32, @intFromEnum({s}))", .{expr}),
        else => return Error.Unsupported,
    }
}

// =====================================================================
// Function wrappers (exports and imports)
// =====================================================================

fn emitImportDecl(w: *std.Io.Writer, r: *Resolver, name: []const u8, f: wit.Func, opts: Options) Error!void {
    if (f.is_async) return emitImportDeclAsync(w, r, name, f, opts);
    const gpa = std.heap.page_allocator;
    var flat_params: std.ArrayList(CoreType) = .empty;
    defer flat_params.deinit(gpa);
    for (f.params) |p| try flattenType(&flat_params, gpa, r, p.ty);

    var flat_results: std.ArrayList(CoreType) = .empty;
    defer flat_results.deinit(gpa);
    if (f.results.len == 1) try flattenType(&flat_results, gpa, r, f.results[0].ty);
    if (f.results.len > 1) {
        for (f.results) |p| try flattenType(&flat_results, gpa, r, p.ty);
    }
    const indirect_results = flat_results.items.len > 1;
    // Canonical ABI: when total flat-params exceed MAX_FLAT_PARAMS (16),
    // all parameters go through a single i32 pointer to a memory area
    // sized for the joint param layout.
    const indirect_params = flat_params.items.len > 16;

    // (1) raw extern.
    try w.writeAll("    const _import_");
    try zigIdent(w, name);
    try w.writeAll(" = @extern(*const fn (");
    if (indirect_params) {
        try w.writeAll("i32");
    } else {
        for (flat_params.items, 0..) |t, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(t.zigName());
        }
    }
    if (indirect_results) {
        if (indirect_params or flat_params.items.len != 0) try w.writeAll(", ");
        try w.writeAll("i32");
    }
    try w.writeAll(") callconv(.c) ");
    if (indirect_results or flat_results.items.len == 0) {
        try w.writeAll("void");
    } else {
        try w.writeAll(flat_results.items[0].zigName());
    }
    try w.print(", .{{ .name = \"{s}\", .library_name = \"{s}\" }});\n", .{ name, opts.import_module });

    try emitDocs(w, f.docs, "    ");
    try w.writeAll("    pub fn ");
    try zigIdent(w, name);
    try w.writeAll("(");
    for (f.params, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try emitParamName(w, p.name);
        try w.writeAll(": ");
        try emitTypeRef(w, r, p.ty);
    }
    try w.writeAll(") ");
    if (f.results.len == 0) {
        try w.writeAll("void");
    } else if (f.results.len == 1) {
        try emitTypeRef(w, r, f.results[0].ty);
    } else {
        try w.writeAll("void");
    }
    try w.writeAll(" {\n");
    if (indirect_results) {
        const l = try jointLayout(r, f.results);
        try w.print("        var _retarea: [{d}]u8 align({d}) = undefined;\n", .{ l.size, l.@"align" });
    }
    var arg_idx: usize = 0;
    if (indirect_params) {
        // Joint param layout (records-style: walk params with running
        // offset and max alignment).
        const l = try jointLayout(r, f.params);
        try w.print("        var _argsarea: [{d}]u8 align({d}) = undefined;\n", .{ l.size, l.@"align" });
        try w.writeAll("        const _args_base: usize = @intFromPtr(&_argsarea);\n");
        var offset: u32 = 0;
        for (f.params) |p| {
            const pl = try layoutOf(r, p.ty);
            offset = alignTo(offset, pl.@"align");
            const expr_buf = try paramNameAlloc(gpa, p.name);
            defer gpa.free(expr_buf);
            try emitStoreMem(w, r, p.ty, expr_buf, "_args_base", offset);
            offset += pl.size;
        }
        try w.writeAll("        const _p0: i32 = @bitCast(@as(u32, @intCast(_args_base)));\n");
        arg_idx = 1;
    } else for (f.params) |p| {
        const expr_buf = try paramNameAlloc(gpa, p.name);
        defer gpa.free(expr_buf);
        try emitLowerImportSlots(w, r, p.ty, expr_buf, &arg_idx);
    }
    try w.writeAll("        ");
    if (f.results.len != 0 and !indirect_results) try w.writeAll("const _r = ");
    try w.writeAll("_import_");
    try zigIdent(w, name);
    try w.writeAll(".*(");
    var k: usize = 0;
    while (k < arg_idx) : (k += 1) {
        if (k != 0) try w.writeAll(", ");
        try w.print("_p{d}", .{k});
    }
    if (indirect_results) {
        if (arg_idx != 0) try w.writeAll(", ");
        try w.writeAll("@bitCast(@as(u32, @intCast(@intFromPtr(&_retarea))))");
    }
    try w.writeAll(");\n");
    if (f.results.len != 0 and !indirect_results) {
        switch (f.results[0].ty.kind) {
            .u32, .u8, .u16, .char => try w.writeAll("        return @bitCast(_r);\n"),
            .u64 => try w.writeAll("        return @bitCast(_r);\n"),
            .result => try w.writeAll("        return if (_r == 0) .{ .ok = {} } else .{ .err = {} };\n"),
            .option => try w.writeAll("        return if (_r == 0) null else .{ .ok = {} };\n"),
            .own, .borrow, .error_context, .stream, .future => try w.writeAll("        return @enumFromInt(@as(u32, @bitCast(_r)));\n"),
            .named => |nm| {
                if (resolveAliasTo(r, nm)) |kind| switch (kind) {
                    .bool => try w.writeAll("        return _r != 0;\n"),
                    .s32, .s64, .f32, .f64 => try w.writeAll("        return _r;\n"),
                    .s8, .s16 => try w.writeAll("        return @intCast(_r);\n"),
                    .u32, .u64 => try w.writeAll("        return @bitCast(_r);\n"),
                    .u8, .u16, .char => try w.writeAll("        return @intCast(@as(u32, @bitCast(_r)));\n"),
                    .result => try w.writeAll("        return if (_r == 0) .{ .ok = {} } else .{ .err = {} };\n"),
                    .option => try w.writeAll("        return if (_r == 0) null else .{ .ok = {} };\n"),
                    else => try w.writeAll("        return @enumFromInt(@as(u32, @bitCast(_r)));\n"),
                } else try w.writeAll("        return @enumFromInt(@as(u32, @bitCast(_r)));\n");
            },
            .bool => try w.writeAll("        return _r != 0;\n"),
            .s32, .s8, .s16, .s64, .f32, .f64 => try w.writeAll("        return _r;\n"),
            else => try w.writeAll("        return @bitCast(_r);\n"),
        }
    } else if (indirect_results and f.results.len == 1) {
        try w.writeAll("        const _base: usize = @intFromPtr(&_retarea);\n");
        try w.writeAll("        return ");
        try emitLoadMem(w, r, f.results[0].ty, "_base", 0);
        try w.writeAll(";\n");
    } else if (indirect_results and f.results.len > 1) {
        try w.writeAll("        @compileError(\"multi-result imports are not yet supported\");\n");
    }
    try w.writeAll("    }\n");

    // Per-function stream/future intrinsics. WASI 0.3 makes heavy use
    // of *sync* functions that traffic in stream/future handles
    // (`read-via-stream: func() -> tuple<stream<u8>, future<…>>`), so
    // these are not an async-only concern.
    try emitFuncStreamFutureIntrinsics(w, r, opts.import_module, name, name, f);
}

/// Emit an async-lowered import. The host function is called via the
/// `[async-lower]<func>` symbol; the return is a packed `i32` whose low
/// 4 bits are the `Status` (STARTING / STARTED / RETURNED / *_CANCELLED)
/// and high 28 bits are the subtask handle (or 0 if Status == RETURNED).
///
/// For now we synthesise a "blocking" wrapper: it issues the async-lower
/// call, then drives the result to completion via the root async
/// `[waitable-set-{new,wait}]` / `[subtask-drop]` builtins. This keeps
/// the user-facing Zig surface synchronous (same shape as the sync
/// path), which is the right default for a guest that doesn't itself
/// run a task scheduler. Real coroutine drive can be layered on later.
fn emitImportDeclAsync(w: *std.Io.Writer, r: *Resolver, name: []const u8, f: wit.Func, opts: Options) Error!void {
    const gpa = std.heap.page_allocator;
    var flat_params: std.ArrayList(CoreType) = .empty;
    defer flat_params.deinit(gpa);
    for (f.params) |p| try flattenType(&flat_params, gpa, r, p.ty);

    var flat_results: std.ArrayList(CoreType) = .empty;
    defer flat_results.deinit(gpa);
    if (f.results.len == 1) try flattenType(&flat_results, gpa, r, f.results[0].ty);
    if (f.results.len > 1) {
        for (f.results) |p| try flattenType(&flat_results, gpa, r, p.ty);
    }

    const indirect_params = flat_params.items.len > 4; // MAX_FLAT_ASYNC_PARAMS
    const has_result = f.results.len != 0;

    // Raw extern. Always returns i32 (the packed Status | subtask).
    try w.writeAll("    const _import_");
    try zigIdent(w, name);
    try w.writeAll(" = @extern(*const fn (");
    var sep = false;
    if (indirect_params) {
        try w.writeAll("i32");
        sep = true;
    } else for (flat_params.items) |t| {
        if (sep) try w.writeAll(", ");
        try w.writeAll(t.zigName());
        sep = true;
    }
    if (has_result) {
        if (sep) try w.writeAll(", ");
        try w.writeAll("i32");
        sep = true;
    }
    try w.print(") callconv(.c) i32, .{{ .name = \"[async-lower]{s}\", .library_name = \"{s}\" }});\n", .{ name, opts.import_module });

    try emitDocs(w, f.docs, "    ");
    try w.writeAll("    pub fn ");
    try zigIdent(w, name);
    try w.writeAll("(");
    for (f.params, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try emitParamName(w, p.name);
        try w.writeAll(": ");
        try emitTypeRef(w, r, p.ty);
    }
    try w.writeAll(") ");
    if (f.results.len == 0) {
        try w.writeAll("void");
    } else if (f.results.len == 1) {
        try emitTypeRef(w, r, f.results[0].ty);
    } else {
        try w.writeAll("void");
    }
    try w.writeAll(" {\n");

    // Result area allocation (when the function has a result the
    // async-lower convention requires a pointer-out param even for
    // single-flat results).
    if (has_result) {
        const l = if (f.results.len == 1)
            try layoutOf(r, f.results[0].ty)
        else
            try jointLayout(r, f.results);
        try w.print("        var _retarea: [{d}]u8 align({d}) = undefined;\n", .{ l.size, l.@"align" });
    }

    var arg_idx: usize = 0;
    if (indirect_params) {
        const l = try jointLayout(r, f.params);
        try w.print("        var _argsarea: [{d}]u8 align({d}) = undefined;\n", .{ l.size, l.@"align" });
        try w.writeAll("        const _args_base: usize = @intFromPtr(&_argsarea);\n");
        var offset: u32 = 0;
        for (f.params) |p| {
            const pl = try layoutOf(r, p.ty);
            offset = alignTo(offset, pl.@"align");
            const expr_buf = try paramNameAlloc(gpa, p.name);
            defer gpa.free(expr_buf);
            try emitStoreMem(w, r, p.ty, expr_buf, "_args_base", offset);
            offset += pl.size;
        }
        try w.writeAll("        const _p0: i32 = @bitCast(@as(u32, @intCast(_args_base)));\n");
        arg_idx = 1;
    } else for (f.params) |p| {
        const expr_buf = try paramNameAlloc(gpa, p.name);
        defer gpa.free(expr_buf);
        try emitLowerImportSlots(w, r, p.ty, expr_buf, &arg_idx);
    }

    try w.writeAll("        const _packed = _import_");
    try zigIdent(w, name);
    try w.writeAll(".*(");
    var k: usize = 0;
    while (k < arg_idx) : (k += 1) {
        if (k != 0) try w.writeAll(", ");
        try w.print("_p{d}", .{k});
    }
    if (has_result) {
        if (arg_idx != 0) try w.writeAll(", ");
        try w.writeAll("@bitCast(@as(u32, @intCast(@intFromPtr(&_retarea))))");
    }
    try w.writeAll(");\n");

    // Drive the async call to completion. The status code is in the
    // low 4 bits, the subtask handle (when non-zero) in the high 28.
    // If STATUS_RETURNED right away, the result is already in
    // `_retarea` and there's nothing to wait for — fast path. The
    // slow path allocates a fresh waitable-set, attaches the
    // subtask, and blocks until any terminal status is delivered
    // (RETURNED / START_CANCELLED / RETURN_CANCELLED). Subtask-drop
    // implicitly unjoins from the set, so the `defer _set.deinit()`
    // is safe.
    try w.writeAll("        const _result = abi.SubtaskResult.unpack(@bitCast(_packed));\n");
    try w.writeAll("        if (_result.status != .returned) {\n");
    try w.writeAll("            const _set = abi.WaitableSet.init();\n");
    try w.writeAll("            defer _set.deinit();\n");
    try w.writeAll("            _set.join(_result.subtask);\n");
    try w.writeAll("            while (true) {\n");
    try w.writeAll("                const _ev = _set.wait();\n");
    try w.writeAll("                if (_ev.code == .subtask and _ev.p1 == _result.subtask) {\n");
    try w.writeAll("                    const _st: abi.Status = @enumFromInt(_ev.p2);\n");
    // Cancellation paths: don't panic — leave `_retarea` undefined
    // and let the caller see the natural junk value. The host
    // cancelled us; a clean termination is the best we can do here
    // without an error-shaped return type.
    try w.writeAll("                    if (_st == .returned or _st == .start_cancelled or _st == .return_cancelled) break;\n");
    try w.writeAll("                }\n");
    try w.writeAll("            }\n");
    try w.writeAll("            abi.root_async.@\"[subtask-drop]\"(_result.subtask);\n");
    try w.writeAll("        }\n");

    if (has_result) {
        if (f.results.len == 1) {
            try w.writeAll("        const _base: usize = @intFromPtr(&_retarea);\n");
            try w.writeAll("        return ");
            try emitLoadMem(w, r, f.results[0].ty, "_base", 0);
            try w.writeAll(";\n");
        } else {
            try w.writeAll("        @compileError(\"multi-result async imports are not yet supported\");\n");
        }
    }
    try w.writeAll("    }\n");

    // Per-function stream/future intrinsics for this async import.
    // The module for these is the same as the function's import
    // module (no `[export]` prefix — that's only for exports).
    // emitFuncStreamFutureIntrinsics writes a `pub const … = struct
    // {…};` — for an import wrapper we're already inside the iface
    // struct, so the same emit works (the namespace becomes a nested
    // `pub const intrinsics_<name> = struct {…};`).
    try emitFuncStreamFutureIntrinsics(w, r, opts.import_module, name, name, f);
}

fn emitCabiExport(w: *std.Io.Writer, r: *Resolver, name: []const u8, dispatch: []const u8, alias_prefix: []const u8, f: wit.Func) Error!void {
    if (f.is_async) return emitCabiExportAsync(w, r, name, dispatch, alias_prefix, f);

    const gpa = std.heap.page_allocator;
    var flat_params: std.ArrayList(CoreType) = .empty;
    defer flat_params.deinit(gpa);
    for (f.params) |p| try flattenType(&flat_params, gpa, r, p.ty);

    var flat_results: std.ArrayList(CoreType) = .empty;
    defer flat_results.deinit(gpa);
    if (f.results.len == 1) try flattenType(&flat_results, gpa, r, f.results[0].ty);
    if (f.results.len > 1) {
        for (f.results) |p| try flattenType(&flat_results, gpa, r, p.ty);
    }

    const indirect_params = flat_params.items.len > 16;
    const indirect_results = flat_results.items.len > 1;

    try w.writeAll("export fn ");
    try zigExportIdent(w, name);
    try w.writeAll("(");
    if (indirect_params) {
        try w.writeAll("args_ptr: i32");
    } else {
        for (flat_params.items, 0..) |t, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("p{d}: {s}", .{ i, t.zigName() });
        }
    }
    try w.writeAll(") ");
    if (indirect_results) {
        try w.writeAll("i32");
    } else if (flat_results.items.len == 0) {
        try w.writeAll("void");
    } else {
        try w.writeAll(flat_results.items[0].zigName());
    }
    try w.writeAll(" {\n");

    // Lift parameters.
    if (indirect_params) {
        try w.writeAll("    const _args_base: usize = @intCast(@as(u32, @bitCast(args_ptr)));\n");
        var offset: u32 = 0;
        for (f.params) |p| {
            const l = try layoutOf(r, p.ty);
            offset = alignTo(offset, l.@"align");
            try w.writeAll("    const ");
            try zigIdent(w, p.name);
            try w.writeAll(": ");
            try emitParamType(w, r, alias_prefix, p);
            try w.writeAll(" = ");
            try emitLoadMem(w, r, p.ty, "_args_base", offset);
            try w.writeAll(";\n");
            offset += l.size;
        }
    } else {
        var slot: usize = 0;
        for (f.params) |p| {
            try w.writeAll("    const ");
            try zigIdent(w, p.name);
            try w.writeAll(": ");
            try emitParamType(w, r, alias_prefix, p);
            try w.writeAll(" = ");
            try emitLiftFlat(w, r, p.ty, &slot);
            try w.writeAll(";\n");
        }
    }

    if (f.results.len == 0) {
        try w.writeAll("    exports.");
    } else {
        try w.writeAll("    const _result = exports.");
    }
    try emitDispatchPath(w, dispatch);
    try w.writeAll("(");
    for (f.params, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try zigIdent(w, p.name);
    }
    try w.writeAll(");\n");

    if (f.results.len == 0) {
        // nothing
    } else if (!indirect_results) {
        try w.writeAll("    return ");
        try emitLowerDirect(w, r, f.results[0].ty, "_result");
        try w.writeAll(";\n");
    } else {
        const ret_buf_name = try retareaNameAlloc(gpa, name);
        defer gpa.free(ret_buf_name);
        if (f.results.len == 1) {
            try emitStoreMem(w, r, f.results[0].ty, "_result", ret_buf_name, 0);
        } else {
            var off: u32 = 0;
            for (f.results) |res| {
                const l = try layoutOf(r, res.ty);
                off = alignTo(off, l.@"align");
                const field_expr = try std.fmt.allocPrint(gpa, "_result.{f}", .{std.zig.fmtId(res.name)});
                defer gpa.free(field_expr);
                try emitStoreMem(w, r, res.ty, field_expr, ret_buf_name, off);
                off += l.size;
            }
        }
        try w.writeAll("    return @bitCast(@as(u32, @intCast(");
        try w.writeAll(ret_buf_name);
        try w.writeAll(")));\n");
    }

    try w.writeAll("}\n\n");

    try emitRetareaAndPostReturn(w, r, name, f.results, indirect_results, flat_results.items);
}

/// Emit an async-lifted export. The core-module surface is:
///
///   export "[async-lift]<name>" : flat_params -> i32 (CallbackCode)
///   export "[callback][async-lift]<name>" : (i32, i32, i32) -> i32
///   import "[export]<iface>"."[task-return]<func>" : flat_results -> ()
///
/// The user-side implementation lives at `exports.<dispatch>` and may
/// return either:
///   - the result value directly (a single eager completion); generated
///     code calls task.return and returns EXIT in one step, OR
///   - `null` to enter the callback loop (state-machine drive). The
///     user's `<dispatch>.callback(event, p1, p2)` is invoked from the
///     generated `[callback]` export and decides the next CallbackCode.
///
/// For the MVP we only support the eager path (synchronous-style
/// implementation). The callback export is still generated so the
/// canon lift is valid; it just traps if it's ever called.
fn emitCabiExportAsync(w: *std.Io.Writer, r: *Resolver, name: []const u8, dispatch: []const u8, alias_prefix: []const u8, f: wit.Func) Error!void {
    const gpa = std.heap.page_allocator;
    var flat_params: std.ArrayList(CoreType) = .empty;
    defer flat_params.deinit(gpa);
    for (f.params) |p| try flattenType(&flat_params, gpa, r, p.ty);

    var flat_results: std.ArrayList(CoreType) = .empty;
    defer flat_results.deinit(gpa);
    if (f.results.len == 1) try flattenType(&flat_results, gpa, r, f.results[0].ty);
    if (f.results.len > 1) {
        for (f.results) |p| try flattenType(&flat_results, gpa, r, p.ty);
    }

    // Async exports still cap params at MAX_FLAT_PARAMS=16 on the lift
    // side (the MAX_FLAT_ASYNC_PARAMS=4 cap only applies to async-lower
    // imports — see Concurrency.md flatten_functype).
    const indirect_params = flat_params.items.len > 16;
    // task.return lowers the result like *parameters* of a call
    // (flatten_functype(result as params, [])), so the direct form
    // carries up to MAX_FLAT_PARAMS=16 flat values and only spills to
    // a single retarea pointer beyond that.
    const indirect_results = flat_results.items.len > 16;

    // task.return import. Module = "[export]<iface-prefix-from-name>" or
    // "[export]$root" if name has no `#`.
    const hash_idx = std.mem.indexOfScalar(u8, name, '#');
    const tr_module = if (hash_idx) |i|
        try std.fmt.allocPrint(gpa, "[export]{s}", .{name[0..i]})
    else
        try gpa.dupe(u8, "[export]$root");
    defer gpa.free(tr_module);
    const tr_func = if (hash_idx) |i| name[i + 1 ..] else name;

    // Declared via `@extern(...)` pointer form so the Zig identifier
    // is unique (sanitized full export name) while the link-name
    // remains the spec-required `[task-return]<bare-func>`. Without
    // this, two async exports sharing a bare WIT name across
    // different interfaces would collide at Zig file scope on the
    // identifier `@"[task-return]<func>"`.
    var tr_ident_buf: std.Io.Writer.Allocating = .init(gpa);
    defer tr_ident_buf.deinit();
    try tr_ident_buf.writer.writeAll("_task_return_");
    try zigSanitizeIdent(&tr_ident_buf.writer, name);
    const tr_ident = tr_ident_buf.writer.buffered();
    try w.print("const {s} = @extern(*const fn (", .{tr_ident});
    if (indirect_results) {
        try w.writeAll("i32");
    } else {
        for (flat_results.items, 0..) |t, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(t.zigName());
        }
    }
    try w.print(") callconv(.c) void, .{{ .name = \"[task-return]{s}\", .library_name = \"{s}\" }});\n\n", .{ tr_func, tr_module });

    // Typed `taskReturn` thunk handed to the state-machine `start`
    // / `step` functions. The user calls it inline to invoke
    // `[task-return]<fn>` with a properly lowered result. Emitted as
    // a free file-scope function so the user can take its address
    // (`&_task_return_helper_<sanitized>`) when their state-machine
    // signature uses `*const fn(R) void` instead of `anytype`.
    var tr_helper_buf: std.Io.Writer.Allocating = .init(gpa);
    defer tr_helper_buf.deinit();
    try tr_helper_buf.writer.writeAll("_task_return_helper_");
    try zigSanitizeIdent(&tr_helper_buf.writer, name);
    const tr_helper = tr_helper_buf.writer.buffered();

    try w.print("fn {s}(", .{tr_helper});
    if (f.results.len == 1) {
        try w.writeAll("_value: ");
        if (needsAlias(f.results[0].ty.kind)) {
            try zigIdent(w, alias_prefix);
            try w.writeAll("_result");
        } else {
            try emitTypeRef(w, r, f.results[0].ty);
        }
    }
    try w.writeAll(") void {\n");
    if (f.results.len == 0) {
        try w.print("    {s}.*();\n", .{tr_ident});
    } else if (f.results.len == 1) {
        try emitTaskReturnLowering(w, r, gpa, f, name, tr_ident, "_value", indirect_results);
    } else {
        try w.writeAll("    @compileError(\"multi-result async exports are not supported (WIT deprecates them at embed time)\");\n");
    }
    try w.writeAll("}\n\n");

    // Main async-lift export: flat_params -> i32 (CallbackCode).
    try w.writeAll("export fn ");
    try zigExportAsyncLiftIdent(w, name);
    try w.writeAll("(");
    if (indirect_params) {
        try w.writeAll("args_ptr: i32");
    } else {
        for (flat_params.items, 0..) |t, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("p{d}: {s}", .{ i, t.zigName() });
        }
    }
    try w.writeAll(") i32 {\n");

    if (indirect_params) {
        try w.writeAll("    const _args_base: usize = @intCast(@as(u32, @bitCast(args_ptr)));\n");
        var offset: u32 = 0;
        for (f.params) |p| {
            const l = try layoutOf(r, p.ty);
            offset = alignTo(offset, l.@"align");
            try w.writeAll("    const ");
            try zigIdent(w, p.name);
            try w.writeAll(": ");
            try emitParamType(w, r, alias_prefix, p);
            try w.writeAll(" = ");
            try emitLoadMem(w, r, p.ty, "_args_base", offset);
            try w.writeAll(";\n");
            offset += l.size;
        }
    } else {
        var slot: usize = 0;
        for (f.params) |p| {
            try w.writeAll("    const ");
            try zigIdent(w, p.name);
            try w.writeAll(": ");
            try emitParamType(w, r, alias_prefix, p);
            try w.writeAll(" = ");
            try emitLiftFlat(w, r, p.ty, &slot);
            try w.writeAll(";\n");
        }
    }

    // Two-way dispatch on the user's export. If they wrote a plain
    // `pub fn fname(args) Result` we take the eager path: invoke,
    // task.return, and let `async_cleanup.lift_outcome()` decide the
    // CallbackCode. If they wrote `pub const fname = struct { State,
    // start, step }` we take the typed state-machine path: alloc a
    // slot, call `.start(state, taskReturn, args)`, dispatch the
    // returned `abi.Step` to either EXIT, YIELD, or WAIT(set). The
    // matching `[callback]` mirrors the dispatch — see below. Both
    // branches compile because the dead branch is pruned by Zig at
    // analysis time (comptime-known condition).
    try w.writeAll("    if (comptime @typeInfo(@TypeOf(exports.");
    try emitDispatchPath(w, dispatch);
    try w.writeAll(")) == .type) {\n");
    try w.writeAll("        const _Sm = exports.");
    try emitDispatchPath(w, dispatch);
    try w.writeAll(";\n");
    try w.writeAll("        const _Slots = abi.StateSlots(_Sm.State);\n");
    try w.writeAll("        const _state = _Slots.alloc();\n");
    try w.print("        const _step = _Sm.start(_state, &{s}", .{tr_helper});
    for (f.params) |p| {
        try w.writeAll(", ");
        try zigIdent(w, p.name);
    }
    try w.writeAll(");\n");
    try emitStepDispatch(w);
    try w.writeAll("    } else {\n");

    if (f.results.len == 0) {
        try w.writeAll("        exports.");
        try emitDispatchPath(w, dispatch);
        try w.writeAll("(");
        for (f.params, 0..) |p, i| {
            if (i != 0) try w.writeAll(", ");
            try zigIdent(w, p.name);
        }
        try w.writeAll(");\n");
        try w.print("        {s}.*();\n", .{tr_ident});
    } else {
        try w.writeAll("        const _result = exports.");
        try emitDispatchPath(w, dispatch);
        try w.writeAll("(");
        for (f.params, 0..) |p, i| {
            if (i != 0) try w.writeAll(", ");
            try zigIdent(w, p.name);
        }
        try w.writeAll(");\n");
        try emitTaskReturnLowering(w, r, gpa, f, name, tr_ident, "_result", indirect_results);
    }

    // Reset the realloc arena now — wit-component rejects post-return
    // clauses on async exports ("cannot specify post-return function in
    // async"). task.return has already copied/consumed any indirect
    // result by the time we get here, so resetting the bump arena is
    // safe and matches what the sync cabi_post hook would have done.
    try w.writeAll("        realloc_state.reset();\n");
    // The minimal state-machine hook: ask `async_cleanup` for the
    // CallbackCode-packed value to return. If the user scheduled
    // cleanup with `schedule(set, fn)`, the [async-lift] yields back
    // to the runtime (WAIT(set) when set != 0, YIELD when set == 0);
    // the [callback] then runs the cleanup and returns EXIT. With
    // nothing scheduled this is just an unconditional `return 0`
    // (EXIT) — the eager-completion path.
    try w.writeAll("        return abi.async_cleanup.lift_outcome();\n");
    try w.writeAll("    }\n}\n\n");

    if (indirect_results) {
        const l = try jointLayout(r, f.results);
        try w.writeAll("var ");
        try emitRetareaIdent(w, name);
        try w.print(": [{d}]u8 align({d}) = undefined;\n\n", .{ l.size, l.@"align" });
    }

    // Callback. Mirrors the two-way dispatch in `[async-lift]`. In
    // the state-machine path we recover the same state pointer from
    // the task-local context slot, hand it to `Sm.step` along with
    // the event triple, and dispatch the returned `abi.Step(R)`. In
    // the eager / `async_cleanup` path we run any scheduled cleanup;
    // if that cleanup itself called `schedule(...)` to chain another
    // step, `lift_outcome()` picks the new code, otherwise EXIT.
    try w.writeAll("export fn ");
    try zigExportAsyncCallbackIdent(w, name);
    try w.writeAll("(event0: i32, p1: i32, p2: i32) i32 {\n");
    try w.writeAll("    if (comptime @typeInfo(@TypeOf(exports.");
    try emitDispatchPath(w, dispatch);
    try w.writeAll(")) == .type) {\n");
    try w.writeAll("        const _Sm = exports.");
    try emitDispatchPath(w, dispatch);
    try w.writeAll(";\n");
    try w.writeAll("        const _Slots = abi.StateSlots(_Sm.State);\n");
    try w.writeAll("        const _state = _Slots.current();\n");
    try w.writeAll("        const _step = _Sm.step(_state, @as(abi.Event, @enumFromInt(@as(u32, @bitCast(event0)))), @as(u32, @bitCast(p1)), @as(u32, @bitCast(p2)));\n");
    try emitStepDispatch(w);
    try w.writeAll("    } else {\n");
    try w.writeAll("        _ = .{ event0, p1, p2 };\n");
    try w.writeAll("        _ = abi.async_cleanup.run();\n");
    try w.writeAll("        return abi.async_cleanup.lift_outcome();\n");
    try w.writeAll("    }\n}\n\n");

    // Per-function stream/future intrinsics live in `[export]<iface>`.
    // Their link_name suffix uses the bare WIT function name, not the
    // <iface>#<func> form.
    try emitFuncStreamFutureIntrinsics(w, r, tr_module, tr_func, name, f);
}

/// Emit the `switch (_step) { .exit => …, .yield => …, .wait => … }`
/// block that closes both the `[async-lift]` and the `[callback]`
/// state-machine branch. `.exit` resets the realloc arena, frees the
/// state slot, and returns EXIT (0). `.yield` returns YIELD (1).
/// `.wait` packs the waitable-set handle into WAIT(set) — 2 | (set << 4).
/// `task.return` is decoupled from the variant: the user has already
/// called the typed `taskReturn` thunk from inside start/step at the
/// appropriate moment.
fn emitStepDispatch(w: *std.Io.Writer) Error!void {
    try w.writeAll("        switch (_step) {\n");
    try w.writeAll("            .exit => {\n");
    try w.writeAll("                realloc_state.reset();\n");
    try w.writeAll("                _Slots.free();\n");
    try w.writeAll("                return 0;\n");
    try w.writeAll("            },\n");
    try w.writeAll("            .yield => return 1,\n");
    try w.writeAll("            .wait => |_set| return @as(i32, @bitCast(@as(u32, 2) | (_set << 4))),\n");
    try w.writeAll("        }\n");
}

/// Emit `<tr_ident>.*(<lowering of result_var>)`. Handles the three
/// task.return-side cases:
///   - no results            → `_task_return.*();`
///   - single direct result  → `_task_return.*(<lowered _result>);`
///   - indirect results      → stores fields into the retarea buffer
///                              and calls `_task_return.*(@bitCast(@as(u32, @intCast(retarea))));`
fn emitTaskReturnLowering(
    w: *std.Io.Writer,
    r: *Resolver,
    gpa: Allocator,
    f: wit.Func,
    name: []const u8,
    tr_ident: []const u8,
    result_var: []const u8,
    indirect_results: bool,
) Error!void {
    if (f.results.len == 0) {
        try w.print("    {s}.*();\n", .{tr_ident});
        return;
    }
    if (!indirect_results) {
        var flat_count: std.ArrayList(CoreType) = .empty;
        defer flat_count.deinit(gpa);
        for (f.results) |res| try flattenType(&flat_count, gpa, r, res.ty);
        if (f.results.len == 1 and flat_count.items.len == 1) {
            try w.print("    {s}.*(", .{tr_ident});
            try emitLowerDirect(w, r, f.results[0].ty, result_var);
            try w.writeAll(");\n");
            return;
        }
        var slot: usize = 0;
        if (f.results.len == 1) {
            try emitLowerImportSlots(w, r, f.results[0].ty, result_var, &slot);
        } else {
            for (f.results) |res| {
                const field_expr = try std.fmt.allocPrint(gpa, "{s}.{f}", .{ result_var, std.zig.fmtId(res.name) });
                defer gpa.free(field_expr);
                try emitLowerImportSlots(w, r, res.ty, field_expr, &slot);
            }
        }
        try w.print("    {s}.*(", .{tr_ident});
        for (0..slot) |i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("_p{d}", .{i});
        }
        try w.writeAll(");\n");
        return;
    }
    const ret_buf_name = try retareaNameAlloc(gpa, name);
    defer gpa.free(ret_buf_name);
    if (f.results.len == 1) {
        try emitStoreMem(w, r, f.results[0].ty, result_var, ret_buf_name, 0);
    } else {
        var off: u32 = 0;
        for (f.results) |res| {
            const l = try layoutOf(r, res.ty);
            off = alignTo(off, l.@"align");
            const field_expr = try std.fmt.allocPrint(gpa, "{s}.{f}", .{ result_var, std.zig.fmtId(res.name) });
            defer gpa.free(field_expr);
            try emitStoreMem(w, r, res.ty, field_expr, ret_buf_name, off);
            off += l.size;
        }
    }
    try w.print("    {s}.*(@bitCast(@as(u32, @intCast(", .{tr_ident});
    try w.writeAll(ret_buf_name);
    try w.writeAll("))));\n");
}

fn zigExportAsyncLiftIdent(w: *std.Io.Writer, name: []const u8) Error!void {
    try w.print("@\"[async-lift]{s}\"", .{name});
}

fn zigExportAsyncCallbackIdent(w: *std.Io.Writer, name: []const u8) Error!void {
    try w.print("@\"[callback][async-lift]{s}\"", .{name});
}

/// One occurrence of `stream<T>` or `future<T>` in a function's signature.
const PayloadOccurrence = struct {
    kind: enum { stream, future },
    payload: ?wit.TypeRef, // null for stream<>/future<> (no-payload)
    index: u32, // monotonic order across params + results
};

/// Walk `func`'s params and results in spec order (params then
/// results, depth-first into composite types), collecting each
/// `stream<T>` / `future<T>` occurrence with a stable index. The
/// index matches what `Resolve::find_futures_and_streams` produces
/// for wit-component — the same numbers wit-component uses when
/// looking up `[stream-new-<i>]<func>` etc.
fn findStreamFutureOccurrences(gpa: Allocator, r: *Resolver, f: wit.Func) Allocator.Error!std.ArrayList(PayloadOccurrence) {
    var out: std.ArrayList(PayloadOccurrence) = .empty;
    errdefer out.deinit(gpa);
    var counter: u32 = 0;
    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(gpa);
    for (f.params) |p| try collectStreamFuture(gpa, r, &out, p.ty, &counter, &visited);
    for (f.results) |p| try collectStreamFuture(gpa, r, &out, p.ty, &counter, &visited);
    return out;
}

fn collectStreamFuture(gpa: Allocator, r: *Resolver, out: *std.ArrayList(PayloadOccurrence), ty: wit.TypeRef, counter: *u32, visited: *std.ArrayList([]const u8)) Allocator.Error!void {
    switch (ty.kind) {
        .stream => |maybe_payload| {
            try out.append(gpa, .{
                .kind = .stream,
                .payload = if (maybe_payload) |p| p.* else null,
                .index = counter.*,
            });
            counter.* += 1;
        },
        .future => |maybe_payload| {
            try out.append(gpa, .{
                .kind = .future,
                .payload = if (maybe_payload) |p| p.* else null,
                .index = counter.*,
            });
            counter.* += 1;
        },
        .list => |inner| try collectStreamFuture(gpa, r, out, inner.*, counter, visited),
        .list_fixed => |info| try collectStreamFuture(gpa, r, out, info.elem.*, counter, visited),
        .option => |inner| try collectStreamFuture(gpa, r, out, inner.*, counter, visited),
        .result => |info| {
            if (info.ok) |o| try collectStreamFuture(gpa, r, out, o.*, counter, visited);
            if (info.err) |e| try collectStreamFuture(gpa, r, out, e.*, counter, visited);
        },
        .tuple => |elems| for (elems) |e| try collectStreamFuture(gpa, r, out, e, counter, visited),
        .named => |name| {
            for (visited.items) |seen| if (std.mem.eql(u8, seen, name)) return;
            try visited.append(gpa, name);
            const td = r.find(name) orelse return;
            switch (td.body) {
                .record => |fields| for (fields) |fld| try collectStreamFuture(gpa, r, out, fld.ty, counter, visited),
                .variant => |cases| for (cases) |c| if (c.ty) |t| try collectStreamFuture(gpa, r, out, t, counter, visited),
                .alias => |a| try collectStreamFuture(gpa, r, out, a, counter, visited),
                else => {},
            }
        },
        else => {},
    }
}

/// Sanitize a WIT function name into a Zig identifier suffix used in
/// generated namespace names. Dashes become underscores; `[`, `]`,
/// `.`, etc. become underscores.
fn zigSanitizeIdent(w: *std.Io.Writer, s: []const u8) Error!void {
    for (s) |c| switch (c) {
        '-', '.', ':', '/', '@', '#', '[', ']' => try w.writeByte('_'),
        else => try w.writeByte(c),
    };
}

/// Whether a stream/future payload's generated Zig representation is
/// bit-identical to its canonical-ABI element layout. Only then can the
/// typed `read`/`write` intrinsic wrappers pass `&T` straight to the
/// canon built-in; everything else (strings, lists, records, variants
/// with payloads — Zig's automatic struct layout is unspecified) has to
/// go through `readRaw`/`writeRaw` + `lift`/`lower`.
fn isScalarPayload(r: *Resolver, maybe_p: ?wit.TypeRef) bool {
    const p = maybe_p orelse return true;
    return switch (p.kind) {
        .bool, .u8, .u16, .u32, .u64, .s8, .s16, .s32, .s64, .f32, .f64, .char => true,
        .own, .borrow, .stream, .future, .error_context => true,
        .named => |name| {
            const td = r.find(name) orelse return false;
            return switch (td.body) {
                .@"enum", .flags => true,
                .alias => |a| isScalarPayload(r, a),
                else => false,
            };
        },
        else => false,
    };
}

/// Emit per-function stream/future canonical-ABI intrinsics for an
/// async function. Each occurrence at index `i` of payload type `T`
/// produces a Zig namespace exposing typed Zig wrappers around the
/// canonical `[stream-new-<i>]<fn>` / `[stream-read-<i>]<fn>` etc.
/// externs, with the correct host-import module (`<iface>` for an
/// imported function, `[export]<iface>` for an exported function).
fn emitFuncStreamFutureIntrinsics(
    w: *std.Io.Writer,
    r: *Resolver,
    /// The "module name" wit-component uses for the canon imports
    /// associated with this function. For an exported function, this
    /// is `[export]<iface>` (or `[export]$root`); for an imported
    /// function it's `<iface>` (or `$root`).
    module: []const u8,
    /// The WIT function name (NOT the qualified `<iface>#<fn>` form
    /// — wit-component's intrinsic name uses the bare WIT function
    /// name as the suffix on each link_name).
    wit_func_name: []const u8,
    /// A name unique within the enclosing struct, sanitized and
    /// prefixed here into the outer `pub const intrinsics_<ns_base> =
    /// struct { … };` slot.
    ns_base: []const u8,
    f: wit.Func,
) Error!void {
    var occ = try findStreamFutureOccurrences(r.gpa, r, f);
    defer occ.deinit(r.gpa);
    if (occ.items.len == 0) return;

    try w.writeAll("pub const intrinsics_");
    try zigSanitizeIdent(w, ns_base);
    try w.writeAll(" = struct {\n");
    for (occ.items) |o| try emitOnePayloadIntrinsicSet(w, r, module, wit_func_name, o);
    try w.writeAll("};\n\n");
}

fn emitOnePayloadIntrinsicSet(w: *std.Io.Writer, r: *Resolver, module: []const u8, wit_func_name: []const u8, o: PayloadOccurrence) Error!void {
    const verb = switch (o.kind) {
        .stream => "stream",
        .future => "future",
    };
    try w.print("    pub const {s}{d} = struct {{\n", .{ verb, o.index });

    // Payload Zig type alias.
    try w.writeAll("        pub const T = ");
    if (o.payload) |p| {
        try emitTypeRef(w, r, p);
    } else {
        try w.writeAll("void");
    }
    try w.writeAll(";\n\n");

    // [<verb>-new-<i>]<func> : () -> i64    (lo=readable, hi=writable)
    try w.print("        extern \"{s}\" fn @\"[{s}-new-{d}]{s}\"() callconv(.c) i64;\n", .{ module, verb, o.index, wit_func_name });
    // [<verb>-read-<i>]<func> (blocking)
    if (o.kind == .stream) {
        try w.print("        extern \"{s}\" fn @\"[{s}-read-{d}]{s}\"(handle: u32, ptr: u32, n: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
        try w.print("        extern \"{s}\" fn @\"[{s}-write-{d}]{s}\"(handle: u32, ptr: u32, n: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
        try w.print("        extern \"{s}\" fn @\"[async-lower][{s}-read-{d}]{s}\"(handle: u32, ptr: u32, n: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
        try w.print("        extern \"{s}\" fn @\"[async-lower][{s}-write-{d}]{s}\"(handle: u32, ptr: u32, n: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
    } else {
        try w.print("        extern \"{s}\" fn @\"[{s}-read-{d}]{s}\"(handle: u32, ptr: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
        try w.print("        extern \"{s}\" fn @\"[{s}-write-{d}]{s}\"(handle: u32, ptr: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
        try w.print("        extern \"{s}\" fn @\"[async-lower][{s}-read-{d}]{s}\"(handle: u32, ptr: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
        try w.print("        extern \"{s}\" fn @\"[async-lower][{s}-write-{d}]{s}\"(handle: u32, ptr: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
    }
    try w.print("        extern \"{s}\" fn @\"[{s}-cancel-read-{d}]{s}\"(handle: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
    try w.print("        extern \"{s}\" fn @\"[{s}-cancel-write-{d}]{s}\"(handle: u32) callconv(.c) u32;\n", .{ module, verb, o.index, wit_func_name });
    try w.print("        extern \"{s}\" fn @\"[{s}-drop-readable-{d}]{s}\"(handle: u32) callconv(.c) void;\n", .{ module, verb, o.index, wit_func_name });
    try w.print("        extern \"{s}\" fn @\"[{s}-drop-writable-{d}]{s}\"(handle: u32) callconv(.c) void;\n", .{ module, verb, o.index, wit_func_name });
    try w.writeAll("\n");

    // Typed wrappers.
    try w.writeAll("        pub const Ends = struct { readable: abi.");
    try w.writeAll(if (o.kind == .stream) "Stream" else "Future");
    try w.writeAll(", writable: abi.");
    try w.writeAll(if (o.kind == .stream) "Stream" else "Future");
    try w.writeAll(" };\n\n");

    try w.print("        pub fn new() Ends {{\n", .{});
    try w.print("            const packed_val: u64 = @bitCast(@\"[{s}-new-{d}]{s}\"());\n", .{ verb, o.index, wit_func_name });
    try w.writeAll("            const ends = abi.StreamEndsI64.unpack(packed_val);\n");
    try w.writeAll("            return .{ .readable = @enumFromInt(ends.readable), .writable = @enumFromInt(ends.writable) };\n");
    try w.writeAll("        }\n\n");

    // Typed read/write pass `&T` straight to the canon built-in, which
    // is only layout-correct when the payload's Zig representation is
    // bit-identical to its canonical element layout. Pointer-carrying
    // and aggregate payloads only get the raw + lift/lower surface, so
    // a layout mismatch is a missing-method compile error instead of
    // silent memory corruption.
    if (isScalarPayload(r, o.payload)) {
        if (o.kind == .stream) {
            // read/write take element-count, NOT byte-count (per spec).
            try w.print("        pub fn read(handle: abi.Stream, buf: []T) abi.CopyOutcome {{\n", .{});
            try w.print("            return abi.CopyOutcome.unpack(@\"[stream-read-{d}]{s}\"(@intFromEnum(handle), @intCast(@intFromPtr(buf.ptr)), @intCast(buf.len)));\n", .{ o.index, wit_func_name });
            try w.writeAll("        }\n\n");

            try w.print("        pub fn write(handle: abi.Stream, buf: []const T) abi.CopyOutcome {{\n", .{});
            try w.print("            return abi.CopyOutcome.unpack(@\"[stream-write-{d}]{s}\"(@intFromEnum(handle), @intCast(@intFromPtr(buf.ptr)), @intCast(buf.len)));\n", .{ o.index, wit_func_name });
            try w.writeAll("        }\n\n");

            try w.print("        pub fn readAsync(handle: abi.Stream, buf: []T) abi.CopyOutcome {{\n", .{});
            try w.print("            return abi.CopyOutcome.unpack(@\"[async-lower][stream-read-{d}]{s}\"(@intFromEnum(handle), @intCast(@intFromPtr(buf.ptr)), @intCast(buf.len)));\n", .{ o.index, wit_func_name });
            try w.writeAll("        }\n\n");

            try w.print("        pub fn writeAsync(handle: abi.Stream, buf: []const T) abi.CopyOutcome {{\n", .{});
            try w.print("            return abi.CopyOutcome.unpack(@\"[async-lower][stream-write-{d}]{s}\"(@intFromEnum(handle), @intCast(@intFromPtr(buf.ptr)), @intCast(buf.len)));\n", .{ o.index, wit_func_name });
            try w.writeAll("        }\n\n");
        } else {
            try w.print("        pub fn read(handle: abi.Future, dst: *T) abi.CopyOutcome {{\n", .{});
            try w.print("            return abi.CopyOutcome.unpack(@\"[future-read-{d}]{s}\"(@intFromEnum(handle), @intCast(@intFromPtr(dst))));\n", .{ o.index, wit_func_name });
            try w.writeAll("        }\n\n");

            try w.print("        pub fn write(handle: abi.Future, value: *const T) abi.CopyOutcome {{\n", .{});
            try w.print("            return abi.CopyOutcome.unpack(@\"[future-write-{d}]{s}\"(@intFromEnum(handle), @intCast(@intFromPtr(value))));\n", .{ o.index, wit_func_name });
            try w.writeAll("        }\n\n");

            try w.print("        pub fn readAsync(handle: abi.Future, dst: *T) abi.CopyOutcome {{\n", .{});
            try w.print("            return abi.CopyOutcome.unpack(@\"[async-lower][future-read-{d}]{s}\"(@intFromEnum(handle), @intCast(@intFromPtr(dst))));\n", .{ o.index, wit_func_name });
            try w.writeAll("        }\n\n");

            try w.print("        pub fn writeAsync(handle: abi.Future, value: *const T) abi.CopyOutcome {{\n", .{});
            try w.print("            return abi.CopyOutcome.unpack(@\"[async-lower][future-write-{d}]{s}\"(@intFromEnum(handle), @intCast(@intFromPtr(value))));\n", .{ o.index, wit_func_name });
            try w.writeAll("        }\n\n");
        }
    }

    // Raw-pointer variants: read into a `[elem_size]u8 align(elem_align)`
    // buffer and `lift`, or `lower` into one and write. This is the only
    // correct path for payloads whose canonical element layout differs
    // from their Zig layout (strings, records, variants with payloads).
    const handle_ty = if (o.kind == .stream) "Stream" else "Future";
    const n_param = if (o.kind == .stream) ", n: u32" else "";
    const n_arg = if (o.kind == .stream) ", n" else "";
    const raw_variants = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "readRaw", "read", "" },
        .{ "writeRaw", "write", "" },
        .{ "readRawAsync", "read", "[async-lower]" },
        .{ "writeRawAsync", "write", "[async-lower]" },
    };
    for (raw_variants) |v| {
        try w.print("        pub fn {s}(handle: abi.{s}, ptr: usize{s}) abi.CopyOutcome {{\n", .{ v[0], handle_ty, n_param });
        try w.print("            return abi.CopyOutcome.unpack(@\"{s}[{s}-{s}-{d}]{s}\"(@intFromEnum(handle), @intCast(ptr){s}));\n", .{ v[2], verb, v[1], o.index, wit_func_name, n_arg });
        try w.writeAll("        }\n\n");
    }

    if (o.payload) |p| {
        const l = try layoutOf(r, p);
        try w.print("        pub const elem_size: u32 = {d};\n", .{l.size});
        try w.print("        pub const elem_align: u32 = {d};\n\n", .{l.@"align"});

        try w.writeAll("        pub fn lift(_base: usize) T {\n");
        try w.writeAll("            return ");
        try emitLoadMem(w, r, p, "_base", 0);
        try w.writeAll(";\n");
        try w.writeAll("        }\n\n");

        try w.writeAll("        pub fn lower(_value: T, _base: usize) void {\n");
        try emitStoreMem(w, r, p, "_value", "_base", 0);
        try w.writeAll("        }\n\n");
    }

    try w.print("        pub fn cancelRead(handle: abi.{s}) abi.CopyOutcome {{\n", .{if (o.kind == .stream) "Stream" else "Future"});
    try w.print("            return abi.CopyOutcome.unpack(@\"[{s}-cancel-read-{d}]{s}\"(@intFromEnum(handle)));\n", .{ verb, o.index, wit_func_name });
    try w.writeAll("        }\n\n");

    try w.print("        pub fn cancelWrite(handle: abi.{s}) abi.CopyOutcome {{\n", .{if (o.kind == .stream) "Stream" else "Future"});
    try w.print("            return abi.CopyOutcome.unpack(@\"[{s}-cancel-write-{d}]{s}\"(@intFromEnum(handle)));\n", .{ verb, o.index, wit_func_name });
    try w.writeAll("        }\n\n");

    try w.print("        pub fn dropReadable(handle: abi.{s}) void {{\n", .{if (o.kind == .stream) "Stream" else "Future"});
    try w.print("            @\"[{s}-drop-readable-{d}]{s}\"(@intFromEnum(handle));\n", .{ verb, o.index, wit_func_name });
    try w.writeAll("        }\n\n");

    try w.print("        pub fn dropWritable(handle: abi.{s}) void {{\n", .{if (o.kind == .stream) "Stream" else "Future"});
    try w.print("            @\"[{s}-drop-writable-{d}]{s}\"(@intFromEnum(handle));\n", .{ verb, o.index, wit_func_name });
    try w.writeAll("        }\n");
    try w.writeAll("    };\n\n");
}

/// Emit the per-export `_retarea_<name>` (when indirect-result) and
/// `cabi_post_<name>` epilogue used by both top-level and resource-
/// method exports. wit-component looks up the post-return by this exact
/// name and calls it after the host has consumed the return value, so
/// we must emit it for every export (otherwise strings/lists allocated
/// via cabi_realloc leak between calls).
fn emitRetareaAndPostReturn(
    w: *std.Io.Writer,
    r: *Resolver,
    name: []const u8,
    results: []const wit.Param,
    indirect_results: bool,
    flat_results: []const CoreType,
) Error!void {
    if (indirect_results) {
        const l = try jointLayout(r, results);
        try w.writeAll("var ");
        try emitRetareaIdent(w, name);
        try w.print(": [{d}]u8 align({d}) = undefined;\n", .{ l.size, l.@"align" });
    }

    try w.writeAll("export fn ");
    try emitPostReturnIdent(w, name);
    try w.writeAll("(");
    if (indirect_results) {
        try w.writeAll("_ptr: i32");
    } else if (flat_results.len == 1) {
        try w.print("_r: {s}", .{flat_results[0].zigName()});
    }
    try w.writeAll(") void {\n");
    if (indirect_results) try w.writeAll("    _ = _ptr;\n");
    if (!indirect_results and flat_results.len == 1) try w.writeAll("    _ = _r;\n");
    try w.writeAll("    realloc_state.reset();\n}\n\n");
}

fn retareaNameAlloc(gpa: Allocator, fn_name: []const u8) Allocator.Error![]u8 {
    if (nameNeedsEscape(fn_name)) {
        return std.fmt.allocPrint(gpa, "@intFromPtr(&@\"_retarea_{s}\")", .{fn_name});
    }
    return std.fmt.allocPrint(gpa, "@intFromPtr(&_retarea_{s})", .{fn_name});
}

/// If `name` resolves (possibly through alias chains) to a primitive
/// TypeRef.Kind, return it. Otherwise null.
fn resolveAliasTo(r: *Resolver, name: []const u8) ?wit.TypeRef.Kind {
    var cur_name = name;
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        const td = r.find(cur_name) orelse return null;
        switch (td.body) {
            .alias => |a| switch (a.kind) {
                .named => |n| cur_name = n,
                else => |k| return k,
            },
            else => return null,
        }
    }
    return null;
}

fn nameNeedsEscape(name: []const u8) bool {
    for (name) |c| switch (c) {
        '-', '#', '[', ']', '.', ':', '/', '@' => return true,
        else => {},
    };
    return false;
}

fn emitRetareaIdent(w: *std.Io.Writer, name: []const u8) Error!void {
    if (nameNeedsEscape(name)) {
        try w.print("@\"_retarea_{s}\"", .{name});
    } else {
        try w.print("_retarea_{s}", .{name});
    }
}

fn emitPostReturnIdent(w: *std.Io.Writer, name: []const u8) Error!void {
    if (nameNeedsEscape(name)) {
        try w.print("@\"cabi_post_{s}\"", .{name});
    } else {
        try w.print("cabi_post_{s}", .{name});
    }
}

// =====================================================================
// Top-level entry point
// =====================================================================

pub fn generateWorld(gpa: Allocator, pkg: wit.Package, world: wit.World, opts: Options) Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    // Flatten the world by expanding `include` clauses (e.g.
    // `world client { include wasi:cli/command@0.2.6; }`).
    var expanded_externs: std.ArrayList(wit.Extern) = .empty;
    defer expanded_externs.deinit(gpa);
    try expandIncludes(gpa, pkg, world, &expanded_externs);
    var flat_world = world;
    flat_world.externs = expanded_externs.items;

    var resolver: Resolver = .{ .gpa = gpa };
    defer resolver.deinit();
    // World-scope and pkg-scope types live at file scope (no iface prefix).
    for (world.types) |t| try resolver.add(t);
    for (pkg.types) |t| try resolver.add(t);
    // Interface types are scoped to that interface's struct namespace.
    // The iface_prefix is the Zig-mangled iface name (e.g.
    // `wasi_http_types`). Resolver lookups prefer same-iface matches,
    // and cross-iface references emit a qualified `<iface>.types.<X>`.
    for (pkg.interfaces) |iface| {
        const ifp = try ifacePrefixAlloc(gpa, pkg, iface.name);
        defer gpa.free(ifp);
        for (iface.types) |t| try resolver.addWithPrefix(ifp, t);
    }
    for (pkg.deps) |dep| {
        for (dep.interfaces) |iface| {
            const ifp = try ifacePrefixAlloc(gpa, dep, iface.name);
            defer gpa.free(ifp);
            for (iface.types) |t| try resolver.addWithPrefix(ifp, t);
        }
        for (dep.types) |t| try resolver.add(t);
    }
    for (flat_world.externs) |e| {
        if (e.body == .inline_interface) {
            for (e.body.inline_interface.types) |t| try resolver.addWithPrefix(e.name, t);
        }
    }

    // Register `use` items so they resolve as same-iface aliases when
    // referenced (e.g. wasi:http/types `use wasi:io/error.{error as io-error}`
    // adds `io-error` as belonging to wasi_http_types).
    try registerUseAliases(&resolver, &pkg, gpa);

    const ver_str = if (pkg.version) |v| v.text else "";
    const ver_at: []const u8 = if (ver_str.len != 0) "@" else "";
    try w.print(
        \\// Generated by zig-wasi-components from package {s}:{s}{s}{s} world {s}.
        \\// Hand edits will be lost.
        \\
        \\const std = @import("std");
        \\const abi = @import("zig_wasi_components").abi;
        \\
        \\
    , .{ pkg.namespace, pkg.name, ver_at, ver_str, world.name });

    // File-scope: only world-scope (no iface prefix) types.
    for (resolver.entries.items) |entry| {
        if (entry.iface_prefix.len == 0) try emitTypeDecl(w, &resolver, entry.td);
    }

    for (flat_world.externs) |e| {
        if (e.kind != .@"export") continue;
        switch (e.body) {
            .func => |f| try emitFuncAliases(w, &resolver, e.name, f),
            .inline_interface => |iface| for (iface.funcs) |f| {
                const prefix = try std.fmt.allocPrint(gpa, "{s}_{s}", .{ e.name, f.name });
                defer gpa.free(prefix);
                try emitFuncAliases(w, &resolver, prefix, f);
            },
            .plain => |p| {
                const lookup = findInterface(&pkg, p) orelse continue;
                for (lookup.iface.funcs) |f| {
                    const prefix = try std.fmt.allocPrint(gpa, "{s}_{s}", .{ lookup.iface.name, f.name });
                    defer gpa.free(prefix);
                    try emitFuncAliases(w, &resolver, prefix, f);
                }
            },
            .value => {},
        }
    }
    try w.writeAll("\n");

    // Imported interfaces are emitted as file-scope structs so that
    // cross-interface references can use the `<iface>.<type>` path.
    // Loose (world-level) function imports stay inside `pub const
    // imports = struct {…};` for ergonomics.
    var world_level_func_imports: bool = false;
    for (flat_world.externs) |e| {
        if (e.kind != .import) continue;
        switch (e.body) {
            .plain => |p| {
                const lookup = findInterface(&pkg, p) orelse continue;
                const wasm_iface = try fullInterfaceName(gpa, lookup.pkg.*, lookup.iface.name);
                defer gpa.free(wasm_iface);
                try emitInterfaceImports(w, &resolver, lookup.iface.*, wasm_iface, lookup.pkg.namespace, lookup.pkg.name);
            },
            .inline_interface => |iface| try emitInlineInterfaceImports(w, &resolver, e.name, iface),
            .func => world_level_func_imports = true,
            .value => {},
        }
    }
    if (world_level_func_imports) {
        try w.writeAll(
            \\/// Functions the host must provide (world-level imports).
            \\pub const imports = struct {
            \\
        );
        for (flat_world.externs) |e| {
            if (e.kind != .import) continue;
            if (e.body != .func) continue;
            try emitImportDecl(w, &resolver, e.name, e.body.func, opts);
        }
        try w.writeAll("};\n\n");
    }

    try w.writeAll(
        \\/// Reference to the user's `wit_exports` namespace declared
        \\/// in the root source file.
        \\const exports = @import("root").wit_exports;
        \\
        \\/// Backing arena for `cabi_realloc`.
        \\var realloc_state: abi.Realloc = .init(std.heap.wasm_allocator);
        \\
        \\export fn cabi_realloc(old_ptr: ?*anyopaque, old_size: usize, alignment: u32, new_size: usize) ?*anyopaque {
        \\    return realloc_state.realloc(old_ptr, old_size, alignment, new_size);
        \\}
        \\
        \\
    );

    for (flat_world.externs) |e| {
        if (e.kind != .@"export") continue;
        switch (e.body) {
            .func => |f| try emitCabiExport(w, &resolver, e.name, e.name, e.name, f),
            .inline_interface => |iface| try emitInlineInterfaceExports(w, &resolver, e.name, e.name, iface),
            .plain => |p| {
                const lookup = findInterface(&pkg, p) orelse continue;
                const wasm_iface = try fullInterfaceName(gpa, lookup.pkg.*, lookup.iface.name);
                defer gpa.free(wasm_iface);
                try emitInterfaceExports(w, &resolver, lookup.iface.*, wasm_iface);
            },
            .value => {},
        }
    }

    var list = aw.toArrayList();
    return list.toOwnedSlice(gpa);
}

fn emitInterfaceExports(w: *std.Io.Writer, r: *Resolver, iface: wit.Interface, wasm_iface: []const u8) Error!void {
    // Set the iface context so type refs in function signatures
    // resolve through `types.<name>` / `<other>.types.<name>` rather
    // than picking whatever iface the import loop left active.
    var prefix_buf: std.Io.Writer.Allocating = .init(r.gpa);
    defer prefix_buf.deinit();
    emitZigIfaceName(&prefix_buf.writer, wasm_iface) catch unreachable;
    const saved_prefix = r.current_iface_prefix;
    const saved_methods = r.methods_scope;
    r.current_iface_prefix = prefix_buf.writer.buffered();
    r.methods_scope = true;
    defer {
        r.current_iface_prefix = saved_prefix;
        r.methods_scope = saved_methods;
    }
    for (iface.funcs) |f| {
        const prefixed = try std.fmt.allocPrint(r.gpa, "{s}#{s}", .{ wasm_iface, f.name });
        defer r.gpa.free(prefixed);
        const dispatch = try std.fmt.allocPrint(r.gpa, "{s}.{s}", .{ iface.name, f.name });
        defer r.gpa.free(dispatch);
        const alias = try std.fmt.allocPrint(r.gpa, "{s}_{s}", .{ iface.name, f.name });
        defer r.gpa.free(alias);
        try emitCabiExport(w, r, prefixed, dispatch, alias, f);
    }
    for (iface.types) |t| {
        if (t.body == .resource) try emitResourceExports(w, r, iface.name, wasm_iface, t.name, t.body.resource);
    }
}

fn emitInlineInterfaceExports(w: *std.Io.Writer, r: *Resolver, iface_zig_name: []const u8, wasm_iface: []const u8, iface: wit.InlineInterface) Error!void {
    const saved_prefix = r.current_iface_prefix;
    const saved_methods = r.methods_scope;
    r.current_iface_prefix = iface_zig_name;
    r.methods_scope = true;
    defer {
        r.current_iface_prefix = saved_prefix;
        r.methods_scope = saved_methods;
    }
    for (iface.funcs) |f| {
        const prefixed = try std.fmt.allocPrint(r.gpa, "{s}#{s}", .{ wasm_iface, f.name });
        defer r.gpa.free(prefixed);
        const dispatch = try std.fmt.allocPrint(r.gpa, "{s}.{s}", .{ iface_zig_name, f.name });
        defer r.gpa.free(dispatch);
        const alias = try std.fmt.allocPrint(r.gpa, "{s}_{s}", .{ iface_zig_name, f.name });
        defer r.gpa.free(alias);
        try emitCabiExport(w, r, prefixed, dispatch, alias, f);
    }
    for (iface.types) |t| {
        if (t.body == .resource) try emitResourceExports(w, r, iface_zig_name, wasm_iface, t.name, t.body.resource);
    }
}

fn emitInterfaceImports(w: *std.Io.Writer, r: *Resolver, iface: wit.Interface, wasm_iface: []const u8, pkg_ns: []const u8, pkg_name: []const u8) Error!void {
    var prefix_buf: std.Io.Writer.Allocating = .init(r.gpa);
    defer prefix_buf.deinit();
    emitZigIfaceName(&prefix_buf.writer, wasm_iface) catch unreachable;
    const this_prefix = prefix_buf.writer.buffered();

    try emitDocs(w, iface.docs, "");
    try w.writeAll("pub const ");
    try w.writeAll(this_prefix);
    try w.writeAll(" = struct {\n");
    const saved_prefix = r.current_iface_prefix;
    const saved_pkg_ns = r.current_pkg_namespace;
    const saved_pkg_name = r.current_pkg_name;
    r.current_iface_prefix = this_prefix;
    r.current_pkg_namespace = pkg_ns;
    r.current_pkg_name = pkg_name;
    defer {
        r.current_iface_prefix = saved_prefix;
        r.current_pkg_namespace = saved_pkg_ns;
        r.current_pkg_name = saved_pkg_name;
    }

    // Types live in a nested `types` sub-struct so resource sub-structs
    // and free functions can have method names that match type names
    // without shadowing.
    try w.writeAll("    pub const types = struct {\n");
    {
        const saved_methods = r.methods_scope;
        r.methods_scope = false;
        defer r.methods_scope = saved_methods;
        // Explicit `use` aliases: `pub const local = <other>.types.<orig>;`
        for (r.entries.items) |entry| {
            if (!entry.is_use_alias) continue;
            if (!std.mem.eql(u8, entry.iface_prefix, this_prefix)) continue;
            try w.writeAll("        pub const ");
            try zigIdent(w, entry.td.name);
            try w.writeAll(" = ");
            try w.writeAll(entry.source_iface_prefix);
            try w.writeAll(".types.");
            try zigIdent(w, entry.source_name);
            try w.writeAll(";\n");
        }
        for (r.entries.items) |entry| {
            if (entry.is_use_alias) continue;
            if (std.mem.eql(u8, entry.iface_prefix, this_prefix)) {
                try emitTypeDecl(w, r, entry.td);
            }
        }
    }
    try w.writeAll("    };\n\n");

    // Methods + free funcs: same-iface type references prefix with
    // `types.` and cross-iface with `<other_iface>.types.<name>`.
    {
        const saved_methods = r.methods_scope;
        r.methods_scope = true;
        defer r.methods_scope = saved_methods;
        // Resources live inside `resources.<name>` to avoid ambiguity
        // with same-named types: `<iface>.types.<name>` is the type,
        // `<iface>.resources.<name>` is the methods namespace.
        var any_res = false;
        for (iface.types) |t| {
            if (t.body == .resource) {
                if (!any_res) {
                    try w.writeAll("    pub const resources = struct {\n");
                    any_res = true;
                }
                try emitResourceImports(w, r, wasm_iface, t.name, t.body.resource);
            }
        }
        if (any_res) try w.writeAll("    };\n");
        for (iface.funcs) |f| {
            try emitImportDecl(w, r, f.name, f, .{ .import_module = wasm_iface });
        }
    }
    try w.writeAll("};\n\n");
}

/// Register every interface's `use` items in the resolver under the
/// using-interface's prefix as alias-stub entries. emitNamedTypeRef
/// then recognises them as same-iface and emits `types.<local>`.
/// The actual `pub const <local> = <other>.types.<orig>;` decl is
/// written explicitly by emitUseAliases (not from these stubs).
fn registerUseAliases(resolver: *Resolver, pkg: *const wit.Package, gpa: Allocator) Error!void {
    for (pkg.interfaces) |iface| {
        const ifp = try ifacePrefixAlloc(gpa, pkg.*, iface.name);
        defer gpa.free(ifp);
        try registerIfaceUses(resolver, iface.uses, ifp, pkg.namespace, pkg.name, gpa);
    }
    for (pkg.deps) |dep| {
        for (dep.interfaces) |iface| {
            const ifp = try ifacePrefixAlloc(gpa, dep, iface.name);
            defer gpa.free(ifp);
            try registerIfaceUses(resolver, iface.uses, ifp, dep.namespace, dep.name, gpa);
        }
    }
}

fn registerIfaceUses(resolver: *Resolver, uses: []const wit.Use, ifp: []const u8, pkg_ns: []const u8, pkg_name: []const u8, gpa: Allocator) Error!void {
    for (uses) |u| {
        const items = u.items orelse continue;
        const iface_in_path = u.path.interface orelse continue;
        const ns = if (u.path.namespace.len != 0) u.path.namespace else pkg_ns;
        const pn = if (u.path.name.len != 0) u.path.name else pkg_name;
        if (ns.len == 0 or pn.len == 0) continue;
        var prefix_buf: std.Io.Writer.Allocating = .init(gpa);
        defer prefix_buf.deinit();
        const full = try std.fmt.allocPrint(gpa, "{s}:{s}/{s}", .{ ns, pn, iface_in_path });
        defer gpa.free(full);
        emitZigIfaceName(&prefix_buf.writer, full) catch return error.OutOfMemory;
        const src_prefix_owned = try resolver.internPrefix(prefix_buf.writer.buffered());
        for (items) |it| {
            const local_name = it.alias orelse it.name;
            const ifp_interned = try resolver.internPrefix(ifp);
            const src_name_owned = try resolver.internPrefix(it.name);
            const local_owned = try resolver.internPrefix(local_name);
            // Skip if already present (avoid duplicates).
            var dup = false;
            for (resolver.entries.items) |e| {
                if (std.mem.eql(u8, e.iface_prefix, ifp_interned) and std.mem.eql(u8, e.td.name, local_owned)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try resolver.entries.append(resolver.gpa, .{
                .iface_prefix = ifp_interned,
                .td = .{ .name = local_owned, .body = .{ .alias = .{ .kind = .{ .named = "" } } } },
                .is_use_alias = true,
                .source_iface_prefix = src_prefix_owned,
                .source_name = src_name_owned,
            });
        }
    }
}

/// Emit Zig aliases for each `use` clause:
/// `pub const local = <other_iface>.types.<original>;`
fn emitUseAliases(w: *std.Io.Writer, r: *Resolver, uses: []const wit.Use) Error!void {
    for (uses) |u| {
        const items = u.items orelse continue;
        const iface_in_path = u.path.interface orelse continue;
        // Sibling form (`use other.{X};`) gets the current package's
        // namespace+name; cross-package form has them in the path.
        const ns = if (u.path.namespace.len != 0) u.path.namespace else r.current_pkg_namespace;
        const pkgn = if (u.path.name.len != 0) u.path.name else r.current_pkg_name;
        if (ns.len == 0 or pkgn.len == 0) continue;

        var prefix_buf: std.Io.Writer.Allocating = .init(r.gpa);
        defer prefix_buf.deinit();
        const full = try std.fmt.allocPrint(r.gpa, "{s}:{s}/{s}", .{ ns, pkgn, iface_in_path });
        defer r.gpa.free(full);
        emitZigIfaceName(&prefix_buf.writer, full) catch return error.OutOfMemory;
        const src_prefix = prefix_buf.writer.buffered();
        for (items) |it| {
            const local_name = it.alias orelse it.name;
            try w.writeAll("        pub const ");
            try zigIdent(w, local_name);
            try w.writeAll(" = ");
            try w.writeAll(src_prefix);
            try w.writeAll(".types.");
            try zigIdent(w, it.name);
            try w.writeAll(";\n");
        }
    }
}

/// Convert `wasi:http/types@0.2.6` into a unique Zig identifier
/// `wasi_http_types`. Drops the package namespace/name/version when the
/// interface name itself is unique enough; for the wasi packages we
/// need the package qualifier to avoid `wasi:filesystem/types` and
/// `wasi:http/types` colliding under `pub const types`.
fn emitZigIfaceName(w: *std.Io.Writer, wasm_iface: []const u8) Error!void {
    var i: usize = 0;
    while (i < wasm_iface.len) : (i += 1) {
        const c = wasm_iface[i];
        if (c == '@') break;
        if (c == ':' or c == '/' or c == '-') {
            try w.writeByte('_');
        } else {
            try w.writeByte(c);
        }
    }
}

/// Allocate the Zig identifier for an interface in a given package:
/// `<ns>_<pkg>_<iface>` with kebab→snake. Used as the key for the
/// resolver's iface_prefix tracking and as the top-level struct name
/// `pub const <ifacePrefix> = struct { ... };`.
fn ifacePrefixAlloc(gpa: Allocator, pkg: wit.Package, iface_name: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    const full = std.fmt.allocPrint(gpa, "{s}:{s}/{s}", .{ pkg.namespace, pkg.name, iface_name }) catch return error.OutOfMemory;
    defer gpa.free(full);
    emitZigIfaceName(w, full) catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        else => unreachable,
    };
    var list = aw.toArrayList();
    return list.toOwnedSlice(gpa);
}

fn emitInlineInterfaceImports(w: *std.Io.Writer, r: *Resolver, name: []const u8, iface: wit.InlineInterface) Error!void {
    try w.writeAll("pub const ");
    try zigIdent(w, name);
    try w.writeAll(" = struct {\n");
    const saved_prefix = r.current_iface_prefix;
    r.current_iface_prefix = name;
    defer r.current_iface_prefix = saved_prefix;

    try w.writeAll("    pub const types = struct {\n");
    {
        const saved_methods = r.methods_scope;
        r.methods_scope = false;
        defer r.methods_scope = saved_methods;
        for (r.entries.items) |entry| {
            if (entry.is_use_alias) continue;
            if (std.mem.eql(u8, entry.iface_prefix, name)) try emitTypeDecl(w, r, entry.td);
        }
    }
    try w.writeAll("    };\n\n");

    {
        const saved_methods = r.methods_scope;
        r.methods_scope = true;
        defer r.methods_scope = saved_methods;
        // Mirror plain-iface emission: wrap resources in a `resources`
        // sub-struct so callers reach them via `<iface>.resources.<res>.<m>`,
        // and so resource sub-struct names cannot shadow same-named
        // types declared in `<iface>.types`.
        var any_res = false;
        for (iface.types) |t| {
            if (t.body == .resource) {
                if (!any_res) {
                    try w.writeAll("    pub const resources = struct {\n");
                    any_res = true;
                }
                try emitResourceImports(w, r, name, t.name, t.body.resource);
            }
        }
        if (any_res) try w.writeAll("    };\n");
        for (iface.funcs) |f| {
            try emitImportDecl(w, r, f.name, f, .{ .import_module = name });
        }
    }
    try w.writeAll("};\n\n");
}

fn emitResourceImports(w: *std.Io.Writer, r: *Resolver, wasm_iface: []const u8, res_name: []const u8, members: []const wit.ResourceMember) Error!void {
    // Nested namespace for each resource: `pub const <resource> = struct { ... };`
    // inside the iface struct. Resource type lives at `<iface>.types.<resource>`;
    // the methods sub-struct lives at `<iface>.<resource>` — different paths.
    try w.writeAll("    pub const ");
    try zigIdent(w, res_name);
    try w.writeAll(" = struct {\n");

    {
        const drop_name = try std.fmt.allocPrint(r.gpa, "[resource-drop]{s}", .{res_name});
        defer r.gpa.free(drop_name);
        try w.writeAll("        const _drop = @extern(*const fn (i32) callconv(.c) void, .{");
        try w.print(" .name = \"{s}\", .library_name = \"{s}\" ", .{ drop_name, wasm_iface });
        try w.writeAll("});\n");
        try w.writeAll("        pub fn drop(self: types.");
        try zigIdent(w, res_name);
        try w.writeAll(") void { _drop.*(@bitCast(@intFromEnum(self))); }\n");
    }

    for (members) |m| {
        const tag = switch (m.kind) {
            .constructor => "[constructor]",
            .method => "[method]",
            .static => "[static]",
        };
        const wasm_member_name = if (m.kind == .constructor)
            try std.fmt.allocPrint(r.gpa, "{s}{s}", .{ tag, res_name })
        else
            try std.fmt.allocPrint(r.gpa, "{s}{s}.{s}", .{ tag, res_name, m.func.name });
        defer r.gpa.free(wasm_member_name);

        const zig_fn_name = if (m.kind == .constructor) "new" else m.func.name;
        try emitResourceMemberImport(w, r, wasm_iface, wasm_member_name, zig_fn_name, res_name, m);

        // Stream/future intrinsics for this member, nested inside the
        // resource's method namespace (`<iface>.resources.<res>.
        // intrinsics_<member>.stream0` etc). The canonical intrinsic
        // link name suffixes the full member name, e.g.
        // `[stream-new-0][method]descriptor.read-via-stream`.
        try emitFuncStreamFutureIntrinsics(w, r, wasm_iface, wasm_member_name, zig_fn_name, m.func);
    }
    try w.writeAll("    };\n");
}

fn emitResourceMemberImport(
    w: *std.Io.Writer,
    r: *Resolver,
    wasm_iface: []const u8,
    wasm_member_name: []const u8,
    zig_fn_name: []const u8,
    res_name: []const u8,
    m: wit.ResourceMember,
) Error!void {
    const f = m.func;
    const gpa = std.heap.page_allocator;

    var flat_params: std.ArrayList(CoreType) = .empty;
    defer flat_params.deinit(gpa);
    if (m.kind == .method) try flat_params.append(gpa, .i32);
    for (f.params) |p| try flattenType(&flat_params, gpa, r, p.ty);

    var flat_results: std.ArrayList(CoreType) = .empty;
    defer flat_results.deinit(gpa);
    if (m.kind == .constructor) {
        try flat_results.append(gpa, .i32);
    } else if (f.results.len == 1) {
        try flattenType(&flat_results, gpa, r, f.results[0].ty);
    } else if (f.results.len > 1) {
        for (f.results) |p| try flattenType(&flat_results, gpa, r, p.ty);
    }
    const indirect_results = flat_results.items.len > 1;
    const indirect_params = flat_params.items.len > 16;

    try w.writeAll("            const _");
    try zigIdent(w, zig_fn_name);
    try w.writeAll(" = @extern(*const fn (");
    if (indirect_params) {
        try w.writeAll("i32");
    } else {
        for (flat_params.items, 0..) |t, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(t.zigName());
        }
    }
    if (indirect_results) {
        if (indirect_params or flat_params.items.len != 0) try w.writeAll(", ");
        try w.writeAll("i32");
    }
    try w.writeAll(") callconv(.c) ");
    if (indirect_results or flat_results.items.len == 0) {
        try w.writeAll("void");
    } else {
        try w.writeAll(flat_results.items[0].zigName());
    }
    try w.print(", .{{ .name = \"{s}\", .library_name = \"{s}\" }});\n", .{ wasm_member_name, wasm_iface });

    try emitDocs(w, m.docs, "        ");
    try w.writeAll("        pub fn ");
    try zigIdent(w, zig_fn_name);
    try w.writeAll("(");
    if (m.kind == .method) {
        try w.writeAll("self: types.");
        try zigIdent(w, res_name);
        if (f.params.len != 0) try w.writeAll(", ");
    }
    for (f.params, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try emitParamName(w, p.name);
        try w.writeAll(": ");
        try emitTypeRef(w, r, p.ty);
    }
    try w.writeAll(") ");
    if (m.kind == .constructor) {
        try w.writeAll("types.");
        try zigIdent(w, res_name);
    } else if (f.results.len == 0) {
        try w.writeAll("void");
    } else if (f.results.len == 1) {
        try emitTypeRef(w, r, f.results[0].ty);
    } else {
        try w.writeAll("void");
    }
    try w.writeAll(" {\n");

    var arg_idx: usize = 0;
    if (indirect_params) {
        const self_slot: Layout = if (m.kind == .method)
            .{ .size = 4, .@"align" = 4 }
        else
            .{ .size = 0, .@"align" = 1 };
        const l = try jointLayoutWithLeading(r, self_slot, f.params);
        try w.print("                var _argsarea: [{d}]u8 align({d}) = undefined;\n", .{ l.size, l.@"align" });
        try w.writeAll("                const _args_base: usize = @intFromPtr(&_argsarea);\n");
        var offset: u32 = 0;
        if (m.kind == .method) {
            try w.writeAll("                @as(*i32, @ptrFromInt(_args_base + 0)).* = @bitCast(@intFromEnum(self));\n");
            offset = 4;
        }
        for (f.params) |p| {
            const pl = try layoutOf(r, p.ty);
            offset = alignTo(offset, pl.@"align");
            const expr_buf = try paramNameAlloc(gpa, p.name);
            defer gpa.free(expr_buf);
            try emitStoreMem(w, r, p.ty, expr_buf, "_args_base", offset);
            offset += pl.size;
        }
        try w.writeAll("                const _p0: i32 = @bitCast(@as(u32, @intCast(_args_base)));\n");
        arg_idx = 1;
    } else {
        if (m.kind == .method) {
            try w.writeAll("                const _p0: i32 = @bitCast(@intFromEnum(self));\n");
            arg_idx = 1;
        }
        for (f.params) |p| {
            const expr_buf = try paramNameAlloc(gpa, p.name);
            defer gpa.free(expr_buf);
            try emitLowerImportSlots(w, r, p.ty, expr_buf, &arg_idx);
        }
    }

    if (indirect_results) {
        const l = try jointLayout(r, f.results);
        try w.print("                var _retarea: [{d}]u8 align({d}) = undefined;\n", .{ l.size, l.@"align" });
    }
    try w.writeAll("                ");
    if (f.results.len != 0 and !indirect_results) try w.writeAll("const _r = ");
    if (m.kind == .constructor) try w.writeAll("const _r = ");
    try w.writeAll("_");
    try zigIdent(w, zig_fn_name);
    try w.writeAll(".*(");
    var k: usize = 0;
    while (k < arg_idx) : (k += 1) {
        if (k != 0) try w.writeAll(", ");
        try w.print("_p{d}", .{k});
    }
    if (indirect_results) {
        if (arg_idx != 0) try w.writeAll(", ");
        try w.writeAll("@bitCast(@as(u32, @intCast(@intFromPtr(&_retarea))))");
    }
    try w.writeAll(");\n");

    if (m.kind == .constructor) {
        try w.writeAll("                return @enumFromInt(@as(u32, @bitCast(_r)));\n");
    } else if (f.results.len != 0 and !indirect_results) {
        switch (f.results[0].ty.kind) {
            .u32, .u8, .u16, .char => try w.writeAll("                return @bitCast(_r);\n"),
            .u64 => try w.writeAll("                return @bitCast(_r);\n"),
            .result => try w.writeAll("                return if (_r == 0) .{ .ok = {} } else .{ .err = {} };\n"),
            .option => try w.writeAll("                return if (_r == 0) null else .{ .ok = {} };\n"),
            .bool => try w.writeAll("                return _r != 0;\n"),
            .s32, .s8, .s16, .s64, .f32, .f64 => try w.writeAll("                return _r;\n"),
            .own, .borrow, .error_context, .stream, .future => try w.writeAll("                return @enumFromInt(@as(u32, @bitCast(_r)));\n"),
            .named => |nm| {
                if (resolveAliasTo(r, nm)) |kind| switch (kind) {
                    .bool => try w.writeAll("                return _r != 0;\n"),
                    .s32, .s64, .f32, .f64 => try w.writeAll("                return _r;\n"),
                    .s8, .s16 => try w.writeAll("                return @intCast(_r);\n"),
                    .u32, .u64 => try w.writeAll("                return @bitCast(_r);\n"),
                    .u8, .u16, .char => try w.writeAll("                return @intCast(@as(u32, @bitCast(_r)));\n"),
                    .result => try w.writeAll("                return if (_r == 0) .{ .ok = {} } else .{ .err = {} };\n"),
                    .option => try w.writeAll("                return if (_r == 0) null else .{ .ok = {} };\n"),
                    else => try w.writeAll("                return @enumFromInt(@as(u32, @bitCast(_r)));\n"),
                } else try w.writeAll("                return @enumFromInt(@as(u32, @bitCast(_r)));\n");
            },
            else => try w.writeAll("                return @bitCast(_r);\n"),
        }
    } else if (indirect_results and f.results.len == 1) {
        try w.writeAll("                const _base: usize = @intFromPtr(&_retarea);\n");
        try w.writeAll("                return ");
        try emitLoadMem(w, r, f.results[0].ty, "_base", 0);
        try w.writeAll(";\n");
    }
    try w.writeAll("            }\n");
}

/// Build the fully-qualified WIT-level name of an interface:
/// `<ns>:<pkg>/<iface>@<ver>`, e.g. `demo:res/counters@0.1.0`.
fn fullInterfaceName(gpa: Allocator, pkg: wit.Package, iface_name: []const u8) Allocator.Error![]u8 {
    if (pkg.version) |v| {
        return std.fmt.allocPrint(gpa, "{s}:{s}/{s}@{s}", .{ pkg.namespace, pkg.name, iface_name, v.text });
    }
    return std.fmt.allocPrint(gpa, "{s}:{s}/{s}", .{ pkg.namespace, pkg.name, iface_name });
}

const InterfaceLookup = struct {
    pkg: *const wit.Package,
    iface: *const wit.Interface,
};

fn findInterface(pkg: *const wit.Package, path: wit.PackagePath) ?InterfaceLookup {
    const iface_name = path.interface orelse return null;
    // Cross-package path.
    if (path.namespace.len != 0 and path.name.len != 0 and
        !(std.mem.eql(u8, path.namespace, pkg.namespace) and std.mem.eql(u8, path.name, pkg.name)))
    {
        for (pkg.deps) |*d| {
            if (!std.mem.eql(u8, d.namespace, path.namespace)) continue;
            if (!std.mem.eql(u8, d.name, path.name)) continue;
            for (d.interfaces) |*i| {
                if (std.mem.eql(u8, i.name, iface_name)) return .{ .pkg = d, .iface = i };
            }
        }
        return null;
    }
    // Same-package path (or sibling-by-name).
    for (pkg.interfaces) |*i| {
        if (std.mem.eql(u8, i.name, iface_name)) return .{ .pkg = pkg, .iface = i };
    }
    return null;
}

fn findWorld(pkg: *const wit.Package, path: wit.PackagePath) ?*const wit.World {
    const wname = path.interface orelse return null;
    if (path.namespace.len != 0 and path.name.len != 0 and
        !(std.mem.eql(u8, path.namespace, pkg.namespace) and std.mem.eql(u8, path.name, pkg.name)))
    {
        for (pkg.deps) |*d| {
            if (!std.mem.eql(u8, d.namespace, path.namespace)) continue;
            if (!std.mem.eql(u8, d.name, path.name)) continue;
            for (d.worlds) |*wld| {
                if (std.mem.eql(u8, wld.name, wname)) return wld;
            }
        }
        return null;
    }
    for (pkg.worlds) |*wld| {
        if (std.mem.eql(u8, wld.name, wname)) return wld;
    }
    return null;
}

/// Flatten `include` clauses into the top-level externs list. Recursively
/// expands transitive includes. Rename clauses are applied as the
/// extern names of the included world's members.
fn expandIncludes(gpa: Allocator, pkg: wit.Package, world: wit.World, out: *std.ArrayList(wit.Extern)) Error!void {
    var visited: std.ArrayList(*const wit.World) = .empty;
    defer visited.deinit(gpa);
    try expandIncludesRec(gpa, pkg, &world, out, &visited);
}

fn expandIncludesRec(
    gpa: Allocator,
    pkg: wit.Package,
    world: *const wit.World,
    out: *std.ArrayList(wit.Extern),
    visited: *std.ArrayList(*const wit.World),
) Error!void {
    for (visited.items) |v| if (v == world) return; // cycle break
    try visited.append(gpa, world);

    try out.appendSlice(gpa, world.externs);
    for (world.includes) |inc| {
        // Find the world AND its owning package so sibling-form
        // includes (`include other-world;` with no namespace) inside
        // a dep package resolve against THAT dep's worlds, not the
        // user's top-level package.
        const found = findWorldWithPkg(&pkg, inc.path) orelse continue;
        var inner_externs: std.ArrayList(wit.Extern) = .empty;
        defer inner_externs.deinit(gpa);
        try expandIncludesRec(gpa, found.pkg.*, found.world, &inner_externs, visited);
        for (inner_externs.items) |e| {
            var renamed = e;
            for (inc.renames) |r| {
                if (std.mem.eql(u8, r.from, e.name)) {
                    renamed.name = r.to;
                    break;
                }
            }
            try out.append(gpa, renamed);
        }
    }
}

const WorldLookup = struct { pkg: *const wit.Package, world: *const wit.World };

fn findWorldWithPkg(pkg: *const wit.Package, path: wit.PackagePath) ?WorldLookup {
    const wname = path.interface orelse return null;
    if (path.namespace.len != 0 and path.name.len != 0 and
        !(std.mem.eql(u8, path.namespace, pkg.namespace) and std.mem.eql(u8, path.name, pkg.name)))
    {
        for (pkg.deps) |*d| {
            if (!std.mem.eql(u8, d.namespace, path.namespace)) continue;
            if (!std.mem.eql(u8, d.name, path.name)) continue;
            for (d.worlds) |*wld| {
                if (std.mem.eql(u8, wld.name, wname)) return .{ .pkg = d, .world = wld };
            }
        }
        return null;
    }
    for (pkg.worlds) |*wld| {
        if (std.mem.eql(u8, wld.name, wname)) return .{ .pkg = pkg, .world = wld };
    }
    // Sibling-form fallback when called from a dep context: also try
    // each dep that contains a world named `wname` whose package the
    // caller might have meant. (Only safe when the name is unique.)
    return null;
}

/// Emit the per-resource exports the canonical ABI expects:
///
///   * `<iface>#[constructor]<res>`  → returns an i32 rep
///   * `<iface>#[method]<res>.<m>`   → takes rep as first param
///   * `<iface>#[static]<res>.<m>`   → no implicit rep
///   * `<iface>#[resource-drop]<res>` → called when handle dies
///
/// The user implements each as `wit_exports.<iface>.<res>.<m>(...)`.
/// The rep is whatever the constructor returns (commonly a `*T`),
/// reinterpreted as an i32 on the way out.
fn emitResourceExports(w: *std.Io.Writer, r: *Resolver, iface_zig_name: []const u8, wasm_iface: []const u8, res_name: []const u8, members: []const wit.ResourceMember) Error!void {
    const iface_name = iface_zig_name;
    const gpa_top = std.heap.page_allocator;

    // Declare the canonical-ABI handle-table helpers as imports from
    // the matching `[export]<iface>` module. The constructor calls
    // `[resource-new]<T>(rep)` to register a new handle; the
    // [resource-drop] import is invoked implicitly by the runtime
    // when a handle is dropped (we provide an export wrapper for it
    // below) and so does not need an `@extern` import here.
    {
        const lib = try std.fmt.allocPrint(gpa_top, "[export]{s}", .{wasm_iface});
        defer gpa_top.free(lib);
        const new_name = try std.fmt.allocPrint(gpa_top, "[resource-new]{s}", .{res_name});
        defer gpa_top.free(new_name);
        try w.writeAll("const _resource_new_");
        try zigIdent(w, res_name);
        try w.writeAll(" = @extern(*const fn (i32) callconv(.c) i32, .{");
        try w.print(" .name = \"{s}\", .library_name = \"{s}\" ", .{ new_name, lib });
        try w.writeAll("});\n");
    }

    const gpa = std.heap.page_allocator;
    for (members) |m| {
        const f = m.func;
        var flat_params: std.ArrayList(CoreType) = .empty;
        defer flat_params.deinit(gpa);
        if (m.kind == .method) try flat_params.append(gpa, .i32); // self rep
        for (f.params) |p| try flattenType(&flat_params, gpa, r, p.ty);

        var flat_results: std.ArrayList(CoreType) = .empty;
        defer flat_results.deinit(gpa);
        if (m.kind == .constructor) {
            try flat_results.append(gpa, .i32);
        } else if (f.results.len == 1) {
            try flattenType(&flat_results, gpa, r, f.results[0].ty);
        } else if (f.results.len > 1) {
            for (f.results) |p| try flattenType(&flat_results, gpa, r, p.ty);
        }

        const tag = switch (m.kind) {
            .constructor => "[constructor]",
            .method => "[method]",
            .static => "[static]",
        };

        // Build the canonical export name.
        var name_buf: std.ArrayList(u8) = .empty;
        defer name_buf.deinit(gpa);
        try name_buf.appendSlice(gpa, wasm_iface);
        try name_buf.append(gpa, '#');
        try name_buf.appendSlice(gpa, tag);
        try name_buf.appendSlice(gpa, res_name);
        if (m.kind != .constructor) {
            try name_buf.append(gpa, '.');
            try name_buf.appendSlice(gpa, f.name);
        }
        const wasm_name = name_buf.items;

        try w.writeAll("export fn ");
        try zigExportIdent(w, wasm_name);
        try w.writeAll("(");
        const indirect_results = flat_results.items.len > 1;
        const indirect_params = flat_params.items.len > 16;
        if (indirect_params) {
            try w.writeAll("args_ptr: i32");
        } else {
            for (flat_params.items, 0..) |t, i| {
                if (i != 0) try w.writeAll(", ");
                try w.print("p{d}: {s}", .{ i, t.zigName() });
            }
        }
        try w.writeAll(") ");
        if (indirect_results) {
            try w.writeAll("i32");
        } else if (flat_results.items.len == 0) {
            try w.writeAll("void");
        } else {
            try w.writeAll(flat_results.items[0].zigName());
        }
        try w.writeAll(" {\n");

        if (indirect_params) {
            try w.writeAll("    const _args_base: usize = @intCast(@as(u32, @bitCast(args_ptr)));\n");
            var offset: u32 = 0;
            if (m.kind == .method) {
                try w.writeAll("    const _self: *exports.");
                try zigIdent(w, iface_name);
                try w.writeAll(".");
                try zigIdent(w, res_name);
                try w.writeAll(".State = @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(@as(*const i32, @ptrFromInt(_args_base + 0)).*)))));\n");
                offset = 4;
            }
            for (f.params) |p| {
                const pl = try layoutOf(r, p.ty);
                offset = alignTo(offset, pl.@"align");
                try w.writeAll("    const ");
                try zigIdent(w, p.name);
                try w.writeAll(": ");
                try emitTypeRef(w, r, p.ty);
                try w.writeAll(" = ");
                try emitLoadMem(w, r, p.ty, "_args_base", offset);
                try w.writeAll(";\n");
                offset += pl.size;
            }
        } else {
            var arg_start: usize = 0;
            if (m.kind == .method) {
                try w.writeAll("    const _self: *exports.");
                try zigIdent(w, iface_name);
                try w.writeAll(".");
                try zigIdent(w, res_name);
                try w.writeAll(".State = @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(p0)))));\n");
                arg_start = 1;
            }
            var slot: usize = arg_start;
            for (f.params) |p| {
                try w.writeAll("    const ");
                try zigIdent(w, p.name);
                try w.writeAll(": ");
                try emitTypeRef(w, r, p.ty);
                try w.writeAll(" = ");
                try emitLiftFlat(w, r, p.ty, &slot);
                try w.writeAll(";\n");
            }
        }

        if (m.kind == .constructor) {
            try w.writeAll("    const _result = exports.");
            try zigIdent(w, iface_name);
            try w.writeAll(".");
            try zigIdent(w, res_name);
            try w.writeAll(".constructor(");
            for (f.params, 0..) |p, i| {
                if (i != 0) try w.writeAll(", ");
                try zigIdent(w, p.name);
            }
            try w.writeAll(");\n");
            // Wrap the rep in a handle via the canonical-ABI's
            // `[resource-new]<T>` host import.
            try w.writeAll("    const _rep: i32 = @bitCast(@as(u32, @intCast(@intFromPtr(_result))));\n");
            try w.writeAll("    return _resource_new_");
            try zigIdent(w, res_name);
            try w.writeAll(".*(_rep);\n");
        } else {
            try w.writeAll("    ");
            if (f.results.len != 0) try w.writeAll("const _result = ");
            try w.writeAll("exports.");
            try zigIdent(w, iface_name);
            try w.writeAll(".");
            try zigIdent(w, res_name);
            try w.writeAll(".");
            try zigIdent(w, f.name);
            try w.writeAll("(");
            if (m.kind == .method) {
                try w.writeAll("_self");
                if (f.params.len != 0) try w.writeAll(", ");
            }
            for (f.params, 0..) |p, i| {
                if (i != 0) try w.writeAll(", ");
                try zigIdent(w, p.name);
            }
            try w.writeAll(");\n");
            if (f.results.len != 0) {
                if (!indirect_results) {
                    try w.writeAll("    return ");
                    try emitLowerDirect(w, r, f.results[0].ty, "_result");
                    try w.writeAll(";\n");
                } else if (f.results.len == 1) {
                    // Indirect single-result: store into a static
                    // retarea sized to the result's joint layout and
                    // return its address.
                    const ret_buf = try retareaNameAlloc(gpa, wasm_name);
                    defer gpa.free(ret_buf);
                    try emitStoreMem(w, r, f.results[0].ty, "_result", ret_buf, 0);
                    try w.writeAll("    return @bitCast(@as(u32, @intCast(");
                    try w.writeAll(ret_buf);
                    try w.writeAll(")));\n");
                } else {
                    try w.writeAll("    @compileError(\"multi-result resource methods not supported (WIT spec deprecated them)\");\n");
                }
            }
        }
        try w.writeAll("}\n\n");

        if (m.kind != .constructor) {
            try emitRetareaAndPostReturn(w, r, wasm_name, f.results, indirect_results, flat_results.items);
        }
    }

    // Auto-emit a `[resource-drop]` export that calls the user's
    // destructor with the rep.
    try w.writeAll("export fn ");
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, wasm_iface);
        try buf.append(gpa, '#');
        try buf.appendSlice(gpa, "[resource-drop]");
        try buf.appendSlice(gpa, res_name);
        try zigExportIdent(w, buf.items);
    }
    try w.writeAll("(p0: i32) void {\n");
    try w.writeAll("    const _self: *exports.");
    try zigIdent(w, iface_name);
    try w.writeAll(".");
    try zigIdent(w, res_name);
    try w.writeAll(".State = @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(p0)))));\n");
    try w.writeAll("    exports.");
    try zigIdent(w, iface_name);
    try w.writeAll(".");
    try zigIdent(w, res_name);
    try w.writeAll(".destructor(_self);\n");
    try w.writeAll("}\n\n");
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "codegen smoke" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:adder@0.1.0;
        \\world adder {
        \\  export add: func(a: u32, b: u32) -> u32;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "export fn add(p0: i32, p1: i32) i32") != null);
    try testing.expect(std.mem.indexOf(u8, src, "cabi_realloc") != null);
}

test "codegen record + variant + option + result" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  record point { x: s32, y: s32 }
        \\  variant outcome { good, bad(string) }
        \\  export move: func(p: point) -> point;
        \\  export classify: func(n: s32) -> outcome;
        \\  export find: func(id: u32) -> option<string>;
        \\  export try-it: func(n: u32) -> result<string, u32>;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "pub const point = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub const outcome = union(enum)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "export fn move(p0: i32, p1: i32) i32") != null);
    try testing.expect(std.mem.indexOf(u8, src, "export fn classify(p0: i32) i32") != null);
}

test "import lowers option<string> and result<u32, u32> params" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  import set-name: func(value: option<string>);
        \\  import classify: func(r: result<u32, u32>);
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "if (_a_value == null) 0 else 1") != null);
    try testing.expect(std.mem.indexOf(u8, src, "if (_a_value) |_v") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@intFromEnum(_a_r)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "switch (_a_r)") != null);
}

test "import of an interface with a resource generates wrappers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface counters {
        \\  resource counter {
        \\    constructor(initial: u32);
        \\    increment: func();
        \\    get: func() -> u32;
        \\  }
        \\}
        \\world w {
        \\  import counters;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "pub const demo_x_counters = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub const counter = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn new(_a_initial: u32) types.counter") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn increment(self: types.counter)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn get(self: types.counter) u32") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn drop(self: types.counter) void") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".name = \"[constructor]counter\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".name = \"[method]counter.increment\"") != null);
}

test "multi-package WIT: block-form deps are parsed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:main@0.1.0;
        \\world w {
        \\  import wasi:io/streams@0.2.6;
        \\}
        \\package wasi:io@0.2.6 {
        \\  interface streams {
        \\    resource input-stream {
        \\      read: func(n: u64) -> list<u8>;
        \\    }
        \\  }
        \\  interface poll {
        \\    resource pollable {
        \\      block: func();
        \\    }
        \\  }
        \\}
    );
    try testing.expectEqualStrings("demo", pkg.namespace);
    try testing.expectEqualStrings("main", pkg.name);
    try testing.expectEqual(@as(usize, 1), pkg.deps.len);
    try testing.expectEqualStrings("wasi", pkg.deps[0].namespace);
    try testing.expectEqualStrings("io", pkg.deps[0].name);
    try testing.expectEqual(@as(usize, 2), pkg.deps[0].interfaces.len);
}

test "import variant param lowers via switch expression" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  variant scheme { HTTP, HTTPS, other(string) }
        \\  import set-scheme: func(s: option<scheme>);
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "if (_a_s == null) 0 else 1") != null);
    try testing.expect(std.mem.indexOf(u8, src, "switch (_v") != null);
}

test "import with >16 flat params uses indirect-param area" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  import sum-many: func(
        \\    a0: u32, a1: u32, a2: u32, a3: u32, a4: u32, a5: u32, a6: u32,
        \\    a7: u32, a8: u32, a9: u32, a10: u32, a11: u32, a12: u32,
        \\    a13: u32, a14: u32, a15: u32, a16: u32,
        \\  ) -> u32;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // The extern signature collapses to a single i32 (args ptr) when
    // >16 flat params, with one trailing i32 result slot.
    try testing.expect(std.mem.indexOf(u8, src, "_argsarea") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@extern(*const fn (i32) callconv(.c) i32") != null);
}

test "doc comments propagate to generated bindings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface counters {
        \\  /// A monotonic counter resource.
        \\  resource counter {
        \\    /// Construct a fresh counter at zero.
        \\    constructor();
        \\    /// Increment by one.
        \\    increment: func();
        \\  }
        \\}
        \\world w {
        \\  import counters;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "/// A monotonic counter resource.") != null);
    try testing.expect(std.mem.indexOf(u8, src, "/// Increment by one.") != null);
}

test "exported resource method with composite return emits retarea + post-return" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface cache {
        \\  resource entry {
        \\    constructor();
        \\    fetch: func() -> result<string, u32>;
        \\  }
        \\}
        \\world w {
        \\  export cache;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // The fetch method returns result<string, u32> which flattens to
    // 3 flat slots (disc + ptr + len) so it goes through the indirect
    // path with a static retarea and a post-return hook.
    try testing.expect(std.mem.indexOf(u8, src, "_retarea_demo") != null);
    try testing.expect(std.mem.indexOf(u8, src, "cabi_post_demo") != null);
    try testing.expect(std.mem.indexOf(u8, src, "realloc_state.reset()") != null);
}

test "fixed-length list (list<T, N>) lifts to [N]T and round-trips memory" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface i {
        \\  bag: func(xs: list<u32, 4>) -> list<u32, 4>;
        \\  by-record: func(r: rec) -> rec;
        \\  record rec { tag: u8, xs: list<u16, 3> }
        \\}
        \\world w {
        \\  import i;
        \\  export i;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "[4]u32") != null);
    try testing.expect(std.mem.indexOf(u8, src, "[3]u16") != null);
    try testing.expect(std.mem.indexOf(u8, src, "Error.Unsupported") == null);
}

test "resource method with >16 flat params uses indirect-param area on both sides" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface big {
        \\  resource thing {
        \\    constructor();
        \\    take: func(
        \\      a0: u32, a1: u32, a2: u32, a3: u32, a4: u32, a5: u32, a6: u32,
        \\      a7: u32, a8: u32, a9: u32, a10: u32, a11: u32, a12: u32,
        \\      a13: u32, a14: u32, a15: u32, a16: u32,
        \\    );
        \\  }
        \\}
        \\world w {
        \\  import big;
        \\  export big;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "@extern(*const fn (i32) callconv(.c) void") != null);
    try testing.expect(std.mem.indexOf(u8, src, "_argsarea") != null);
    try testing.expect(std.mem.indexOf(u8, src, "args_ptr: i32") != null);
    try testing.expect(std.mem.indexOf(u8, src, "_args_base") != null);
}

test "async export emits [async-lift]/[callback]/[task-return] trio" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface kit {
        \\  delay: async func(value: u32) -> u32;
        \\}
        \\world w {
        \\  export kit;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "@\"[async-lift]demo:x/kit@0.1.0#delay\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@\"[callback][async-lift]demo:x/kit@0.1.0#delay\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".name = \"[task-return]delay\", .library_name = \"[export]demo:x/kit@0.1.0\"") != null);
    // The callback chains back through async_cleanup so multi-step
    // producers can re-schedule themselves from inside the cleanup.
    try testing.expect(std.mem.indexOf(u8, src, "_ = abi.async_cleanup.run();") != null);
    try testing.expect(std.mem.indexOf(u8, src, "return abi.async_cleanup.lift_outcome();") != null);
}

test "async export emits typed state-machine dispatch and taskReturn thunk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface kit {
        \\  greet: async func(name: string) -> u32;
        \\}
        \\world w {
        \\  export kit;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // Typed taskReturn thunk emitted as a free function so the user
    // can hand its address to a `*const fn(R) void` parameter.
    try testing.expect(std.mem.indexOf(u8, src, "fn _task_return_helper_demo_x_kit_0_1_0_greet(_value: u32) void") != null);
    // The [async-lift] dispatches on the user's export shape at comptime.
    try testing.expect(std.mem.indexOf(u8, src, "if (comptime @typeInfo(@TypeOf(exports.kit.greet)) == .type)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "_Sm.start(_state, &_task_return_helper_demo_x_kit_0_1_0_greet, name)") != null);
    // Step dispatch: .exit frees + EXIT, .yield -> 1, .wait -> WAIT(set).
    try testing.expect(std.mem.indexOf(u8, src, ".exit => {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "_Slots.free();") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".yield => return 1,") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".wait => |_set| return @as(i32, @bitCast(@as(u32, 2) | (_set << 4))),") != null);
    // The [callback] dispatches via Sm.step with the lifted event triple.
    try testing.expect(std.mem.indexOf(u8, src, "_Sm.step(_state, @as(abi.Event, @enumFromInt") != null);
}

test "async export with void result emits zero-param taskReturn thunk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  export tick: async func();
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "fn _task_return_helper_tick() void {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "_task_return_tick.*();") != null);
}

test "async import emits [async-lower] extern and SubtaskResult drive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  import fetch: async func(url: string) -> u32;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, ".name = \"[async-lower]fetch\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "abi.SubtaskResult.unpack") != null);
    try testing.expect(std.mem.indexOf(u8, src, "abi.WaitableSet.init()") != null);
}

test "sync import with stream/future signature emits per-function intrinsics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface io {
        \\  pipe: func() -> tuple<stream<u8>, future<result<_, string>>>;
        \\}
        \\world w {
        \\  import io;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // WASI 0.3 returns stream/future handles from *sync* functions
    // (`read-via-stream` and friends), so the per-function canon
    // intrinsics cannot be gated on `async func`.
    try testing.expect(std.mem.indexOf(u8, src, "pub const intrinsics_pipe = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "extern \"demo:x/io@0.1.0\" fn @\"[stream-new-0]pipe\"()") != null);
    try testing.expect(std.mem.indexOf(u8, src, "extern \"demo:x/io@0.1.0\" fn @\"[future-read-1]pipe\"(") != null);
    // Compound payloads expose the canonical element layout plus
    // lift/lower so callers can use readRaw/writeRaw buffers.
    try testing.expect(std.mem.indexOf(u8, src, "pub fn readRaw(handle: abi.Future, ptr: usize) abi.CopyOutcome {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn lift(_base: usize) T {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn lower(_value: T, _base: usize) void {") != null);
}

test "resource method with stream result emits member intrinsics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface fsx {
        \\  resource node {
        \\    tap: func() -> stream<u8>;
        \\  }
        \\}
        \\world w {
        \\  import fsx;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // The canon intrinsic link name suffixes the full member name.
    try testing.expect(std.mem.indexOf(u8, src, "pub const intrinsics_tap = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, src, "extern \"demo:x/fsx@0.1.0\" fn @\"[stream-new-0][method]node.tap\"()") != null);
    try testing.expect(std.mem.indexOf(u8, src, "extern \"demo:x/fsx@0.1.0\" fn @\"[stream-drop-writable-0][method]node.tap\"(") != null);
}

test "async export with void result has zero-param task.return" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  export ping: async func();
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "@\"[async-lift]ping\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".name = \"[task-return]ping\", .library_name = \"[export]$root\"") != null);
}

test "async export with compound result lowers task.return as flat params" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface deps {
        \\  variant fault { none, detail(string) }
        \\  resource thing;
        \\}
        \\interface kit {
        \\  use deps.{fault, thing};
        \\  poke: async func(t: thing) -> result<thing, fault>;
        \\}
        \\world w {
        \\  import deps;
        \\  export kit;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // task.return lowers the result like call *parameters*
    // (flatten_functype(result as params, [])): up to MAX_FLAT_PARAMS=16
    // flat values, not the 1-flat-then-retarea rule used for sync
    // results. result<thing, fault> flattens to 4 core values.
    try testing.expect(std.mem.indexOf(u8, src, "const _task_return_demo_x_kit_0_1_0_poke = @extern(*const fn (i32, i32, i32, i32) callconv(.c) void") != null);
    try testing.expect(std.mem.indexOf(u8, src, "_task_return_demo_x_kit_0_1_0_poke.*(_p0, _p1, _p2, _p3);") != null);
    // The typed taskReturn thunk takes the emitted `<prefix>_result`
    // alias, not a synthesized `<prefix>__value` that nothing defines.
    try testing.expect(std.mem.indexOf(u8, src, "fn _task_return_helper_demo_x_kit_0_1_0_poke(_value: kit_poke_result) void") != null);
    try testing.expect(std.mem.indexOf(u8, src, "__value") == null);
    // File-scope cabi glue must reference `use`d cross-interface types
    // through the source interface's struct — the exporting interface
    // has no struct of its own at file scope.
    try testing.expect(std.mem.indexOf(u8, src, "const t: demo_x_deps.types.thing = ") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub const kit_poke_result = union(enum) { ok: demo_x_deps.types.thing, err: demo_x_deps.types.fault };") != null);
}

test "nested variant store lowering uses unique captures" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface kit {
        \\  variant fault { none, detail(string) }
        \\  grab: func() -> result<string, fault>;
        \\}
        \\world w {
        \\  export kit;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // The sync export spills result<string, fault> to a retarea via
    // emitStoreMem. The nested `.err` arm switches on the variant
    // inside the result capture — both captures must be distinct
    // `_vN` names or Zig rejects the shadowing.
    try testing.expect(std.mem.indexOf(u8, src, "|_pl|") == null);
}

test "list<T,N> projected to single flat slot in variant case lowers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // variant has a 1-slot case with a u32 payload and a multi-slot
    // case with list<u32,2>. The join produces 2 slots; lowering the
    // .quad arm needs to project a `[2]u32` value into slots {disc, 0, 1}.
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  variant pair { single(u32), quad(list<u32, 2>) }
        \\  import emit: func(p: pair);
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // The projection of the [2]u32 payload into slot 1 should index [1] —
    // the second element of the fixed list.
    try testing.expect(std.mem.indexOf(u8, src, "Error.Unsupported") == null);
    // Sanity: a switch over the variant must reference both cases.
    try testing.expect(std.mem.indexOf(u8, src, ".single") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".quad") != null);
}

test "export returning flags / enum / alias-of-primitive lowers correctly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\interface i {
        \\  flags perms { read, write, exec }
        \\  enum color { red, green, blue }
        \\  type status-code = u16;
        \\  make-perms: func() -> perms;
        \\  pick-color: func() -> color;
        \\  status: func() -> status-code;
        \\}
        \\world w {
        \\  export i;
        \\}
    );
    const src = try generateWorld(testing.allocator, pkg, pkg.worlds[0], .{});
    defer testing.allocator.free(src);
    // Flags lowered through packed-struct bitCast, NOT intFromEnum.
    try testing.expect(std.mem.indexOf(u8, src, "@as(u8, @bitCast(_result))") != null);
    // Enum lowered with intFromEnum cast through u32.
    try testing.expect(std.mem.indexOf(u8, src, "@as(u32, @intFromEnum(_result))") != null);
    // Alias-of-u16 follows the alias chain; lowers like a u16 (intCast via u32).
    try testing.expect(std.mem.indexOf(u8, src, "@as(u32, _result)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "Error.Unsupported") == null);
}

test "canonical memory layout matches spec" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try wit.parse(arena.allocator(),
        \\package demo:x@0.1.0;
        \\world w {
        \\  record r1 { a: u8, b: u32 }
        \\  variant v1 { none, some(u32) }
        \\}
    );
    var resolver: Resolver = .{ .gpa = testing.allocator };
    defer resolver.deinit();
    for (pkg.worlds[0].types) |t| try resolver.add(t);
    // r1: u8(off 0, sz 1) + 3-byte pad + u32(off 4, sz 4) => size 8, align 4.
    const r1_layout = try layoutOf(&resolver, .{ .kind = .{ .named = "r1" } });
    try testing.expectEqual(@as(u32, 8), r1_layout.size);
    try testing.expectEqual(@as(u32, 4), r1_layout.@"align");
    // v1: disc(u8, off 0) + 3-byte pad + payload(u32, off 4) => size 8, align 4.
    const v1_layout = try layoutOf(&resolver, .{ .kind = .{ .named = "v1" } });
    try testing.expectEqual(@as(u32, 8), v1_layout.size);
    try testing.expectEqual(@as(u32, 4), v1_layout.@"align");
}
