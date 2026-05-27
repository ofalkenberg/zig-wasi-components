# http-get

A Zig wasi:http component built with this toolchain. The component
behaves like a tiny `curl`: it makes an HTTP `GET` against a hard-coded
URL, streams the response body, and writes it to stdout via
`wasi:cli/stdout`.

```
zig build http-get
wasmtime run -S http=y zig-out/wasm/http-get.component.wasm
```

Sample output:

```
<!doctype html><html lang="en"><head><title>Example Domain</title>
...
</body></html>
```

## How it differs from the other examples

The greeter, dual and resource examples each have a tiny custom WIT
world. `http-get` is the example that proves the codegen pipeline
scales to the full wasi-0.2.6 surface: resource handles passed as
`own<T>` arguments, tagged composite (`option<T>` / `result<T, E>`)
parameters and returns nested two or three deep, and the
`future-incoming-response` + `pollable.block()` flow for awaiting
an outbound response — all generated, none written by hand.

The full WIT tree comes from `wit/`, a verbatim copy of the
wasi-0.2.6 packages shipped with Wasmtime. `wasm-tools component
wit` resolves it into a single multi-package document at build
time, our codegen ingests that, and the resulting `bindings.zig` is
what `component.zig` `@import`s.

The `cabi_realloc` runtime backing comes from `src/abi.zig` (the
same arena allocator the other examples use).

## Layout

```
examples/http-get/
  component.zig    The guest. Imports the generated bindings and
                   uses them to drive the wasi:cli/run export.
  wit/
    world.wit      Our top-level world (`demo:httpget/client`).
    deps/          Verbatim copy of the wasi 0.2.6 packages
                   (cli, http, io, clocks, random, filesystem, sockets).
                   `wasm-tools component embed` resolves the
                   transitive imports out of here.
  README.md        This file.
```

## Toolchain pipeline

```
wasm-tools component wit ./wit/            # resolve the world + deps
  → zig-wit gen <resolved.wit> client      # our codegen → bindings.zig
  → zig build-exe component.zig + bindings → core wasm
  → wasm-tools component embed + new       → component
```

The generated module exposes each WIT interface as a nested Zig
namespace, e.g. `bindings.wasi_http_types.types.outgoing_request`
for the type, `bindings.wasi_http_types.resources.outgoing_request.new(headers)`
for the constructor, and `bindings.wasi_http_types.resources.outgoing_request.set_scheme(req, scheme)`
for methods. `use` clauses produce per-interface alias decls so
cross-interface references look like
`bindings.wasi_http_outgoing_handler.types.outgoing_request` rather
than reaching across the module path.

## A wasi:http quirk worth knowing

`wasi:http/outgoing-handler.handle(request, options)` takes
`options: option<request-options>`. Passing `None` works in
principle, but at least with Wasmtime 45 + wasi-http 0.2.6 it is
friendlier to allocate an empty `request-options` and pass
`Some(ro)`. The `request-options` handle is consumed by `handle`,
so no explicit drop.

## Limitations

- The URL is hard-coded as `https://example.com/`. Adding CLI-argument
  support is a matter of one more wasi binding
  (`wasi:cli/environment.get-arguments`).
- Only `GET` is exercised. `POST` would require building an
  `outgoing-body` and writing into its output-stream — same shape,
  more bindings.
- TLS verification is whatever Wasmtime's wasi-http implementation
  chooses to do; pass `-S http=y` and trust the system store.
