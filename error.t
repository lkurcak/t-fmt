//! What's wrong with a file that doesn't lex or parse: where, and why.

use alloc::string::String;

/// Bytes `start` up to, not including, `end` of the source.
#[derive(Copy, Discard, Eq)]
pub struct Span { pub start: usize, pub end: usize }

impl Span {
    pub fn new(start: usize, end: usize) -> Span { Span { start, end } }

    /// From the start of `self` to the end of `other`.
    pub fn to(self, other: Span) -> Span { Span { start: self.start, end: other.end } }
}

/// A syntax error: the source at `span` isn't what T allows there.
#[derive(Discard)]
pub struct Error { pub span: Span, pub message: String }

impl Error {
    pub fn syntax(span: Span, message: &str) -> Error {
        Error { span, message: String::from(message) }
    }

    /// One whose message is worked out, as an f-string is.
    pub fn owned(span: Span, message: String) -> Error { Error { span, message } }
}
