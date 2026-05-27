//! Rust host that drives the Zig-built async component through the
//! component-model async canonical ABI. Exercises every direction:
//!
//! - `[async-lift]` exports invoked from the host
//!   (`succ`, `measure`, `greet`, `promise`)
//! - `[async-lower]` import invoked from the guest
//!   (`relay` calls the host-provided `clock.tick`)
//! - guest-produced `stream<u8>` drained host-side via a
//!   `StreamConsumer` (`greet` returns "Hello, <name>!" bytes)
//! - guest-produced `future<u32>` drained host-side via a
//!   `FutureConsumer` (`promise(21)` resolves to `42`)

use anyhow::Result;
use futures::channel::oneshot;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use wasmtime::component::{
    Accessor, Component, FutureConsumer, HasSelf, Linker, Source, StreamConsumer, StreamResult,
    bindgen,
};
use wasmtime::{AsContextMut, Config, Engine, Store, StoreContextMut};

bindgen!({
    path: "../world.wit",
    world: "demo",
    imports: { default: async | trappable },
    exports: { default: async },
});

struct Ctx {}

impl demo::asyncdemo::clock::HostWithStore for HasSelf<Ctx> {
    async fn tick<T>(_: &Accessor<T, Self>, value: u32) -> wasmtime::Result<u32> {
        for _ in 0..2 {
            tokio::task::yield_now().await;
        }
        Ok(value.wrapping_mul(10))
    }
}

impl demo::asyncdemo::clock::Host for Ctx {}

struct BytesAccumulator(Arc<Mutex<Vec<u8>>>);

impl<D> StreamConsumer<D> for BytesAccumulator {
    type Item = u8;

    fn poll_consume(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
        mut store: StoreContextMut<D>,
        source: Source<Self::Item>,
        _: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        let available = source.remaining(store.as_context_mut());
        if available == 0 {
            Poll::Ready(Ok(StreamResult::Dropped))
        } else {
            let mut direct = source.as_direct(store);
            let bytes = direct.remaining().to_vec();
            direct.mark_read(bytes.len());
            self.get_mut().0.lock().unwrap().extend_from_slice(&bytes);
            Poll::Ready(Ok(StreamResult::Completed))
        }
    }
}

struct OneshotFutureConsumer<T>(Option<oneshot::Sender<T>>);

impl<D, T: wasmtime::component::Lift + Send + 'static> FutureConsumer<D> for OneshotFutureConsumer<T> {
    type Item = T;

    fn poll_consume(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
        store: StoreContextMut<D>,
        mut source: Source<'_, T>,
        _: bool,
    ) -> Poll<wasmtime::Result<()>> {
        let value = &mut None;
        source.read(store, value)?;
        let _ = self.get_mut().0.take().unwrap().send(value.take().unwrap());
        Poll::Ready(Ok(()))
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let wasm_path = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("usage: host <component.wasm>"))?;

    let mut config = Config::new();
    config.wasm_component_model_async(true);
    let engine = Engine::new(&config)?;
    let component = Component::from_file(&engine, &wasm_path)?;
    let mut linker: Linker<Ctx> = Linker::new(&engine);
    demo::asyncdemo::clock::add_to_linker::<_, HasSelf<Ctx>>(&mut linker, |c| c)?;
    let mut store = Store::new(&engine, Ctx {});

    let bindings = Demo::instantiate_async(&mut store, &component, &linker).await?;
    let kit = bindings.demo_asyncdemo_kit();

    let result = store
        .run_concurrent(async move |accessor| -> Result<()> {
            let succ_out = kit.call_succ(accessor, 41).await?;
            println!("succ(41) = {}", succ_out);
            assert_eq!(succ_out, 42);

            let measured = kit
                .call_measure(accessor, "hello async".to_string())
                .await?;
            println!("measure(\"hello async\") = {}", measured);
            assert_eq!(measured, 11);

            let relayed = kit.call_relay(accessor, 7).await?;
            println!("relay(7) = {} (host tick → 70, guest +1 → 71)", relayed);
            assert_eq!(relayed, 71);

            // Guest produces a stream<u8> with "Hello, <name>!" inside.
            // Attach a consumer that accumulates the bytes, then yield a
            // few times so the guest's yield-then-cleanup loop can drop
            // the writable end after we've drained.
            let stream = kit
                .call_greet(accessor, "wasmtime".to_string())
                .await?;
            let buffer = Arc::new(Mutex::new(Vec::<u8>::new()));
            accessor.with(|mut access| -> wasmtime::Result<()> {
                stream.pipe(&mut access, BytesAccumulator(buffer.clone()))?;
                Ok(())
            })?;
            for _ in 0..16 {
                tokio::task::yield_now().await;
            }
            let text = String::from_utf8(buffer.lock().unwrap().clone())?;
            println!("greet(\"wasmtime\") -> {:?}", text);
            assert_eq!(text, "Hello, wasmtime!");

            // Guest produces a future<u32> with the doubled value.
            let future = kit.call_promise(accessor, 21).await?;
            let (tx, mut rx) = oneshot::channel::<u32>();
            accessor.with(|mut access| -> wasmtime::Result<()> {
                future.pipe(&mut access, OneshotFutureConsumer(Some(tx)))?;
                Ok(())
            })?;
            for _ in 0..16 {
                tokio::task::yield_now().await;
            }
            let value = rx
                .try_recv()?
                .ok_or_else(|| anyhow::anyhow!("future never resolved"))?;
            println!("promise(21) -> {}", value);
            assert_eq!(value, 42);

            Ok(())
        })
        .await?;
    result?;

    println!("OK");
    Ok(())
}
