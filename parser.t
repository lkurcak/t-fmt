//! The parser: tokens to a syntax tree, a port of t-lang's `src/parser.rs`
//! (its grammar is written out there). A recursive descent: `Parser` holds
//! the tokens and where it is in them, and the functions of `items`,
//! `types`, `exprs` and `patterns` each read one thing at that place.
//!
//! Doc comments are taken out of the tokens first, and each run of them is
//! attached to what starts right after it (`Parser::doc`); the ones nothing
//! takes are `Program::stray_docs`.
//!
//! In the head of an `if`, `match`, `while` or `for`, `x {` can't start a
//! struct literal, since `{` starts the body there: `Parser::no_struct`
//! says so while one is read.

use alloc::list::List;
use alloc::string::String;

use crate::ast::{DocComment, DocLine, Ident, ModDecl, Program, TypeExpr, Vis};
use crate::error::{Error, Span};
use crate::lexer::{FPiece, Lexed, Tok, Token};
use crate::text;

mod exprs;
mod items;
mod patterns;
mod types;

/// The syntax tree of the file `lexed` is the tokens of, or the first
/// thing wrong with it. Doc comments are attached to what they document;
/// the rest are `Program::stray_docs`. A `mod m;` in it is a module with
/// no items: they're in a file of their own.
pub fn parse(lexed: &Lexed) -> Result<Program, Error> {
    let end = match lexed.toks.last() {
        Some(t) => t.span.end,
        None => 0,
    };
    let mut mods = List::new();
    mods.push(ModDecl {
        doc: None,
        allows: List::new(),
        inner_allows: List::new(),
        span: Span::new(0, end),
        name: Ident { name: String::new(), span: Span::new(0, 0) },
        parent: None,
        vis: Vis::Private,
        in_file: false,
    });
    let mut prog = Program {
        mods,
        uses: List::new(),
        types: List::new(),
        traits: List::new(),
        impls: List::new(),
        fns: List::new(),
        stray_docs: List::new(),
    };
    let mut p = Parser::new(&lexed.toks, &lexed.pieces, crate::ast::ROOT);
    items::items(&mut p, &mut prog, Tok::Eof)?;
    prog.stray_docs = p.stray_docs();
    Ok(prog)
}

/// Where the parser is in a file's tokens, or a format string hole's.
#[derive(Discard)]
pub struct Parser<'a, 's> {
    /// Every token but doc comments, ending with an `Eof`.
    toks: List<Token<'s>>,
    /// The doc comments, `///` and `//!` in order, and whether each is
    /// attached to something yet.
    docs: List<Token<'s>>,
    attached: List<bool>,
    pos: usize,
    /// Set while reading the head of an `if`, `match` or loop, where `x {`
    /// must not be read as a struct literal.
    no_struct: bool,
    /// The module being read, by its index in `Program::mods`.
    module: usize,
    /// The pieces of the file's format strings, which its `FStr` tokens
    /// point into.
    pieces: &'a List<FPiece<'s>>,
}

impl<'a, 's> Parser<'a, 's> {
    /// A parser at the start of `toks`, which end with an `Eof`, in module
    /// `module`.
    fn new(toks: &List<Token<'s>>, pieces: &'a List<FPiece<'s>>, module: usize) -> Parser<'a, 's> {
        let mut docs = List::new();
        let mut rest = List::new();
        for t in toks.iter() {
            match t.tok {
                Tok::Doc(_) | Tok::InnerDoc(_) => docs.push(*t),
                _ => rest.push(*t),
            }
        }
        let attached = List::filled(docs.len(), false);
        Parser { toks: rest, docs, attached, pos: 0, no_struct: false, module, pieces }
    }

    /// The token `n` on from the next one, which is the next for 0, or the
    /// `Eof` if the tokens end before it.
    fn ahead(&self, n: usize) -> Token<'s> {
        match self.toks.get(self.pos + n) {
            Some(t) => *t,
            None => *self.toks.last().expect("an `Eof` at least"),
        }
    }

    /// The next token.
    fn peek(&self) -> Tok<'s> { self.ahead(0).tok }

    /// The token after the next one.
    fn peek2(&self) -> Tok<'s> { self.ahead(1).tok }

    /// The token after that.
    fn peek3(&self) -> Tok<'s> { self.ahead(2).tok }

    /// Where the next token is.
    fn span(&self) -> Span { self.ahead(0).span }

    /// The token before the next one.
    fn before(&self) -> Token<'s> { *text::item(&self.toks, self.pos - 1) }

    /// Whether the next two tokens have nothing between them.
    fn adjacent(&self) -> bool { self.span().end == self.ahead(1).span.start }

    /// The next token, moving past it, but not past the `Eof`.
    fn bump(&mut self) -> Token<'s> {
        let t = self.ahead(0);
        if t.tok != Tok::Eof {
            self.pos = self.pos + 1;
        }
        t
    }

    /// Moves past the next token if it's `tok`, and says whether it was.
    fn eat(&mut self, tok: Tok) -> bool {
        if self.peek() == tok {
            self.bump();
            true
        } else {
            false
        }
    }

    /// Where the next token is, moving past it, if it's `tok`.
    fn expect(&mut self, tok: Tok) -> Result<Span, Error> {
        if self.peek() == tok {
            Ok(self.bump().span)
        } else {
            Err(self.unexpected(tok.describe().as_str()))
        }
    }

    /// `item, item, ..` up to `close`, after what opens the list, with a
    /// comma after the last if it's wanted: the items, and where `close` is.
    fn comma_list<
        effect e,
        T: Discard,
        F: FnMut(&mut Parser<'a, 's>) -> Result<T, Error> with e + Discard,
    >(&mut self, close: Tok, mut item: F) -> Result<(List<T>, Span), Error> with {alloc, panic, e} {
        let mut items = List::new();
        loop {
            if self.peek() == close {
                break;
            }
            items.push(item(self)?);
            if !self.eat(Tok::Comma) {
                break;
            }
        }
        let end = self.expect(close)?;
        Ok((items, end))
    }

    /// What `f` reads, with struct literals `allowed` in it or not; after
    /// it, they're as they were.
    fn structs<effect e, T, F: FnOnce(&mut Parser<'a, 's>) -> T with e>(
        &mut self,
        allowed: bool,
        f: F,
    ) -> T with e {
        let saved = self.no_struct;
        self.no_struct = !allowed;
        let out = f(self);
        self.no_struct = saved;
        out
    }

    /// That the next token isn't what's `wanted`.
    fn unexpected(&self, wanted: &str) -> Error {
        let found = self.peek().describe();
        Error::owned(self.span(), String::of(&f"expected {wanted}, found {found}"))
    }

    /// The doc comment for what starts at the next token: the `///` lines
    /// between the token before and it, if there are any.
    fn doc(&mut self) -> Option<DocComment> { self.docs_before(false) }

    /// The `//!` lines between the token before and the next, if there are
    /// any: the doc comment of the module whose body starts there.
    fn inner_doc(&mut self) -> Option<DocComment> { self.docs_before(true) }

    /// The doc comment lines of the kind `inner` says between the token
    /// before and the next. Those of the other kind are left for others,
    /// or to be stray.
    fn docs_before(&mut self, inner: bool) -> Option<DocComment> {
        let from = match self.pos {
            0 => 0,
            _ => self.before().span.end,
        };
        let to = self.span().start;
        let last = first_from(&self.docs, to);
        let mut lines = List::new();
        let mut i = first_from(&self.docs, from);
        while i < last {
            let d = *text::item(&self.docs, i);
            if is_inner(d.tok) == inner {
                if let Some(a) = self.attached.get_mut(i) {
                    *a = true;
                }
                lines.push(d);
            }
            i = i + 1;
        }
        match lines.is_empty() {
            true => None,
            false => Some(doc_comment(&lines)),
        }
    }

    /// The doc comments nothing took, each run of lines of one kind with
    /// no other token between them as one.
    fn stray_docs(&self) -> List<DocComment> {
        let mut out = List::new();
        let mut run = List::new();
        let mut prev: Option<(usize, bool)> = None;
        for (i, d) in self.docs.iter().enumerate() {
            if *text::item(&self.attached, i) {
                continue;
            }
            // The first token after it: the same for lines with nothing
            // between them.
            let this = (first_from(&self.toks, d.span.start), is_inner(d.tok));
            if prev != Some(this) && !run.is_empty() {
                out.push(doc_comment(&run));
                run = List::new();
            }
            run.push(*d);
            prev = Some(this);
        }
        if !run.is_empty() {
            out.push(doc_comment(&run));
        }
        out
    }

    /// A name.
    fn ident(&mut self) -> Result<Ident, Error> {
        match self.peek() {
            Tok::Ident(name) => Ok(Ident { name: String::from(name), span: self.bump().span }),
            _ => Err(self.unexpected("a name")),
        }
    }

    /// A name being bound: anything but `self`, which only a receiver
    /// binds.
    fn binder(&mut self) -> Result<Ident, Error> {
        let name = self.ident()?;
        match name.name.as_str() {
            "self" => Err(Error::syntax(
                name.span,
                "only a method's receiver can be called `self`",
            )),
            _ => Ok(name),
        }
    }

    /// A variable's name, where one is bound: a parameter, or in a
    /// pattern. It can't start with an uppercase letter, which in a pattern
    /// makes a name a path: so no variable can be named what a variant or
    /// const is.
    fn variable(&mut self) -> Result<Ident, Error> {
        let name = self.binder()?;
        if starts_upper(name.name.as_str()) {
            let n = name.name.as_str();
            return Err(Error::owned(
                name.span,
                String::of(
                    &f"a variable's name can't start with an uppercase letter: a name like `{n}` is a variant's or a const's",
                ),
            ));
        }
        Ok(name)
    }

    /// `'a`
    fn lifetime(&mut self) -> Result<Ident, Error> {
        match self.peek() {
            Tok::Lifetime(name) => Ok(Ident { name: String::from(name), span: self.bump().span }),
            _ => Err(self.unexpected("a lifetime, like `'a`")),
        }
    }

    /// One segment of a path: a name, or `crate` or `super`.
    fn segment(&mut self) -> Result<Ident, Error> {
        let name = match self.peek() {
            Tok::Crate => "crate",
            Tok::Super => "super",
            _ => return self.ident(),
        };
        Ok(Ident { name: String::from(name), span: self.bump().span })
    }

    /// `a::b::Show`: a path of plain names, as one name, its segments
    /// joined by `::`, spanning them all. A path to a trait is written
    /// like this.
    fn path(&mut self) -> Result<Ident, Error> {
        let mut path = self.segment()?;
        while self.peek() == Tok::ColonColon && is_ident(self.peek2()) {
            self.bump();
            let next = self.ident()?;
            path = join(&path, &next);
        }
        Ok(path)
    }

    /// `a::Shape::<i64>::Dot`: names with `::` between, each maybe with
    /// type arguments, up to a `::` that has neither a name nor `<`
    /// after it.
    fn segments(&mut self) -> Result<List<Segment>, Error> {
        let mut segs = List::new();
        loop {
            let name = self.segment()?;
            let (targs, end) = self.turbofish()?;
            segs.push(Segment { name, targs, end });
            if self.peek() == Tok::ColonColon && is_ident(self.peek2()) {
                self.bump();
            } else {
                return Ok(segs);
            }
        }
    }

    /// `::<i64, bool>` after a name, if it's there: explicit type
    /// arguments, and where they end. As in Rust, the `::` keeps the `<`
    /// from reading as less-than.
    fn turbofish(&mut self) -> Result<(List<TypeExpr>, Option<Span>), Error> {
        if self.peek() == Tok::ColonColon && self.peek2() == Tok::Lt {
            self.bump();
            self.bump();
            let (args, end) = self.comma_list(Tok::Gt, types::type_arg)?;
            Ok((args, Some(end)))
        } else {
            Ok((List::new(), None))
        }
    }

    /// `pub` or `export`, if one is next.
    fn vis(&mut self) -> Vis {
        match self.peek() {
            Tok::Pub => Vis::Pub(self.bump().span),
            Tok::Export => Vis::Export(self.bump().span),
            _ => Vis::Private,
        }
    }

    /// Checks there's no `pub` or `export` next, where nothing can be:
    /// `why`.
    fn no_pub(&self, why: &str) -> Result<(), Error> {
        let word = match self.peek() {
            Tok::Pub => "pub",
            Tok::Export => "export",
            _ => return Ok(()),
        };
        Err(Error::owned(self.span(), String::of(&f"this can't be `{word}`: {why}")))
    }

    /// Where the `)` that ends `( .. )` is, after its `n` items, the first
    /// comma between or after them at `comma` if there's one. No items is
    /// `()`, one with no comma is only grouped, and two or more are a
    /// tuple's; `(x,)` is wrong, as a tuple has no elements or at least two.
    fn close_parens(&mut self, n: usize, comma: Option<Span>) -> Result<Span, Error> {
        let close = self.expect(Tok::RParen)?;
        if let (1, Some(at)) = (n, comma) {
            return Err(Error::syntax(
                at,
                "a tuple has no elements or at least two; for one value, leave out the \
                 parentheses",
            ));
        }
        Ok(close)
    }
}

/// A segment of a path in an expression or pattern, with its type
/// arguments and where they end, if it has any.
#[derive(Discard)]
struct Segment { name: Ident, targs: List<TypeExpr>, end: Option<Span> }

/// Checks that none of `segs`, the start of a path, has type arguments:
/// they go after the type's name, or a function's.
fn no_targs(segs: &List<Segment>) -> Result<(), Error> {
    for s in segs.iter() {
        if let Some(end) = s.end {
            return Err(Error::syntax(
                end,
                "type arguments can only go after the type or function they're for",
            ));
        }
    }
    Ok(())
}

/// The names of `segs` and then `last`, as one: `a::b::c`, spanning them.
fn joined(segs: &List<Segment>, last: &Ident) -> Ident {
    let mut out = match segs.first() {
        Some(s) => copied(&s.name),
        None => return copied(last),
    };
    for s in segs.iter().skip(1) {
        out = join(&out, &s.name);
    }
    join(&out, last)
}

/// `a::b` from `a` and `b`: one name for a path, spanning both.
fn join(a: &Ident, b: &Ident) -> Ident {
    Ident { name: String::of(&f"{a.name}::{b.name}"), span: a.span.to(b.span) }
}

/// Another of `name`.
fn copied(name: &Ident) -> Ident {
    Ident { name: String::from(name.name.as_str()), span: name.span }
}

/// Is `tok` a name?
fn is_ident(tok: Tok) -> bool {
    match tok {
        Tok::Ident(_) => true,
        _ => false,
    }
}

/// Is `tok` the name `name`?
fn is_word(tok: Tok, name: &str) -> bool {
    match tok {
        Tok::Ident(n) => n == name,
        _ => false,
    }
}

/// Does `name` start with an uppercase letter, which makes it a path in a
/// pattern?
fn starts_upper(name: &str) -> bool {
    match text::at(name.as_bytes(), 0) {
        Some(b) => b >= b'A' && b <= b'Z',
        None => false,
    }
}

/// Is `tok` a `//!` line?
fn is_inner(tok: Tok) -> bool {
    match tok {
        Tok::InnerDoc(_) => true,
        _ => false,
    }
}

/// The index of the first of `toks` that starts at `at` or after it.
fn first_from(toks: &List<Token>, at: usize) -> usize {
    let mut lo = 0usize;
    let mut hi = toks.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if text::item(toks, mid).span.start < at {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

/// One doc comment from a run of `///` or `//!` lines.
fn doc_comment(run: &List<Token>) -> DocComment {
    let mut lines = List::new();
    for t in run.iter() {
        let text = match t.tok {
            Tok::Doc(text) => text,
            Tok::InnerDoc(text) => text,
            _ => panic("only doc comments are set aside"),
        };
        lines.push(DocLine { text: String::from(text), span: t.span });
    }
    DocComment { lines, inner: is_inner(text::item(run, 0).tok) }
}
