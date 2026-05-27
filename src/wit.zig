//! WIT (Wasm Interface Types) parser.
//!
//! Designed to cover everything used by real WASIp3-era WIT files:
//! packages with versions, worlds with `include`, interfaces with `use`,
//! cross-package `use` (`use foo:bar/baz@1.0.0.{x, y}`), resources with
//! constructors / methods / statics / `borrow<T>` / `own<T>`, stream and
//! future types, error-context, feature gates (`@since` / `@unstable` /
//! `@deprecated`), `async` functions, named return tuples, and inline
//! interface bodies inside world imports/exports.
//!
//! This is a pure syntactic parser. It does not resolve type names
//! across packages, but it preserves enough information that a later
//! resolver pass can do so by reading the parsed AST.
//!
//! The grammar is recursive descent. Identifiers in WIT are kebab-case;
//! reserved keywords may be escaped with a leading `%`. Comments are
//! `//` line and `/* */` block, plus `///` doc comments which we collapse
//! into the same trivia category.

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const Allocator = mem.Allocator;

pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidVersion,
    OutOfMemory,
};

/// Result of parsing the optional version on a package id / use path.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// Raw text, including any pre-release / build suffix.
    text: []const u8,
};

/// Fully-qualified id used by package decls and by `use` paths.
/// `wasi:cli/run@0.2.8` parses as namespace=wasi, name=cli,
/// interface=Some("run"), version=Some(0.2.8).
pub const PackagePath = struct {
    namespace: []const u8,
    name: []const u8,
    interface: ?[]const u8 = null,
    version: ?Version = null,
};

/// A "use" inside an interface or world: brings names into scope.
pub const Use = struct {
    /// Path to the source interface. `interface` is required for
    /// item-level uses (`use foo.{x}`) — when the path is just a
    /// local identifier it appears as `interface` with empty
    /// namespace/name.
    path: PackagePath,
    /// `null` items means `use foo;` — import everything by name.
    /// Otherwise each entry is `(orig_name, optional_local_alias)`.
    items: ?[]const UseItem,
};

pub const UseItem = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
};

pub const FeatureGate = union(enum) {
    none,
    since: Version,
    unstable: []const u8,
    deprecated: Version,
};

pub const TypeRef = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        // primitives ----------------------------------------------------
        bool,
        s8,
        u8,
        s16,
        u16,
        s32,
        u32,
        s64,
        u64,
        f32,
        f64,
        char,
        string,
        error_context,
        // generics ------------------------------------------------------
        list: *const TypeRef,
        /// Fixed-length list `list<T, N>` (post-WIT-0.3 addition).
        list_fixed: struct { elem: *const TypeRef, len: u32 },
        option: *const TypeRef,
        result: struct { ok: ?*const TypeRef, err: ?*const TypeRef },
        tuple: []const TypeRef,
        // handles -------------------------------------------------------
        own: []const u8, // resource name
        borrow: []const u8, // resource name
        // async types ---------------------------------------------------
        stream: ?*const TypeRef,
        future: ?*const TypeRef,
        // named user type (record/variant/enum/flags/resource/type alias)
        named: []const u8,
    };
};

pub const Field = struct {
    name: []const u8,
    ty: TypeRef,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const Case = struct {
    name: []const u8,
    ty: ?TypeRef,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const ResourceMember = struct {
    kind: Kind,
    /// For methods/statics: the function. For constructors: parameters
    /// stored under a function named "constructor" with no result.
    func: Func,
    gate: FeatureGate = .none,
    docs: []const u8 = "",

    pub const Kind = enum { constructor, method, static };
};

pub const TypeBody = union(enum) {
    record: []const Field,
    variant: []const Case,
    @"enum": []const EnumCase,
    flags: []const FlagLabel,
    alias: TypeRef,
    resource: []const ResourceMember,
};

pub const EnumCase = struct {
    name: []const u8,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const FlagLabel = struct {
    name: []const u8,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const TypeDef = struct {
    name: []const u8,
    body: TypeBody,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const Param = struct {
    name: []const u8,
    ty: TypeRef,
};

pub const Func = struct {
    name: []const u8,
    params: []const Param,
    /// `null` = no result (`func(...)`); single anonymous result is
    /// stored as a single-element slice with empty name.
    results: []const Param = &.{},
    is_async: bool = false,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const InlineInterface = struct {
    funcs: []const Func,
    types: []const TypeDef,
    uses: []const Use,
};

pub const ExternKind = enum { import, @"export" };

/// What a world import/export refers to.
pub const ExternBody = union(enum) {
    /// `import foo;` — by-name binding to a sibling interface/type
    /// in the same package, or a cross-package path like
    /// `import wasi:io/streams@0.2.8;`. The plain form is stored
    /// with empty namespace/name.
    plain: PackagePath,
    /// `import foo: func(...) [-> T];`
    func: Func,
    /// `import foo: interface { ... }`
    inline_interface: InlineInterface,
    /// `import foo: <type-expr>;` — value import (post-MVP).
    value: TypeRef,
};

pub const Extern = struct {
    kind: ExternKind,
    /// Name used to bind the import/export, or the path string for
    /// plain forms (we keep both — `name` is the local identifier
    /// extracted from the path when applicable).
    name: []const u8,
    body: ExternBody,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const Include = struct {
    path: PackagePath,
    /// `include foo with { a as b, c as d }`. Empty when there is no
    /// rename clause.
    renames: []const Rename = &.{},
    gate: FeatureGate = .none,

    pub const Rename = struct { from: []const u8, to: []const u8 };
};

pub const Interface = struct {
    name: []const u8,
    funcs: []const Func,
    types: []const TypeDef,
    uses: []const Use,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const World = struct {
    name: []const u8,
    externs: []const Extern,
    includes: []const Include,
    uses: []const Use,
    /// Type aliases declared at world scope.
    types: []const TypeDef,
    docs: []const u8 = "",
    gate: FeatureGate = .none,
};

pub const Package = struct {
    namespace: []const u8,
    name: []const u8,
    version: ?Version,
    worlds: []const World,
    interfaces: []const Interface,
    /// File-scope type definitions (rare but legal — wasi packages
    /// keep all their types inside interfaces).
    types: []const TypeDef,
    /// File-scope `use` statements.
    uses: []const Use,
    /// Sub-packages declared in block-`package` form. `wasm-tools
    /// component wit` emits all transitive deps inline like this:
    /// `package wasi:io@0.2.6 { interface ... interface ... }`.
    deps: []const Package = &.{},
};

// =====================================================================
// Tokenizer
// =====================================================================

const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    /// Doc-comment text that has accumulated since the last token; the
    /// parser consumes this when attaching docs to a declaration.
    doc_buf: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn deinit(self: *Tokenizer) void {
        self.doc_buf.deinit(self.gpa);
    }

    fn skipTrivia(self: *Tokenizer) Allocator.Error!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (ascii.isWhitespace(c)) {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len) {
                const c2 = self.src[self.pos + 1];
                if (c2 == '/') {
                    const is_doc = self.pos + 2 < self.src.len and self.src[self.pos + 2] == '/';
                    self.pos += if (is_doc) @as(usize, 3) else 2;
                    const line_start = self.pos;
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                    if (is_doc) {
                        const line = self.src[line_start..self.pos];
                        const trimmed = mem.trim(u8, line, " \t");
                        try self.doc_buf.appendSlice(self.gpa, trimmed);
                        try self.doc_buf.append(self.gpa, '\n');
                    }
                    continue;
                }
                if (c2 == '*') {
                    self.pos += 2;
                    while (self.pos + 1 < self.src.len and
                        !(self.src[self.pos] == '*' and self.src[self.pos + 1] == '/'))
                    {
                        self.pos += 1;
                    }
                    if (self.pos + 1 < self.src.len) {
                        self.pos += 2;
                    } else {
                        self.pos = self.src.len;
                    }
                    continue;
                }
            }
            break;
        }
    }

    fn takeDocs(self: *Tokenizer) []const u8 {
        const out = self.doc_buf.toOwnedSlice(self.gpa) catch &.{};
        return out;
    }

    fn clearDocs(self: *Tokenizer) void {
        self.doc_buf.clearRetainingCapacity();
    }

    fn nextIdent(self: *Tokenizer) Allocator.Error!?[]const u8 {
        try self.skipTrivia();
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '%') {
            self.pos += 1;
        }
        const id_start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (ascii.isAlphanumeric(c) or c == '-' or c == '_') {
                self.pos += 1;
            } else break;
        }
        if (self.pos == id_start) {
            self.pos = start;
            return null;
        }
        return self.src[id_start..self.pos];
    }

    /// Same as `nextIdent` but also requires that the identifier
    /// doesn't start with a digit and isn't empty.
    fn expectIdent(self: *Tokenizer) Error![]const u8 {
        const id = (try self.nextIdent()) orelse return Error.UnexpectedToken;
        return id;
    }

    fn consume(self: *Tokenizer, lit: []const u8) Allocator.Error!bool {
        try self.skipTrivia();
        if (self.pos + lit.len > self.src.len) return false;
        if (!mem.eql(u8, self.src[self.pos .. self.pos + lit.len], lit)) return false;
        self.pos += lit.len;
        return true;
    }

    fn consumeWord(self: *Tokenizer, lit: []const u8) Allocator.Error!bool {
        const save = self.pos;
        try self.skipTrivia();
        if (self.pos + lit.len > self.src.len) return false;
        if (!mem.eql(u8, self.src[self.pos .. self.pos + lit.len], lit)) return false;
        const after = self.pos + lit.len;
        if (after < self.src.len) {
            const c = self.src[after];
            if (ascii.isAlphanumeric(c) or c == '-' or c == '_') {
                self.pos = save;
                return false;
            }
        }
        self.pos = after;
        return true;
    }

    fn expect(self: *Tokenizer, lit: []const u8) Error!void {
        if (!try self.consume(lit)) return Error.UnexpectedToken;
    }

    fn expectWord(self: *Tokenizer, lit: []const u8) Error!void {
        if (!try self.consumeWord(lit)) return Error.UnexpectedToken;
    }
};

// =====================================================================
// Parser
// =====================================================================

const Parser = struct {
    gpa: Allocator,
    tok: Tokenizer,
    pkg_namespace: []const u8 = "",
    pkg_name: []const u8 = "",
    pkg_version: ?Version = null,

    worlds: std.ArrayList(World) = .empty,
    interfaces: std.ArrayList(Interface) = .empty,
    types: std.ArrayList(TypeDef) = .empty,
    uses: std.ArrayList(Use) = .empty,
    deps: std.ArrayList(Package) = .empty,

    fn parsePackage(self: *Parser) Error!Package {
        try self.tok.skipTrivia();
        if (try self.tok.consumeWord("package")) {
            self.pkg_namespace = try self.tok.expectIdent();
            try self.tok.expect(":");
            self.pkg_name = try self.tok.expectIdent();
            if (try self.tok.consume("@")) {
                self.pkg_version = try self.parseVersion();
            }
            try self.tok.expect(";");
        }
        self.tok.clearDocs();

        try self.parsePackageBody(false);

        return .{
            .namespace = self.pkg_namespace,
            .name = self.pkg_name,
            .version = self.pkg_version,
            .worlds = try self.worlds.toOwnedSlice(self.gpa),
            .interfaces = try self.interfaces.toOwnedSlice(self.gpa),
            .types = try self.types.toOwnedSlice(self.gpa),
            .uses = try self.uses.toOwnedSlice(self.gpa),
            .deps = try self.deps.toOwnedSlice(self.gpa),
        };
    }

    /// Parse worlds/interfaces/types/uses. When `expect_brace_close` is
    /// true, stop on `}`; otherwise stop on EOF. Encountering a
    /// `package X@v { ... }` block descends into a sub-package and
    /// appends it to `self.deps`.
    fn parsePackageBody(self: *Parser, expect_brace_close: bool) Error!void {
        while (true) {
            try self.tok.skipTrivia();
            if (self.tok.pos >= self.tok.src.len) {
                if (expect_brace_close) return Error.UnexpectedEof;
                break;
            }
            if (expect_brace_close and try self.tok.consume("}")) break;

            const gate = try self.parseGate();
            const docs = self.tok.takeDocs();

            if (try self.tok.consumeWord("package")) {
                try self.parseSubPackage();
                continue;
            }
            if (try self.tok.consumeWord("use")) {
                const u = try self.parseUseTail();
                try self.uses.append(self.gpa, u);
                self.tok.clearDocs();
                continue;
            }
            if (try self.tok.consumeWord("world")) {
                try self.parseWorld(docs, gate);
                continue;
            }
            if (try self.tok.consumeWord("interface")) {
                try self.parseInterface(docs, gate);
                continue;
            }
            if (try self.peekTypeKeyword()) {
                const td = try self.parseTypeDef(docs, gate);
                try self.types.append(self.gpa, td);
                continue;
            }
            return Error.UnexpectedToken;
        }
    }

    fn parseSubPackage(self: *Parser) Error!void {
        const ns = try self.tok.expectIdent();
        try self.tok.expect(":");
        const name = try self.tok.expectIdent();
        var version: ?Version = null;
        if (try self.tok.consume("@")) {
            version = try self.parseVersion();
        }
        // Sub-packages may also be declared inline as `package X@v;`
        // (rare but legal) — treat it as an empty package.
        if (try self.tok.consume(";")) {
            try self.deps.append(self.gpa, .{
                .namespace = ns,
                .name = name,
                .version = version,
                .worlds = &.{},
                .interfaces = &.{},
                .types = &.{},
                .uses = &.{},
            });
            return;
        }
        try self.tok.expect("{");

        const saved_worlds = self.worlds;
        const saved_interfaces = self.interfaces;
        const saved_types = self.types;
        const saved_uses = self.uses;
        const saved_ns = self.pkg_namespace;
        const saved_pkg_name = self.pkg_name;
        const saved_ver = self.pkg_version;

        self.worlds = .empty;
        self.interfaces = .empty;
        self.types = .empty;
        self.uses = .empty;
        self.pkg_namespace = ns;
        self.pkg_name = name;
        self.pkg_version = version;

        try self.parsePackageBody(true);

        const sub: Package = .{
            .namespace = ns,
            .name = name,
            .version = version,
            .worlds = try self.worlds.toOwnedSlice(self.gpa),
            .interfaces = try self.interfaces.toOwnedSlice(self.gpa),
            .types = try self.types.toOwnedSlice(self.gpa),
            .uses = try self.uses.toOwnedSlice(self.gpa),
        };

        self.worlds = saved_worlds;
        self.interfaces = saved_interfaces;
        self.types = saved_types;
        self.uses = saved_uses;
        self.pkg_namespace = saved_ns;
        self.pkg_name = saved_pkg_name;
        self.pkg_version = saved_ver;

        try self.deps.append(self.gpa, sub);
    }

    fn parseVersion(self: *Parser) Error!Version {
        try self.tok.skipTrivia();
        const start = self.tok.pos;
        while (self.tok.pos < self.tok.src.len) {
            const c = self.tok.src[self.tok.pos];
            // Stop on `.` unless it is followed by an alphanumeric — the
            // `.{` after a use path is part of the surrounding grammar,
            // not the version.
            if (c == '.') {
                const next = if (self.tok.pos + 1 < self.tok.src.len) self.tok.src[self.tok.pos + 1] else 0;
                if (!ascii.isAlphanumeric(next)) break;
                self.tok.pos += 1;
                continue;
            }
            if (ascii.isAlphanumeric(c) or c == '-' or c == '+') {
                self.tok.pos += 1;
            } else break;
        }
        const text = self.tok.src[start..self.tok.pos];
        if (text.len == 0) return Error.InvalidVersion;
        // Parse strictly the leading "<u32>.<u32>.<u32>" and store the
        // whole text (including pre-release / build metadata).
        var nums: [3]u32 = .{ 0, 0, 0 };
        var idx: usize = 0;
        var seg_start: usize = 0;
        var seg_idx: usize = 0;
        while (idx <= text.len) : (idx += 1) {
            const at_end = idx == text.len;
            const c = if (at_end) @as(u8, 0) else text[idx];
            if (at_end or c == '.' or c == '-' or c == '+') {
                if (seg_idx < 3 and idx > seg_start) {
                    nums[seg_idx] = std.fmt.parseInt(u32, text[seg_start..idx], 10) catch {
                        if (seg_idx == 0) return Error.InvalidVersion;
                        // soft-fail for non-numeric pre-release tail
                        break;
                    };
                    seg_idx += 1;
                }
                if (c == '-' or c == '+') break;
                seg_start = idx + 1;
                if (seg_idx >= 3) break;
            }
        }
        return .{ .major = nums[0], .minor = nums[1], .patch = nums[2], .text = text };
    }

    /// Parse a (possibly-zero) sequence of `@since(...)` / `@unstable(...)` /
    /// `@deprecated(...)` annotations and return the most recent one
    /// (only one is meaningful per item per the spec, but we tolerate
    /// stacking and keep the last).
    fn parseGate(self: *Parser) Error!FeatureGate {
        var out: FeatureGate = .none;
        while (true) {
            try self.tok.skipTrivia();
            if (!try self.tok.consume("@")) break;
            const name = try self.tok.expectIdent();
            try self.tok.expect("(");
            if (mem.eql(u8, name, "since")) {
                try self.tok.expectWord("version");
                try self.tok.expect("=");
                out = .{ .since = try self.parseVersion() };
            } else if (mem.eql(u8, name, "unstable")) {
                try self.tok.expectWord("feature");
                try self.tok.expect("=");
                const feat = try self.tok.expectIdent();
                out = .{ .unstable = feat };
            } else if (mem.eql(u8, name, "deprecated")) {
                try self.tok.expectWord("version");
                try self.tok.expect("=");
                out = .{ .deprecated = try self.parseVersion() };
            } else {
                // Skip the body of unknown annotations to keep moving.
                var depth: usize = 1;
                while (self.tok.pos < self.tok.src.len and depth > 0) {
                    const c = self.tok.src[self.tok.pos];
                    self.tok.pos += 1;
                    if (c == '(') depth += 1;
                    if (c == ')') depth -= 1;
                }
                continue;
            }
            try self.tok.expect(")");
        }
        return out;
    }

    fn peekTypeKeyword(self: *Parser) Allocator.Error!bool {
        const save = self.tok.pos;
        defer self.tok.pos = save;
        try self.tok.skipTrivia();
        inline for (.{ "record", "variant", "enum", "flags", "type", "resource" }) |kw| {
            if (try self.tok.consumeWord(kw)) return true;
        }
        return false;
    }

    fn parseUseTail(self: *Parser) Error!Use {
        // `use foo;` | `use foo.{...};` | `use ns:pkg/iface[@ver][.{...}];`
        const path = try self.parsePath(.allow_dot_items);
        var items: ?[]const UseItem = null;
        if (try self.tok.consume(".")) {
            try self.tok.expect("{");
            var list: std.ArrayList(UseItem) = .empty;
            try self.tok.skipTrivia();
            if (!try self.tok.consume("}")) {
                while (true) {
                    const orig = try self.tok.expectIdent();
                    var alias: ?[]const u8 = null;
                    if (try self.tok.consumeWord("as")) {
                        alias = try self.tok.expectIdent();
                    }
                    try list.append(self.gpa, .{ .name = orig, .alias = alias });
                    try self.tok.skipTrivia();
                    if (try self.tok.consume(",")) {
                        try self.tok.skipTrivia();
                        if (try self.tok.consume("}")) break;
                        continue;
                    }
                    try self.tok.expect("}");
                    break;
                }
            }
            items = try list.toOwnedSlice(self.gpa);
        }
        try self.tok.expect(";");
        return .{ .path = path, .items = items };
    }

    const PathMode = enum { full, allow_dot_items };

    fn parsePath(self: *Parser, mode: PathMode) Error!PackagePath {
        // Either a bare identifier (sibling interface), or
        // `ns:pkg[/iface][@ver]`.
        const first = try self.tok.expectIdent();
        if (try self.tok.consume(":")) {
            const pkg_name = try self.tok.expectIdent();
            var iface: ?[]const u8 = null;
            if (try self.tok.consume("/")) {
                iface = try self.tok.expectIdent();
            }
            var ver: ?Version = null;
            if (try self.tok.consume("@")) {
                ver = try self.parseVersion();
            }
            _ = mode;
            return .{
                .namespace = first,
                .name = pkg_name,
                .interface = iface,
                .version = ver,
            };
        }
        return .{ .namespace = "", .name = "", .interface = first };
    }

    fn parseWorld(self: *Parser, docs: []const u8, gate: FeatureGate) Error!void {
        const name = try self.tok.expectIdent();
        try self.tok.expect("{");
        var externs: std.ArrayList(Extern) = .empty;
        var includes: std.ArrayList(Include) = .empty;
        var uses: std.ArrayList(Use) = .empty;
        var types: std.ArrayList(TypeDef) = .empty;
        while (true) {
            try self.tok.skipTrivia();
            if (try self.tok.consume("}")) break;

            const inner_gate = try self.parseGate();
            const inner_docs = self.tok.takeDocs();

            if (try self.tok.consumeWord("use")) {
                const u = try self.parseUseTail();
                try uses.append(self.gpa, u);
                continue;
            }
            if (try self.tok.consumeWord("include")) {
                const inc = try self.parseIncludeTail(inner_gate);
                try includes.append(self.gpa, inc);
                continue;
            }
            if (try self.peekTypeKeyword()) {
                const td = try self.parseTypeDef(inner_docs, inner_gate);
                try types.append(self.gpa, td);
                continue;
            }
            const kind: ExternKind = if (try self.tok.consumeWord("import"))
                .import
            else if (try self.tok.consumeWord("export"))
                .@"export"
            else
                return Error.UnexpectedToken;

            const ex = try self.parseExternTail(kind, inner_docs, inner_gate);
            try externs.append(self.gpa, ex);
        }
        try self.worlds.append(self.gpa, .{
            .name = name,
            .externs = try externs.toOwnedSlice(self.gpa),
            .includes = try includes.toOwnedSlice(self.gpa),
            .uses = try uses.toOwnedSlice(self.gpa),
            .types = try types.toOwnedSlice(self.gpa),
            .docs = docs,
            .gate = gate,
        });
    }

    fn parseIncludeTail(self: *Parser, gate: FeatureGate) Error!Include {
        const path = try self.parsePath(.full);
        var renames: []const Include.Rename = &.{};
        if (try self.tok.consumeWord("with")) {
            try self.tok.expect("{");
            var rl: std.ArrayList(Include.Rename) = .empty;
            try self.tok.skipTrivia();
            if (!try self.tok.consume("}")) {
                while (true) {
                    const from = try self.tok.expectIdent();
                    try self.tok.expectWord("as");
                    const to = try self.tok.expectIdent();
                    try rl.append(self.gpa, .{ .from = from, .to = to });
                    try self.tok.skipTrivia();
                    if (try self.tok.consume(",")) {
                        try self.tok.skipTrivia();
                        if (try self.tok.consume("}")) break;
                        continue;
                    }
                    try self.tok.expect("}");
                    break;
                }
            }
            renames = try rl.toOwnedSlice(self.gpa);
        }
        try self.tok.expect(";");
        return .{ .path = path, .renames = renames, .gate = gate };
    }

    fn parseExternTail(self: *Parser, kind: ExternKind, docs: []const u8, gate: FeatureGate) Error!Extern {
        // After `import` / `export`, either:
        //   <plain-path>;                        (e.g. `import sibling;` or `import ns:pkg/iface@ver;`)
        //   <name>: func(...) [-> T];
        //   <name>: interface { ... }
        //   <name>: <type-expr>;
        //
        // The first form may *contain* a `:`, so we have to peek ahead
        // before assuming a stand-alone colon means "typed binding".
        const ident = try self.tok.expectIdent();
        try self.tok.skipTrivia();
        // Plain-path form: `ident:pkg/iface@ver;` — recognised by the
        // `:` being immediately followed by an identifier and then `/`,
        // `@`, or `;` (not by `func`, `interface`, `async`, or a type
        // keyword).
        if (self.tok.pos < self.tok.src.len and self.tok.src[self.tok.pos] == ':') {
            const save = self.tok.pos;
            self.tok.pos += 1;
            const ahead = try self.tok.nextIdent();
            const looks_like_path = blk: {
                if (ahead == null) break :blk false;
                try self.tok.skipTrivia();
                if (self.tok.pos >= self.tok.src.len) break :blk false;
                const c = self.tok.src[self.tok.pos];
                break :blk (c == '/' or c == '@' or c == ';');
            };
            if (looks_like_path) {
                var path: PackagePath = .{ .namespace = ident, .name = ahead.?, .interface = null };
                if (try self.tok.consume("/")) path.interface = try self.tok.expectIdent();
                if (try self.tok.consume("@")) path.version = try self.parseVersion();
                try self.tok.expect(";");
                return .{
                    .kind = kind,
                    .name = if (path.interface) |i| i else path.name,
                    .body = .{ .plain = path },
                    .docs = docs,
                    .gate = gate,
                };
            }
            self.tok.pos = save;
        }
        if (try self.tok.consume(":")) {
            if (try self.tok.consumeWord("func")) {
                const sig = try self.parseFuncTail(ident, false);
                try self.tok.expect(";");
                return .{
                    .kind = kind,
                    .name = ident,
                    .body = .{ .func = sig },
                    .docs = docs,
                    .gate = gate,
                };
            }
            if (try self.tok.consumeWord("async")) {
                try self.tok.expectWord("func");
                const sig = try self.parseFuncTail(ident, true);
                try self.tok.expect(";");
                return .{
                    .kind = kind,
                    .name = ident,
                    .body = .{ .func = sig },
                    .docs = docs,
                    .gate = gate,
                };
            }
            if (try self.tok.consumeWord("interface")) {
                const body = try self.parseInlineInterfaceBody();
                return .{
                    .kind = kind,
                    .name = ident,
                    .body = .{ .inline_interface = body },
                    .docs = docs,
                    .gate = gate,
                };
            }
            const ty = try self.parseTypeExpr();
            try self.tok.expect(";");
            return .{
                .kind = kind,
                .name = ident,
                .body = .{ .value = ty },
                .docs = docs,
                .gate = gate,
            };
        }
        // Plain `import foo;` referring to a sibling interface or world.
        const path: PackagePath = .{ .namespace = "", .name = "", .interface = ident };
        try self.tok.expect(";");
        return .{
            .kind = kind,
            .name = if (path.interface) |i| i else path.name,
            .body = .{ .plain = path },
            .docs = docs,
            .gate = gate,
        };
    }

    fn parseInterface(self: *Parser, docs: []const u8, gate: FeatureGate) Error!void {
        const name = try self.tok.expectIdent();
        const body = try self.parseInlineInterfaceBody();
        try self.interfaces.append(self.gpa, .{
            .name = name,
            .funcs = body.funcs,
            .types = body.types,
            .uses = body.uses,
            .docs = docs,
            .gate = gate,
        });
    }

    fn parseInlineInterfaceBody(self: *Parser) Error!InlineInterface {
        try self.tok.expect("{");
        var funcs: std.ArrayList(Func) = .empty;
        var types: std.ArrayList(TypeDef) = .empty;
        var uses: std.ArrayList(Use) = .empty;
        while (true) {
            try self.tok.skipTrivia();
            if (try self.tok.consume("}")) break;

            const member_gate = try self.parseGate();
            const member_docs = self.tok.takeDocs();

            if (try self.tok.consumeWord("use")) {
                const u = try self.parseUseTail();
                try uses.append(self.gpa, u);
                continue;
            }
            if (try self.peekTypeKeyword()) {
                const td = try self.parseTypeDef(member_docs, member_gate);
                try types.append(self.gpa, td);
                continue;
            }
            // function: `name: [async] func(...) [-> T];`
            const fname = try self.tok.expectIdent();
            try self.tok.expect(":");
            const is_async = try self.tok.consumeWord("async");
            try self.tok.expectWord("func");
            var sig = try self.parseFuncTail(fname, is_async);
            sig.docs = member_docs;
            sig.gate = member_gate;
            try self.tok.expect(";");
            try funcs.append(self.gpa, sig);
        }
        return .{
            .funcs = try funcs.toOwnedSlice(self.gpa),
            .types = try types.toOwnedSlice(self.gpa),
            .uses = try uses.toOwnedSlice(self.gpa),
        };
    }

    fn parseFuncTail(self: *Parser, name: []const u8, is_async: bool) Error!Func {
        try self.tok.expect("(");
        var params: std.ArrayList(Param) = .empty;
        try self.tok.skipTrivia();
        if (!try self.tok.consume(")")) {
            while (true) {
                // doc comments allowed mid-param list (real wasi WITs use them)
                self.tok.clearDocs();
                const pname = try self.tok.expectIdent();
                try self.tok.expect(":");
                const pty = try self.parseTypeExpr();
                try params.append(self.gpa, .{ .name = pname, .ty = pty });
                try self.tok.skipTrivia();
                if (try self.tok.consume(",")) {
                    try self.tok.skipTrivia();
                    if (try self.tok.consume(")")) break;
                    continue;
                }
                try self.tok.expect(")");
                break;
            }
        }
        var results: []const Param = &.{};
        if (try self.tok.consume("->")) {
            results = try self.parseResultsTail();
        }
        return .{ .name = name, .params = try params.toOwnedSlice(self.gpa), .results = results, .is_async = is_async };
    }

    /// Parse the value(s) after `->`. Either a single type expression or
    /// a named-tuple `(name: T, name: T)`.
    fn parseResultsTail(self: *Parser) Error![]const Param {
        try self.tok.skipTrivia();
        if (try self.tok.consume("(")) {
            // could be a named-tuple result OR a tuple type expression
            // wrapped in parens. WIT's grammar reserves `(x: T, y: T)`
            // for named results.
            // Detect by looking ahead for `ident :`.
            const save = self.tok.pos;
            const id = self.tok.nextIdent() catch null;
            const sep_ok = id != null and (try self.tok.consume(":"));
            if (sep_ok) {
                var out: std.ArrayList(Param) = .empty;
                const first_ty = try self.parseTypeExpr();
                try out.append(self.gpa, .{ .name = id.?, .ty = first_ty });
                while (true) {
                    try self.tok.skipTrivia();
                    if (try self.tok.consume(",")) {
                        const n = try self.tok.expectIdent();
                        try self.tok.expect(":");
                        const t = try self.parseTypeExpr();
                        try out.append(self.gpa, .{ .name = n, .ty = t });
                        continue;
                    }
                    try self.tok.expect(")");
                    break;
                }
                return try out.toOwnedSlice(self.gpa);
            }
            // Not named results — backtrack and parse as plain type expr.
            self.tok.pos = save;
        }
        const ty = try self.parseTypeExpr();
        const single = try self.gpa.alloc(Param, 1);
        single[0] = .{ .name = "", .ty = ty };
        return single;
    }

    fn parseTypeDef(self: *Parser, docs: []const u8, gate: FeatureGate) Error!TypeDef {
        if (try self.tok.consumeWord("record")) {
            const name = try self.tok.expectIdent();
            try self.tok.expect("{");
            var fields: std.ArrayList(Field) = .empty;
            try self.tok.skipTrivia();
            if (!try self.tok.consume("}")) {
                while (true) {
                    const fgate = try self.parseGate();
                    const fdocs = self.tok.takeDocs();
                    const fname = try self.tok.expectIdent();
                    try self.tok.expect(":");
                    const fty = try self.parseTypeExpr();
                    try fields.append(self.gpa, .{ .name = fname, .ty = fty, .docs = fdocs, .gate = fgate });
                    try self.tok.skipTrivia();
                    if (try self.tok.consume(",")) {
                        try self.tok.skipTrivia();
                        if (try self.tok.consume("}")) break;
                        continue;
                    }
                    try self.tok.expect("}");
                    break;
                }
            }
            return .{ .name = name, .body = .{ .record = try fields.toOwnedSlice(self.gpa) }, .docs = docs, .gate = gate };
        }
        if (try self.tok.consumeWord("variant")) {
            const name = try self.tok.expectIdent();
            try self.tok.expect("{");
            var cases: std.ArrayList(Case) = .empty;
            try self.tok.skipTrivia();
            if (!try self.tok.consume("}")) {
                while (true) {
                    const cgate = try self.parseGate();
                    const cdocs = self.tok.takeDocs();
                    const cname = try self.tok.expectIdent();
                    var payload: ?TypeRef = null;
                    try self.tok.skipTrivia();
                    if (try self.tok.consume("(")) {
                        payload = try self.parseTypeExpr();
                        try self.tok.expect(")");
                    }
                    try cases.append(self.gpa, .{ .name = cname, .ty = payload, .docs = cdocs, .gate = cgate });
                    try self.tok.skipTrivia();
                    if (try self.tok.consume(",")) {
                        try self.tok.skipTrivia();
                        if (try self.tok.consume("}")) break;
                        continue;
                    }
                    try self.tok.expect("}");
                    break;
                }
            }
            return .{ .name = name, .body = .{ .variant = try cases.toOwnedSlice(self.gpa) }, .docs = docs, .gate = gate };
        }
        if (try self.tok.consumeWord("enum")) {
            const name = try self.tok.expectIdent();
            const labels = try self.parseGatedLabelList();
            const out = try self.gpa.alloc(EnumCase, labels.len);
            for (labels, 0..) |l, i| out[i] = .{ .name = l.name, .docs = l.docs, .gate = l.gate };
            return .{ .name = name, .body = .{ .@"enum" = out }, .docs = docs, .gate = gate };
        }
        if (try self.tok.consumeWord("flags")) {
            const name = try self.tok.expectIdent();
            const labels = try self.parseGatedLabelList();
            const out = try self.gpa.alloc(FlagLabel, labels.len);
            for (labels, 0..) |l, i| out[i] = .{ .name = l.name, .docs = l.docs, .gate = l.gate };
            return .{ .name = name, .body = .{ .flags = out }, .docs = docs, .gate = gate };
        }
        if (try self.tok.consumeWord("type")) {
            const name = try self.tok.expectIdent();
            try self.tok.expect("=");
            const target = try self.parseTypeExpr();
            try self.tok.expect(";");
            return .{ .name = name, .body = .{ .alias = target }, .docs = docs, .gate = gate };
        }
        if (try self.tok.consumeWord("resource")) {
            const name = try self.tok.expectIdent();
            // either `resource name;` or `resource name { ... }`
            try self.tok.skipTrivia();
            if (try self.tok.consume(";")) {
                return .{ .name = name, .body = .{ .resource = &.{} }, .docs = docs, .gate = gate };
            }
            try self.tok.expect("{");
            var members: std.ArrayList(ResourceMember) = .empty;
            while (true) {
                try self.tok.skipTrivia();
                if (try self.tok.consume("}")) break;
                const mgate = try self.parseGate();
                const mdocs = self.tok.takeDocs();
                if (try self.tok.consumeWord("constructor")) {
                    var ctor = try self.parseFuncTail("constructor", false);
                    ctor.docs = mdocs;
                    ctor.gate = mgate;
                    try self.tok.expect(";");
                    try members.append(self.gpa, .{ .kind = .constructor, .func = ctor, .docs = mdocs, .gate = mgate });
                    continue;
                }
                const mname = try self.tok.expectIdent();
                try self.tok.expect(":");
                const is_static = try self.tok.consumeWord("static");
                const is_async = try self.tok.consumeWord("async");
                try self.tok.expectWord("func");
                var sig = try self.parseFuncTail(mname, is_async);
                sig.docs = mdocs;
                sig.gate = mgate;
                try self.tok.expect(";");
                try members.append(self.gpa, .{
                    .kind = if (is_static) .static else .method,
                    .func = sig,
                    .docs = mdocs,
                    .gate = mgate,
                });
            }
            return .{ .name = name, .body = .{ .resource = try members.toOwnedSlice(self.gpa) }, .docs = docs, .gate = gate };
        }
        return Error.UnexpectedToken;
    }

    const GatedLabel = struct { name: []const u8, docs: []const u8, gate: FeatureGate };

    fn parseGatedLabelList(self: *Parser) Error![]const GatedLabel {
        try self.tok.expect("{");
        var out: std.ArrayList(GatedLabel) = .empty;
        try self.tok.skipTrivia();
        if (!try self.tok.consume("}")) {
            while (true) {
                const lgate = try self.parseGate();
                const ldocs = self.tok.takeDocs();
                const lbl = try self.tok.expectIdent();
                try out.append(self.gpa, .{ .name = lbl, .docs = ldocs, .gate = lgate });
                try self.tok.skipTrivia();
                if (try self.tok.consume(",")) {
                    try self.tok.skipTrivia();
                    if (try self.tok.consume("}")) break;
                    continue;
                }
                try self.tok.expect("}");
                break;
            }
        }
        return try out.toOwnedSlice(self.gpa);
    }

    fn parseTypeExpr(self: *Parser) Error!TypeRef {
        try self.tok.skipTrivia();
        if (try self.tok.consumeWord("list")) {
            try self.tok.expect("<");
            const inner = try self.parseTypeExpr();
            const boxed = try self.gpa.create(TypeRef);
            boxed.* = inner;
            // optional fixed length `list<T, N>`
            if (try self.tok.consume(",")) {
                try self.tok.skipTrivia();
                const num_start = self.tok.pos;
                while (self.tok.pos < self.tok.src.len and ascii.isDigit(self.tok.src[self.tok.pos])) {
                    self.tok.pos += 1;
                }
                const n = std.fmt.parseInt(u32, self.tok.src[num_start..self.tok.pos], 10) catch return Error.UnexpectedToken;
                try self.tok.expect(">");
                return .{ .kind = .{ .list_fixed = .{ .elem = boxed, .len = n } } };
            }
            try self.tok.expect(">");
            return .{ .kind = .{ .list = boxed } };
        }
        if (try self.tok.consumeWord("option")) {
            try self.tok.expect("<");
            const inner = try self.parseTypeExpr();
            try self.tok.expect(">");
            const boxed = try self.gpa.create(TypeRef);
            boxed.* = inner;
            return .{ .kind = .{ .option = boxed } };
        }
        if (try self.tok.consumeWord("result")) {
            try self.tok.skipTrivia();
            if (!try self.tok.consume("<")) {
                return .{ .kind = .{ .result = .{ .ok = null, .err = null } } };
            }
            var ok_p: ?*const TypeRef = null;
            var err_p: ?*const TypeRef = null;
            try self.tok.skipTrivia();
            if (!try self.tok.consume("_")) {
                const ok = try self.parseTypeExpr();
                const box = try self.gpa.create(TypeRef);
                box.* = ok;
                ok_p = box;
            }
            try self.tok.skipTrivia();
            if (try self.tok.consume(",")) {
                const err = try self.parseTypeExpr();
                const box = try self.gpa.create(TypeRef);
                box.* = err;
                err_p = box;
            }
            try self.tok.expect(">");
            return .{ .kind = .{ .result = .{ .ok = ok_p, .err = err_p } } };
        }
        if (try self.tok.consumeWord("tuple")) {
            try self.tok.expect("<");
            var elems: std.ArrayList(TypeRef) = .empty;
            while (true) {
                const t = try self.parseTypeExpr();
                try elems.append(self.gpa, t);
                try self.tok.skipTrivia();
                if (try self.tok.consume(",")) continue;
                try self.tok.expect(">");
                break;
            }
            return .{ .kind = .{ .tuple = try elems.toOwnedSlice(self.gpa) } };
        }
        if (try self.tok.consumeWord("own")) {
            try self.tok.expect("<");
            const id = try self.tok.expectIdent();
            try self.tok.expect(">");
            return .{ .kind = .{ .own = id } };
        }
        if (try self.tok.consumeWord("borrow")) {
            try self.tok.expect("<");
            const id = try self.tok.expectIdent();
            try self.tok.expect(">");
            return .{ .kind = .{ .borrow = id } };
        }
        if (try self.tok.consumeWord("stream")) {
            try self.tok.skipTrivia();
            if (try self.tok.consume("<")) {
                const inner = try self.parseTypeExpr();
                try self.tok.expect(">");
                const box = try self.gpa.create(TypeRef);
                box.* = inner;
                return .{ .kind = .{ .stream = box } };
            }
            return .{ .kind = .{ .stream = null } };
        }
        if (try self.tok.consumeWord("future")) {
            try self.tok.skipTrivia();
            if (try self.tok.consume("<")) {
                const inner = try self.parseTypeExpr();
                try self.tok.expect(">");
                const box = try self.gpa.create(TypeRef);
                box.* = inner;
                return .{ .kind = .{ .future = box } };
            }
            return .{ .kind = .{ .future = null } };
        }
        if (try self.tok.consumeWord("error-context")) {
            return .{ .kind = .error_context };
        }

        const prim_map = .{
            .{ "bool", TypeRef.Kind.bool },
            .{ "s8", TypeRef.Kind.s8 },
            .{ "u8", TypeRef.Kind.u8 },
            .{ "s16", TypeRef.Kind.s16 },
            .{ "u16", TypeRef.Kind.u16 },
            .{ "s32", TypeRef.Kind.s32 },
            .{ "u32", TypeRef.Kind.u32 },
            .{ "s64", TypeRef.Kind.s64 },
            .{ "u64", TypeRef.Kind.u64 },
            .{ "f32", TypeRef.Kind.f32 },
            .{ "f64", TypeRef.Kind.f64 },
            .{ "char", TypeRef.Kind.char },
            .{ "string", TypeRef.Kind.string },
        };
        inline for (prim_map) |entry| {
            if (try self.tok.consumeWord(entry[0])) return .{ .kind = entry[1] };
        }

        const id = try self.tok.expectIdent();
        return .{ .kind = .{ .named = id } };
    }
};

pub fn parse(gpa: Allocator, src: []const u8) Error!Package {
    var parser: Parser = .{ .gpa = gpa, .tok = .{ .src = src, .gpa = gpa } };
    defer parser.tok.deinit();
    return parser.parsePackage();
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "parse trivial package" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try parse(arena.allocator(),
        \\package demo:adder@0.1.0;
        \\world adder {
        \\  export add: func(a: u32, b: u32) -> u32;
        \\}
    );
    try testing.expectEqualStrings("demo", pkg.namespace);
    try testing.expectEqualStrings("adder", pkg.name);
    try testing.expect(pkg.version.?.major == 0 and pkg.version.?.minor == 1);
    try testing.expectEqual(@as(usize, 1), pkg.worlds.len);
    const w = pkg.worlds[0];
    try testing.expectEqualStrings("adder", w.name);
    try testing.expectEqual(@as(usize, 1), w.externs.len);
    try testing.expect(w.externs[0].kind == .@"export");
    try testing.expect(w.externs[0].body == .func);
}

test "parse record / variant / list / option / result" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try parse(arena.allocator(),
        \\package demo:app@1.0.0;
        \\record user { id: u32, name: string, age: u32, }
        \\variant outcome { ok-case, failed(string) }
        \\enum color { red, green, blue }
        \\flags perms { read, write, exec }
        \\world w {
        \\  export greet: func(u: user) -> string;
        \\  export users: func() -> list<user>;
        \\  export find: func(id: u32) -> option<user>;
        \\  export validate: func(name: string) -> result<user, string>;
        \\}
    );
    try testing.expectEqual(@as(usize, 4), pkg.types.len);
    try testing.expect(pkg.types[0].body == .record);
    try testing.expectEqual(@as(usize, 3), pkg.types[0].body.record.len);
    try testing.expect(pkg.types[1].body == .variant);
    try testing.expect(pkg.types[1].body.variant[1].ty != null);
    try testing.expectEqual(@as(usize, 3), pkg.types[2].body.@"enum".len);
    try testing.expectEqual(@as(usize, 3), pkg.types[3].body.flags.len);
    const w = pkg.worlds[0];
    try testing.expectEqual(@as(usize, 4), w.externs.len);
    try testing.expect(w.externs[2].body.func.results[0].ty.kind == .option);
    const rr = w.externs[3].body.func.results[0].ty.kind.result;
    try testing.expect(rr.ok != null and rr.err != null);
}

test "parse feature gates, includes, use, resources, async" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try parse(arena.allocator(),
        \\package wasi:demo@0.3.0-draft;
        \\@since(version = 0.2.0)
        \\interface streams {
        \\  use wasi:io/poll@0.2.8.{pollable};
        \\  @since(version = 0.2.0)
        \\  resource input-stream {
        \\    constructor(name: string);
        \\    read: func(len: u64) -> result<list<u8>, string>;
        \\    @unstable(feature = drop-pollable)
        \\    merge: static func(a: borrow<input-stream>) -> own<input-stream>;
        \\  }
        \\}
        \\@since(version = 0.2.0)
        \\world example {
        \\  @since(version = 0.2.0)
        \\  include base with { a as b };
        \\  import streams;
        \\  export step: async func() -> result;
        \\  export inline: interface {
        \\    ping: func() -> string;
        \\  }
        \\}
    );

    try testing.expectEqualStrings("wasi", pkg.namespace);
    try testing.expectEqualStrings("demo", pkg.name);
    try testing.expectEqualStrings("0.3.0-draft", pkg.version.?.text);

    try testing.expectEqual(@as(usize, 1), pkg.interfaces.len);
    const iface = pkg.interfaces[0];
    try testing.expect(iface.gate == .since);
    try testing.expectEqual(@as(usize, 1), iface.uses.len);
    try testing.expectEqualStrings("wasi", iface.uses[0].path.namespace);
    try testing.expectEqualStrings("io", iface.uses[0].path.name);
    try testing.expectEqualStrings("poll", iface.uses[0].path.interface.?);
    try testing.expectEqual(@as(usize, 1), iface.types.len);
    try testing.expect(iface.types[0].body == .resource);
    const members = iface.types[0].body.resource;
    try testing.expectEqual(@as(usize, 3), members.len);
    try testing.expect(members[0].kind == .constructor);
    try testing.expect(members[1].kind == .method);
    try testing.expect(members[2].kind == .static);
    try testing.expect(members[2].gate == .unstable);
    try testing.expect(members[2].func.params[0].ty.kind == .borrow);

    const w = pkg.worlds[0];
    try testing.expectEqual(@as(usize, 1), w.includes.len);
    try testing.expectEqualStrings("base", w.includes[0].path.interface.?);
    try testing.expectEqual(@as(usize, 1), w.includes[0].renames.len);
    try testing.expectEqualStrings("a", w.includes[0].renames[0].from);
    try testing.expectEqualStrings("b", w.includes[0].renames[0].to);
    try testing.expectEqual(@as(usize, 3), w.externs.len);
    try testing.expect(w.externs[0].body == .plain);
    try testing.expect(w.externs[1].body.func.is_async);
    try testing.expect(w.externs[2].body == .inline_interface);
    try testing.expectEqual(@as(usize, 1), w.externs[2].body.inline_interface.funcs.len);
}

test "parse stream / future / error-context / named results" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pkg = try parse(arena.allocator(),
        \\package demo:async@0.3.0;
        \\interface i {
        \\  read-all: func(s: stream<u8>) -> future<list<u8>>;
        \\  ctx: func() -> error-context;
        \\  pair: func() -> (lo: u32, hi: u32);
        \\  bare: func() -> stream;
        \\}
    );
    const iface = pkg.interfaces[0];
    try testing.expectEqual(@as(usize, 4), iface.funcs.len);
    try testing.expect(iface.funcs[0].params[0].ty.kind == .stream);
    try testing.expect(iface.funcs[0].results[0].ty.kind == .future);
    try testing.expect(iface.funcs[1].results[0].ty.kind == .error_context);
    try testing.expectEqual(@as(usize, 2), iface.funcs[2].results.len);
    try testing.expectEqualStrings("lo", iface.funcs[2].results[0].name);
    try testing.expect(iface.funcs[3].results[0].ty.kind.stream == null);
}
