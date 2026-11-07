// `moon.mod` parsing: the module's name, version and dependency list.
//
// A manifest is read by more than one tool, and a typo in it usually reaches a
// human as a stack trace from somewhere unrelated. So the parse is total: every
// failure path returns `Err` with the line and the expectation that failed, and
// nothing here can panic on malformed text.

///|
/// Parse `moon.mod` text.
///
/// Reads `name`, `version` and the `import { ... }` dependency list. Comments,
/// blank lines, unknown keys and array-valued keys (`keywords`, `targets`) are
/// skipped, and an `import` may appear anywhere in the file. Import paths are
/// returned in declaration order without duplicates — a repeated dependency
/// changes nothing about the build, so it changes nothing about the parse.
///
/// `version` defaults to `"0.0.0"` when absent. A missing `name` is an error:
/// every path in the workspace is resolved against it, so there is no useful
/// value to invent.
pub fn parse_mod(source : String) -> Result[ModManifest, ParseError] {
  let tokens = match tokenize(source) {
    Ok(parsed) => parsed
    Err(error) => {
      return Err(error)
    }
  }
  let mut name : String? = None
  let mut version : String? = None
  let imports : Array[String] = []
  let mut i = 0
  while i < tokens.length() {
    let token = tokens[i]
    match token.kind {
      Tok::Ident(word) => {
        if word == "import" {
          let block = read_import(tokens, i + 1)
          if !block.closed {
            return Err(ParseError::{
              reason: "unterminated import block starting on line " +
              token.line.to_string(),
            })
          }
          for item in block.items {
            push_unique(imports, item)
          }
          i = block.next
        } else if word == "name" {
          match value_after(tokens, i) {
            Some(value) => {
              name = Some(value)
              i = i + 3
            }
            None => {
              return Err(ParseError::{
                reason: "`name` on line " +
                token.line.to_string() +
                " is not a quoted string",
              })
            }
          }
        } else if word == "version" {
          match value_after(tokens, i) {
            Some(value) => {
              version = Some(value)
              i = i + 3
            }
            None => {
              return Err(ParseError::{
                reason: "`version` on line " +
                token.line.to_string() +
                " is not a quoted string",
              })
            }
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
  match name {
    None => {
      Err(ParseError::{ reason: "missing `name` field" })
    }
    Some(name) => {
      let resolved = match version {
        Some(version) => version
        None => "0.0.0"
      }
      Ok(ModManifest::{ name, version: resolved, imports })
    }
  }
}
