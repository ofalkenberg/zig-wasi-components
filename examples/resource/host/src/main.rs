use anyhow::Result;
use wasmtime::component::{Component, Linker, bindgen};
use wasmtime::{Engine, Store};

bindgen!({
    path: "../resource.wit",
    world: "counts",
});

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let path = args.next().ok_or_else(|| anyhow::anyhow!("usage: counts-host <wasm>"))?;
    let engine = Engine::default();
    let component = Component::from_file(&engine, &path)?;
    let linker: Linker<()> = Linker::new(&engine);
    let mut store = Store::new(&engine, ());
    let bindings = Counts::instantiate(&mut store, &component, &linker)?;

    let counters = bindings.demo_res_counters();
    let counter = counters.counter();

    let c1 = counter.call_constructor(&mut store, 10)?;
    let c2 = counter.call_constructor(&mut store, 100)?;
    counter.call_increment(&mut store, c1)?;
    counter.call_increment(&mut store, c1)?;
    counter.call_add(&mut store, c1, 5)?;
    counter.call_add(&mut store, c2, 50)?;

    let v1 = counter.call_get(&mut store, c1)?;
    let v2 = counter.call_get(&mut store, c2)?;
    println!("counter1 = {}", v1);
    println!("counter2 = {}", v2);

    c1.resource_drop(&mut store)?;
    c2.resource_drop(&mut store)?;

    assert_eq!(v1, 17);
    assert_eq!(v2, 150);
    println!("OK — resource lifecycle (constructor → methods → drop) verified.");
    Ok(())
}
