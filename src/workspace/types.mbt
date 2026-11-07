// Data model for a MoonBit workspace: the module manifest, the package
// manifests, the package graph, content fingerprints and the invalidation
// result.
//
// Everything in this package is a pure function over text. Nothing here reads
// the filesystem, so a build tool can hand in the files it already has, and a
// test can hand in three strings. The one place text is interpreted — the
// `moon.mod` / `moon.pkg` lexer — returns a reason on failure instead of
// panicking, because a manifest a human just mistyped is a normal input.

///|
/// Why a `moon.mod` or `moon.pkg` could not be parsed.
///
/// Parsing is total: malformed text comes back as this value, never as a panic,
/// and `reason` names the line and the expectation that failed.
pub(all) struct ParseError {
  reason : String
} derive(Debug, Eq)

///|
/// A parsed `moon.mod`.
pub(all) struct ModManifest {
  name : String
  /// Defaults to `"0.0.0"` when the file omits it, which is the version a
  /// module without one is published under.
  version : String
  /// Import paths exactly as written, in declaration order, without duplicates.
  imports : Array[String]
} derive(Debug, Eq)

///|
/// What a `moon.pkg` says it builds.
///
/// The value set is open: a toolchain that grows a new package kind must not
/// make an older parser reject the whole workspace, so anything unrecognised is
/// carried through as `Unknown` instead of becoming an error.
pub(all) enum PkgType {
  Library
  Executable
  Test
  WhiteBoxTest
  Unknown(String)
} derive(Debug, Eq)

///|
/// A parsed `moon.pkg`.
pub(all) struct PkgManifest {
  /// Dependencies of the package itself, in declaration order, deduplicated.
  imports : Array[String]
  /// Dependencies only the package's tests need (`import { ... } for "test"`).
  /// Kept apart from `imports` because a library build does not need them.
  test_imports : Array[String]
  pkgtype : PkgType
  /// Whether the package declares `is-main = true`.
  is_main : Bool
} derive(Debug, Eq)

///|
/// One file of a workspace: where it is and what is in it.
///
/// `path` is workspace-relative. It may use either separator; every function in
/// this package normalises before comparing, so `src\a\a.mbt` and `src/a/a.mbt`
/// name the same file.
pub(all) struct WorkspaceFile {
  path : String
  content : String
} derive(Debug, Eq)

///|
/// One package of a workspace, resolved.
///
/// A package is a directory: `moon.pkg` supplies the dependencies and the
/// `dir` itself supplies the files. `files` holds the non-test `.mbt` files,
/// `test_files` the black-box (`*_test.mbt`) and white-box (`*_wbtest.mbt`)
/// ones — both belong to the package, but only the former are part of what it
/// exports.
pub(all) struct PackageNode {
  /// Package directory, workspace-relative, `""` for the module root.
  dir : String
  /// Import path of the package: `module_name` for the root, otherwise
  /// `module_name + "/" + dir`.
  name : String
  /// Whether a `moon.pkg` was found *and* parsed.
  has_manifest : Bool
  imports : Array[String]
  test_imports : Array[String]
  pkgtype : PkgType
  is_main : Bool
  /// Non-test `.mbt` files, sorted.
  files : Array[String]
  /// Black-box and white-box test files, sorted.
  test_files : Array[String]
  /// Directories of the packages this one depends on, sorted.
  ///
  /// Only packages inside this workspace appear: an import of
  /// `moonbitlang/parser` is a real dependency, but it is not a directory this
  /// graph can invalidate. Test-only imports are included, because a change to
  /// a test dependency invalidates this package's tests just as surely.
  deps : Array[String]
} derive(Debug, Eq)

///|
/// Every package of a workspace, sorted by directory.
///
/// Sorted rather than map-ordered so that two runs over the same input produce
/// the same answer, which is what makes the invalidation result diffable.
pub(all) struct PackageGraph {
  module_name : String
  packages : Array[PackageNode]
} derive(Debug, Eq)

///|
/// The content identity of one file.
///
/// `hash` is a fixed-width hexadecimal string (see `hash_text`) and `size` is
/// the number of characters in the content. Both are computed from the content
/// alone, so two files with the same bytes have the same fingerprint whatever
/// their paths, and a fingerprint is comparable across runs and machines.
pub(all) struct FileFingerprint {
  path : String
  hash : String
  size : Int
} derive(Debug, Eq)

///|
/// What changed between two fingerprint tables and which packages that
/// invalidates.
///
/// `changed`, `added` and `removed` are sorted paths. `packages` is the sorted
/// transitive closure of the packages those files live in — the package itself
/// plus every package that depends on it, however indirectly, because a change
/// to a dependency changes everything above it.
pub(all) struct Invalidation {
  changed : Array[String]
  added : Array[String]
  removed : Array[String]
  packages : Array[String]
} derive(Debug, Eq)
