// EXPECT-BACKWARD 6 -> [5, 6]
// EXPECT-FORWARD 6 -> [6, 7, 8]
fn bump() -> Int {
  let mut n = 0
  n = 1
  n = n + 2 // target
  n = n * 3
  return n
}
