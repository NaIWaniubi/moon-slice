// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "NaIWaniubi/moon-slice"

version = "0.7.2"

readme = "README.mbt.md"

repository = "https://github.com/NaIWaniubi/moon-slice"

license = "Apache-2.0"

keywords = [ "slicing", "static-analysis", "developer-tools", "pdg" ]

preferred_target = "wasm"

description = "Program slicing, dependency graphs, and data-flow paths for MoonBit"

import {
  "moonbitlang/parser@0.4.6",
  "moonbitlang/x@0.5.1",
}
