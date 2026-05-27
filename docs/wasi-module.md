# The `wasi` convenience module

`src/wasi.zig` (re-exported as `zig_wasi_components.wasi`) wraps the
generated `wasi:cli`, `wasi:clocks`, `wasi:random`, `wasi:io`,
`wasi:filesystem`, `wasi:sockets` and `wasi:http` bindings into a
handful of functions that read the way you would expect them to. It
exists for the common case where you do not want to learn the
canonical-ABI resource lifecycle just to fetch a URL, read a file, or
look up a hostname.

## Wiring it up

The module is generic over the bindings type so it works against any
world that imports the relevant WASI interfaces:

```zig
const std = @import("std");
const bindings = @import("bindings");
const wasi = @import("zig_wasi_components").wasi.Wasi(bindings);
```

Because Zig only semantically analyses the helpers that are actually
called, you do not need every WASI interface in your world — only the
ones whose helpers you reach for.

## What is in there

```zig
// Clocks
const ts   = wasi.clock.now();               // wasi:clocks/wall-clock
const sec  = wasi.clock.unixSeconds();       // fractional seconds
const t0   = wasi.clock.monotonic();         // nanoseconds, monotonic
wasi.clock.sleepMillis(50);
wasi.clock.sleepNanos(1_000_000);
wasi.clock.sleepUntil(t0 + 5 * std.time.ns_per_s);

// Randomness
var seed: [32]u8 = undefined;
wasi.random.bytes(&seed);                    // CSPRNG
const owned = try wasi.random.alloc(gpa, 64);
const n     = wasi.random.int();             // u64
const cheap = wasi.random.insecure.int();    // non-CSPRNG

// Stdio (returns error.StreamClosed / error.StreamFailed)
try wasi.stdout.print("answer = {d}\n", .{42});
try wasi.stderr.write("oh no\n");
const input = try wasi.stdin.read(gpa, 4096);

// Environment, args, cwd
for (wasi.environment.args()) |arg| { ... }
if (wasi.environment.get("HOME")) |home| { ... }

// Exit (does not return)
wasi.exit.success();

// Files (paths are resolved against host preopens — the longest
// matching prefix wins, the rest is treated as a sandboxed relative
// path, so "/tmp/foo.txt" works when wasmtime was started with
// `--dir /tmp`).
try wasi.fs.writeFile("/tmp/hello.txt", "hi\n");
const text = try wasi.fs.readFile(gpa, "/tmp/hello.txt");
defer gpa.free(text);
if (wasi.fs.exists("/tmp/hello.txt")) { ... }
const meta = try wasi.fs.stat("/tmp/hello.txt"); // .kind, .size, .modified_seconds
try wasi.fs.mkdir("/tmp/new-dir");
try wasi.fs.rename("/tmp/a", "/tmp/b");           // same preopen on both sides
try wasi.fs.remove("/tmp/hello.txt");             // unlink a file
try wasi.fs.rmdir("/tmp/new-dir");
const entries = try wasi.fs.listDir(gpa, "/tmp"); // []Entry { kind, name }
for (wasi.fs.preopens()) |p| { ... }              // (descriptor, host path)

// DNS + TCP
const ips = try wasi.net.resolve(gpa, "example.com");
defer gpa.free(ips);
var conn = try wasi.net.connectTcp(ips[0], 80);
defer conn.close();
try conn.write("GET / HTTP/1.0\r\n\r\n");
const reply = try conn.readAll(gpa, 4096);
defer gpa.free(reply);

// HTTP
const body = try wasi.http.get(gpa, "https://example.com/");
defer gpa.free(body);

// Is anyone watching?
if (wasi.terminal.isStdoutTty()) { ... }

var resp = try wasi.http.fetch(gpa, .{
    .method = .post,
    .url = "https://api.example.com/things",
    .headers = &.{ .{ .name = "content-type", .value = "application/json" } },
    .body = "{\"hello\":\"world\"}",
});
defer resp.deinit();
// resp.status (u16), resp.headers ([]Header), resp.body ([]u8)
```

`stdout.print` / `stderr.print` format into a 4 KiB stack buffer; for
larger output build the slice yourself and call `write`.

## The world your component needs

For the full surface above:

```wit
world demo {
  include wasi:cli/command@0.2.6;
  import wasi:http/outgoing-handler@0.2.6;
  import wasi:http/types@0.2.6;
}
```

The `wasi:cli/command` include drags in stdio, clocks, randomness,
environment, exit and filesystem; the two extra imports add outbound
HTTP. If your component does not make HTTP requests, drop the
`wasi:http` lines — the wrapper's HTTP helpers will simply remain
uncompiled.

## End-to-end example

`examples/wasi-demo/` is a complete `wasi:cli/command` component that
walks through every helper category and finishes with a live GET of
`https://example.com/`. Build and run it with:

```bash
zig build wasi-demo
wasmtime run \
    -S http=y -S allow-ip-name-lookup \
    --env HOME=/home/user --dir /tmp \
    zig-out/wasm/wasi-demo.component.wasm hello world
```

`-S http=y` enables outbound HTTP, `-S allow-ip-name-lookup` enables
the DNS resolver, and `--dir /tmp` mounts `/tmp` as the only writable
preopen. The output walks through every helper category: wall + unix
time, sixteen hex random bytes, a random `u64`, a ~50 ms monotonic
sleep, the argv, `HOME`, the tty probes, the list of preopens, a
file write/read/stat/listDir/remove round-trip, a DNS lookup of
`example.com` returning both v4 and v6 addresses, and finally a 200
response with nine headers from `https://example.com/` plus the
first 200 bytes of the HTML body.

## WASI 0.3: the `wasi3` module

WASI 0.3 redesigned I/O around component-model `stream<T>` and
`future<T>` values: `wasi:io` is gone, stdio and file contents travel
through streams, and most filesystem and socket operations are `async
func`s. `src/wasi3.zig` (re-exported as `zig_wasi_components.wasi3`)
is the 0.3 counterpart of this module with the same blocking,
allocator-friendly surface:

```zig
const wasi3 = @import("zig_wasi_components").wasi3.Wasi3(bindings);

try wasi3.stdout.print("now = {d}\n", .{wasi3.clock.monotonic()});
wasi3.clock.sleepMillis(50);             // async wasi:clocks wait-for
try wasi3.fs.writeFile("out.txt", "hi"); // stream<u8> + result future
const text = try wasi3.fs.readFile(gpa, "out.txt");
const entries = try wasi3.fs.listDir(gpa, "."); // stream<directory-entry>
const ips = try wasi3.net.resolve(gpa, "example.com");
const body = try wasi3.http.get(gpa, "http://example.com/");
```

Differences from the 0.2 wrapper worth knowing:

- `clock.now()` returns the 0.3 `system-clock` instant whose seconds
  are signed; sleeps go through the async `monotonic-clock.wait-until`
  / `wait-for` imports (the generated bindings block on the subtask
  for you).
- Every stream-carrying operation follows the 0.3 pattern: write the
  payload, drop the writable end, then await the operation's result
  future. The helpers do this dance internally and surface a plain
  `StreamError` / `FsError`.
- `wasi3.http.fetch` supports methods and headers but not request
  bodies yet — streaming a body requires interleaving writes with the
  in-flight `client.send` call, which needs the state-machine async
  export form rather than a blocking helper.
- TCP connections issue one `send` stream and one `receive` stream per
  socket (`connectTcp` sets both up; `write`/`readAll`/`close` work as
  before). There is no `instance-network` authority in 0.3.

`examples/wasi-demo-p3/` is a complete `wasi:cli/command@0.3.0`
component exercising the module (`zig build wasi-demo-p3`; the step
also compile-checks the http client wrappers against
`wasi:http/service@0.3.0` and validates both with `wasm-tools
component new`). Note that released runtimes still vendor the March
2026 release candidate of WASI 0.3 — identical shapes, different
version string — so components built against final `@0.3.0` will not
link against wasmtime ≤ 47 yet. The demo was validated end-to-end
under wasmtime 45/47 by rebuilding the identical guest against the
rc-versioned WIT; once a runtime ships the final packages the
installed demo runs as-is:

```bash
wasmtime run -S p3,inherit-network=y,allow-ip-name-lookup=y \
    -W component-model-async,component-model-more-async-builtins \
    --dir . --invoke 'run()' zig-out/wasm/wasi-demo-p3.component.wasm
```

## Path resolution

`wasi:filesystem` does not expose absolute filesystem paths: every
operation works through a `descriptor` for a preopened directory. The
`wasi.fs` helpers hide this by walking the list returned by
`wasi:filesystem/preopens.get-directories()` and picking the longest
preopen path that is a prefix of yours. So if wasmtime was started
with `--dir /tmp`, `wasi.fs.readFile(gpa, "/tmp/foo")` opens `foo`
relative to the `/tmp` descriptor; anything that does not land under
a preopen returns `error.NotPreopened`. Paths inside a preopen must
not escape it — the host will reject `..` segments that climb above
the root with `error.FsAccess`.
