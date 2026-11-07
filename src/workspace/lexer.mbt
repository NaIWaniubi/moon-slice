// A small lexer for `moon.mod` and `moon.pkg` text.
//
// Both files share one shape: `key = value` entries plus `name { ... }` blocks
// whose bodies are lists of quoted strings. A general TOML parser would be more
// code than the problem, and would accept constructs these files never contain;
// this lexer recognises exactly the token kinds they use and reports anything
// else with the line it appeared on. That is what turns "a human mistyped the
// manifest" into an `Err` with a reason instead of a panic.

///|
/// The token kinds `moon.mod` / `moon.pkg` use.
///
/// Braces, brackets, `=` and `,` are kept because they delimit the import lists
/// and the array-valued keys (`keywords`, `targets`) the parsers step over.
priv enum Tok {
  Ident(String)
  Str(String)
  OpenBrace
  CloseBrace
  OpenBracket
  CloseBracket
  Equals
  Comma
} derive(Eq)

///|
/// A token together with the 1-based line it started on, so an error can point
/// at the place a human has to fix.
priv struct Token {
  kind : Tok
  line : Int
}

///|
fn is_space_char(ch : Char) -> Bool {
  ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

///|
/// Characters that may form an unquoted word: identifiers such as `name`,
/// `pkgtype`, `is-main`, bare values such as `true`, and the `@alias` / dotted
/// spellings a package manifest may carry. Quoted strings are still the only
/// place a value is read from, so widening this set can only make the lexer
/// step over something it does not interpret, never misread a value.
fn is_word_char(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) ||
  ch == '_' ||
  ch == '-' ||
  ch == '@' ||
  ch == '.'
}

///|
/// Split manifest text into tokens.
///
/// Line comments (`//`) and block comments (`/* */`) are skipped, and strings
/// understand the escapes a manifest can contain (`\"`, `\\`, `\n`, `\t`,
/// `\r`). Everything outside that set is an error: an unclosed string, an
/// unclosed block comment, or a character no manifest field uses.
fn tokenize(source : String) -> Result[Array[Token], ParseError] {
  let chars : Array[Char] = []
  for ch in source.iter() {
    chars.push(ch)
  }
  let tokens : Array[Token] = []
  let n = chars.length()
  let mut i = 0
  let mut line = 1
  while i < n {
    let ch = chars[i]
    if ch == '\n' {
      line = line + 1
      i = i + 1
    } else if is_space_char(ch) {
      i = i + 1
    } else if ch == '/' && i + 1 < n && chars[i + 1] == '/' {
      while i < n && chars[i] != '\n' {
        i = i + 1
      }
    } else if ch == '/' && i + 1 < n && chars[i + 1] == '*' {
      let opened_line = line
      i = i + 2
      let mut closed = false
      while i < n && !closed {
        if chars[i] == '\n' {
          line = line + 1
        }
        if chars[i] == '*' && i + 1 < n && chars[i + 1] == '/' {
          closed = true
          i = i + 2
        } else {
          i = i + 1
        }
      }
      if !closed {
        return Err(ParseError::{
          reason: "unterminated block comment starting on line " +
          opened_line.to_string(),
        })
      }
    } else if ch == '"' {
      let opened_line = line
      i = i + 1
      let text = StringBuilder()
      let mut closed = false
      while i < n && !closed {
        let current = chars[i]
        if current == '"' {
          closed = true
          i = i + 1
        } else if current == '\\' && i + 1 < n {
          let escaped = chars[i + 1]
          if escaped == 'n' {
            text.write_char('\n')
          } else if escaped == 't' {
            text.write_char('\t')
          } else if escaped == 'r' {
            text.write_char('\r')
          } else {
            text.write_char(escaped)
          }
          i = i + 2
        } else {
          if current == '\n' {
            line = line + 1
          }
          text.write_char(current)
          i = i + 1
        }
      }
      if !closed {
        return Err(ParseError::{
          reason: "unterminated string starting on line " +
          opened_line.to_string(),
        })
      }
      tokens.push(Token::{ kind: Tok::Str(text.to_string()), line: opened_line })
    } else if ch == '{' {
      tokens.push(Token::{ kind: Tok::OpenBrace, line })
      i = i + 1
    } else if ch == '}' {
      tokens.push(Token::{ kind: Tok::CloseBrace, line })
      i = i + 1
    } else if ch == '[' {
      tokens.push(Token::{ kind: Tok::OpenBracket, line })
      i = i + 1
    } else if ch == ']' {
      tokens.push(Token::{ kind: Tok::CloseBracket, line })
      i = i + 1
    } else if ch == '=' {
      tokens.push(Token::{ kind: Tok::Equals, line })
      i = i + 1
    } else if ch == ',' {
      tokens.push(Token::{ kind: Tok::Comma, line })
      i = i + 1
    } else if is_word_char(ch) {
      let word = StringBuilder()
      while i < n && is_word_char(chars[i]) {
        word.write_char(chars[i])
        i = i + 1
      }
      tokens.push(Token::{ kind: Tok::Ident(word.to_string()), line })
    } else {
      let message = StringBuilder()
      message.write_string("unexpected character '")
      message.write_char(ch)
      message.write_string("' on line ")
      message.write_string(line.to_string())
      return Err(ParseError::{ reason: message.to_string() })
    }
  }
  Ok(tokens)
}

///|
/// The index just past the group opened at `start`.
///
/// Used to step over values this parser does not interpret — `keywords = [ .. ]`,
/// `targets = [ .. ]`, an alias block — without pretending to understand them.
/// A group that never closes consumes the rest of the file; the callers that
/// care report that separately.
fn skip_group(tokens : Array[Token], start : Int) -> Int {
  let opening = tokens[start].kind
  let closing = if opening == Tok::OpenBrace {
    Tok::CloseBrace
  } else {
    Tok::CloseBracket
  }
  let mut depth = 0
  let mut i = start
  while i < tokens.length() {
    let kind = tokens[i].kind
    if kind == opening {
      depth = depth + 1
    } else if kind == closing {
      depth = depth - 1
      if depth == 0 {
        return i + 1
      }
    }
    i = i + 1
  }
  tokens.length()
}

///|
/// The index just past the value of the entry that starts at `start`.
///
/// An entry is `key = value`; a key without `=` is skipped on its own. Unknown
/// keys are stepped over rather than rejected, because the manifest format is
/// allowed to grow and an older reader should still find `name` and `import`.
fn skip_entry(tokens : Array[Token], start : Int) -> Int {
  let mut i = start + 1
  if i < tokens.length() && tokens[i].kind == Tok::Equals {
    i = i + 1
    if i < tokens.length() {
      match tokens[i].kind {
        Tok::OpenBrace => {
          i = skip_group(tokens, i)
        }
        Tok::OpenBracket => {
          i = skip_group(tokens, i)
        }
        _ => {
          i = i + 1
        }
      }
    }
  }
  i
}

///|
/// The quoted value of `key = "..."` where `key` is the token at `index`.
///
/// `None` covers every way the entry can fail to be a string assignment: no
/// `=`, no value, or a value that is a bare word instead of a quoted string.
fn value_after(tokens : Array[Token], key : Int) -> String? {
  if key + 2 >= tokens.length() {
    return None
  }
  if tokens[key + 1].kind != Tok::Equals {
    return None
  }
  match tokens[key + 2].kind {
    Tok::Str(value) => Some(value)
    _ => None
  }
}

///|
/// Append `value` unless it is already present, preserving declaration order.
fn push_unique(items : Array[String], value : String) -> Unit {
  if !items.contains(value) {
    items.push(value)
  }
}

///|
/// An `import` (or `test-import`) entry, already consumed.
priv struct ImportBlock {
  /// Index of the first token after the block and its scope.
  next : Int
  items : Array[String]
  /// `Some("test")` for `import { ... } for "test"`; `None` for an unscoped
  /// import.
  scope : String?
  /// Whether a braced block was closed. `false` means the file ended inside it.
  closed : Bool
}

///|
/// Read one import entry starting at `start`.
///
/// Both spellings are accepted: the usual `import { "a", "b", }` and the bare
/// `import "a"`. A scope such as `for "test"` is attached to the entry rather
/// than the file, which is how `moon.pkg` distinguishes a build dependency from
/// a test-only one.
fn read_import(tokens : Array[Token], start : Int) -> ImportBlock {
  let items : Array[String] = []
  let mut i = start
  let mut closed = true
  let mut braced = false
  if i < tokens.length() {
    match tokens[i].kind {
      Tok::Str(value) => {
        items.push(value)
        i = i + 1
      }
      Tok::OpenBrace => {
        braced = true
        i = i + 1
      }
      _ => ()
    }
  }
  if braced {
    closed = false
    while i < tokens.length() && !closed {
      match tokens[i].kind {
        Tok::CloseBrace => {
          closed = true
          i = i + 1
        }
        Tok::Str(value) => {
          push_unique(items, value)
          i = i + 1
        }
        Tok::OpenBrace => {
          i = skip_group(tokens, i)
        }
        Tok::OpenBracket => {
          i = skip_group(tokens, i)
        }
        _ => {
          i = i + 1
        }
      }
    }
  }
  let mut scope : String? = None
  let mut at_scope = false
  if i < tokens.length() {
    match tokens[i].kind {
      Tok::Ident(word) => {
        if word == "for" {
          at_scope = true
        }
      }
      _ => ()
    }
  }
  if at_scope && i + 1 < tokens.length() {
    match tokens[i + 1].kind {
      Tok::Str(target) => {
        scope = Some(target)
        i = i + 2
      }
      _ => {
        i = i + 1
      }
    }
  }
  ImportBlock::{ next: i, items, scope, closed }
}
