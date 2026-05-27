# Build-system integration

Doing the codegen, the Zig compile, and the two `wasm-tools` steps
by hand is fine while you are exploring. As soon as the project grows
past a few files, you want it all driven by `zig build`. This page
shows how, with a complete template you can paste into your own
`build.zig`.

The template is exactly the pattern the bundled examples use. If you
want the canonical implementation, `build.zig` at the root of this
repo has seven worked variants (`demo`, `dual`, `resource`,
`http-get`, `async-basic`, `wasi-demo`, `wasi-demo-p3`) you can crib
from.

## What the pipeline looks like

For a component without WASI deps:

1. Run `zig_wasi_components gen <wit-file> <world>` and capture
   stdout into a generated `bindings.zig`.
2. Compile `component.zig` (which imports the generated bindings)
   to a `wasm32-freestanding` core module.
3. Run `wasm-tools component embed <wit-file> <core.wasm>` to add
   the component-type custom section.
4. Run `wasm-tools component new <embedded.wasm>` to wrap it as a
   component.
5. Install the final `.component.wasm` to the output prefix.

For a component with WASI deps, step 1 is preceded by:

1a. Run `wasm-tools component wit <wit-dir>` and capture stdout
    into `resolved.wit`. Then feed that file to `gen`.

The build-integration template below covers both cases — comment in
the dep-resolution step when you need it.

## Depend on `zig-wasi-components` from your project

Add the dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_wasi_components = .{
        .url = "https://example.invalid/zig-wasi-components.tar.gz",
        .hash = "...",
    },
},
```

For local development, swap `.url`/`.hash` for `.path = "../zig-wasi-components"`
(or wherever you have the project checked out).

## Template `build.zig`

This is the minimum that builds one component end-to-end. Replace
`my-world`, `my-package.wit`, and `src/component.zig` with your own
file paths.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zwc = b.dependency("zig_wasi_components", .{
        .target = target,
        .optimize = optimize,
    });
    const zwc_mod = zwc.module("zig_wasi_components");
    const gen_exe = zwc.artifact("zig_wasi_components");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // 1. Generate bindings.zig from the WIT.
    const gen = b.addRunArtifact(gen_exe);
    gen.addArg("gen");
    gen.addFileArg(b.path("wit/my-package.wit"));
    gen.addArg("my-world");
    const bindings = gen.captureStdOut(.{ .basename = "bindings.zig" });

    // 2. Compile component.zig + bindings → core wasm module.
    const guest_mod = b.createModule(.{
        .root_source_file = b.path("src/component.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = zwc_mod },
        },
    });
    guest_mod.addAnonymousImport("bindings", .{
        .root_source_file = bindings,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = zwc_mod },
        },
    });

    const guest = b.addExecutable(.{
        .name = "my-component",
        .root_module = guest_mod,
    });
    guest.entry = .disabled;
    guest.rdynamic = true;

    // 3. wasm-tools component embed (adds the component-type section).
    const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    embed.addFileArg(b.path("wit/my-package.wit"));
    embed.addArtifactArg(guest);
    const embedded = embed.addPrefixedOutputFileArg("-o", "embedded.wasm");

    // 4. wasm-tools component new (final component).
    const new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    new.addFileArg(embedded);
    const component = new.addPrefixedOutputFileArg("-o", "my-component.component.wasm");

    // 5. Install to zig-out/wasm/.
    const install = b.addInstallFile(component, "wasm/my-component.component.wasm");
    const step = b.step("component", "Build the component");
    step.dependOn(&install.step);
}
```

Running `zig build component` produces
`zig-out/wasm/my-component.component.wasm`.

## Template extension: WASI deps

If your WIT has a `deps/` tree, add a `wasm-tools component wit`
step that resolves it into a single file, and feed that file to
`gen` instead of the raw WIT. The full pattern from `build.zig`
in this repo is:

```zig
const resolve = b.addSystemCommand(&.{ "wasm-tools", "component", "wit" });
resolve.addDirectoryArg(b.path("wit"));
addWitTreeAsInputs(b, resolve, "wit");
const resolved = resolve.captureStdOut(.{ .basename = "resolved.wit" });

const gen = b.addRunArtifact(gen_exe);
gen.addArg("gen");
gen.addFileArg(resolved);     // not a static path — the captured output
gen.addArg("my-world");
const bindings = gen.captureStdOut(.{ .basename = "bindings.zig" });
```

The `embed` step also needs the directory (not the resolved file)
plus a `--world` selector:

```zig
const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
embed.addDirectoryArg(b.path("wit"));
embed.addArtifactArg(guest);
embed.addArgs(&.{ "--world", "demo:mypackage/my-world" });
addWitTreeAsInputs(b, embed, "wit");
const embedded = embed.addPrefixedOutputFileArg("-o", "embedded.wasm");
```

## Why `addWitTreeAsInputs` is necessary

`addDirectoryArg` only registers the directory entry as a build
input, not the files underneath. If you edit a `.wit` inside `deps/`,
Zig's build cache does not see the change and happily reuses the
stale embedded.wasm. The helper at the top of `build.zig` walks the
tree at configure time and registers every `.wit` file as an
explicit input.

You can lift the helper into your own `build.zig` verbatim:

```zig
fn addWitTreeAsInputs(b: *std.Build, run: *std.Build.Step.Run, rel_root: []const u8) void {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, rel_root, .{ .iterate = true }) catch |e|
        std.debug.panic("addWitTreeAsInputs: cannot open '{s}': {t}", .{ rel_root, e });
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch |e|
        std.debug.panic("addWitTreeAsInputs: walker init failed: {t}", .{e});
    defer walker.deinit();
    while (true) {
        const maybe_entry = walker.next(io) catch |e|
            std.debug.panic("addWitTreeAsInputs: walker step failed: {t}", .{e});
        const entry = maybe_entry orelse break;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wit")) continue;
        const rel = b.fmt("{s}/{s}", .{ rel_root, entry.path });
        run.addFileInput(b.path(rel));
    }
}
```

## Why `exe.entry = .disabled` and `exe.rdynamic = true`

Components do not have a `main`. The first line tells the Zig wasm
linker not to require one. The second tells it to keep every
publicly exported symbol in the output even when it appears
unused — which is exactly the case for `cabi_realloc`, every
`export fn`, and every `cabi_post_*`.

Without `rdynamic = true`, the linker strips the exports and
`wasm-tools component embed` either fails or produces a component
that crashes on first invocation.

## Where to find the canonical template

Read `build.zig` at the repo root. The `demo`, `dual`, `resource`,
and `async-basic` steps each implement the dep-less variant; the
`http-get` and `wasi-demo` steps implement the WASI dep-tree
variant. Each one is well isolated and self-contained. Lifting any
of them into a fresh project is straight copy-paste with the file
paths swapped.

The `wasi-demo-p3` step shows a third option: when the WIT is
already a single fully-resolved file (no `deps/` tree), the whole
gen → compile → embed → `component new` pipeline collapses into the
`addComponent` helper at the top of `build.zig`, driven by a small
`ComponentSpec` literal (name, root source, WIT path, world). If
your project builds several components from pre-resolved WIT files,
that helper is the thing to lift.
