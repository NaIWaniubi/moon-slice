// EXPECT-BACKWARD 7 -> [4, 5, 6, 7, 8]
// EXPECT-FORWARD 7 -> [7, 10]
fn loop_sum(n : Int) -> Int {
  let mut i = 0
  let mut total = 0
  while i < n {
    total = total + i // target
    i = i + 1
  }
  return total
}
