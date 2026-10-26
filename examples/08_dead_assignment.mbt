// EXPECT-BACKWARD 7 -> [6, 7]
// EXPECT-FORWARD 7 -> [7, 8, 9]
fn dead_store() -> Int {
  let mut cache = 1
  cache = 2
  cache = 3
  cache = cache + 4 // target
  let result = cache * 2
  return result
}
