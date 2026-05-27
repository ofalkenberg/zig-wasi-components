//! Rust host that loads the Zig-built `greeter` component and calls
//! its exports across the canonical ABI. Exercises both a primitive
//! `string -> u32` and a `list<u32> -> u32`, which together prove
//! that Zig's emitted canonical-ABI lifting code interoperates with
//! a Rust caller via Wasmtime.

use anyhow::Result;
use wasmtime::component::{Component, Linker, bindgen};
use wasmtime::{Engine, Store};

bindgen!({
    path: "../greeter.wit",
    world: "greeter",
});

struct Ctx {
    logs: Vec<String>,
}

impl GreeterImports for Ctx {
    fn log(&mut self, msg: String) {
        self.logs.push(msg);
    }
    fn origin(&mut self) -> Point {
        Point { x: 10, y: 20 }
    }
    fn label_point(&mut self, p: Point) -> String {
        format!("({}, {})", p.x, p.y)
    }
}

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let wasm_path = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("usage: host <component.wasm>"))?;

    let engine = Engine::default();
    let component = Component::from_file(&engine, &wasm_path)?;
    let mut linker: Linker<Ctx> = Linker::new(&engine);
    Greeter::add_to_linker::<_, wasmtime::component::HasSelf<Ctx>>(&mut linker, |c| c)?;
    let mut store = Store::new(&engine, Ctx { logs: Vec::new() });
    let bindings = Greeter::instantiate(&mut store, &component, &linker)?;

    // Rust → Zig.
    let len = bindings.call_greet(&mut store, "Hello from Rust!")?;
    println!("greet({:?}) = {}", "Hello from Rust!", len);

    // Rust → Zig with a list.
    let total = bindings.call_sum(&mut store, &[1, 2, 3, 4, 5, 100])?;
    println!("sum([1,2,3,4,5,100]) = {}", total);

    // Rust → Zig with a record (`point { x, y }`).
    let d = bindings.call_manhattan(&mut store, Point { x: -3, y: 4 })?;
    println!("manhattan(point {{ x: -3, y: 4 }}) = {}", d);

    // Rust → Zig returning a string (indirect return area).
    let s = bindings.call_format_greeting(&mut store, "world")?;
    println!("format-greeting({:?}) = {:?}", "world", s);

    // Rust → Zig returning a variant.
    use Outcome;
    let o1 = bindings.call_classify(&mut store, 0)?;
    let o2 = bindings.call_classify(&mut store, 42)?;
    let o3 = bindings.call_classify(&mut store, -1)?;
    println!("classify(0) = {:?}", o1);
    println!("classify(42) = {:?}", o2);
    println!("classify(-1) = {:?}", o3);

    // Rust → Zig returning option<u32>.
    let m1 = bindings.call_maybe_double(&mut store, 21)?;
    let m2 = bindings.call_maybe_double(&mut store, 200)?;
    println!("maybe-double(21) = {:?}", m1);
    println!("maybe-double(200) = {:?}", m2);

    // Rust → Zig returning result<u32, string>.
    let r1 = bindings.call_safe_divide(&mut store, 10, 2)?;
    let r2 = bindings.call_safe_divide(&mut store, 1, 0)?;
    println!("safe-divide(10, 2) = {:?}", r1);
    println!("safe-divide(1, 0) = {:?}", r2);

    // Rust → Zig returning tuple<u32, u32>.
    let pair = bindings.call_pair(&mut store, 7)?;
    println!("pair(7) = {:?}", pair);

    // Rust → Zig char ↔ char.
    let uc = bindings.call_upper_char(&mut store, 'k')?;
    println!("upper-char('k') = {:?}", uc);

    // Rust → Zig with 17 u32 params (exceeds MAX_FLAT_PARAMS=16, so
    // the host hands the arguments through a memory area).
    let sm = bindings.call_sum_many(
        &mut store,
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
    )?;
    println!("sum-many(1..17) = {}", sm);

    // Rust → Zig with list<point>.
    let td = bindings.call_total_distance(
        &mut store,
        &[
            Point { x: 1, y: 1 },
            Point { x: -2, y: 3 },
            Point { x: 0, y: -4 },
        ],
    )?;
    println!("total-distance(3 points) = {}", td);

    // Rust → Zig with a `flags` parameter (packed struct(u8) in Zig).
    let pp = bindings.call_perms_popcount(
        &mut store,
        Perms::READ | Perms::EXEC,
    )?;
    println!("perms-popcount({{read,exec}}) = {}", pp);

    // Rust → Zig with a named-tuple return (joint-layout return area).
    let dm = bindings.call_divmod(&mut store, 17, 5)?;
    println!("divmod(17, 5) = {:?}", dm);

    // Rust → Zig with `result<u32, list<u8>>` as a PARAMETER followed
    // by another scalar. Tests slot advancement past unequal arm
    // arities (ok=1 slot, err=2 slots).
    // Zig → Rust: import with an indirect-result (point return area).
    let dfo = bindings.call_distance_from_origin(&mut store, Point { x: 13, y: 25 })?;
    println!("distance-from-origin(point {{ x: 13, y: 25 }}) = {}", dfo);

    let ch_ok = bindings.call_choose(&mut store, Ok("abc"), 0)?;
    let ch_err = bindings.call_choose(&mut store, Err(123), 0)?;
    let ch_empty = bindings.call_choose(&mut store, Ok(""), 42)?;
    println!("choose(Ok(\"abc\"), 0) = {}", ch_ok);
    println!("choose(Err(123), 0) = {}", ch_err);
    println!("choose(Ok(\"\"), 42) = {}", ch_empty);

    // Zig → Rust: any log calls the guest made are now in the context.
    println!("captured logs: {:?}", store.data().logs);

    assert_eq!(len, "Hello from Rust!".len() as u32);
    assert_eq!(total, 115);
    assert_eq!(d, 7);
    assert_eq!(s, "Hi, world!");
    assert!(matches!(o1, Outcome::OkEmpty));
    assert!(matches!(o2, Outcome::OkValue(42)));
    assert!(matches!(&o3, Outcome::Fail(s) if s == "negative"));
    assert_eq!(m1, Some(42));
    assert_eq!(m2, None);
    assert_eq!(r1, Ok(5));
    assert_eq!(r2, Err("division by zero".to_string()));
    assert_eq!(pair, (7, 14));
    assert_eq!(uc, 'K');
    assert_eq!(sm, (1..=17).sum::<u32>());
    assert_eq!(td, 2 + 5 + 4);
    assert_eq!(pp, 2);
    assert_eq!(dm.0, 3);
    assert_eq!(dm.1, 2);
    assert_eq!(dfo, 3 + 5);
    assert_eq!(ch_ok, 'a' as u32);
    assert_eq!(ch_err, 123);
    assert_eq!(ch_empty, 42);
    assert_eq!(
        store.data().logs,
        vec![
            "hello Hello from Rust!".to_string(),
            "(13, 25)".to_string(),
        ],
    );
    println!("OK — Rust ↔ Zig component interop (both directions) verified.");
    Ok(())
}
