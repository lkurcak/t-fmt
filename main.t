//! t-fmt: T's formatter, `t fmt`, written in T.

use alloc::list::List;
use core::fmt::Write;
use alloc::string::String;
use std::io::Error;
use std::Os;

use lexer::{FPiece, Lexed, Token};

mod ast;
mod error;
mod lexer;
mod parser;
mod pretty;
mod text;

fn main(os: Os) -> Result<(), Error> {
    let mut out = os.stdout;
    let mut err = os.stderr;
    let (Some(mode), Some(path)) = (os.args.get(0), os.args.get(1)) else {
        return err.line("usage: t-fmt --tokens|--parse|--print <file.t>");
    };
    let src = os.fs.read_to_string(path)?;
    match mode {
        "--tokens" => match lexer::lex(src.as_str()) {
            Ok(lexed) => {
                let mut s = String::new();
                dump(&lexed, &lexed.toks, 0, &mut s);
                out.put(s.as_str())
            },
            Err(e) => out.line(&f"error {e.span.start}..{e.span.end}: {e.message}"),
        },
        // Whether the file parses, or its syntax error, as the oracle
        // prints them: for comparing the two.
        "--parse" => {
            let lexed = match lexer::lex(src.as_str()) {
                Ok(lexed) => lexed,
                Err(e) => return out.line(&f"error {e.span.start}..{e.span.end}: {e.message}"),
            };
            match parser::parse(&lexed) {
                Ok(_) => out.line("ok"),
                Err(e) => out.line(&f"error {e.span.start}..{e.span.end}: {e.message}"),
            }
        },
        // What `t fmt` would make of the file, or its syntax error, as the
        // oracle prints them: for comparing the two.
        "--print" => {
            let lexed = match lexer::lex(src.as_str()) {
                Ok(lexed) => lexed,
                Err(e) => return out.line(&f"error {e.span.start}..{e.span.end}: {e.message}"),
            };
            match parser::parse(&lexed) {
                Ok(program) => out.put(pretty::format(src.as_str(), &lexed, &program).as_str()),
                Err(e) => out.line(&f"error {e.span.start}..{e.span.end}: {e.message}"),
            }
        },
        _ => err.line("usage: t-fmt --tokens|--parse|--print <file.t>"),
    }
}

/// Each of `toks` on a line, with where it is, and a format string's
/// holes' tokens after it, indented.
fn dump(lexed: &Lexed, toks: &List<Token>, depth: usize, s: &mut String) {
    for t in toks.iter() {
        let mut d = 0;
        while d < depth {
            s.push_str("  ");
            d = d + 1;
        }
        s.line(&f"{t.tok.describe()} {t.span.start}..{t.span.end}");
        if let lexer::Tok::FStr(p) = t.tok {
            let mut i = p.first;
            while i < p.first + p.len {
                if let Some(FPiece::Hole(h)) = lexed.pieces.get(i) {
                    dump(lexed, &h.toks, depth + 1, s);
                }
                i = i + 1;
            }
        }
    }
}
