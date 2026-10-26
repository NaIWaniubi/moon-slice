// EXPECT-BACKWARD 7 -> [5, 7]
// EXPECT-FORWARD 7 -> [7, 10]
fn classify(code : Int) -> Int {
  let mut label = 0
  match code {
    0 => { label = 10 }
    1 => { label = 20 } // target
    _ => { label = 30 }
  }
  return label
}
