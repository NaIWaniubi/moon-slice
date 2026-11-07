// Content fingerprints: a stable identity for a file's bytes.
//
// A build cache has to answer "is this the same file I compiled last time?"
// without keeping the file's text. A hash is enough, but only if it is the same
// hash everywhere: the same workspace may be fingerprinted on a 32-bit wasm
// target and on a 64-bit native one, and a fingerprint that disagreed with
// itself across targets would invalidate the cache on every switch.
//
// So the two accumulators below are chosen to never leave the range an `Int`
// holds on any target — the products stay below 2^31 — instead of using FNV-1a
// 64, whose multiply is defined by wrapping and therefore depends on the
// platform's word size. Two independent lanes of about 10^6 states each give a
// 12-hex-digit fingerprint, which is the same order of collision safety as the
// file-size pair it replaces.

///|
/// Modulus of the first hash lane. Prime, and small enough that
/// `(mod - 1) * HASH_BASE_A + max_char` is far below `2^31`.
const HASH_MOD_A : Int = 1_000_003

///|
/// Modulus of the second hash lane. A different prime, so a collision in one
/// lane does not imply a collision in the other.
const HASH_MOD_B : Int = 999_983

///|
/// Multiplier of the first lane.
const HASH_BASE_A : Int = 31

///|
/// Multiplier of the second lane, larger than `HASH_BASE_A` so the two lanes
/// disagree about the weight of each position as well as about the modulus.
const HASH_BASE_B : Int = 131

///|
/// A lane value as six lower-case hex digits.
///
/// Fixed width is the point: `"0f"` and `"00000f"` must not be able to name
/// different states of the same lane.
fn hex_pad(value : Int) -> String {
  let digits = value.to_string(radix=16)
  let out = StringBuilder()
  let mut pad = 6 - digits.length()
  while pad > 0 {
    out.write_char('0')
    pad = pad - 1
  }
  out.write_string(digits)
  out.to_string()
}

///|
/// Fingerprint one file's content.
///
/// `size` counts characters, not bytes: the loop that feeds the hash is the same
/// loop, so the two numbers cannot disagree about what was read. The path is
/// recorded but not hashed — the same content in two files has the same hash,
/// which is what lets a rename show up as a move rather than an edit.
pub fn fingerprint(path : String, content : String) -> FileFingerprint {
  let mut lane_a = 0
  let mut lane_b = 0
  let mut size = 0
  for ch in content.iter() {
    let code = ch.to_int()
    lane_a = (lane_a * HASH_BASE_A + code) % HASH_MOD_A
    lane_b = (lane_b * HASH_BASE_B + code) % HASH_MOD_B
    size = size + 1
  }
  FileFingerprint::{
    path,
    hash: hex_pad(lane_a) + "-" + hex_pad(lane_b),
    size,
  }
}

///|
/// The hash `fingerprint` would give this text, without a path.
///
/// Exposed on its own for callers that only need to compare content — a cache
/// keyed by text, or a test that wants to show two sources differ.
pub fn hash_text(text : String) -> String {
  let computed = fingerprint("", text)
  computed.hash
}

///|
/// Fingerprint every file in `files`, preserving the given order.
///
/// Order is preserved rather than sorted because the input order is the
/// caller's scan order and a fingerprint table is usually written back out in
/// it. Paths are normalised as they are recorded, so a table written on one
/// platform compares cleanly against a table written on another.
pub fn fingerprints(files : Array[WorkspaceFile]) -> Array[FileFingerprint] {
  let out : Array[FileFingerprint] = []
  for file in files {
    out.push(fingerprint(normalize_path(file.path), file.content))
  }
  out
}
