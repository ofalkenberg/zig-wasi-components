# Limitations

The project covers everything in the canonical ABI that has stabilized
in the WIT 0.2.x / 0.3.x line. A handful of corners remain that
either depend on upstream movement, contradict the current spec, or
have no shipping consumer to validate them against.

Read this list before opening an issue. The files that would need
changes to close each gap are called out.

## Flags with more than 32 labels

The canonical ABI spec (`CanonicalABI.md`, `alignment_flags` and
`elem_size_flags`) explicitly asserts `0 < n <= 32`. We mirror that
and return `error.Unsupported` past that boundary in
`src/codegen.zig`. If you need a larger bag of bits, split into
multiple `flags` types or model them as a record of `bool` fields —
both are spec-legal alternatives.

## Multi-named result tuples

WIT historically allowed return types like
`func() -> (a: u32, b: string)` — a tuple-like return where each
element has a name. Modern `wasm-tools` rejects this at embed time,
so the `@compileError` we emit when we see one is unreachable in
any working build. The parser still accepts the syntax so older
files round-trip, but a `record` return type is the only
post-deprecation form you can actually ship.

## Multi-result returns on imports and resource methods

`emitImportDecl` and `emitResourceExports` still emit
`@compileError` for `func() -> (a: T1, b: T2, …)` style multi-
result returns. Modern `wasm-tools` rejects these at embed time
just like the multi-named tuple case, so the error path is
unreachable in shipping builds. Use a `record` return type or a
named single result.

## HTTP request bodies in the `wasi3` convenience module

`wasi3.http.fetch` supports methods and headers but not request
bodies — `Request` has no `body` field, so the gap is a compile
error rather than a runtime surprise. The blocking wrapper cannot
provide one: the WASI 0.3 host only responds once the request's
body stream is dropped, but the body can only be written while
`client.send` is already in flight, so the two have to interleave.
That requires the state-machine async export form (see
[bindings.md](bindings.md)) rather than a plain blocking call. If
you need a request body today, drive `wasi:http/types@0.3.0`
through the generated bindings and their `intrinsics_*` namespaces
directly from a state-machine export. The 0.2 module's
`wasi.http.fetch` supports bodies as before.

## File-watching and incremental codegen

The CLI is single-shot. Each run reparses the WIT and reemits the
full bindings. For component projects this is fine because the WIT
changes infrequently; for someone editing WIT in a tight loop, an
LSP-style server would be nicer. Not planned.

## CLI ergonomics

There is no `--help` flag, no version subcommand, no machine-
readable output mode. The two subcommands (`dump`, `gen`) and
their exit codes are the full surface. If you need to script
around the generator, run it with the file and world and parse
stderr for errors. The exit code is non-zero on any failure.
