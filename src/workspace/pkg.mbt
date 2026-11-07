// `moon.pkg` parsing: a package's dependencies and what it builds.
//
// The same lexer as `moon.mod`, because a package manifest is the same kind of
// file. What differs is one detail that matters downstream: an import can be
// scoped, `import { ... } for "test"`. A test-only dependency is not a
// dependency of the library, so it is kept in its own list instead of being
// merged — a package that imports a test helper must still build without it.

///|
/// The text form of a package kind, the same spelling `moon.pkg` uses.
///
/// An `Unknown` kind echoes back what the manifest said, so a newer toolchain's
/// `pkgtype` survives a round trip instead of being flattened to `library`.
pub fn pkgtype_text(kind : PkgType) -> String {
  match kind {
    PkgType::Library => "library"
    PkgType::Executable => "executable"
    PkgType::Test => "test"
    PkgType::WhiteBoxTest => "wbtest"
    PkgType::Unknown(text) => text
  }
}

///|
fn pkg_type_of(text : String) -> PkgType {
  match text {
    "library" => PkgType::Library
    "executable" => PkgType::Executable
    "test" => PkgType::Test
    "wbtest" => PkgType::WhiteBoxTest
    "whitebox" => PkgType::WhiteBoxTest
    _ => PkgType::Unknown(text)
  }
}

///|
/// Parse `moon.pkg` text.
///
/// Reads `import { ... }` and `test-import { ... }` / `wbtest-import { ... }`
/// blocks, `pkgtype = "..."` and `is-main = true`. Every other key — `warnings`,
/// `alert-list`, `targets`, `pre-build` — is stepped over, so a package manifest
/// that grows a field keeps parsing here.
///
/// An empty file is valid and yields a library with no dependencies, which is
/// what `src/suppress/moon.pkg` in this repository is.
pub fn parse_pkg(source : String) -> Result[PkgManifest, ParseError] {
  let tokens = match tokenize(source) {
    Ok(parsed) => parsed
    Err(error) => {
      return Err(error)
    }
  }
  let imports : Array[String] = []
  let test_imports : Array[String] = []
  let mut pkgtype = PkgType::Library
  let mut is_main = false
  let mut i = 0
  while i < tokens.length() {
    let token = tokens[i]
    match token.kind {
      Tok::Ident(word) => {
        if word == "import" ||
          word == "test-import" ||
          word == "wbtest-import" {
          let block = read_import(tokens, i + 1)
          if !block.closed {
            return Err(ParseError::{
              reason: "unterminated `" +
              word +
              "` block starting on line " +
              token.line.to_string(),
            })
          }
          let scope = match block.scope {
            Some(scope) => scope
            None => ""
          }
          let scoped_to_test = word != "import" ||
            scope == "test" ||
            scope == "wbtest" ||
            scope == "whitebox"
          if scoped_to_test {
            for item in block.items {
              push_unique(test_imports, item)
            }
          } else {
            for item in block.items {
              push_unique(imports, item)
            }
          }
          i = block.next
        } else if word == "pkgtype" {
          match value_after(tokens, i) {
            Some(value) => {
              pkgtype = pkg_type_of(value)
              i = i + 3
            }
            None => {
              return Err(ParseError::{
                reason: "`pkgtype` on line " +
                token.line.to_string() +
                " is not a quoted string",
              })
            }
          }
        } else if word == "is-main" {
          if i + 2 < tokens.length() && tokens[i + 1].kind == Tok::Equals {
            match tokens[i + 2].kind {
              Tok::Ident(flag) => {
                if flag == "true" {
                  is_main = true
                }
              }
              _ => ()
            }
            i = i + 3
          } else {
            i = i + 1
          }
        } else {
          i = skip_entry(tokens, i)
        }
      }
      Tok::CloseBrace => {
        return Err(ParseError::{
          reason: "unmatched `}` on line " + token.line.to_string(),
        })
      }
      Tok::CloseBracket => {
        return Err(ParseError::{
          reason: "unmatched `]` on line " + token.line.to_string(),
        })
      }
      _ => {
        i = i + 1
      }
    }
  }
  Ok(PkgManifest::{ imports, test_imports, pkgtype, is_main })
}
