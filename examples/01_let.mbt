// EXPECT-BACKWARD 5 -> [4, 5]
// EXPECT-FORWARD 5 -> [5, 6, 8]
fn let_chain() -> Int {
  let a = 1
  let b = a + 2 // target
  let c = b * 3
  let unused = 99
  return c
}
