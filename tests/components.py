#!/usr/bin/env python3
"""Compile generated bindings, validate components, and exercise the ABI."""

import argparse
from pathlib import Path
import subprocess
import tempfile

MODES = ("Debug", "ReleaseSmall")

WASMTIME_FEATURES = (
    "component-model-implements,component-model-async,"
    "component-model-more-async-builtins,component-model-async-stackful,"
    "component-model-fixed-length-lists"
)


def run(*args):
    result = subprocess.run(
        [str(arg) for arg in args], capture_output=True, text=True, timeout=60
    )
    if result.returncode:
        raise RuntimeError(
            f"Command failed: {' '.join(str(arg) for arg in args)}\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout


def invoke(component, call, expected):
    actual = run("wasmtime", "run", "-W", WASMTIME_FEATURES,
                 "--invoke", call, component).strip()
    if actual != expected:
        raise AssertionError(f"{call}: expected {expected!r}, got {actual!r}")


class World:
    """One world of one fixture. Neither the WIT check nor the bindings
    depend on the optimisation mode, so both run once."""

    def __init__(self, repo, generator, work, source, world, wit):
        self.repo = repo
        self.work = work
        self.source = source
        self.world = world
        self.wit = wit
        # The reference parser must accept the input before it tests our generator.
        run("wasm-tools", "component", "wit", wit)
        self.bindings = work / f"{source}.bindings.zig"
        self.bindings.write_text(run(generator, "gen", wit, world))

    def build(self, mode):
        tests = self.repo / "tests"
        out = self.work / f"{self.source}-{mode}"
        out.mkdir()
        core = out / "core.wasm"
        run(
            "zig", "build-exe", "-target", "wasm32-freestanding", "-O", mode,
            "-fno-entry", "-rdynamic",
            "--dep", "bindings", "--dep", "zig_wasi_components",
            f"-Mroot={tests / (self.source + '.zig')}",
            "--dep", "zig_wasi_components", f"-Mbindings={self.bindings}",
            f"-Mzig_wasi_components={self.repo / 'src/root.zig'}",
            f"-femit-bin={core}",
        )
        embedded = out / "embedded.wasm"
        run("wasm-tools", "component", "embed", self.wit, core,
            "--world", self.world, "-o", embedded)
        component = out / "component.wasm"
        run("wasm-tools", "component", "new", embedded, "-o", component)
        run("wasm-tools", "validate", "--features", "all", component)
        return component


class Pair:
    """A guest whose imports are answered by a second component built
    from the same WIT."""

    def __init__(self, repo, generator, work, name, no_imports=True):
        wit = repo / "tests" / f"{name}.wit"
        self.name = name
        self.work = work
        self.no_imports = no_imports
        self.guest = World(repo, generator, work, name, "demo", wit)
        self.provider = World(repo, generator, work, f"{name}-provider",
                              "provider", wit)

    def link(self, mode):
        guest = self.guest.build(mode)
        provider = self.provider.build(mode)
        linked = self.work / f"{self.name}-linked-{mode}.wasm"
        imports = ("--no-imports",) if self.no_imports else ()
        run("wasm-tools", "compose", guest, "-d", provider, *imports, "-o", linked)
        return linked


class Chain(Pair):
    """Exercise exports that receive another component's resource handles."""

    def __init__(self, repo, generator, work, name):
        super().__init__(repo, generator, work, name)
        wit = repo / "tests" / f"{name}.wit"
        self.middle = World(repo, generator, work, f"{name}-middle", "middle", wit)

    def link(self, mode):
        guest = self.guest.build(mode)
        config = self.work / f"{self.name}-{mode}.yml"
        config.write_text(
            "instantiations:\n"
            "  root:\n"
            "    arguments:\n"
            f"      test:{self.name}/i: provider\n"
            f"      test:{self.name}/user: middle\n"
            "  middle:\n"
            "    dependency: middle\n"
            "    arguments:\n"
            f"      test:{self.name}/i: provider\n"
            "  provider:\n"
            "    dependency: provider\n"
            "dependencies:\n"
            f"  middle: {self.middle.build(mode)}\n"
            f"  provider: {self.provider.build(mode)}\n"
        )
        linked = self.work / f"{self.name}-linked-{mode}.wasm"
        run("wasm-tools", "compose", guest, "-c", config, "-o", linked)
        return linked


SCOPE_VALUE = "{prefix: 7, x: 4294967297, kind: large}"

SCOPE_CALLS = (
    ("test:scopes/first.echo({value: 255, kind: large})", "{value: 255, kind: large}"),
    ("renamed.echo({value: 4294967297, kind: large})", "{value: 4294967297, kind: large}"),
    (f"test:scopes/api.echo(some({SCOPE_VALUE}))", f"some({SCOPE_VALUE})"),
    ("test:scopes/api.echo(none)", "none"),
    (f"test:scopes/api.echo-list([{SCOPE_VALUE}, {SCOPE_VALUE}])", f"[{SCOPE_VALUE}, {SCOPE_VALUE}]"),
    ("test:scopes/api.echo-list([])", "[]"),
    (f"top-echo({SCOPE_VALUE})", SCOPE_VALUE),
    (f"inline-api.echo({SCOPE_VALUE})", SCOPE_VALUE),
    ("inline-api.local-echo({x: 4294967297})", "{x: 4294967297}"),
)

# The last two values count destructor calls to verify ownership.
BORROWS_RUN = "[4, 22, 20, 7, 20, 9, 124, 20, 11, 26, 21, 1300, 300, 1, 2]"

IDENTIFIER_CALLS = (
    ("run()", "2062"),
    ("switch(17, some(25))", "some(42)"),
    ("switch(17, none)", "none"),
)

OPTION_CALLS = (
    ("echo", ("none", "some(none)", "some(some(42))")),
    ("echo-deep", ("none", "some(none)", "some(some(none))", "some(some(some(none)))", "some(some(some(some(42))))")),
    ("echo-complex", ("none", "some(none)", "some(some(ok(42)))", 'some(some(err("oops")))')),
    ("echo-list", ("[]", "[none, some(none), some(some(42))]")),
    ("echo-outcomes", ("[]", '[ok(42), err("oops"), ok(4294967295)]')),
    ("echo-complex-list", ("[]", '[none, some(none), some(some(ok(42))), some(some(err("oops")))]')),
    ("echo-value", ("{before: 7, field: some(none), after: 4294967297}",)),
    ("echo-choice", ("empty", "wrap(none)", "wrap(some(none))", "wrap(some(some(42)))")),
    ("echo-many", ("(none, some(none), some(some(42)), none, some(none), some(some(7)))",)),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--generator", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    generator = (args.generator or repo / "zig-out/bin/zig_wasi_components").resolve()
    with tempfile.TemporaryDirectory(prefix="zig-wasi-components-") as directory:
        work = Path(directory)
        http_wit = work / "http.wit"
        http_wit.write_text(run("wasm-tools", "component", "wit", repo / "examples/wasi-demo/wit"))

        scopes = World(repo, generator, work, "scopes", "demo", repo / "tests/scopes.wit")
        http = World(repo, generator, work, "http-finish", "demo", http_wit)
        identifiers = Pair(repo, generator, work, "identifiers")
        # A world `use` declaration retains structural type imports.
        options = Pair(repo, generator, work, "options", no_imports=False)
        simple = [Pair(repo, generator, work, name) for name in ("resources", "async-types", "shadowing")]
        borrows = Chain(repo, generator, work, "borrows")
        expected_run = {"resources": "4294967314", "async-types": "true", "shadowing": "54321"}

        for mode in MODES:
            component = scopes.build(mode)
            for call, expected in SCOPE_CALLS:
                invoke(component, call, expected)
            print(f"{mode}: scoped and renamed types round-trip", flush=True)

            linked = identifiers.link(mode)
            for call, expected in IDENTIFIER_CALLS:
                invoke(linked, call, expected)
            print(f"{mode}: keyword identifiers and imported calls round-trip", flush=True)

            for pair in simple:
                invoke(pair.link(mode), "run()", expected_run[pair.name])
                print(f"{mode}: {pair.name} run across component boundaries", flush=True)

            invoke(borrows.link(mode), "run()", BORROWS_RUN)
            print(f"{mode}: borrowed and owned handles cross export thunks", flush=True)

            linked = options.link(mode)
            invoke(linked, "run()", "true")
            for function, values in OPTION_CALLS:
                for value in values:
                    invoke(linked, f"{function}({value})", value)
            print(f"{mode}: options run across component boundaries", flush=True)

            run("wasmtime", "run", "-S", "http", http.build(mode))
            print(f"{mode}: HTTP body failure returns without double-drop", flush=True)


if __name__ == "__main__":
    main()
