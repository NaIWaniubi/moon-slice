fn loop_with_early_return(c : Bool, n : Int) -> Int {
  let mut x = 0
  while x < n {
    if c {
      return x
    }
    x = x + 1
  }
  return x
}

// Demonstration input for `moon-slice compare`.
//
// The function starts on line 1 so `--line 7` always targets `x = x + 1`,
// regardless of how this trailer is edited.
//
// Structural control dependence reports 18 edges on this program; the
// post-dominator builder reports 7. The difference is the structural rule
// marking the loop head and the exits as controlled by branches that cannot
// actually skip them, while the precise builder adds the loop-carried edge
// `if -> loop head` that the syntax tree cannot express.
//
//   ./dev.sh run cmd/main -- compare --file bench/precise_cdg.mbt --line 7
//   ./dev.sh run cmd/main -- graph   --file bench/precise_cdg.mbt --precise
