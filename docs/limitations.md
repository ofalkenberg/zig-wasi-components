# Limitations

The project covers every stable canonical-ABI feature in WIT 0.2.x and
0.3.x.

A few corner cases remain.
They depend on upstream movement, conflict with the current
specification, or lack a shipping consumer for validation.

Read this list before opening an issue.
Each section names the files that need changes.

## Flags with more than 32 labels

The canonical ABI specification (`CanonicalABI.md`, `alignment_flags`
and `elem_size_flags`) asserts `0 < n <= 32`.
The generator follows this limit.
It returns `error.Unsupported` past that boundary in `src/codegen.zig`.

If you need more bits, split them across multiple `flags` types.
You can also model them with a record of `bool` fields.
Both options are specification-compliant.

## Multi-named result tuples

WIT historically allowed returns such as
`func() -> (a: u32, b: string)`.
This form is a tuple-like return with a name for each element.

WIT removed this syntax.
Modern `wasm-tools` rejects it.
The parser also rejects it at parse time.
Use a `record` return type instead.

## Multi-result returns on imports and resource methods

`emitImportDecl` and `emitResourceExports` still emit `@compileError`
for `func() -> (a: T1, b: T2, …)` multi-result returns.

The parser rejects that syntax before code generation.
This matches modern `wasm-tools`.
Use a `record` return type or a named single result.

## HTTP request bodies in the `wasi3` convenience module

`wasi3.http.fetch` supports methods and headers but not request bodies.
`Request` has no `body` field.
The missing field makes this gap a compile error, not a runtime surprise.

The blocking wrapper cannot provide request bodies.
The WASI 0.3 host only responds after the request body stream is dropped.
The body can only be written while `client.send` is in flight.
Those operations must interleave.

Use the state-machine async export form instead.
See [bindings.md](bindings.md).

For request bodies today, drive `wasi:http/types@0.3.1` through the
generated bindings and their `intrinsics_*` namespaces.
Call them from a state-machine export.
The 0.2 module's `wasi.http.fetch` still supports bodies.

## File-watching and incremental code generation

The CLI is single-shot.
Each run reparses the WIT and reemits the full bindings.

This is suitable for component projects because WIT changes infrequently.
An LSP-style server would help people editing WIT in a tight loop.
It is not planned.

## CLI ergonomics

The CLI has no `--help` flag, version subcommand, or machine-readable
output mode.
The `dump` and `gen` subcommands, with their exit codes, are the full
surface.

To script the generator, run it with the file and world.
Parse stderr for errors.
The exit code is non-zero on any failure.
