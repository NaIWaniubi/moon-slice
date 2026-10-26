// EXPECT-BACKWARD 6 -> [5, 6]
// EXPECT-FORWARD 6 -> [6, 7]
fn shadow() -> Int {
  let a = 1
  let a = 100
  let b = a + 3 // target
  return a + b
}
