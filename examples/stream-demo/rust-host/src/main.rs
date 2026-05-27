//! Rust host that drives the Zig stream-demo component. It calls the two
//! stream-producing exports, attaches a consumer to each readable end, pumps
//! the async runtime until the guest has written every element and dropped
//! its writable end, then checks the collected values against what the guest
//! promised.
//!
//! `squares` carries `u32`s and `fibonacci` carries `u64`s; the same generic
//! `Collector<T>` drains both, reading typed items straight out of the
//! component-model `Source<T>` into a `Vec<T>`.

use anyhow::Result;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use wasmtime::component::{
    Accessor, Component, Linker, Source, StreamConsumer, StreamReader, StreamResult, bindgen,
};
use wasmtime::{AsContextMut, Config, Engine, Store, StoreContextMut};

bindgen!({
    path: "../world.wit",
    world: "demo",
    exports: { default: async },
});

struct Ctx {}

/// Drains a `stream<T>` into a shared `Vec<T>`. Each call accepts the whole
/// pending write at once; when the guest drops its writable end the next poll
/// sees nothing remaining and reports the stream dropped.
struct Collector<T>(Arc<Mutex<Vec<T>>>);

impl<D, T> StreamConsumer<D> for Collector<T>
where
    T: wasmtime::component::Lift + Send + Sync + 'static,
{
    type Item = T;

    fn poll_consume(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
        mut store: StoreContextMut<D>,
        mut source: Source<Self::Item>,
        _: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        let remaining = source.remaining(store.as_context_mut());
        if remaining == 0 {
            return Poll::Ready(Ok(StreamResult::Dropped));
        }
        let mut buf: Vec<T> = Vec::with_capacity(remaining);
        source.read(store, &mut buf)?;
        self.get_mut().0.lock().unwrap().extend(buf);
        Poll::Ready(Ok(StreamResult::Completed))
    }
}

/// Attaches a `Collector` to a readable end, pumps the runtime until the
/// guest has finished writing and dropped its end, then prints and checks
/// the collected elements.
async fn drain_verify<T>(
    accessor: &Accessor<Ctx>,
    label: &str,
    stream: StreamReader<T>,
    expected: &[T],
) -> Result<()>
where
    T: wasmtime::component::Lift + Send + Sync + 'static + std::fmt::Debug + PartialEq,
{
    let collected: Arc<Mutex<Vec<T>>> = Arc::new(Mutex::new(Vec::new()));
    accessor.with(|mut access| -> Result<()> {
        stream.pipe(&mut access, Collector(collected.clone()))?;
        Ok(())
    })?;
    for _ in 0..16 {
        tokio::task::yield_now().await;
    }
    let got = collected.lock().unwrap();
    println!("{label:<13} -> {got:?}");
    assert_eq!(got.as_slice(), expected);
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let wasm_path = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("usage: host <component.wasm>"))?;

    let mut config = Config::new();
    config.wasm_component_model_async(true);
    let engine = Engine::new(&config)?;
    let component = Component::from_file(&engine, &wasm_path)?;
    let linker: Linker<Ctx> = Linker::new(&engine);
    let mut store = Store::new(&engine, Ctx {});

    let bindings = Demo::instantiate_async(&mut store, &component, &linker).await?;
    let numbers = bindings.demo_streams_numbers();

    store
        .run_concurrent(async move |accessor| -> Result<()> {
            let squares = numbers.call_squares(accessor, 8).await?;
            drain_verify(accessor, "squares(8)", squares, &[1u32, 4, 9, 16, 25, 36, 49, 64]).await?;

            let fib = numbers.call_fibonacci(accessor, 10).await?;
            drain_verify(accessor, "fibonacci(10)", fib, &[0u64, 1, 1, 2, 3, 5, 8, 13, 21, 34]).await?;

            Ok(())
        })
        .await??;

    println!("OK");
    Ok(())
}
