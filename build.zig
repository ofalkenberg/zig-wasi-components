const std = @import("std");

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
        // Follow symlinks to plain files so symlinked .wit deps also
        // register as inputs.
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wit")) continue;
        const rel = b.fmt("{s}/{s}", .{ rel_root, entry.path });
        run.addFileInput(b.path(rel));
    }
}

const ComponentSpec = struct {
    name: []const u8,
    root_source: []const u8,
    wit: []const u8,
    world: []const u8,
};

const Component = struct {
    file: std.Build.LazyPath,
    /// The `wasm-tools component new` step — depend on this to get
    /// validation without installing the artifact.
    new_step: *std.Build.Step,
};

/// The standard pipeline for an example whose WIT is a single
/// fully-resolved file: generate bindings, compile the guest to a
/// wasm32-freestanding core module, `wasm-tools component embed`, and
/// validate with `wasm-tools component new`.
fn addComponent(
    b: *std.Build,
    gen_exe: *std.Build.Step.Compile,
    mod: *std.Build.Module,
    wasm_target: std.Build.ResolvedTarget,
    spec: ComponentSpec,
) Component {
    const gen = b.addRunArtifact(gen_exe);
    gen.addArg("gen");
    gen.addFileArg(b.path(spec.wit));
    gen.addArg(spec.world);
    const bindings = gen.captureStdOut(.{ .basename = "bindings.zig" });

    const guest_mod = b.createModule(.{
        .root_source_file = b.path(spec.root_source),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    guest_mod.addAnonymousImport("bindings", .{
        .root_source_file = bindings,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    const guest = b.addExecutable(.{
        .name = spec.name,
        .root_module = guest_mod,
    });
    guest.entry = .disabled;
    guest.rdynamic = true;

    const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    embed.addFileArg(b.path(spec.wit));
    embed.addArtifactArg(guest);
    embed.addArgs(&.{ "--world", spec.world });
    const embedded = embed.addPrefixedOutputFileArg("-o", b.fmt("{s}.embedded.wasm", .{spec.name}));
    const new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    new.addFileArg(embedded);
    const component = new.addPrefixedOutputFileArg("-o", b.fmt("{s}.component.wasm", .{spec.name}));
    return .{ .file = component, .new_step = &new.step };
}

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zig_wasi_components", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zig_wasi_components",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zig_wasi_components" is the name you will use in your source code to
                // import this module (e.g. `@import("zig_wasi_components")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zig_wasi_components", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ----- demo: build the greeter component end-to-end -----
    //
    // 1. Run the codegen exe to produce `bindings.zig` from `greeter.wit`.
    // 2. Compile `component.zig` (which imports the generated bindings)
    //    to a wasm32-freestanding core module.
    // 3. Use `wasm-tools component embed` + `component new` to wrap
    //    the core module into a real WebAssembly component.
    //
    // This is the same workflow `cargo-component` / `wit-bindgen` use
    // for Rust, but driven entirely by `zig build`.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const gen_run = b.addRunArtifact(exe);
    gen_run.addArg("gen");
    gen_run.addFileArg(b.path("examples/greeter/greeter.wit"));
    gen_run.addArg("greeter");
    const bindings_path = gen_run.captureStdOut(.{ .basename = "bindings.zig" });

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/greeter/component.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    demo_mod.addAnonymousImport("bindings", .{
        .root_source_file = bindings_path,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });

    const demo_exe = b.addExecutable(.{
        .name = "greeter",
        .root_module = demo_mod,
    });
    demo_exe.entry = .disabled;
    demo_exe.rdynamic = true;

    const core_install = b.addInstallArtifact(demo_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });

    // wasm-tools component embed + new
    const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    embed.addFileArg(b.path("examples/greeter/greeter.wit"));
    embed.addArtifactArg(demo_exe);
    const embedded = embed.addPrefixedOutputFileArg("-o", "embedded.wasm");

    const new_cmd = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    new_cmd.addFileArg(embedded);
    const component_file = new_cmd.addPrefixedOutputFileArg("-o", "greeter.component.wasm");

    const install_component = b.addInstallFile(component_file, "wasm/greeter.component.wasm");

    const demo_step = b.step("demo", "Build the greeter component end-to-end");
    demo_step.dependOn(&core_install.step);
    demo_step.dependOn(&install_component.step);

    // ----- dual demo: Zig sibling of the Rust `math` component -----
    const gen_math = b.addRunArtifact(exe);
    gen_math.addArg("gen");
    gen_math.addFileArg(b.path("examples/dual/math.wit"));
    gen_math.addArg("math");
    const math_bindings = gen_math.captureStdOut(.{ .basename = "bindings.zig" });
    const math_mod = b.createModule(.{
        .root_source_file = b.path("examples/dual/zig-impl/component.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    math_mod.addAnonymousImport("bindings", .{
        .root_source_file = math_bindings,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    const math_exe = b.addExecutable(.{
        .name = "math",
        .root_module = math_mod,
    });
    math_exe.entry = .disabled;
    math_exe.rdynamic = true;

    const math_embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    math_embed.addFileArg(b.path("examples/dual/math.wit"));
    math_embed.addArtifactArg(math_exe);
    const math_embedded = math_embed.addPrefixedOutputFileArg("-o", "math.embedded.wasm");
    const math_new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    math_new.addFileArg(math_embedded);
    const math_component = math_new.addPrefixedOutputFileArg("-o", "math.component.wasm");
    const math_install = b.addInstallFile(math_component, "wasm/math.component.wasm");

    const dual_step = b.step("dual", "Build the math component (Zig) for the dual-language demo");
    dual_step.dependOn(&math_install.step);

    // ----- resource demo: a `counter` resource end-to-end -----
    const gen_res = b.addRunArtifact(exe);
    gen_res.addArg("gen");
    gen_res.addFileArg(b.path("examples/resource/resource.wit"));
    gen_res.addArg("counts");
    const res_bindings = gen_res.captureStdOut(.{ .basename = "bindings.zig" });
    const res_mod = b.createModule(.{
        .root_source_file = b.path("examples/resource/component.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    res_mod.addAnonymousImport("bindings", .{
        .root_source_file = res_bindings,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    const res_exe = b.addExecutable(.{
        .name = "counts",
        .root_module = res_mod,
    });
    res_exe.entry = .disabled;
    res_exe.rdynamic = true;

    const res_embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    res_embed.addFileArg(b.path("examples/resource/resource.wit"));
    res_embed.addArtifactArg(res_exe);
    const res_embedded = res_embed.addPrefixedOutputFileArg("-o", "counts.embedded.wasm");
    const res_new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    res_new.addFileArg(res_embedded);
    const res_component = res_new.addPrefixedOutputFileArg("-o", "counts.component.wasm");
    const res_install = b.addInstallFile(res_component, "wasm/counts.component.wasm");

    const res_step = b.step("resource", "Build the counter resource demo");
    res_step.dependOn(&res_install.step);

    // ----- http-get: wasi:cli `run` command that fetches a URL -----
    // `wasm-tools component wit` resolves the world plus every
    // transitive wasi dep from `wit/deps/` into a single multi-package
    // WIT document, which our codegen ingests directly. The guest then
    // imports `bindings` like the other examples — no hand-written
    // wasi-http externs anywhere.
    const http_resolve = b.addSystemCommand(&.{ "wasm-tools", "component", "wit" });
    http_resolve.addDirectoryArg(b.path("examples/http-get/wit"));
    addWitTreeAsInputs(b, http_resolve, "examples/http-get/wit");
    const http_resolved = http_resolve.captureStdOut(.{ .basename = "resolved.wit" });

    const http_gen = b.addRunArtifact(exe);
    http_gen.addArg("gen");
    http_gen.addFileArg(http_resolved);
    http_gen.addArg("client");
    const http_bindings = http_gen.captureStdOut(.{ .basename = "bindings.zig" });

    const http_mod = b.createModule(.{
        .root_source_file = b.path("examples/http-get/component.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    http_mod.addAnonymousImport("bindings", .{
        .root_source_file = http_bindings,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    const http_exe = b.addExecutable(.{
        .name = "http-get",
        .root_module = http_mod,
    });
    http_exe.entry = .disabled;
    http_exe.rdynamic = true;

    const http_embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    http_embed.addDirectoryArg(b.path("examples/http-get/wit"));
    http_embed.addArtifactArg(http_exe);
    http_embed.addArgs(&.{ "--world", "demo:httpget/client" });
    // addDirectoryArg only registers the directory entry, not the
    // tree underneath, so edits to world.wit or any wasi dep would
    // silently reuse a stale embedded.wasm. Walk the directory at
    // configure time and add every .wit file as an explicit input.
    addWitTreeAsInputs(b, http_embed, "examples/http-get/wit");
    const http_embedded = http_embed.addPrefixedOutputFileArg("-o", "http-get.embedded.wasm");
    const http_new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    http_new.addFileArg(http_embedded);
    const http_component = http_new.addPrefixedOutputFileArg("-o", "http-get.component.wasm");
    const http_install = b.addInstallFile(http_component, "wasm/http-get.component.wasm");

    const http_step = b.step("http-get", "Build the wasi:http GET example");
    http_step.dependOn(&http_install.step);

    // ----- wasi-demo: showcase the `wasi` convenience module -----
    // Reuses the wasi:cli/command + wasi:http imports already vendored
    // under examples/http-get/wit/deps (symlinked from this demo's
    // wit/ directory). The guest only uses helpers from src/wasi.zig.
    const wasi_resolve = b.addSystemCommand(&.{ "wasm-tools", "component", "wit" });
    wasi_resolve.addDirectoryArg(b.path("examples/wasi-demo/wit"));
    addWitTreeAsInputs(b, wasi_resolve, "examples/wasi-demo/wit");
    const wasi_resolved = wasi_resolve.captureStdOut(.{ .basename = "resolved.wit" });

    const wasi_gen = b.addRunArtifact(exe);
    wasi_gen.addArg("gen");
    wasi_gen.addFileArg(wasi_resolved);
    wasi_gen.addArg("demo");
    const wasi_bindings = wasi_gen.captureStdOut(.{ .basename = "bindings.zig" });

    const wasi_mod = b.createModule(.{
        .root_source_file = b.path("examples/wasi-demo/component.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    wasi_mod.addAnonymousImport("bindings", .{
        .root_source_file = wasi_bindings,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    const wasi_exe = b.addExecutable(.{
        .name = "wasi-demo",
        .root_module = wasi_mod,
    });
    wasi_exe.entry = .disabled;
    wasi_exe.rdynamic = true;

    const wasi_embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    wasi_embed.addDirectoryArg(b.path("examples/wasi-demo/wit"));
    wasi_embed.addArtifactArg(wasi_exe);
    wasi_embed.addArgs(&.{ "--world", "demo:wasidemo/demo" });
    addWitTreeAsInputs(b, wasi_embed, "examples/wasi-demo/wit");
    const wasi_embedded = wasi_embed.addPrefixedOutputFileArg("-o", "wasi-demo.embedded.wasm");
    const wasi_new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    wasi_new.addFileArg(wasi_embedded);
    const wasi_component = wasi_new.addPrefixedOutputFileArg("-o", "wasi-demo.component.wasm");
    const wasi_install = b.addInstallFile(wasi_component, "wasm/wasi-demo.component.wasm");

    const wasi_step = b.step("wasi-demo", "Build the wasi convenience-module demo");
    wasi_step.dependOn(&wasi_install.step);

    // ----- async-basic: async-with-callback canonical ABI end-to-end -----
    const gen_async = b.addRunArtifact(exe);
    gen_async.addArg("gen");
    gen_async.addFileArg(b.path("examples/async-basic/world.wit"));
    gen_async.addArg("demo");
    const async_bindings = gen_async.captureStdOut(.{ .basename = "bindings.zig" });
    const async_mod = b.createModule(.{
        .root_source_file = b.path("examples/async-basic/component.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    async_mod.addAnonymousImport("bindings", .{
        .root_source_file = async_bindings,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    const async_exe = b.addExecutable(.{
        .name = "async-basic",
        .root_module = async_mod,
    });
    async_exe.entry = .disabled;
    async_exe.rdynamic = true;

    const async_embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    async_embed.addFileArg(b.path("examples/async-basic/world.wit"));
    async_embed.addArtifactArg(async_exe);
    async_embed.addArgs(&.{ "--world", "demo:asyncdemo/demo" });
    const async_embedded = async_embed.addPrefixedOutputFileArg("-o", "async-basic.embedded.wasm");
    const async_new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    async_new.addFileArg(async_embedded);
    const async_component = async_new.addPrefixedOutputFileArg("-o", "async-basic.component.wasm");
    const async_install = b.addInstallFile(async_component, "wasm/async-basic.component.wasm");

    const async_step = b.step("async-basic", "Build the async-with-callback demo component");
    async_step.dependOn(&async_install.step);

    // ----- stream-demo: typed stream<u32> / stream<u64> end-to-end -----
    const gen_stream = b.addRunArtifact(exe);
    gen_stream.addArg("gen");
    gen_stream.addFileArg(b.path("examples/stream-demo/world.wit"));
    gen_stream.addArg("demo");
    const stream_bindings = gen_stream.captureStdOut(.{ .basename = "bindings.zig" });
    const stream_mod = b.createModule(.{
        .root_source_file = b.path("examples/stream-demo/component.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    stream_mod.addAnonymousImport("bindings", .{
        .root_source_file = stream_bindings,
        .imports = &.{
            .{ .name = "zig_wasi_components", .module = mod },
        },
    });
    const stream_exe = b.addExecutable(.{
        .name = "stream-demo",
        .root_module = stream_mod,
    });
    stream_exe.entry = .disabled;
    stream_exe.rdynamic = true;

    const stream_embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    stream_embed.addFileArg(b.path("examples/stream-demo/world.wit"));
    stream_embed.addArtifactArg(stream_exe);
    stream_embed.addArgs(&.{ "--world", "demo:streams/demo" });
    const stream_embedded = stream_embed.addPrefixedOutputFileArg("-o", "stream-demo.embedded.wasm");
    const stream_new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    stream_new.addFileArg(stream_embedded);
    const stream_component = stream_new.addPrefixedOutputFileArg("-o", "stream-demo.component.wasm");
    const stream_install = b.addInstallFile(stream_component, "wasm/stream-demo.component.wasm");

    const stream_step = b.step("stream-demo", "Build the typed stream<T> demo component");
    stream_step.dependOn(&stream_install.step);

    // ----- wasi-demo-p3: the `wasi3` convenience module against WASI 0.3.0 -----
    // The main guest targets the real `wasi:cli/command@0.3.0` world
    // (wit/cli.wit is the final upstream package set, fully resolved).
    // A second guest compiles the wasi3 http client wrappers against
    // `wasi:http/service@0.3.0` and is validated by `component new`
    // but not installed — no released runtime links the final
    // wasi:http 0.3.0 interfaces yet.
    const p3 = addComponent(b, exe, mod, wasm_target, .{
        .name = "wasi-demo-p3",
        .root_source = "examples/wasi-demo-p3/component.zig",
        .wit = "examples/wasi-demo-p3/wit/cli.wit",
        .world = "command",
    });
    const p3_install = b.addInstallFile(p3.file, "wasm/wasi-demo-p3.component.wasm");

    const p3http = addComponent(b, exe, mod, wasm_target, .{
        .name = "wasi-http-check",
        .root_source = "examples/wasi-demo-p3/http-check.zig",
        .wit = "examples/wasi-demo-p3/wit-http/http.wit",
        .world = "service",
    });

    const p3_step = b.step("wasi-demo-p3", "Build the wasi3 (WASI 0.3.0) convenience-module demo");
    p3_step.dependOn(&p3_install.step);
    p3_step.dependOn(p3http.new_step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
