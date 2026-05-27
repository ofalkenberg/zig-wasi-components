//! Top-level module for `zig_wasi_components`.
//!
//! This package implements the WebAssembly Component Model in Zig.
//! It is organised into three layers:
//!
//!   * `wit`   — parser for the WIT (Wasm Interface Type) text format.
//!   * `abi`   — runtime helpers implementing the canonical ABI
//!               (lifting/lowering, `cabi_realloc`, `cabi_post_*`).
//!               Designed to be compiled into a guest core wasm module
//!               targeting wasm32-freestanding.
//!   * `codegen` — turns a parsed WIT world into Zig source code that
//!               wires guest exports and host imports to the ABI layer.
//!
//! The standard build pipeline is identical to the one used by
//! `wit-bindgen` / `cargo-component` for Rust:
//!
//!   1. Generate Zig bindings from a WIT world (via `codegen`).
//!   2. Compile the user's Zig code, linking in the `abi` runtime,
//!      to wasm32-freestanding.
//!   3. Use `wasm-tools component embed` + `component new` to wrap
//!      the resulting core module into a real `.wasm` component.
//!
//! See `LOG.md` in the repository for a running development log.

const std = @import("std");

pub const wit = @import("wit.zig");
pub const abi = @import("abi.zig");
pub const codegen = @import("codegen.zig");
pub const wasi = @import("wasi.zig");
pub const wasi3 = @import("wasi3.zig");

test {
    std.testing.refAllDecls(@This());
}
