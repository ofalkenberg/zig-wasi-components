use anyhow::Result;
use wasmtime::component::{Component, Linker, bindgen};
use wasmtime::{Engine, Store};

bindgen!({
    path: "../math.wit",
    world: "math",
});

fn main() -> Result<()> {
    let engine = Engine::default();
    let linker: Linker<()> = Linker::new(&engine);

    let paths = std::env::args().skip(1).collect::<Vec<_>>();
    if paths.is_empty() {
        anyhow::bail!("usage: dual-host <component.wasm> [<component.wasm>...]");
    }
    for path in paths {
        let component = Component::from_file(&engine, &path)?;
        let mut store = Store::new(&engine, ());
        let bindings = Math::instantiate(&mut store, &component, &linker)?;
        let r = bindings.call_add(&mut store, 2, 3)?;
        let language = if path.contains("rust") { "Rust" } else { "Zig" };
        println!("{language:6} component @ {path}: add(2, 3) = {r}");
        assert_eq!(r, 5);
    }
    println!("OK — same WIT world, two languages, identical canonical-ABI behaviour.");
    Ok(())
}
