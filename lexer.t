//! Turns source text into a flat list of tokens, and the comments between
//! them: a port of t-lang's `src/lexer.rs`.
//!
//! Tokens are `Copy`: a name is a slice of the source, and a format
//! string's pieces are kept in a table of their own (`Lexed::pieces`),
//! which its token points into. T has no `Clone`, so a token that owned a
//! `String` couldn't be looked at and kept both.

use alloc::list::List;
use alloc::string::String;

use crate::ast::{FmtAlign, FmtKind, FmtPad, FmtSpec, FmtWidth, IntTy};
use crate::error::{Error, Span};
use crate::text::{at, byte, char_at, is_alnum, is_alpha, is_digit, is_hex, is_ws, sub};

#[derive(Copy, Discard, Eq)]
pub enum Tok<'s> {
    /// An integer literal: its value, and the type its suffix says, as
    /// in `255u8`, if it has one.
    Int(u64, Option<IntTy>),
    /// `b'a'`: a byte literal, a `u8`.
    Byte(u8),
    /// `'a'`: a character literal.
    Char(char),
    /// `"hi"`: a string literal. What it means isn't kept: the printer
    /// writes literals as the source does.
    Str,
    /// `b"hi"`: a byte string literal.
    ByteStr,
    /// `f"x = {x}"`: a format string, its pieces in `Lexed::pieces`.
    FStr(Pieces),
    Ident(&'s str),
    // keywords
    Fn,
    Let,
    If,
    Else,
    True,
    False,
    Struct,
    Enum,
    Trait,
    Impl,
    For,
    In,
    Match,
    Mut,
    Move,
    While,
    Loop,
    Unsafe,
    Return,
    Break,
    Continue,
    Type,
    As,
    Pub,
    Export,
    Mod,
    Use,
    Crate,
    Super,
    Where,
    Ensures,
    Invariant,
    Law,
    With,
    Effect,
    Unsized,
    Sealed,
    Const,
    Static,
    Extern,
    /// `'a`: a lifetime, with its `'`.
    Lifetime(&'s str),
    // punctuation
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Hash,
    Question,
    Comma,
    Colon,
    ColonColon,
    Semi,
    Dot,
    DotDot,
    DotDotEq,
    Arrow,
    FatArrow,
    // operators
    Eq,
    /// `+=`, `-=` and the others: an operator and `=`, assigning.
    OpEq(OpEq),
    EqEq,
    NotEq,
    Lt,
    Le,
    Gt,
    Ge,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Bang,
    Amp,
    AndAnd,
    OrOr,
    Pipe,
    Caret,
    /// `<<`. There's no `>>` token: the parser takes two `>`s with nothing
    /// between them as a shift.
    Shl,
    /// A `///` doc comment line: the text after the `///`.
    Doc(&'s str),
    /// A `//!` doc comment line: the text after the `//!`.
    InnerDoc(&'s str),
    Eof,
}

/// Where a format string's pieces are in `Lexed::pieces`: `len` of them
/// from `first` on.
#[derive(Copy, Discard, Eq)]
pub struct Pieces { pub first: usize, pub len: usize }

/// The operator of a compound assignment like `+=`.
#[derive(Copy, Discard, Eq)]
pub enum OpEq { Add, Sub, Mul, Div, Rem, And, Or, Xor, Shl }

impl OpEq {
    pub fn symbol(self) -> &'static str {
        match self {
            OpEq::Add => "+",
            OpEq::Sub => "-",
            OpEq::Mul => "*",
            OpEq::Div => "/",
            OpEq::Rem => "%",
            OpEq::And => "&",
            OpEq::Or => "|",
            OpEq::Xor => "^",
            OpEq::Shl => "<<",
        }
    }
}

/// A piece of a format string, `f".."`: text, or a hole.
#[derive(Discard)]
pub enum FPiece<'s> {
    /// Text. What it means isn't kept, as for `Tok::Str`.
    Text,
    Hole(Hole<'s>),
}

/// `{e}`, `{e:?}`, `{e:x}`, `{e:>8}` ..: the tokens of expression `e`,
/// ending with an `Eof` where it ends; how it's written; where the name
/// of its width's variable is, for `{e:>w$}`; and its span, the braces
/// included.
#[derive(Discard)]
pub struct Hole<'s> {
    pub toks: List<Token<'s>>,
    pub spec: FmtSpec,
    pub width_at: Option<Span>,
    pub span: Span,
}

#[derive(Copy, Discard)]
pub struct Token<'s> { pub tok: Tok<'s>, pub span: Span }

/// A file's tokens, ending with an `Eof`; the comments between them, in
/// order; and the pieces of its format strings.
#[derive(Discard)]
pub struct Lexed<'s> {
    pub toks: List<Token<'s>>,
    pub comments: List<Span>,
    pub pieces: List<FPiece<'s>>,
}

impl<'s> Tok<'s> {
    /// How the token is shown in error messages.
    pub fn describe(self) -> String {
        let s = match self {
            Tok::Int(n, None) => return String::of(&f"`{n}`"),
            Tok::Int(n, Some(t)) => return String::of(&f"`{n}{t.name()}`"),
            Tok::Byte(b) => return String::of(&f"`{byte_literal(b)}`"),
            Tok::Char(c) => return String::of(&f"`{char_literal(c)}`"),
            Tok::Str => return String::from("a string literal"),
            Tok::FStr(_) => return String::from("a format string"),
            Tok::ByteStr => return String::from("a byte string literal"),
            Tok::Ident(name) => return String::of(&f"`{name}`"),
            Tok::Doc(_) | Tok::InnerDoc(_) => return String::from("a doc comment"),
            Tok::Lifetime(name) => return String::of(&f"`{name}`"),
            Tok::OpEq(op) => return String::of(&f"`{op.symbol()}=`"),
            Tok::Eof => return String::from("end of file"),
            Tok::Fn => "fn",
            Tok::Let => "let",
            Tok::If => "if",
            Tok::Else => "else",
            Tok::True => "true",
            Tok::False => "false",
            Tok::Struct => "struct",
            Tok::Enum => "enum",
            Tok::Trait => "trait",
            Tok::Impl => "impl",
            Tok::For => "for",
            Tok::In => "in",
            Tok::Match => "match",
            Tok::Mut => "mut",
            Tok::Move => "move",
            Tok::While => "while",
            Tok::Loop => "loop",
            Tok::Unsafe => "unsafe",
            Tok::Return => "return",
            Tok::Break => "break",
            Tok::Continue => "continue",
            Tok::Type => "type",
            Tok::As => "as",
            Tok::Pub => "pub",
            Tok::Export => "export",
            Tok::Mod => "mod",
            Tok::Use => "use",
            Tok::Crate => "crate",
            Tok::Super => "super",
            Tok::Where => "where",
            Tok::Ensures => "ensures",
            Tok::Invariant => "invariant",
            Tok::Law => "law",
            Tok::With => "with",
            Tok::Effect => "effect",
            Tok::Unsized => "unsized",
            Tok::Sealed => "sealed",
            Tok::Const => "const",
            Tok::Static => "static",
            Tok::Extern => "extern",
            Tok::LParen => "(",
            Tok::RParen => ")",
            Tok::LBrace => "{",
            Tok::RBrace => "}",
            Tok::LBracket => "[",
            Tok::RBracket => "]",
            Tok::Hash => "#",
            Tok::Question => "?",
            Tok::Comma => ",",
            Tok::Colon => ":",
            Tok::ColonColon => "::",
            Tok::Semi => ";",
            Tok::Dot => ".",
            Tok::DotDot => "..",
            Tok::DotDotEq => "..=",
            Tok::Arrow => "->",
            Tok::FatArrow => "=>",
            Tok::Eq => "=",
            Tok::EqEq => "==",
            Tok::NotEq => "!=",
            Tok::Lt => "<",
            Tok::Le => "<=",
            Tok::Gt => ">",
            Tok::Ge => ">=",
            Tok::Plus => "+",
            Tok::Minus => "-",
            Tok::Star => "*",
            Tok::Slash => "/",
            Tok::Percent => "%",
            Tok::Bang => "!",
            Tok::Amp => "&",
            Tok::AndAnd => "&&",
            Tok::OrOr => "||",
            Tok::Pipe => "|",
            Tok::Caret => "^",
            Tok::Shl => "<<",
        };
        String::of(&f"`{s}`")
    }
}

/// The tokens, the comments between them, and the pieces of the format
/// strings, of all of `src`.
pub fn lex<'s>(src: &'s str) -> Result<Lexed<'s>, Error> {
    let mut pieces = List::new();
    let (toks, comments) = lex_between(src, 0, src.len(), &mut pieces)?;
    Ok(Lexed { toks, comments, pieces })
}

/// The tokens of `src` from `from` to `to`, with an `Eof` at `to`, and the
/// comments between them, both in order and where they are in all of
/// `src`. Format strings' pieces go into `pieces`.
fn lex_between<'s>(
    src: &'s str,
    from: usize,
    to: usize,
    pieces: &mut List<FPiece<'s>>,
) -> Result<(List<Token<'s>>, List<Span>), Error> {
    let bytes = src.as_bytes();
    let mut toks = List::new();
    let mut comments = List::new();
    let mut i = from;

    while i < to {
        let c = byte(bytes, i);
        let start = i;

        if is_ws(c) {
            i = i + 1;
            continue;
        }
        if c == b'/' && at(bytes, i + 1) == Some(b'/') {
            while i < bytes.len() && byte(bytes, i) != b'\n' {
                i = i + 1;
            }
            let end = start + sub(src, start, i).trim_end().len();
            let span = Span::new(start, end);
            // `///`, but not `////`, which is a plain comment, as in Rust.
            let text = sub(src, start, end);
            let doc = match text.strip_prefix("///") {
                Some(text) => match text.starts_with('/') {
                    true => None,
                    false => Some(Tok::Doc(text)),
                },
                None => None,
            };
            let doc = match (doc, text.strip_prefix("//!")) {
                (Some(d), _) => Some(d),
                (None, Some(text)) => Some(Tok::InnerDoc(text)),
                (None, None) => None,
            };
            match doc {
                Some(tok) => toks.push(Token { tok, span }),
                None => comments.push(span),
            }
            continue;
        }

        let tok = if is_digit(c) {
            let (tok, end) = number(src, i)?;
            i = end;
            tok
        } else if c == b'f' && at(bytes, i + 1) == Some(b'"') {
            let (list, end) = fstring(src, i, pieces)?;
            i = end;
            Tok::FStr(list)
        } else if c == b'"' {
            i = quoted(src, i, Quote::Str)?.end;
            Tok::Str
        } else if c == b'b' && (at(bytes, i + 1) == Some(b'"') || at(bytes, i + 1) == Some(b'\'')) {
            match byte(bytes, i + 1) {
                b'"' => {
                    i = quoted(src, i + 1, Quote::ByteStr)?.end;
                    Tok::ByteStr
                },
                _ => {
                    let q = quoted(src, i + 1, Quote::Byte)?;
                    i = q.end;
                    Tok::Byte(q.first as u8)
                },
            }
        } else if c == b'\'' && is_char_literal(src, i) {
            let q = quoted(src, i, Quote::Char)?;
            i = q.end;
            Tok::Char(char::from_u32(q.first).expect("one character"))
        } else if is_alpha(c) || c == b'_' {
            while i < bytes.len() && (is_alnum(byte(bytes, i)) || byte(bytes, i) == b'_') {
                i = i + 1;
            }
            keyword(sub(src, start, i))
        } else if c == b'\'' {
            i = i + 1;
            while i < bytes.len() && (is_alnum(byte(bytes, i)) || byte(bytes, i) == b'_') {
                i = i + 1;
            }
            if i == start + 1 || is_digit(byte(bytes, start + 1)) {
                let span = Span::new(start, start + 1);
                return Err(Error::syntax(span, "expected a lifetime name after `'`, like `'a`"));
            }
            // `'ab'` is no lifetime, but a character literal of two.
            if at(bytes, i) == Some(b'\'') {
                return Err(Error::syntax(
                    Span::new(start, i + 1),
                    "a character literal holds exactly one character",
                ));
            }
            Tok::Lifetime(sub(src, start, i))
        } else {
            let (tok, len) = punct(c, at(bytes, i + 1), at(bytes, i + 2));
            if len == 0 {
                let ch = char_at(src, start).expect("a character starts here");
                let span = Span::new(start, start + ch.len_utf8());
                return Err(Error::owned(span, String::of(&f"unexpected character `{ch}`")));
            }
            i = i + len;
            tok
        };
        toks.push(Token { tok, span: Span::new(start, i) });
    }

    toks.push(Token { tok: Tok::Eof, span: Span::new(to, to) });
    Ok((toks, comments))
}

/// The keyword `word` is, or else a name.
fn keyword<'s>(word: &'s str) -> Tok<'s> {
    match word {
        "fn" => Tok::Fn,
        "let" => Tok::Let,
        "if" => Tok::If,
        "else" => Tok::Else,
        "true" => Tok::True,
        "false" => Tok::False,
        "struct" => Tok::Struct,
        "enum" => Tok::Enum,
        "trait" => Tok::Trait,
        "impl" => Tok::Impl,
        "for" => Tok::For,
        "in" => Tok::In,
        "match" => Tok::Match,
        "mut" => Tok::Mut,
        "move" => Tok::Move,
        "while" => Tok::While,
        "loop" => Tok::Loop,
        "unsafe" => Tok::Unsafe,
        "return" => Tok::Return,
        "break" => Tok::Break,
        "continue" => Tok::Continue,
        "type" => Tok::Type,
        "as" => Tok::As,
        "pub" => Tok::Pub,
        "export" => Tok::Export,
        "mod" => Tok::Mod,
        "use" => Tok::Use,
        "crate" => Tok::Crate,
        "super" => Tok::Super,
        "where" => Tok::Where,
        "ensures" => Tok::Ensures,
        "invariant" => Tok::Invariant,
        "law" => Tok::Law,
        "with" => Tok::With,
        "effect" => Tok::Effect,
        "unsized" => Tok::Unsized,
        "sealed" => Tok::Sealed,
        "const" => Tok::Const,
        "static" => Tok::Static,
        "extern" => Tok::Extern,
        name => Tok::Ident(name),
    }
}

/// The punctuation or operator starting with byte `c`, followed by
/// `next` and `third`, and how many bytes it has: none if it's none.
fn punct<'s>(c: u8, next: Option<u8>, third: Option<u8>) -> (Tok<'s>, usize) {
    match (c, next, third) {
        (b'.', Some(b'.'), Some(b'=')) => (Tok::DotDotEq, 3),
        (b'.', Some(b'.'), _) => (Tok::DotDot, 2),
        (b'-', Some(b'>'), _) => (Tok::Arrow, 2),
        (b'=', Some(b'>'), _) => (Tok::FatArrow, 2),
        (b':', Some(b':'), _) => (Tok::ColonColon, 2),
        (b'=', Some(b'='), _) => (Tok::EqEq, 2),
        (b'!', Some(b'='), _) => (Tok::NotEq, 2),
        (b'<', Some(b'='), _) => (Tok::Le, 2),
        (b'>', Some(b'='), _) => (Tok::Ge, 2),
        (b'&', Some(b'&'), _) => (Tok::AndAnd, 2),
        (b'|', Some(b'|'), _) => (Tok::OrOr, 2),
        (b'+', Some(b'='), _) => (Tok::OpEq(OpEq::Add), 2),
        (b'-', Some(b'='), _) => (Tok::OpEq(OpEq::Sub), 2),
        (b'*', Some(b'='), _) => (Tok::OpEq(OpEq::Mul), 2),
        (b'/', Some(b'='), _) => (Tok::OpEq(OpEq::Div), 2),
        (b'%', Some(b'='), _) => (Tok::OpEq(OpEq::Rem), 2),
        (b'&', Some(b'='), _) => (Tok::OpEq(OpEq::And), 2),
        (b'|', Some(b'='), _) => (Tok::OpEq(OpEq::Or), 2),
        (b'^', Some(b'='), _) => (Tok::OpEq(OpEq::Xor), 2),
        (b'<', Some(b'<'), Some(b'=')) => (Tok::OpEq(OpEq::Shl), 3),
        (b'<', Some(b'<'), _) => (Tok::Shl, 2),
        (b'^', _, _) => (Tok::Caret, 1),
        (b'&', _, _) => (Tok::Amp, 1),
        (b'|', _, _) => (Tok::Pipe, 1),
        (b'(', _, _) => (Tok::LParen, 1),
        (b')', _, _) => (Tok::RParen, 1),
        (b'{', _, _) => (Tok::LBrace, 1),
        (b'}', _, _) => (Tok::RBrace, 1),
        (b'[', _, _) => (Tok::LBracket, 1),
        (b']', _, _) => (Tok::RBracket, 1),
        (b'#', _, _) => (Tok::Hash, 1),
        (b'?', _, _) => (Tok::Question, 1),
        (b',', _, _) => (Tok::Comma, 1),
        (b':', _, _) => (Tok::Colon, 1),
        (b';', _, _) => (Tok::Semi, 1),
        (b'.', _, _) => (Tok::Dot, 1),
        (b'=', _, _) => (Tok::Eq, 1),
        (b'<', _, _) => (Tok::Lt, 1),
        (b'>', _, _) => (Tok::Gt, 1),
        (b'+', _, _) => (Tok::Plus, 1),
        (b'-', _, _) => (Tok::Minus, 1),
        (b'*', _, _) => (Tok::Star, 1),
        (b'/', _, _) => (Tok::Slash, 1),
        (b'%', _, _) => (Tok::Percent, 1),
        (b'!', _, _) => (Tok::Bang, 1),
        _ => (Tok::Eof, 0),
    }
}

/// The integer literal starting with the digit at `start`, and where it
/// ends.
fn number<'s>(src: &'s str, start: usize) -> Result<(Tok<'s>, usize), Error> {
    let bytes = src.as_bytes();
    let c = byte(bytes, start);
    let mut i = start;
    let radix: u64 = match (c, at(bytes, i + 1)) {
        (b'0', Some(b'x')) => 16,
        (b'0', Some(b'b')) => 2,
        (b'0', Some(b'o')) => 8,
        (b'0', Some(b'X')) => return Err(upper_prefix(start, "x")),
        (b'0', Some(b'B')) => return Err(upper_prefix(start, "b")),
        (b'0', Some(b'O')) => return Err(upper_prefix(start, "o")),
        _ => 10,
    };
    if radix != 10 {
        i = i + 2;
    }
    // Its digits: hexadecimal ones for any radix, so that `0b102` says `2`
    // isn't a binary digit rather than that `2` isn't a suffix. A suffix
    // starts with `i` or `u`, which aren't any.
    let first = i;
    while i < bytes.len() && (is_hex(byte(bytes, i)) || byte(bytes, i) == b'_') {
        i = i + 1;
    }
    let mut count = 0usize;
    let mut j = first;
    while j < i {
        if byte(bytes, j) != b'_' {
            count = count + 1;
        }
        j = j + 1;
    }
    if count == 0 {
        let prefix = sub(src, start, first);
        return Err(Error::owned(
            Span::new(start, first),
            String::of(&f"`{prefix}` needs digits after it"),
        ));
    }
    // Each digit's value, and the literal's, while it fits.
    let mut n: Option<u64> = Some(0);
    let mut j = first;
    while j < i {
        let b = byte(bytes, j);
        j = j + 1;
        if b == b'_' {
            continue;
        }
        let d = digit_value(b);
        if d >= radix {
            let what = match radix {
                2 => "a binary digit",
                8 => "an octal digit",
                _ => "a decimal digit",
            };
            let digit = sub(src, j - 1, j);
            return Err(Error::owned(Span::new(j - 1, j), String::of(&f"`{digit}` isn't {what}")));
        }
        n = match n {
            Some(v) => match checked_mul(v, radix) {
                Some(v) => checked_add(v, d),
                None => None,
            },
            None => None,
        };
    }
    let Some(n) = n else {
        return Err(Error::syntax(Span::new(start, i), "integer literal is too large"));
    };
    // A suffix, `255u8`, says which integer type it is.
    let at_suffix = i;
    while i < bytes.len() && (is_alnum(byte(bytes, i)) || byte(bytes, i) == b'_') {
        i = i + 1;
    }
    let suffix = match sub(src, at_suffix, i) {
        "" => None,
        s => match IntTy::named(s) {
            Some(t) => Some(t),
            None => {
                return Err(Error::owned(
                    Span::new(at_suffix, i),
                    String::of(
                        &f"`{s}` isn't an integer type, so it can't be a literal's suffix, as `u8` is in `255u8`",
                    ),
                ));
            },
        },
    };
    Ok((Tok::Int(n, suffix), i))
}

/// `0X`, `0B` or `0O` at `start`: the prefix is written in lowercase.
fn upper_prefix(start: usize, lower: &str) -> Error {
    Error::owned(Span::new(start, start + 2), String::of(&f"write `0{lower}`, in lowercase"))
}

/// The value of hexadecimal digit `b`, or 16 if it isn't one.
fn digit_value(b: u8) -> u64 {
    match b {
        b'0'..=b'9' => (b - b'0') as u64,
        b'a'..=b'f' => (b - b'a') as u64 + 10,
        b'A'..=b'F' => (b - b'A') as u64 + 10,
        _ => 16,
    }
}

/// The format string starting with the `f` at `start`: where its pieces
/// are in `pieces`, and where it ends, after the closing quote. Its text is
/// a string literal's, with `{{` and `}}` for braces; a hole is an
/// expression, and `:?` after it for `Debug`.
fn fstring<'s>(
    src: &'s str,
    start: usize,
    pieces: &mut List<FPiece<'s>>,
) -> Result<(Pieces, usize), Error> {
    let bytes = src.as_bytes();
    // Its own pieces, put in `pieces` at the end, after those of the
    // format strings in its holes, so they're all together.
    let mut own: List<FPiece<'s>> = List::new();
    let mut text = false;
    let mut i = start + 2;
    loop {
        let Some(c) = char_at(src, i) else {
            return Err(Error::syntax(Span::new(start, start + 2), "this format string never ends"));
        };
        match c {
            '"' => {
                i = i + 1;
                break;
            },
            '\\' => {
                i = escape(src, i, Quote::Str)?.end;
                text = true;
            },
            '{' | '}' => {
                // `{{` and `}}` are the characters.
                if at(bytes, i + 1) == Some(c as u8) {
                    text = true;
                    i = i + 2;
                    continue;
                }
                if c == '}' {
                    return Err(Error::syntax(
                        Span::new(i, i + 1),
                        "a `}` in a format string closes a hole; write `}}` for the character",
                    ));
                }
                if text {
                    own.push(FPiece::Text);
                    text = false;
                }
                let (h, end) = hole(src, i, pieces)?;
                own.push(FPiece::Hole(h));
                i = end;
            },
            c => {
                text = true;
                i = i + c.len_utf8();
            },
        }
    }
    if text {
        own.push(FPiece::Text);
    }
    let first = pieces.len();
    let len = own.len();
    for p in own {
        pieces.push(p);
    }
    Ok((Pieces { first, len }, i))
}

/// The hole of a format string starting with the `{` at `start`, and where
/// it ends, after its `}`. Its expression ends at the first `}` or `:` not
/// in brackets, braces or parentheses of its own, but for a `::`; a `:`
/// starts what it says of how it's written. It can't hold a `"`, nor a
/// comment.
fn hole<'s>(
    src: &'s str,
    start: usize,
    pieces: &mut List<FPiece<'s>>,
) -> Result<(Hole<'s>, usize), Error> {
    let bytes = src.as_bytes();
    let mut i = start + 1;
    let mut depth = 0usize;
    let end = loop {
        let Some(c) = char_at(src, i) else { return Err(never_closed(start)) };
        match c {
            // A `"` that ends the format string, rather than starting a
            // string in the hole: no `}` follows it on the line.
            '"' => {
                if depth == 0 && !rest_of_line(src, i + 1).contains('}') {
                    return Err(never_closed(start));
                }
                return Err(Error::syntax(
                    Span::new(i, i + 1),
                    "a hole in a format string can't hold a `\"`; work out what needs one in a `let` first",
                ));
            },
            '/' => {
                if at(bytes, i + 1) == Some(b'/') {
                    return Err(Error::syntax(
                        Span::new(i, i + 2),
                        "a hole in a format string can't hold a comment",
                    ));
                }
            },
            '\'' => {
                if is_char_literal(src, i) {
                    i = quoted(src, i, Quote::Char)?.end;
                    continue;
                }
            },
            '(' | '[' | '{' => depth = depth + 1,
            ')' | ']' => {
                if depth > 0 {
                    depth = depth - 1;
                }
            },
            '}' => {
                if depth == 0 {
                    break i;
                }
                depth = depth - 1;
            },
            ':' => {
                if at(bytes, i + 1) == Some(b':') {
                    i = i + 1;
                } else if depth == 0 {
                    break i;
                }
            },
            _ => {},
        }
        i = i + c.len_utf8();
    };
    if sub(src, start + 1, end).trim().is_empty() {
        return Err(Error::syntax(
            Span::new(start, end + 1),
            "a hole in a format string says what goes in it, as in `{x}`",
        ));
    }
    let (toks, comments) = lex_between(src, start + 1, end, pieces)?;
    let _ = comments;
    let mut doc = false;
    for t in toks.iter() {
        match t.tok {
            Tok::Doc(_) | Tok::InnerDoc(_) => doc = true,
            _ => {},
        }
    }
    if doc {
        return Err(Error::syntax(
            Span::new(start + 1, end),
            "a hole in a format string can't hold a comment",
        ));
    }
    // `Eof` is at `end` already: `lex_between` puts it at `to`.
    let mut i = end;
    let mut spec = FmtSpec { kind: FmtKind::Display, pad: None };
    let mut width_at = None;
    if at(bytes, i) == Some(b':') {
        let stop = match find_close(src, i) {
            Some(n) => n,
            None => i + 1,
        };
        let named = sub(src, start + 1, end).trim();
        let read = spec_of(src, i + 1, stop, named)?;
        match (read, at(bytes, stop) == Some(b'}')) {
            (Some((s, w)), true) => {
                spec = s;
                width_at = w;
            },
            _ => return Err(Error::syntax(Span::new(i, stop), SPEC_HELP)),
        }
        i = stop;
    }
    match at(bytes, i) {
        Some(b'}') => Ok((Hole { toks, spec, width_at, span: Span::new(start, i + 1) }, i + 1)),
        _ => { Err(never_closed(start)) },
    }
}

const SPEC_HELP: &str = "a hole in a format string can say `:?`, for `Debug`, `:x` or `:08x`, for hexadecimal, at least 8 digits, `:05`, for decimal, at least 5 characters, and `:<8`, `:^8` or `:>8` for a width, with a fill before the side and `?` or `x` after, as in `:*>8x`, and nothing else";

fn never_closed(start: usize) -> Error {
    Error::syntax(
        Span::new(start, start + 1),
        "this hole is never closed; write `{{` for the character",
    )
}

/// The source from `i` to the end of its line.
fn rest_of_line<'s>(src: &'s str, i: usize) -> &'s str {
    let rest = sub(src, i, src.len());
    match rest.find('\n') {
        Some(n) => sub(rest, 0, n),
        None => rest,
    }
}

/// Where the first `}` or `"` from `i` on is.
fn find_close(src: &str, i: usize) -> Option<usize> {
    let bytes = src.as_bytes();
    let mut j = i;
    while j < bytes.len() {
        if byte(bytes, j) == b'}' || byte(bytes, j) == b'"' {
            return Some(j);
        }
        j = j + 1;
    }
    None
}

/// Are all of `w`'s bytes decimal digits, and is there one at least?
fn digits(w: &str) -> bool {
    if w.is_empty() {
        return false;
    }
    for b in w.as_bytes() {
        if !is_digit(*b) {
            return false;
        }
    }
    true
}

/// The value of `w`, decimal digits, if it's at most `most`.
fn decimal(w: &str, most: u64) -> Option<u64> {
    let mut n = 0u64;
    for b in w.as_bytes() {
        n = n * 10 + (*b - b'0') as u64;
        if n > most {
            return None;
        }
    }
    Some(n)
}

/// The side of the width character `c` says.
fn side(c: char) -> Option<FmtAlign> {
    match c {
        '<' => Some(FmtAlign::Left),
        '^' => Some(FmtAlign::Center),
        '>' => Some(FmtAlign::Right),
        _ => None,
    }
}

/// The spec of a hole of a format string, written from `from` to `stop`
/// after its `:`, in a hole that holds `named`: `[[fill] side width]
/// [? | x]`, or `0` and a width, then `x` or nothing. A width is 1 to
/// 65535, or a variable, `w$`, whose span it gives too. `None` if it's
/// none of those.
fn spec_of(
    src: &str,
    from: usize,
    stop: usize,
    named: &str,
) -> Result<Option<(FmtSpec, Option<Span>)>, Error> {
    let written = sub(src, from, stop);
    let mut chars = written.chars();
    let first = chars.next();
    let second = chars.next();
    // The fill, if it's written, the side, and where the width starts.
    let mut pad: Option<(Option<char>, FmtAlign, usize)> = None;
    if let (Some(f), Some(s)) = (first, second) {
        if f != '{' && f != '}' && f != '\\' {
            if let Some(align) = side(s) {
                pad = Some((Some(f), align, f.len_utf8() + 1));
            }
        }
    }
    if pad.is_none() {
        if let Some(s) = first {
            if let Some(align) = side(s) {
                pad = Some((None, align, 1));
            }
        }
    }
    let Some((fill, align, skip)) = pad else {
        // `0` and a width, with `x` or not.
        if let Some(w) = written.strip_prefix('0') {
            let (w, hex) = match w.strip_suffix('x') {
                Some(w) => (w, true),
                None => (w, false),
            };
            if !digits(w) {
                return Ok(None);
            }
            let Some(n) = decimal(w, 0xFFFF_FFFF) else { return Ok(None) };
            let kind = if hex { FmtKind::Hex(n as usize) } else { FmtKind::Dec(n as usize) };
            return Ok(Some((FmtSpec { kind, pad: None }, None)));
        }
        // A width with no side says nothing of where the value goes.
        let mut n = written;
        loop {
            match n.strip_suffix('?') {
                Some(m) => n = m,
                None => match n.strip_suffix('x') {
                    Some(m) => n = m,
                    None => break,
                },
            }
        }
        if digits(n) {
            let n = written;
            return Err(Error::owned(
                Span::new(from, stop),
                String::of(
                    &f"say which side of the width `{named}` goes: `{{{named}:>{n}}}`, `{{{named}:<{n}}}` or `{{{named}:^{n}}}`",
                ),
            ));
        }
        let kind = match written {
            "?" => FmtKind::Debug,
            "x" => FmtKind::Hex(0),
            _ => return Ok(None),
        };
        return Ok(Some((FmtSpec { kind, pad: None }, None)));
    };
    let rest = sub(written, skip, written.len());
    let start = from + skip;
    let (width, width_at, after) = match rest.find('$') {
        // `w$`: a variable's.
        Some(d) => {
            let v = sub(rest, 0, d);
            if !is_name(v) {
                return Ok(None);
            }
            let name = Span::new(start, start + v.len());
            (FmtWidth::Var(String::from(v)), Some(name), sub(rest, d + 1, rest.len()))
        },
        None => {
            let bytes = rest.as_bytes();
            let mut k = 0;
            while k < bytes.len() && is_digit(byte(bytes, k)) {
                k = k + 1;
            }
            let w = sub(rest, 0, k);
            let after = sub(rest, k, rest.len());
            let at_w = Span::new(start, start + w.len());
            if digits(w) && all_zeros(w) {
                return Err(Error::syntax(at_w, "a width is at least 1"));
            }
            // `>08` would say both a fill and 0s.
            if !digits(w) || w.starts_with('0') {
                return Ok(None);
            }
            match decimal(w, 65535) {
                Some(n) => (FmtWidth::Lit(n as usize), None, after),
                None => return Err(Error::syntax(at_w, "a width is at most 65535")),
            }
        },
    };
    let kind = match after {
        "" => FmtKind::Display,
        "?" => FmtKind::Debug,
        "x" => FmtKind::Hex(0),
        _ => return Ok(None),
    };
    let pad = Some(FmtPad { fill, align, width });
    Ok(Some((FmtSpec { kind, pad }, width_at)))
}

fn all_zeros(w: &str) -> bool {
    for b in w.as_bytes() {
        if *b != b'0' {
            return false;
        }
    }
    true
}

/// Is `s` a variable's name: a letter or `_`, then letters, digits and
/// `_`s?
fn is_name(s: &str) -> bool {
    let bytes = s.as_bytes();
    if bytes.is_empty() || !(is_alpha(byte(bytes, 0)) || byte(bytes, 0) == b'_') {
        return false;
    }
    for b in bytes {
        if !(is_alnum(*b) || *b == b'_') {
            return false;
        }
    }
    true
}

/// Which kind of quoted literal `quoted` reads.
#[derive(Copy, Discard, Eq)]
enum Quote { Str, Char, ByteStr, Byte }

impl Quote {
    fn bytes(self) -> bool { self == Quote::ByteStr || self == Quote::Byte }

    fn one(self) -> bool { self == Quote::Char || self == Quote::Byte }
}

/// Does the `'` at `i` start a character literal, rather than a lifetime?
/// It does if it's followed by one character and a `'`, or by an escape:
/// `'a'`, `'é'`, `'\n'`, as against `'a`.
fn is_char_literal(src: &str, i: usize) -> bool {
    let rest = sub(src, i + 1, src.len());
    let mut chars = rest.chars();
    match chars.next() {
        Some('\\') => true,
        Some('\'') => true,
        Some(c) => chars.next() == Some('\'')
            || !(c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '_'),
        None => false,
    }
}

/// What reading a quoted literal or an escape gave: where it ends, and the
/// first character or byte it means, if it means any.
#[derive(Copy, Discard)]
struct Read { end: usize, first: u32 }

/// The quoted literal starting with the quote at `q`: where it ends, after
/// the closing quote, and what its first character means. Each escape
/// means one thing: `\u{..}` a character, in text, and `\x..` a byte, in a
/// byte literal.
fn quoted(src: &str, q: usize, kind: Quote) -> Result<Read, Error> {
    let bytes = src.as_bytes();
    let quote = byte(bytes, q);
    let what = match kind {
        Quote::Str => "string literal",
        Quote::ByteStr => "byte string literal",
        Quote::Char => "character literal",
        Quote::Byte => "byte literal",
    };
    let start = if kind.bytes() { q - 1 } else { q };
    let mut count = 0usize;
    let mut first: Option<u32> = None;
    let mut i = q + 1;
    loop {
        let Some(c) = char_at(src, i) else {
            return Err(Error::owned(
                Span::new(start, start + 1),
                String::of(&f"this {what} never ends"),
            ));
        };
        if c as u32 == quote as u32 {
            i = i + 1;
            break;
        }
        if kind.one() && (c == '\n' || c == '\r' || c == '\t') {
            return Err(Error::owned(
                Span::new(i, i + 1),
                String::of(
                    &f"a {what} can't hold a raw tab or line break; write it as an escape, like `\\n`",
                ),
            ));
        }
        count = count + 1;
        if c != '\\' {
            if kind.bytes() && !c.is_ascii() {
                return Err(Error::syntax(
                    Span::new(i, i + c.len_utf8()),
                    "a byte literal holds only ASCII characters; write other bytes as `\\x..`",
                ));
            }
            if first.is_none() {
                first = Some(c as u32);
            }
            i = i + c.len_utf8();
            continue;
        }
        let e = escape(src, i, kind)?;
        if first.is_none() {
            first = Some(e.first);
        }
        i = e.end;
    }
    if kind.one() && count != 1 {
        return Err(Error::owned(
            Span::new(start, i),
            String::of(&f"a {what} holds exactly one character"),
        ));
    }
    Ok(Read { end: i, first: first.unwrap_or(0) })
}

/// The escape at `esc`, a `\`, in a literal of kind `kind`: where it ends,
/// and what it means.
fn escape(src: &str, esc: usize, kind: Quote) -> Result<Read, Error> {
    let Some(e) = char_at(src, esc + 1) else { return Ok(Read { end: esc + 1, first: 0 }) };
    let mut i = esc + 1 + e.len_utf8();
    let simple: Option<u32> = match e {
        'n' => Some(10),
        'r' => Some(13),
        't' => Some(9),
        '\\' => Some(92),
        '0' => Some(0),
        '\'' => Some(39),
        '"' => Some(34),
        _ => None,
    };
    if let Some(b) = simple {
        return Ok(Read { end: i, first: b });
    }
    // A `\` that ends a line of a string, a byte string or a format string
    // goes on to the next, without the line break or the blanks that start
    // it, as Rust's does: a long string written over lines.
    if (e == '\n' || e == '\r') && !kind.one() {
        if e == '\r' && !sub(src, i, src.len()).starts_with('\n') {
            return Err(Error::syntax(
                Span::new(esc, i),
                "a `\\` that ends a line goes on to the next; a `\\r` alone isn't one",
            ));
        }
        let bytes = src.as_bytes();
        while i < bytes.len()
            && (byte(bytes, i) == b' '
                || byte(bytes, i) == b'\t'
                || byte(bytes, i) == b'\n'
                || byte(bytes, i) == b'\r')
        {
            i = i + 1;
        }
        return Ok(Read { end: i, first: 0 });
    }
    match e {
        'x' => {
            let hex = match src.get(i, i + 2) {
                Some(h) => h,
                None => "",
            };
            let hex = match hex.len() == 2 && is_hex_str(hex) {
                true => hex,
                false => {
                    return Err(Error::syntax(
                        Span::new(esc, i),
                        "`\\x` takes two hexadecimal digits, as in `\\x7F`",
                    ));
                },
            };
            let hb = hex.as_bytes();
            let b = digit_value(byte(hb, 0)) * 16 + digit_value(byte(hb, 1));
            // In a string or a character, only ASCII, which is a whole
            // character in UTF-8: a byte past it is part of one.
            if !kind.bytes() && b > 127 {
                return Err(Error::owned(
                    Span::new(esc, i + 2),
                    String::of(
                        &f"`\\x{hex}` isn't ASCII, so it's a byte, not a character; write the character as `\\u{{{hex}}}`",
                    ),
                ));
            }
            Ok(Read { end: i + 2, first: b as u32 })
        },
        'u' => {
            if kind.bytes() {
                return Err(Error::syntax(
                    Span::new(esc, i),
                    "`\\u{..}` escapes are for characters; write a byte as `\\x..`",
                ));
            }
            let rest = sub(src, i, src.len());
            let close = rest.find('}');
            let digits = match (close, rest.starts_with('{')) {
                (Some(c), true) => sub(rest, 1, c),
                _ => "",
            };
            if digits.is_empty() || digits.len() > 6 || !is_hex_str(digits) {
                return Err(Error::syntax(
                    Span::new(esc, i),
                    "`\\u` takes one to six hexadecimal digits in braces, as in `\\u{20AC}`",
                ));
            }
            let end = i + close.expect("found") + 1;
            let mut n = 0u64;
            for b in digits.as_bytes() {
                n = n * 16 + digit_value(*b);
            }
            match char::from_u32(n as u32) {
                Some(c) => Ok(Read { end, first: c as u32 }),
                None => Err(Error::owned(
                    Span::new(esc, end),
                    String::of(&f"`\\u{{{digits}}}` isn't a Unicode scalar value"),
                )),
            }
        },
        _ => Err(Error::owned(Span::new(esc, i), String::of(&f"unknown escape `\\{e}`"))),
    }
}

fn is_hex_str(s: &str) -> bool {
    for b in s.as_bytes() {
        if !is_hex(*b) {
            return false;
        }
    }
    true
}

/// Character `c` as a literal: `'a'`, `'\n'`.
pub fn char_literal(c: char) -> String {
    let mut out = String::from("'");
    match c {
        '"' => out.push('"'),
        '\0' => out.push_str("\\0"),
        '\'' => out.push_str("\\'"),
        c => escape_char(c, &mut out),
    }
    out.push('\'');
    out
}

/// Byte `b` as a literal: `b'a'`, `b'\xFF'`.
pub fn byte_literal(b: u8) -> String {
    let mut out = String::from("b'");
    match b {
        b'\n' => out.push_str("\\n"),
        b'\r' => out.push_str("\\r"),
        b'\t' => out.push_str("\\t"),
        b'\\' => out.push_str("\\\\"),
        0 => out.push_str("\\0"),
        b'\'' => out.push_str("\\'"),
        b' '..=b'~' => out.push(char::from_u32(b as u32).expect("ASCII")),
        b => {
            out.push_str("\\x");
            out.push(hex_digit(b / 16));
            out.push(hex_digit(b % 16));
        },
    }
    out.push('\'');
    out
}

fn hex_digit(d: u8) -> char {
    let b = if d < 10 { b'0' + d } else { b'A' + d - 10 };
    char::from_u32(b as u32).expect("ASCII")
}

/// `c` as `char::escape_debug` writes it, for the characters messages
/// show: escapes for `\n`, `\r`, `\t`, `\\` and the other controls.
fn escape_char(c: char, out: &mut String) {
    match c {
        '\n' => out.push_str("\\n"),
        '\r' => out.push_str("\\r"),
        '\t' => out.push_str("\\t"),
        '\\' => out.push_str("\\\\"),
        c => {
            if c as u32 < 32 || c as u32 == 127 {
                let n = c as u32;
                out.push_str(String::of(&f"\\u{{{n:x}}}").as_str());
            } else {
                out.push(c);
            }
        },
    }
}
