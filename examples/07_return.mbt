// EXPECT-BACKWARD 6 -> [4, 5, 6]
// EXPECT-FORWARD 6 -> [6, 7, 8, 10]
fn early_return() -> Int {
  let base = 5
  let cap = 8
  let total = base + cap // target
  if total > 10 {
    return total - 10
  }
  return total
}
