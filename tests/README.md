# Regression checks

Run the native tests and the component regressions from the repository root:

```sh
zig build test test-components
zig test src/root.zig -O ReleaseFast
```

`test-components` needs Python 3, `zig`, `wasm-tools`, and `wasmtime` on
`PATH`. It builds every fixture in Debug and ReleaseSmall, checks its WIT
with the reference parser, generates and compiles the Zig bindings, creates
and validates the component, and checks returned values in Wasmtime.
Imported calls use a second component as their implementation. Temporary
build files are removed when the runner exits. The HTTP failure fixture
fails while finishing its request body, before a network request is sent.

The following failures were reproduced against the original implementation
at `a01bf3d9264abe4f4cc2136481bd9856bc5c7a3b`. The fixes and their regression
coverage are deliberately tied to those failures.

1. **Named types resolved in the wrong interface.** Two exported interfaces
   defining different `item` records generated a thunk using the first
   interface's record for the second interface. Renaming a type through two
   `use` statements also failed with `UnknownType`. Resolving fields of a
   used record in the importing interface could change a `u64` field into
   that interface's same-named `u8` alias. Resolution now follows scoped
   aliases and retains the defining scope during every recursive ABI walk.
   World and inline-interface uses, including types from included worlds,
   are registered explicitly. Interface type references are qualified so
   world aliases cannot make them ambiguous. `scopes.wit` checks duplicate
   names, transitive renames, conflicting nested names, included worlds,
   inline interfaces, and values greater than `2^32`. The native resolver
   test checks the exact size, alignment, flat types, scope restoration,
   and rejection of an unrelated interface's name.

2. **Generated identifiers were invalid or collided.** A valid `%type`
   parameter produced `_a_@"type"`; `%align` and `%volatile` fields were
   unescaped; an exported `p0` parameter collided with its core ABI input;
   two exported resources named `item` both declared `_resource_new_item`;
   a `c-int` record became `c_int`, which shadows a Zig C-ABI primitive.
   Complete identifiers now convert dashes first, then run the result
   through Zig's identifier formatter. A snake name that lands on a
   keyword or a primitive still gets escaped. Identifier fragments are
   escaped only after composition where necessary, lifted parameters have
   the same private prefix as imported parameters, and constructor helpers
   include their interface's ABI name. `identifiers` exercises keyword
   fields, functions, and parameters in both directions. It also carries a
   `c-int` record and a `c-long` function that returns a list, so the
   escape holds for a type, a function, and a generated return type.
   `resources` constructs both resource types, checks their distinct values,
   and verifies one destructor call per resource.

3. **Nested and repeated stream/future indices were wrong.** The old walker
   numbered `stream<future<u64>>` as stream 0, future 1. Component creation
   failed with `stream.new requires a stream type`. A global visited set
   also skipped repeated uses of a named stream type. The walker now visits
   payloads before their enclosing handle and suppresses only cycles on
   the active path, matching the reference
   [wit-parser traversal](https://github.com/bytecodealliance/wasm-tools/blob/4a72fcd2edb281073b466798bc4e111be2823c82/crates/wit-parser/src/lib.rs#L1377-L1438).
   Each payload retains its defining type scope. The native test asserts
   all five indices for two nested occurrences plus a result. `async-types`
   creates and transfers the affected handles through composed components.

4. **Payloadless futures did not compile with `futureAwait`.** Their generated
   namespace has `T = void` but no `elem_size`, `elem_align`, or `lift`.
   `futureAwait` now uses a zero-byte buffer and produces a completed `void`
   value for that namespace. The native test distinguishes completion from
   cancellation; `async-types` delivers and awaits an actual payloadless
   future across components.

5. **Zero-size canonical reallocations trapped in Debug.** Incoming empty
   lists reached Zig's `rawAlloc`, which requires a positive size. Realloc
   now returns a non-null aligned dangling pointer for size zero, with old
   arena storage reclaimed at the existing reset point. The native test
   checks new allocations and shrinking to zero at alignments 1, 2, 4, and
   8. Empty and nonempty lists are both exercised in component calls. This
   preserves the alignment required by the
   [canonical ABI](https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md).

6. **Nested optional values silently lost a state.** An identity function
   for `option<option<u32>>` returned `none` when passed `some(none)`.
   A nested `null` literal inherited the outer optional type. Flat and
   memory lifting now give an optional payload its exact child type before
   wrapping it in the outer optional. The expected Zig type is propagated
   through aliases, records, variants, results, tuples, arrays, and lists;
   this also avoids manufacturing fresh anonymous union types. `options`
   checks every presence state through four optional layers, result
   payloads, lists, records, variants, fixed lists, indirect parameters,
   imported returns, and a future payload.

7. **Lists of anonymous results did not compile.** Lifting
   `list<result<u32, string>>` emitted several separate anonymous unions for
   its slice and buffer. Zig correctly rejected assigning one slice to the
   other. List lifting now derives the element type from the destination
   slice and reuses it for allocation, alignment, and element loads.
   `options` round-trips empty and mixed success/error lists, as well as
   lists containing nested optional results.

8. **Unterminated trailing block comments were accepted.** The parser
   accepted `package demo:x; world w {} /*`, while the reference parser
   rejected it. Trivia scanning now returns `UnexpectedEof` when comment
   nesting remains open. Native tests cover comments at the beginning,
   after a package, after a complete world, and nested comments, with a
   closed nested comment as a positive control.

9. **HTTP body errors caused a second resource drop.** Finishing a one-byte
   body with `Content-Length: 2` returned an error and consumed the body;
   the deferred error cleanup then dropped the consumed handle. Wasmtime
   trapped with `unknown handle index 2`. The ownership flag is now set
   before calling `finish`, whose argument is owned in the
   [vendored WIT contract](../examples/wasi-demo/wit/deps/http/types.wit).
   `http-finish.zig` verifies that this exact mismatch returns `BodyFailed`
   without trapping in either build mode.

Validation on 2026-09-10 used Zig `0.17.0-dev.2119+1bc892110`, wasm-tools
`1.258.0`, and the Wasmtime CLI `48.0.1`. Native Debug tests passed 72/72;
the library's ReleaseFast tests passed 71/71. Component regressions passed
in both modes. The existing examples built with:

```sh
zig build demo dual resource http-get wasi-demo async-basic stream-demo wasi-demo-p3
```

The existing Rust hosts passed for greeter, resource lifecycle, async calls,
and typed streams against the rebuilt components (their locked Wasmtime
versions are 45.0.0 and 45.0.2). The WASI-p2 and WASI-p3 commands passed
filesystem round trips, clock checks, and DNS lookups with network access
enabled, using temporary preopen directories. The WASI-p2 command also
completed its HTTPS request. The WASI-p3 HTTP service handled two concurrent
success requests and two concurrent error requests, all returning 200 with
the expected upstream-status headers. These runtime checks used:

```sh
wasmtime run -S p3,inherit-network,allow-ip-name-lookup \
  -W component-model-async,component-model-more-async-builtins,component-model-async-stackful \
  --dir "$temporary_directory::." zig-out/wasm/wasi-demo-p3.component.wasm
wasmtime serve -S p3,cli \
  -W component-model-async,component-model-more-async-builtins,component-model-async-stackful \
  --addr 127.0.0.1:8080 zig-out/wasm/wasi-http-check.component.wasm
```

These tests establish the listed counterexamples and their corrected
behavior. Full WASI-p3 conformance, exhaustive cancellation and scheduling
behavior, and all malformed ABI inputs remain unproven. The dual example's
Rust implementation and host were not run.
