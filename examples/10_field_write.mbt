// EXPECT-BACKWARD 11 -> [9, 10, 11]
// EXPECT-FORWARD 11 -> [11, 12]
struct Pair {
  mut left : Int
  right : Int
}

fn field_write() -> Int {
  let p = { left : 1, right : 2 }
  p.left = p.right + 4
  let total = p.left + p.right // target
  return total
}
