// EXPECT-BACKWARD 6 -> [5, 6]
// EXPECT-FORWARD 6 -> [6, 10]
fn branch_merge(x : Int) -> Int {
  let mut tag = 0
  if x > 0 {
    tag = 1 // target
  } else {
    tag = 2
  }
  return tag
}
