//! The printer: a syntax tree back to source, in the one T style, with
//! the source's comments and single blank lines. A port of t-lang's
//! `src/pretty.rs` (as `t fmt` uses it), `src/doc.rs`, `src/trivia.rs`
//! and `src/fmt.rs`.

use alloc::string::String;

use crate::ast::Program;
use crate::lexer::Lexed;

/// `program`, parsed from `src`, whose tokens and comments are `lexed`,
/// printed as `t fmt` prints it.
pub fn format(src: &str, lexed: &Lexed, program: &Program) -> String {
    let _ = (src, lexed, program);
    panic("todo: the printer")
}
