# The `wasi` convenience module

`src/wasi.zig` wraps generated WASI bindings in a small set of familiar functions.
It's re-exported as `zig_wasi_components.wasi`.

You can use it to fetch a URL, read a file, or look up a hostname without first learning the canonical-ABI resource lifecycle.
It wraps these bindings:

- `wasi:cli`
- `wasi:clocks`
- `wasi:random`
- `wasi:io`
- `wasi:filesystem`
- `wasi:sockets`
- `wasi:http`

## Wiring it up

The module takes your bindings type as a parameter.
It works with any world that imports the relevant WASI interfaces:

```zig
const std = @import("std");
const bindings = @import("bindings");
const wasi = @import("zig_wasi_components").wasi.Wasi(bindings);
```

Zig only semantically analyzes the helpers you actually call, so you only need the interfaces those helpers use.

## What is in there

```zig
// Clocks
const ts   = wasi.clock.now();               // wasi:clocks/wall-clock
const sec  = wasi.clock.unixSeconds();       // fractional seconds
const t0   = wasi.clock.monotonic();         // nanoseconds, monotonic
wasi.clock.sleepMillis(50);
wasi.clock.sleepSeconds(1);
wasi.clock.sleepNanos(1_000_000);
wasi.clock.sleepUntil(t0 + 5 * std.time.ns_per_s);

// Randomness
var seed: [32]u8 = undefined;
wasi.random.bytes(&seed);                    // CSPRNG
const owned = try wasi.random.alloc(gpa, 64);
const n     = wasi.random.int();             // u64
const cheap = wasi.random.insecure.int();    // non-CSPRNG
wasi.random.insecure.bytes(&seed);

// Stdio (error.StreamClosed / error.StreamFailed)
try wasi.stdout.print("answer = {d}\n", .{42});
try wasi.stderr.write("oh no\n");
const input = try wasi.stdin.read(gpa, 4096); // up to 4096 bytes, stops at EOF

// Environment, args, cwd
for (wasi.environment.args()) |arg| { ... }
for (wasi.environment.vars()) |kv| { ... }   // .{ name, value }
if (wasi.environment.get("HOME")) |home| { ... }
if (wasi.environment.cwd()) |dir| { ... }

// Exit (does not return)
wasi.exit.success();                         // or failure(), withCode(u8)

// Files use host preopens. The longest matching prefix wins.
// The remaining path is sandboxed and relative. Therefore,
// "/tmp/foo.txt" works when wasmtime starts with `--dir /tmp`.
try wasi.fs.writeFile("/tmp/hello.txt", "hi\n");
try wasi.fs.appendFile("/tmp/hello.txt", "again\n");
const text = try wasi.fs.readFile(gpa, "/tmp/hello.txt");
defer gpa.free(text);
if (wasi.fs.exists("/tmp/hello.txt")) { ... }
const meta = try wasi.fs.stat("/tmp/hello.txt"); // .kind, .size, .modified_seconds
try wasi.fs.mkdir("/tmp/new-dir");
try wasi.fs.rename("/tmp/a", "/tmp/b");           // same preopen on both sides
try wasi.fs.remove("/tmp/hello.txt");             // unlink a file
try wasi.fs.rmdir("/tmp/new-dir");
const entries = try wasi.fs.listDir(gpa, "/tmp"); // []Entry { kind, name }
for (wasi.fs.preopens()) |p| { ... }              // (descriptor, guest path)

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

// Is anyone watching? (also isStderrTty, isStdinTty)
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

`stdout.print` / `stderr.print` format into a 4 KiB stack buffer.
Longer output fails with `error.NoSpaceLeft`, so build the slice
yourself and call `write` instead.

`wasi.clock` also has these helpers:

- `resolution`
- `monotonicResolution`
- `timezone` / `utcOffset`

To use the timezone helpers, your world needs the unstable `wasi:clocks/timezone` interface, and your host must provide it.

`Request` defaults to a `GET` with no headers and an empty body, so `.url` is the only field you need to set.

`wasi.net.Address` is a `v4` / `v6` union with `family()` and `format()` methods.

## The world your component needs

To use all the helpers above:

```wit
package demo:wasidemo@0.1.0;

world demo {
  include wasi:cli/command@0.2.6;
  import wasi:http/outgoing-handler@0.2.6;
  import wasi:http/types@0.2.6;
}
```

The `wasi:cli/command` include brings in:

- Stdio and terminal.
- Clocks and randomness.
- Environment and exit.
- Filesystem.
- Sockets (DNS and TCP).

The two extra imports add outbound HTTP.
If your component doesn't make HTTP requests, drop the `wasi:http` lines.
The wrapper's HTTP helpers will stay uncompiled.

## End-to-end example

```bash
zig build wasi-demo
wasmtime run \
    -S http=y -S allow-ip-name-lookup \
    --env HOME=/home/user --dir /tmp \
    zig-out/wasm/wasi-demo.component.wasm hello world
```

This builds and runs `examples/wasi-demo/`, a complete `wasi:cli/command` component.
It walks through most helper categories and finishes with a live GET of `https://example.com/`.

The flags set up the host:

- `-S http=y` enables outbound HTTP.
- `-S allow-ip-name-lookup` enables the DNS resolver.
- `--dir /tmp` mounts `/tmp` as the only writable preopen.

The output shows:

- Wall and unix time.
- Sixteen hex random bytes and a random `u64`.
- A ~50 ms monotonic sleep.
- The argv and `HOME`.
- The tty probes and the list of preopens.
- A file write/read/stat/listDir/remove round trip.

It ends with a DNS lookup of `example.com`, then a 200 response from `https://example.com/` with its headers and the first 200 bytes of the HTML body.

The demo doesn't open a raw TCP connection.
If your component calls `wasi.net.connectTcp`, also pass `-S inherit-network`.
Otherwise, socket creation fails with `error.CreateSocketFailed`.

## WASI 0.3: the `wasi3` module

WASI 0.3 redesigned I/O around component-model `stream<T>` and `future<T>` values.
`wasi:io` is gone, and stdio, file contents and TCP data travel through streams.

Most filesystem operations are `async func`s.
So are TCP `connect`, UDP `send` / `receive` and name resolution.

`src/wasi3.zig`, re-exported as `zig_wasi_components.wasi3`, is the 0.3 version of this module.
It gives you the same blocking, allocator-friendly API:

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

`wasi:cli/command@0.3.2` doesn't import `wasi:http`.
For the `http` helpers, add `import wasi:http/client@0.3.2;` and
`import wasi:http/types@0.3.2;` to your world, and pass `-S http` to
`wasmtime run`.

Here's what changes from the 0.2 wrapper:

- `clock.now()` returns the 0.3 `system-clock` instant whose seconds
  are signed; sleeps go through the async `monotonic-clock.wait-until`
  / `wait-for` imports (the generated bindings block on the subtask
  for you).
- Writes follow the 0.3 pattern: write the payload, drop the writable
  end, then await the operation's result future.
  Reads drain the stream, then check the future.
  The helpers handle those steps for you and return a plain `StreamError` / `FsError`.
- `wasi3.http.fetch` supports methods and headers but not request bodies yet.
  To stream a body, you need to interleave writes with the in-flight `client.send` call.
  That takes the state-machine async export form rather than a blocking helper.
- TCP connections issue one `send` stream and one `receive` stream per
  socket.
  `connectTcp` sets both up, and `write` / `readAll` / `close` work as
  before, except that they all take `*TcpStream`.
  There's no `instance-network` authority in 0.3.
- `fs.rename` doesn't check that both paths live under the same preopen.
  The 0.2 version returns `error.FsInvalid` in that case.
- `Stat.modified_seconds` is a `?i64` (it's a `?u64` in 0.2), and
  `clock.resolution()` returns nanoseconds as a `u64` instead of a
  `Datetime`.
- The timezone helpers are `timezoneId`, `utcOffset` (nanoseconds, as
  a `?i64`) and `timezoneDebugString`.

`zig build wasi-demo-p3` builds `examples/wasi-demo-p3/`, a complete `wasi:cli/command@0.3.2` component that exercises the module.
The step also builds an http guest against `wasi:http/service@0.3.2` and validates both with `wasm-tools component new`.

Wasmtime 46 and later run the demo as-is:

```bash
wasmtime run -S p3,inherit-network=y,allow-ip-name-lookup=y \
    -W component-model-async,component-model-more-async-builtins \
    --dir . --invoke 'run()' zig-out/wasm/wasi-demo-p3.component.wasm
```

```bash
wasmtime serve -S p3,cli \
    -W component-model-async,component-model-more-async-builtins \
    zig-out/wasm/wasi-http-check.component.wasm
curl -i http://127.0.0.1:8080/
```

The http guest (`examples/wasi-demo-p3/http-check.zig`) is a real service.
It answers every request with a 200 whose headers report the result of an outbound `wasi3.http.fetch`.
That exercises the client wrappers and response construction in one round trip.

## Path resolution

`wasi:filesystem` doesn't expose absolute filesystem paths.
Every operation works through a `descriptor` for a preopened directory.
The `wasi.fs` and `wasi3.fs` helpers handle this by walking the list from `wasi:filesystem/preopens.get-directories()` and picking the longest preopen path that's a prefix of yours.

So if wasmtime was started with `--dir /tmp`, `wasi.fs.readFile(gpa, "/tmp/foo")` opens `foo` relative to the `/tmp` descriptor.
Anything outside a preopen returns `error.NotPreopened`.

Matching works on whole path components, so `/tmpx/a.txt` doesn't match a `/tmp` preopen.
Repeated slashes, `.` segments and trailing slashes are ignored.

A relative path such as `"out.txt"` only matches a `.` preopen (`--dir .`), and an absolute path never does.
The preopen list is fetched once and cached.

Paths inside a preopen must stay inside it.
The host rejects `..` segments that climb above the root with
`error.FsAccess`.
