fn inc(x : Int) -> Int {
  x + 1
}

fn twice(x : Int) -> Int {
  let a = inc(x)
  let b = inc(a)
  b
}

fn main_fn(x : Int) -> Int {
  twice(x)
}
