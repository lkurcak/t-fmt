//! What `t fmt` has to keep that isn't in the syntax tree: comments, and
//! the blank lines between things. A port of t-lang's `src/trivia.rs`.
//!
//! The printer walks the tree in source order and, at each place a comment
//! can go, asks `Trivia` for the comments up to there. Each comment is
//! handed out once, in order, so none is lost or duplicated; one that sits
//! somewhere the printer never asks about (inside `a + b`, say) comes out at
//! the next place it does ask, on a line of its own.
//!
//! A `///` that documents nothing (`Program::stray_docs`) is trivia too,
//! but moving one can make it document something: before a field, it
//! would document the field. So inside a struct or enum, they're held back
//! until its `}` (`hold_docs`).

use alloc::list::List;
use alloc::string::String;

use crate::error::Span;
use crate::lexer::{Tok, Token};
use crate::text::{byte, item, sub};

/// A comment, and the place in the source to print it at: where it is,
/// unless it's held back.
#[derive(Copy, Discard)]
struct Held { at: usize, span: Span }

/// A file's comments, to hand out in order, and its tokens, to say where
/// things are.
#[derive(Discard)]
pub struct Trivia<'s> {
    src: &'s str,
    /// The tokens, but for doc comments, ending with an `Eof`.
    toks: List<Token<'s>>,
    /// The comments, in the order they're printed.
    comments: List<Held>,
    /// The first comment not printed yet.
    next: usize,
    /// Where each comment is in the source, in order.
    spans: List<Span>,
}

/// A comment after code on the same line, with any comments lined up under
/// it on the lines that follow:
///
/// ```text
/// print(h(true));   // expect: 1
///                   // expect: 2
/// ```
#[derive(Discard)]
pub struct Trailing { pub text: String, pub more: List<String> }

/// A comment on a line of its own.
#[derive(Discard)]
pub struct Leading {
    pub text: String,
    /// Whether a blank line comes before it.
    pub blank: bool,
}

impl<'s> Trivia<'s> {
    /// The trivia of `src`, whose tokens, doc comments left out, are
    /// `toks`, and whose comments are at `comments`, in order.
    pub fn new(src: &'s str, toks: List<Token<'s>>, comments: List<Span>) -> Trivia<'s> {
        let mut held = List::new();
        for c in comments.iter() {
            held.push(Held { at: c.start, span: *c });
        }
        Trivia { src, toks, comments: held, next: 0, spans: comments }
    }

    /// Holds back the doc comments not printed yet that are between `from`
    /// and `to`, the `}` that ends a struct or enum, to print there, where
    /// they can't document a field or variant.
    pub fn hold_docs(&mut self, from: usize, to: usize) {
        let mut i = self.next;
        while i < self.comments.len() {
            let c = *item(&self.comments, i);
            let text = sub(self.src, c.span.start, c.span.end);
            let doc = text.starts_with("///") && !text.starts_with("////");
            if from <= c.span.start && c.span.start < to && doc {
                if let Some(h) = self.comments.get_mut(i) {
                    h.at = to - 1;
                }
            }
            i = i + 1;
        }
        // Stable, so comments printed at the same place keep their order.
        let next = self.next;
        sort(&mut self.comments, next, |h| h.at);
    }

    fn text(&self, c: Span) -> String { String::from(sub(self.src, c.start, c.end)) }

    /// Where the line that `offset` is on starts.
    fn line_start(&self, offset: usize) -> usize {
        let bytes = self.src.as_bytes();
        let mut i = offset;
        while i > 0 && byte(bytes, i - 1) != b'\n' {
            i = i - 1;
        }
        i
    }

    /// Is nothing but whitespace before `c` on its line?
    fn own_line(&self, c: Span) -> bool {
        sub(self.src, self.line_start(c.start), c.start).trim().is_empty()
    }

    fn column(&self, offset: usize) -> usize {
        sub(self.src, self.line_start(offset), offset).chars().count()
    }

    /// The index of the first token starting at or after `pos`.
    fn tok_index(&self, pos: usize) -> usize {
        let mut lo = 0usize;
        let mut hi = self.toks.len();
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if item(&self.toks, mid).span.start < pos {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    /// Are there comments not printed yet that start before `pos`?
    pub fn any_before(&self, pos: usize) -> bool {
        match self.comments.get(self.next) {
            Some(h) => h.at < pos,
            None => false,
        }
    }

    /// Takes the comments not printed yet that start before `pos`.
    pub fn leading(&mut self, pos: usize) -> List<Leading> {
        let mut out = List::new();
        while let Some(h) = self.comments.get(self.next) {
            if h.at >= pos {
                break;
            }
            let c = h.span;
            out.push(Leading { text: self.text(c), blank: self.blank_before(c.start) });
            self.next = self.next + 1;
        }
        out
    }

    /// Takes the comment after the code that ends at `end`, if it's on the
    /// same line with nothing but `,` or `;` between.
    pub fn trailing(&mut self, end: usize) -> Option<Trailing> {
        let h = *self.comments.get(self.next)?;
        let c = h.span;
        if h.at != c.start
            || c.start < end
            || self.own_line(c)
            || sub(self.src, end, c.start).contains('\n')
        {
            return None;
        }
        let mut i = self.tok_index(end);
        let to = self.tok_index(c.start);
        while i < to {
            match item(&self.toks, i).tok {
                Tok::Comma | Tok::Semi => {},
                _ => return None,
            }
            i = i + 1;
        }
        let text = self.text(c);
        let column = self.column(c.start);
        let mut prev_end = c.end;
        self.next = self.next + 1;

        let mut more = List::new();
        while let Some(h) = self.comments.get(self.next) {
            let c = h.span;
            if h.at != c.start
                || newlines(sub(self.src, prev_end, c.start)) != 1
                || !self.own_line(c)
                || self.column(c.start) != column
            {
                break;
            }
            more.push(self.text(c));
            prev_end = c.end;
            self.next = self.next + 1;
        }
        Some(Trailing { text, more })
    }

    /// Is there a blank line between `pos` and the token or comment before
    /// it?
    pub fn blank_before(&self, pos: usize) -> bool {
        let i = self.tok_index(pos);
        let tok_end = if i == 0 { 0 } else { item(&self.toks, i - 1).span.end };
        // The index of the first comment starting at or after `pos`.
        let mut c = 0usize;
        let mut hi = self.spans.len();
        while c < hi {
            let mid = c + (hi - c) / 2;
            if item(&self.spans, mid).start < pos {
                c = mid + 1;
            } else {
                hi = mid;
            }
        }
        let comment_end = if c == 0 { 0 } else { item(&self.spans, c - 1).end };
        let prev = core::cmp::min(core::cmp::max(tok_end, comment_end), pos);
        // Only whitespace in between, so two newlines make a blank line.
        prev > 0 && newlines(sub(self.src, prev, pos)) >= 2
    }

    /// Where the first `tok` at or after `pos` is.
    pub fn find(&self, pos: usize, tok: Tok) -> Span {
        let mut i = self.tok_index(pos);
        while i < self.toks.len() {
            let t = item(&self.toks, i);
            if t.tok == tok {
                return t.span;
            }
            i = i + 1;
        }
        Span::new(self.src.len(), self.src.len())
    }

    /// How the literal at `span` is written, `0xFF_u8` or `"a\u{20AC}"`,
    /// or the literal pattern, `-0x80..=0x7F`: its tokens, with nothing
    /// between them. `None` if there's anything else there.
    pub fn spelled(&self, span: Span) -> Option<String> {
        let mut out = String::new();
        let mut i = self.tok_index(span.start);
        while i < self.toks.len() {
            let t = item(&self.toks, i);
            if t.span.start >= span.end {
                break;
            }
            match t.tok {
                Tok::Int(..)
                | Tok::Byte(_)
                | Tok::Char(_)
                | Tok::Str
                | Tok::FStr(_)
                | Tok::ByteStr
                | Tok::Minus
                | Tok::DotDot
                | Tok::DotDotEq => out.push_str(sub(self.src, t.span.start, t.span.end)),
                _ => return None,
            }
            i = i + 1;
        }
        if out.is_empty() { None } else { Some(out) }
    }

    /// The token just before the one at `pos`: the `fn` before a function's
    /// name, or the `let` before a pattern.
    pub fn before(&self, pos: usize) -> Span {
        let i = self.tok_index(pos);
        item(&self.toks, if i == 0 { 0 } else { i - 1 }).span
    }
    /// The literal at `span` as the source writes it, where something else
    /// is there too, as parentheses: its literal tokens, with nothing
    /// between them.
    pub fn literal(&self, span: Span) -> String {
        let mut out = String::new();
        let mut i = self.tok_index(span.start);
        while i < self.toks.len() {
            let t = item(&self.toks, i);
            if t.span.start >= span.end {
                break;
            }
            match t.tok {
                Tok::Str | Tok::ByteStr | Tok::FStr(_) => {
                    out.push_str(sub(self.src, t.span.start, t.span.end));
                },
                _ => {},
            }
            i = i + 1;
        }
        out
    }

    /// Where the format string in `span` is.
    pub fn fstring(&self, span: Span) -> Span {
        let mut i = self.tok_index(span.start);
        while i < self.toks.len() {
            let t = item(&self.toks, i);
            if let Tok::FStr(_) = t.tok {
                return t.span;
            }
            i = i + 1;
        }
        span
    }

    /// The source from `from` to `to`.
    pub fn source(&self, from: usize, to: usize) -> &'s str { sub(self.src, from, to) }
}

/// How many line breaks `s` has.
fn newlines(s: &str) -> usize {
    let mut n = 0usize;
    for b in s.as_bytes() {
        if *b == b'\n' {
            n = n + 1;
        }
    }
    n
}

/// Sorts the values of `l` from index `from` on by `key`, keeping those
/// with equal keys in the order they're in.
pub fn sort<effect e, T: Copy, K: Fn(&T) -> usize with e + Discard>(
    l: &mut List<T>,
    from: usize,
    key: K,
) with {panic, e} {
    let mut i = from + 1;
    while i < l.len() {
        let x = *item(l, i);
        let k = key(&x);
        let mut j = i;
        while j > from && key(item(l, j - 1)) > k {
            let prev = *item(l, j - 1);
            put(l, j, prev);
            j = j - 1;
        }
        put(l, j, x);
        i = i + 1;
    }
}

/// Puts `v` at index `i` of `l`, which has one.
fn put<T: Copy>(l: &mut List<T>, i: usize, v: T) {
    match l.get_mut(i) {
        Some(x) => *x = v,
        None => panic("index out of range"),
    }
}
