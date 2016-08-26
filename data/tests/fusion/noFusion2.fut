-- ==
fun f(a: f64        ): f64 = a + 3.0
fun g(a: f64        ): f64 = a * 3.0

fun main(arr: []f64): f64 =
    let x = map(f, arr) in
    let y = map(f, x)   in
    let z = map(g, x)   in
    y[0] + z[0]
