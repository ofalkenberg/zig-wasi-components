# Limitations

The project covers nearly all of the canonical ABI for WIT 0.2.x and 0.3.x.
These are the known gaps.
Some come from the specification itself, and the others are missing because no real-world schema needs them yet.

Read this list before opening an issue.

## Stream and future intrinsics for synchronous exports

Imports and async exports that mention `stream<T>` or `future<T>` get an `intrinsics_*` namespace with the operations for each payload (see [bindings.md](bindings.md#stream-and-future-intrinsics)).
You don't get one for a synchronous export or a method of a resource you export.

No WASI world ships such a function, so there's nothing to validate an implementation against yet.
Make the export `async` if you need to create or read streams from it.

## Async methods on resources you export

An `async func` method on a resource you export is lifted as a plain synchronous function.
`wasm-tools` accepts the result, but the method can't suspend.
Async methods on resources you *import* work normally.

## Resource helpers when an interface is both imported and exported

If your world imports an interface and also exports it (`import counters; export counters;`, or under a name with `export main: counters;`), you don't get `new` / `rep` / `drop` helpers for the exported resources.
Constructors and method receivers still convert between handles and `*State` for you.
You lose the ability to pass your own resource as a plain `own<T>` parameter or result.

See [resources.md](resources.md#handles-to-your-own-resource).

## Flags with more than 32 labels

The canonical ABI specification (`CanonicalABI.md`, `alignment_flags` and `elem_size_flags`) asserts `0 < n <= 32`.
`wasm-tools` rejects a WIT file with bigger flags, so no component can use them anyway.
The generator fails with `error.Unsupported` when it finds one in a function signature.

If you need more bits, split them across multiple `flags` types.
You can also model them with a record of `bool` fields.

## Multi-named result tuples

WIT used to allow returns such as `func() -> (a: u32, b: string)`.
That's a tuple-like return with a name for each element.

WIT removed this syntax, and so did modern `wasm-tools`.
The parser rejects it too.
Use a `record` or `tuple` return type instead.

## HTTP request bodies in the `wasi3` convenience module

`wasi3.http.fetch` supports methods and headers but not request bodies.
`Request` has no `body` field, so if you try to send one, you'll get a compile error rather than a runtime surprise.

A blocking wrapper can't provide request bodies.
The WASI 0.3 host only responds after the request body stream is dropped, and you can only write the body while `client.send` is in flight.
So the two must interleave.

To send a body, use `wasi:http/types@0.3.2` through the generated bindings from a [state-machine async export](bindings.md#typed-state-machine-form).
The 0.2 module's `wasi.http.fetch` still supports bodies.

## CLI ergonomics

The CLI doesn't have:

- A `--help` flag.
- A version subcommand.
- A machine-readable output mode.

You get the `dump` and `gen` subcommands and their exit codes.

Parse errors name the problem, such as `UnexpectedToken`, but don't tell you where it is.
Run `wasm-tools component wit` on the same file to find the line.

`gen` doesn't check that everything a world imports or exports is actually in the file.
If an interface is missing from an unflattened WIT, it's silently left out of the bindings.
See [the WASI doc](wasi.md#why-interface-only-wit-files-do-not-work-directly).

To script the generator, run it with the file and world.
The exit code is non-zero on any failure, and errors go to stderr.

## File watching and incremental code generation

The CLI runs once and exits.
Each run parses the WIT again and writes out the full bindings.

That works for component projects because WIT doesn't change often.
An LSP-style server would help if you're editing WIT in a tight loop, but one isn't planned.
