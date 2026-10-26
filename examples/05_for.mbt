// EXPECT-BACKWARD 7 -> [4, 5, 6, 7]
// EXPECT-FORWARD 7 -> [7, 9]
fn for_acc() -> Int {
  let mut acc = 0
  for i in 0..<3 {
    let scaled = i * 2
    acc = acc + scaled // target
  }
  return acc
}
