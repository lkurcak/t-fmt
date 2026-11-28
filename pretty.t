//! The printer: a syntax tree back to source, in the one T style, with
//! the source's comments and single blank lines. A port of t-lang's
//! `src/pretty.rs` (as `t fmt` uses it), `src/doc.rs`, `src/trivia.rs`
//! and the glue of `src/fmt.rs`.
//!
//! The printer turns the tree into a `Doc`, which says where lines may
//! break, and `doc::render` decides where they do. It has the source's
//! comments and blank lines (`Trivia`), and puts them back as it goes:
//! each is handed out once, in order, so what the printer asks for first
//! matters, and the functions here ask in the order t-lang's do.
//!
//! The functions that print each kind of thing are in `items`, `exprs`
//! and `types`, taking the `Printer`; what they share is here.

use alloc::list::List;
use alloc::string::String;

use crate::ast::{Allow, Derive, DocComment, Program, ROOT};
use crate::error::Span;
use crate::lexer::{Lexed, Tok};
use crate::pretty::doc::{group, if_break, nest, render, text, Doc};
use crate::pretty::trivia::{sort, Trivia};
use crate::text::item;

mod doc;
mod exprs;
mod items;
mod trivia;
mod types;

/// `program`, parsed from `src`, whose tokens and comments are `lexed`,
/// printed as `t fmt` prints it: its items in the order they're written,
/// with the comments and blank lines of the source.
pub fn format(src: &str, lexed: &Lexed, program: &Program) -> String {
    let mut p = Printer { trivia: trivia(src, lexed, program), quiet: false };
    let root = item(&program.mods, ROOT);
    let docs = match &root.doc {
        Some(d) => Some(inner_doc(d)),
        None => None,
    };
    let docs = p.with_inner_allows(docs, &root.inner_allows);
    let (mut doc, mut empty) = items::items(&mut p, program, ROOT);
    if let Some(docs) = docs {
        doc = match empty {
            true => docs,
            false => docs.add(Doc::HardLine).add(Doc::HardLine).add(doc),
        };
        empty = false;
    }
    let mut i = 0usize;
    for c in p.dangling(core::num::greatest::<usize>(), empty) {
        if i > 0 || !empty {
            doc = doc.add(Doc::HardLine);
        }
        doc = doc.add(c);
        i = i + 1;
    }
    render(&doc)
}

/// The comments and blank lines to keep. The printer prints doc comments
/// from the tree, but a doc comment that documents nothing isn't in a
/// place the printer knows to put it, so it's kept like a plain comment.
fn trivia<'s>(src: &'s str, lexed: &Lexed<'s>, program: &Program) -> Trivia<'s> {
    let mut toks = List::new();
    for t in lexed.toks.iter() {
        match t.tok {
            Tok::Doc(_) | Tok::InnerDoc(_) => {},
            _ => toks.push(*t),
        }
    }
    let mut comments = List::new();
    for c in lexed.comments.iter() {
        comments.push(*c);
    }
    for d in program.stray_docs.iter() {
        for l in d.lines.iter() {
            comments.push(l.span);
        }
    }
    sort(&mut comments, 0, |c| c.start);
    Trivia::new(src, toks, comments)
}

/// A module's `//!` doc comment, a line each.
pub fn inner_doc(d: &DocComment) -> Doc {
    let mut doc = Doc::nil();
    let mut i = 0usize;
    for l in d.lines.iter() {
        if i > 0 {
            doc = doc.add(Doc::HardLine);
        }
        doc = doc.owned(String::of(&f"//!{l.text}"));
        i = i + 1;
    }
    doc
}

/// What prints the tree: the source's comments and blank lines, to hand
/// out as it goes.
#[derive(Discard)]
pub struct Printer<'s> {
    pub trivia: Trivia<'s>,
    /// Set while printing something without its comments: an expression
    /// in a format string's hole, or in a derive's `where`, as t-lang
    /// prints them, with a printer that has no trivia.
    pub quiet: bool,
}

/// Where an expression is.
#[derive(Copy, Discard)]
pub struct Ctx {
    /// In the head of an `if` or `match`, where a struct literal needs
    /// parentheses.
    pub no_struct: bool,
    /// At the start of a statement, where an `if`, `match` or block ends
    /// the statement, so one that's only the start of it (`(if c { 1 }
    /// else { 2 }) - x`) needs parentheses.
    pub stmt: bool,
}

/// Anywhere that isn't the start of a statement or the head of an `if`.
pub const ANY: Ctx = Ctx { no_struct: false, stmt: false };

impl Ctx {
    /// The same place, but not the start of a statement any more.
    pub fn inner(self) -> Ctx { Ctx { no_struct: self.no_struct, stmt: false } }
}

/// The delimiters of a list, and whether there's a space inside them when
/// it's on one line: `{ x: 1 }`, but `(1, 2)`.
#[derive(Copy, Discard)]
pub struct Delims { open: &'static str, close: &'static str, spaced: bool }

pub const PARENS: Delims = Delims { open: "(", close: ")", spaced: false };
pub const ANGLES: Delims = Delims { open: "<", close: ">", spaced: false };
pub const BRACES: Delims = Delims { open: "{", close: "}", spaced: true };
pub const BRACKETS: Delims = Delims { open: "[", close: "]", spaced: false };
/// A `use` list's, which has no spaces inside: `a::{b, c}`.
pub const USE: Delims = Delims { open: "{", close: "}", spaced: false };
pub const PIPES: Delims = Delims { open: "|", close: "|", spaced: false };

impl<'s> Printer<'s> {
    /// What goes before something that starts at `pos` in the source and
    /// starts a line: an item, statement, arm or list element. That's the
    /// comments before it, each on a line of its own, and a blank line if
    /// there was one, unless it's `first` in its block or list.
    pub fn element(&mut self, pos: usize, first: bool) -> Doc {
        if self.quiet {
            return Doc::nil();
        }
        let mut doc = Doc::nil();
        let mut first = first;
        for c in self.trivia.leading(pos) {
            if c.blank && !first {
                doc = doc.add(Doc::HardLine);
            }
            doc = doc.add(Doc::Text(c.text)).add(Doc::HardLine);
            first = false;
        }
        if self.trivia.blank_before(pos) && !first {
            doc = doc.add(Doc::HardLine);
        }
        doc
    }

    /// The doc comment and attributes of something that starts at `pos` in
    /// the source (after them), each line on a line of its own, with any
    /// comments between them and it. The doc comment goes first, wherever
    /// it was.
    pub fn lead(&mut self, doc: &Option<DocComment>, allows: &List<Allow>, pos: usize) -> Doc {
        self.lead_derives(doc, allows, &List::new(), pos)
    }

    /// `lead`, with `#[derive(..)]`s after the `#[allow(..)]`s.
    pub fn lead_derives(
        &mut self,
        doc: &Option<DocComment>,
        allows: &List<Allow>,
        derives: &List<Derive>,
        pos: usize,
    ) -> Doc {
        if doc.is_none() && allows.is_empty() && derives.is_empty() {
            return Doc::nil();
        }
        let mut out = Doc::nil();
        if let Some(d) = doc {
            for l in d.lines.iter() {
                out = out.owned(String::of(&f"///{l.text}")).add(Doc::HardLine);
            }
        }
        for a in allows.iter() {
            let attr = if a.warn { "warn" } else { "allow" };
            let mut names = List::new();
            for l in a.lints.iter() {
                names.push(String::from(l.name.as_str()));
            }
            out = self.attribute(out, attr, a.span, names);
        }
        for d in derives.iter() {
            let mut names = List::new();
            let mut i = 0usize;
            for l in d.names.iter() {
                match d.wheres.get(i) {
                    Some(Some(w)) => {
                        let w = types::where_clause(self, w);
                        names.push(String::of(&f"{l.name} {w}"));
                    },
                    _ => names.push(String::from(l.name.as_str())),
                }
                i = i + 1;
            }
            out = self.attribute(out, "derive", d.span, names);
        }
        out.add(self.element(pos, true))
    }

    /// `out`, then attribute `#[attr(names)]`, which is at `span`, on a line
    /// of its own. One that doesn't fit on a line has a line for each name.
    fn attribute(&mut self, out: Doc, attr: &str, span: Span, names: List<String>) -> Doc {
        let joined = join(&names, ", ");
        let one_line = String::of(&f"#[{attr}({joined})]");
        let attr = match one_line.len() > doc::WIDTH {
            true => {
                let mut each = Doc::nil();
                for n in names.iter() {
                    each = each.add(Doc::HardLine).owned(String::of(&f"{n},"));
                }
                Doc::Text(String::of(&f"#[{attr}(")).add(nest(each)).add(Doc::HardLine).text(")]")
            },
            false => Doc::Text(one_line),
        };
        let out = out.add(self.element(span.start, true)).add(attr);
        out.add(self.trailing(span.end)).add(Doc::HardLine)
    }

    /// A module's `//!` doc comment, `doc`, then its `#![allow(..)]`s and
    /// `#![warn(..)]`s, `allows`, each on a line of its own: nothing if it
    /// has neither.
    pub fn with_inner_allows(&mut self, doc: Option<Doc>, allows: &List<Allow>) -> Option<Doc> {
        let mut out = doc;
        for a in allows.iter() {
            let attr = if a.warn { "warn" } else { "allow" };
            let mut names = List::new();
            for l in a.lints.iter() {
                names.push(String::from(l.name.as_str()));
            }
            let names = join(&names, ", ");
            let written = String::of(&f"#![{attr}({names})]");
            let line = self.element(a.span.start, true).owned(written);
            let line = line.add(self.trailing(a.span.end));
            out = Some(match out {
                Some(d) => d.add(Doc::HardLine).add(line),
                None => line,
            });
        }
        out
    }

    /// The comment after something that ends at `end`, if it's on the same
    /// line, and those lined up under it.
    pub fn trailing(&mut self, end: usize) -> Doc {
        if self.quiet {
            return Doc::nil();
        }
        let Some(t) = self.trivia.trailing(end) else { return Doc::nil() };
        let mut doc = Doc::Comment(t.text);
        for more in t.more {
            doc = doc.add(Doc::HardLine).add(Doc::Comment(more));
        }
        doc
    }

    /// The comments left before `close`, the end of a block or list, each to
    /// go on a line of its own. A blank line before one is kept, unless
    /// it's `first` in its block or list.
    pub fn dangling(&mut self, close: usize, first: bool) -> List<Doc> {
        let mut out = List::new();
        if self.quiet {
            return out;
        }
        let mut first = first;
        for c in self.trivia.leading(close) {
            // Only a blank line before a comment makes the next one not
            // the first any more.
            let blank = match c.blank {
                true => {
                    let was = first;
                    first = false;
                    !was
                },
                false => false,
            };
            let doc = Doc::Text(c.text).add(Doc::BreakParent);
            out.push(match blank {
                true => Doc::HardLine.add(doc),
                false => doc,
            });
        }
        out
    }

    /// Are there comments to print before `pos`?
    pub fn comments_before(&self, pos: usize) -> bool { !self.quiet && self.trivia.any_before(pos) }

    /// The literal at `span` as the source writes it, `0xFF`, or else, when
    /// quiet or where something else is there too, as `plain` says.
    pub fn spelled(&self, span: Span, plain: String) -> Doc {
        if self.quiet {
            return Doc::Text(plain);
        }
        match self.trivia.spelled(span) {
            Some(s) => Doc::Text(s),
            None => Doc::Text(plain),
        }
    }

    /// The string literal at `span` as the source writes it. t-lang writes
    /// one from what it means where something else is there too, as
    /// parentheses, or when quiet; the tree doesn't keep that, so this
    /// writes the source's literal then.
    pub fn written(&self, span: Span) -> Doc {
        if !self.quiet {
            if let Some(s) = self.trivia.spelled(span) {
                return Doc::Text(s);
            }
        }
        Doc::Text(self.trivia.literal(span))
    }

    /// Where the first `tok` at or after `pos` starts in the source.
    pub fn find(&self, pos: usize, tok: Tok) -> usize { self.trivia.find(pos, tok).start }

    /// Where the token before the one at `pos` starts.
    pub fn before(&self, pos: usize) -> usize { self.trivia.before(pos).start }

    /// Where the `close` after the last of `ends` is, or else the first one
    /// after `open`: the end of a list.
    pub fn close(&self, open: usize, ends: Option<usize>, close: Tok) -> usize {
        match ends {
            Some(end) => self.find(end, close),
            None => self.find(open, close),
        }
    }

    /// `items`, separated by commas: all on one line, or else one per line
    /// with a comma after the last too. `close_pos` is where the closing
    /// delimiter is in the source, `span` says where each item starts and
    /// ends, and `rest` goes after the last item (`..` in a struct pattern).
    pub fn list<
        T,
        S: Fn(&T) -> (usize, usize) + Discard,
        F: FnMut(&mut Printer<'s>, &T) -> Doc + Discard,
    >(
        &mut self,
        delims: Delims,
        close_pos: usize,
        items: &List<T>,
        span: S,
        rest: Option<(usize, &str)>,
        mut each: F,
    ) -> Doc {
        if items.is_empty() && rest.is_none() && !self.comments_before(close_pos) {
            return Doc::Text(String::of(&f"{delims.open}{delims.close}"));
        }
        let mut entries: List<Doc> = List::new();
        let mut i = 0usize;
        for x in items.iter() {
            let (start, end) = span(x);
            let lead = self.element(start, i == 0);
            let doc = each(self, x);
            let comma = match i + 1 == items.len() && rest.is_none() {
                true => if_break(text(","), text("")),
                false => text(","),
            };
            entries.push(lead.add(doc).add(comma).add(self.trailing(end)));
            i = i + 1;
        }
        if let Some((pos, r)) = rest {
            entries.push(self.element(pos, items.is_empty()).text(r));
        }
        let first = entries.is_empty();
        for d in self.dangling(close_pos, first) {
            entries.push(d);
        }
        let mut inner = Doc::nil();
        let mut i = 0usize;
        for e in entries {
            let line = match i == 0 {
                true => line(delims.spaced),
                false => Doc::Line,
            };
            inner = inner.add(line.add(e));
            i = i + 1;
        }
        group(text(delims.open).add(nest(inner)).add(line(delims.spaced)).text(delims.close))
    }
}

/// What's inside a list's delimiters at each end: a space on one line, if
/// it's `spaced`, or nothing.
fn line(spaced: bool) -> Doc {
    match spaced {
        true => Doc::Line,
        false => Doc::SoftLine,
    }
}

/// `parts`, with `sep` between each two.
pub fn join(parts: &List<String>, sep: &str) -> String {
    let mut out = String::new();
    let mut i = 0usize;
    for p in parts.iter() {
        if i > 0 {
            out.push_str(sep);
        }
        out.push_str(p.as_str());
        i = i + 1;
    }
    out
}
