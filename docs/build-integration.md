# Build-system integration

Use `zig build` to generate bindings, compile Zig, and run `wasm-tools`.
Doing those steps by hand is fine while you're trying things out, but it gets tedious once your project grows past a few files.

This page has a complete `build.zig` template you can paste into your project.

The bundled examples use the same pattern.
The root `build.zig` is the reference implementation, with eight working variants:

- `demo`
- `dual`
- `resource`
- `http-get`
- `async-basic`
- `stream-demo`
- `wasi-demo`
- `wasi-demo-p3`

## What the pipeline looks like

For a component without WASI dependencies, the steps are:

1. Run `zig_wasi_components gen <wit-file> <world>` and capture
   stdout into a generated `bindings.zig`.
2. Compile `component.zig` (which imports the generated bindings)
   to a `wasm32-freestanding` core module.
3. Run `wasm-tools component embed <wit-file> <core.wasm>` to add
   the component-type custom section.
4. Run `wasm-tools component new <embedded.wasm>` to wrap it as a
   component.
5. Install the final `.component.wasm` to the output prefix.

If your component has WASI dependencies, do this before step 1:

1a. Run `wasm-tools component wit <wit-dir>` and capture stdout
    into `resolved.wit`. Then feed that file to `gen`.

The template below covers both cases.
Add the dependency-resolution step when you need it.

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

For local development, replace `.url` and `.hash` with
`.path = "../zig-wasi-components"`.
Use the path where you checked out the project.

## Template `build.zig`

This is the minimum you need to build one component end to end.
Replace these with your own world name and file paths:

- `my-world`
- `my-package.wit`
- `src/component.zig`

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

    // 2. Compile component.zig + bindings into a core wasm module.
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

Run `zig build component` and you'll get `zig-out/wasm/my-component.component.wasm`.

## Template extension: WASI deps

If your WIT has a `deps/` tree, add a `wasm-tools component wit` step.
It resolves the tree into a single file, which you pass to `gen` instead of the raw WIT.

Here's the full pattern from this repository's `build.zig`:

```zig
const resolve = b.addSystemCommand(&.{ "wasm-tools", "component", "wit" });
resolve.addDirectoryArg(b.path("wit"));
addWitTreeAsInputs(b, resolve, "wit");
const resolved = resolve.captureStdOut(.{ .basename = "resolved.wit" });

const gen = b.addRunArtifact(gen_exe);
gen.addArg("gen");
gen.addFileArg(resolved);     // Captured output, not a static path.
gen.addArg("my-world");
const bindings = gen.captureStdOut(.{ .basename = "bindings.zig" });
```

The `embed` step can take the same resolved file:

```zig
const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
embed.addFileArg(resolved);
embed.addArtifactArg(guest);
embed.addArgs(&.{ "--world", "demo:mypackage/my-world" });
const embedded = embed.addPrefixedOutputFileArg("-o", "embedded.wasm");
```

You only need `--world` when your package declares more than one world, but it's fine to name it either way.
This repository's `build.zig` passes the `wit` directory to `embed`
instead, with a second `addWitTreeAsInputs` call.
Both work.

## Why `addWitTreeAsInputs` is necessary

`addDirectoryArg` registers the directory entry as a build input.
It doesn't register the files inside it.

If you edit a `.wit` file inside `deps/`, Zig's build cache misses the
change.
It then reuses the old `resolved.wit` and everything built from it.

The helper at the top of `build.zig` walks the tree at configure time.
It registers every `.wit` file as an explicit input.

You can copy the helper straight into your own `build.zig`:

```zig
fn addWitTreeAsInputs(b: *std.Build, run: *std.Build.Step.Run, rel_root: []const u8) void {
    const io = b.graph.io;
    var dir = b.root.openDir(io, rel_root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => std.debug.panic("addWitTreeAsInputs: cannot open '{s}': {t}", .{ rel_root, e }),
    };
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

Components don't have a `main`.
The first line tells the Zig wasm linker not to require one.
The second keeps every public export, even if it looks unused.

That includes:

- `cabi_realloc`
- every `export fn`
- every `cabi_post_*`

Without `rdynamic = true`, the core module exports nothing but its
memory, and `wasm-tools component new` rejects it with
`failed to find export of function ...`.

## Where to find the canonical template

Look in the root `build.zig`.
These steps use the version without dependencies:

- `demo`
- `dual`
- `resource`
- `async-basic`
- `stream-demo`

These use the WASI dependency-tree version:

- `http-get`
- `wasi-demo`

Each step works on its own.
You can copy one into a new project and change the file paths.

The `wasi-demo-p3` step shows a third option, for WIT that's already fully resolved in one file without a `deps/` tree.
The `addComponent` helper handles code generation, compilation, embedding, and `component new`.

A small `ComponentSpec` literal supplies:

- the name
- the root source
- the WIT path
- the world

Copy that helper if your project builds several components from
pre-resolved WIT files.
