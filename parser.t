//! The parser: tokens to a syntax tree, a port of t-lang's `src/parser.rs`.

use crate::ast::Program;
use crate::error::Error;
use crate::lexer::Lexed;

/// The syntax tree of the file `lexed` is the tokens of, or the first
/// thing wrong with it. Doc comments are attached to what they document;
/// the rest are `Program::stray_docs`.
pub fn parse(lexed: &Lexed) -> Result<Program, Error> {
    let _ = lexed;
    panic("todo: the parser")
}
