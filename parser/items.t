//! Items: what a module holds, a function, `struct`, `enum`, `type`,
//! `trait`, `impl`, `mod`, `use`, `const` or `static`, and what's before
//! one (its doc comment and attributes, `Head`), and generic parameters.

use alloc::boxed::Box;
use alloc::list::List;
use alloc::string::String;

use crate::ast::{
    Allow,
    AliasDecl,
    AssocDecl,
    AssocDef,
    Bound,
    Derive,
    DocComment,
    EffectDecl,
    EffectDef,
    EnumDecl,
    Expr,
    ExprKind,
    Extern,
    FnDecl,
    Generics,
    Ident,
    ImplDecl,
    Law,
    ModDecl,
    Param,
    ParamKind,
    Program,
    StructDecl,
    Test,
    TraitDecl,
    TraitMethod,
    TypeDecl,
    TypeExpr,
    TypeExprKind,
    TypeParam,
    UseDecl,
    UseKind,
    UseTree,
    Variant,
    Vis,
    Where,
    WhereBound,
};
use crate::error::{Error, Span};
use crate::lexer::Tok;
use crate::parser::{copied, is_ident, is_word, join, starts_upper, Parser};
use crate::parser::exprs;
use crate::parser::types::{self, Said};

/// Why an `extern fn` can't be where one is written: in a function, an
/// impl or a trait.
pub const NOT_EXTERN: &str = "an `extern fn` is a module's: C calls it, or it's C, by its name alone, \
                              which no function, impl or trait it's in could be part of";

/// Why a `#[blame_caller]` can't be where it is: what it says is of a
/// body, which a trait's method without one, an intrinsic, or what isn't
/// a function doesn't have.
const NOT_BLAMING: &str = "`#[blame_caller]` can only be on a function with a body: what aborts \
                           in it is shown where it was called";

/// Why a `#[measure]` can't be where it is.
pub const NOT_METHOD: &str = "only a method of `&self` can be a measure";

/// What can come before a `fn`, `struct`, `enum`, field or variant: its
/// doc comment and attributes.
#[derive(Discard)]
pub struct Head {
    doc: Option<DocComment>,
    allows: List<Allow>,
    derives: List<Derive>,
    /// Where its `#[intrinsic]` is, if it has one: only a function's can.
    intrinsic: Option<Span>,
    /// Where its `#[measure]` is, if it has one: only a function's can.
    measure: Option<Span>,
    /// Its `#[test]`, if it has one: only a module's function's can.
    test: Option<Test>,
    /// Where its `#[blame_caller]` is, if it has one: only a function's
    /// with a body can.
    blame_caller: Option<Span>,
}

impl Head {
    /// Checks this head, for an associated type or effect, has no
    /// `#[allow(..)]`.
    fn no_allows(&self) -> Result<(), Error> { self.no_allows_on("an associated type") }

    /// Checks this head, for `what`, has no `#[allow(..)]`.
    fn no_allows_on(&self, what: &str) -> Result<(), Error> {
        match self.allows.first() {
            Some(a) => Err(Error::owned(a.span, String::of(&f"`#[allow(..)]` can't be on {what}"))),
            None => Ok(()),
        }
    }

    /// This head, for something that isn't a function, so can't have an
    /// `#[intrinsic]`.
    pub fn no_intrinsic(self) -> Result<Head, Error> {
        match self.intrinsic {
            Some(at) => Err(Error::syntax(
                at,
                "`#[intrinsic]` can only be on a function, a struct, a trait, or a method of an \
                 impl that isn't a trait's",
            )),
            None => Ok(self),
        }
    }

    /// This head, for something that isn't a function, so can't have a
    /// `#[measure]`: `why`.
    pub fn no_measure(self, why: &str) -> Result<Head, Error> {
        match self.measure {
            Some(at) => Err(Error::syntax(at, why)),
            None => Ok(self),
        }
    }

    /// This head, for something that isn't a function of a module's, so
    /// can't have a `#[test]`: a test is run as a program of its own, as
    /// `main` is, and nothing could give a method its `self`.
    pub fn no_test(self) -> Result<Head, Error> {
        match self.test {
            Some(t) => Err(Error::syntax(
                t.span,
                "`#[test]` can only be on a function of a module, not a method or a function \
                 inside another",
            )),
            None => Ok(self),
        }
    }

    /// This head, for something that isn't a function, so can't have a
    /// `#[blame_caller]`.
    pub fn no_blame_caller(self) -> Result<Head, Error> {
        match self.blame_caller {
            Some(at) => Err(Error::syntax(at, NOT_BLAMING)),
            None => Ok(self),
        }
    }

    /// This head, for an `extern fn`: C calls it, or it's C, so it's none
    /// of what the attributes on a function make it.
    fn for_extern(self) -> Result<Head, Error> {
        let test = match self.test {
            Some(t) => Some(t.span),
            None => None,
        };
        let derive = match self.derives.first() {
            Some(d) => Some(d.span),
            None => None,
        };
        let found = match (self.intrinsic, self.measure, test, self.blame_caller, derive) {
            (Some(at), _, _, _, _) => Some((at, "`#[intrinsic]`")),
            (None, Some(at), _, _, _) => Some((at, "`#[measure]`")),
            (None, None, Some(at), _, _) => Some((at, "`#[test]`")),
            (None, None, None, Some(at), _) => Some((at, "`#[blame_caller]`")),
            (None, None, None, None, Some(at)) => Some((at, "`#[derive(..)]`")),
            (None, None, None, None, None) => None,
        };
        match found {
            Some((at, what)) => Err(Error::owned(
                at,
                String::of(
                    &f"{what} can't be on an `extern fn`: it's called by C, or is C, the same way any C function is",
                ),
            )),
            None => Ok(self),
        }
    }

    /// This head, for something that isn't a struct or enum, so can't
    /// have a `#[derive(..)]`.
    pub fn no_derives(self) -> Result<Head, Error> {
        match self.derives.first() {
            Some(d) => Err(Error::syntax(
                d.span,
                "`#[derive(..)]` can only be on a struct or enum",
            )),
            None => Ok(self),
        }
    }
}

/// The doc comment and attributes of what starts at the next token, or
/// after the attributes there.
pub fn read_head(p: &mut Parser) -> Result<Head, Error> {
    let mut doc = p.doc();
    let mut allows = List::new();
    let mut derives = List::new();
    let mut intrinsic = None;
    let mut measure = None;
    let mut test = None;
    let mut blame_caller = None;
    while p.peek() == Tok::Hash {
        let start = p.bump().span;
        if p.peek() == Tok::Bang {
            return Err(Error::syntax(
                start.to(p.span()),
                "`#![..]` is only at the top of a module: of its file, or of the `{ }` of \
                 `mod m { .. }`, after its `//!` doc comment",
            ));
        }
        p.expect(Tok::LBracket)?;
        let kind = match p.peek() {
            Tok::Ident(name) => name,
            _ => {
                return Err(p.unexpected(
                    "`allow`, `blame_caller`, `derive`, `intrinsic`, `measure`, `test` or `warn`",
                ));
            },
        };
        match kind {
            "allow" | "warn" | "derive" => {},
            "intrinsic" => {
                p.bump();
                intrinsic = Some(start.to(p.expect(Tok::RBracket)?));
                continue;
            },
            "measure" => {
                p.bump();
                measure = Some(start.to(p.expect(Tok::RBracket)?));
                continue;
            },
            "blame_caller" => {
                p.bump();
                if p.peek() == Tok::LParen {
                    return Err(Error::syntax(
                        p.span(),
                        "`#[blame_caller]` takes nothing: it says the function's caller is \
                         blamed for what aborts in it",
                    ));
                }
                blame_caller = Some(start.to(p.expect(Tok::RBracket)?));
                continue;
            },
            "test" => {
                p.bump();
                let panics = p.eat(Tok::LParen);
                if panics {
                    if !is_word(p.peek(), "panics") {
                        return Err(Error::syntax(
                            p.span(),
                            "a test can only say `panics`: `#[test(panics)]` passes only if it \
                             panics",
                        ));
                    }
                    p.bump();
                    p.expect(Tok::RParen)?;
                }
                let span = start.to(p.expect(Tok::RBracket)?);
                test = Some(Test { span, panics });
                continue;
            },
            name => {
                return Err(Error::owned(
                    p.span(),
                    String::of(
                        &f"unknown attribute `{name}`; the only ones are `allow`, `blame_caller`, `derive`, `intrinsic`, `measure`, `test` and `warn`",
                    ),
                ));
            },
        }
        p.bump();
        if kind == "derive" {
            p.expect(Tok::LParen)?;
            let (names, wheres) = derive_list(p)?;
            let span = start.to(p.expect(Tok::RBracket)?);
            derives.push(Derive { span, names, wheres });
        } else {
            allows.push(lint_list(p, start, kind == "warn")?);
        }
    }
    if !(allows.is_empty() && derives.is_empty()) {
        if let Some(after) = p.doc() {
            doc = match doc {
                Some(mut d) => {
                    for line in after.lines {
                        d.lines.push(line);
                    }
                    Some(d)
                },
                None => Some(after),
            };
        }
    }
    Ok(Head { doc, allows, derives, intrinsic, measure, test, blame_caller })
}

/// The `(lints)]` of `#[allow(lints)]` or `#[warn(lints)]`, the `#` at
/// `start`; `warn` for `warn`.
fn lint_list(p: &mut Parser, start: Span, warn: bool) -> Result<Allow, Error> {
    p.expect(Tok::LParen)?;
    let lints = p.comma_list(Tok::RParen, |p| p.ident())?.0;
    let span = start.to(p.expect(Tok::RBracket)?);
    Ok(Allow { span, lints, warn })
}

/// The `#![allow(..)]`s and `#![warn(..)]`s at the top of a module.
fn inner_allows(p: &mut Parser) -> Result<List<Allow>, Error> {
    let mut out = List::new();
    while p.peek() == Tok::Hash && p.peek2() == Tok::Bang {
        let start = p.bump().span;
        p.bump();
        p.expect(Tok::LBracket)?;
        let warn = match p.peek() {
            Tok::Ident("allow") => false,
            Tok::Ident("warn") => true,
            _ => {
                return Err(p.unexpected(
                    "`allow` or `warn`, the only attributes of a module's own",
                ));
            },
        };
        p.bump();
        out.push(lint_list(p, start, warn)?);
    }
    Ok(out)
}

/// `Discard, Eq where T: Eq, U: Show)` in a `#[derive(..)]`, after the
/// `(`: each trait, with the `where` after it, if it has one. The bounds
/// of a `where` go on while a name and a `:` come after a `,`.
fn derive_list(p: &mut Parser) -> Result<(List<Ident>, List<Option<Where>>), Error> {
    let mut names = List::new();
    let mut wheres = List::new();
    while p.peek() != Tok::RParen {
        names.push(p.path()?);
        let w = match p.peek() == Tok::Where {
            false => None,
            true => {
                let start = p.bump().span;
                let mut bounds = List::new();
                let end = loop {
                    let subject = p.ident()?;
                    p.expect(Tok::Colon)?;
                    let mut items = List::new();
                    items.push(types::trait_bound(p)?);
                    while p.eat(Tok::Plus) {
                        items.push(types::trait_bound(p)?);
                    }
                    let end = items.last().expect("a bound at least").span;
                    bounds.push(Bound { subject, items });
                    let more = p.peek() == Tok::Comma
                        && is_ident(p.peek2())
                        && p.peek3() == Tok::Colon;
                    if !more {
                        break end;
                    }
                    p.bump();
                };
                Some(Where { span: start.to(end), bounds })
            },
        };
        wheres.push(w);
        if !p.eat(Tok::Comma) {
            break;
        }
    }
    p.expect(Tok::RParen)?;
    Ok((names, wheres))
}

/// The items of the module being read, up to `close`: `}`, or the end of
/// the file for the root, and its `//!` doc comment and `#![..]`s first.
pub fn items(p: &mut Parser, prog: &mut Program, close: Tok) -> Result<(), Error> {
    if let Some(doc) = p.inner_doc() {
        let m = module(prog, p.module);
        m.doc = Some(doc);
    }
    let inner = inner_allows(p)?;
    let m = module(prog, p.module);
    for a in inner {
        m.inner_allows.push(a);
    }
    while p.peek() != close {
        if p.peek() == Tok::Eof {
            return Err(p.unexpected(close.describe().as_str()));
        }
        item(p, prog)?;
    }
    if close != Tok::Eof {
        p.bump();
    }
    Ok(())
}

/// Module `i` of `prog`.
fn module(prog: &mut Program, i: usize) -> &mut ModDecl { prog.mods.get_mut(i).expect("a module") }

/// One item of a module, put in `prog`.
fn item(p: &mut Parser, prog: &mut Program) -> Result<(), Error> {
    let head = read_head(p)?;
    let vis = p.vis();
    let sealed_at = match p.peek() {
        Tok::Sealed => {
            let at = p.span();
            p.bump();
            if p.peek() != Tok::Trait {
                return Err(Error::syntax(
                    at,
                    "only a trait can be `sealed`: it says no other package can implement it",
                ));
            }
            Some(at)
        },
        _ => None,
    };
    let head = match p.peek() {
        Tok::Fn => head.no_measure(NOT_METHOD)?,
        Tok::Extern => head.for_extern()?,
        Tok::Const | Tok::Static => {
            head.no_intrinsic()?.no_measure(NOT_METHOD)?.no_test()?.no_blame_caller()?.no_derives()?
        },
        Tok::Struct | Tok::Trait => head.no_measure(NOT_METHOD)?.no_test()?.no_blame_caller()?,
        _ => head.no_intrinsic()?.no_measure(NOT_METHOD)?.no_test()?.no_blame_caller()?,
    };
    match p.peek() {
        Tok::Struct => {
            let mut d = struct_decl(p, head)?;
            d.vis = vis;
            prog.types.push(TypeDecl::Struct(d));
        },
        Tok::Enum => {
            let mut d = enum_decl(p, head)?;
            d.vis = vis;
            prog.types.push(TypeDecl::Enum(d));
        },
        Tok::Type => {
            let mut d = alias_decl(p, head.no_derives()?)?;
            d.vis = vis;
            prog.types.push(TypeDecl::Alias(d));
        },
        Tok::Trait => {
            let mut d = trait_decl(p, head.no_derives()?)?;
            d.vis = vis;
            d.sealed_ = sealed_at;
            prog.traits.push(d);
        },
        Tok::Impl => {
            if let Some(at) = vis_span(vis) {
                let word = vis_word(vis);
                return Err(Error::owned(
                    at,
                    String::of(
                        &f"an `impl` can't be `{word}`: a trait impl is wherever the trait and type are, and an inherent impl's methods each say if they are",
                    ),
                ));
            }
            prog.impls.push(impl_decl(p, head.no_derives()?)?);
        },
        Tok::Unsafe => {
            let at = p.bump().span;
            if p.peek() != Tok::Impl {
                return Err(p.unexpected(
                    "`impl` after `unsafe`: only an impl can be, outside a function",
                ));
            }
            if let Some(v) = vis_span(vis) {
                return Err(Error::syntax(v, "an `impl` can't be `pub` or `export`"));
            }
            let mut d = impl_decl(p, head.no_derives()?)?;
            d.unsafe_ = Some(at);
            d.span = at.to(d.span);
            prog.impls.push(d);
        },
        Tok::Mod => mod_decl(p, prog, head.no_derives()?, vis)?,
        Tok::Const | Tok::Static => {
            let mut f = const_decl(p, head)?;
            f.vis = vis;
            prog.fns.push(f);
        },
        Tok::Extern => {
            let at = p.bump().span;
            if p.peek() != Tok::Fn {
                return Err(p.unexpected("`fn` after `extern`: only a function can be"));
            }
            let mut f = function(p, head, false, false, Some(at))?.0;
            f.span = at.to(f.span);
            f.vis = vis;
            prog.fns.push(f);
        },
        Tok::Use => {
            head.no_derives()?.no_allows_on("a `use`")?;
            let d = use_decl(p, vis)?;
            prog.uses.push(d);
        },
        _ => {
            let mut f = fn_decl(p, head.no_derives()?)?;
            if let (Some(_), Some(at)) = (f.test, vis_span(vis)) {
                let word = vis_word(vis);
                return Err(Error::owned(
                    at,
                    String::of(
                        &f"a test can't be `{word}`: `t test` runs it, and nothing else needs to see it",
                    ),
                ));
            }
            f.vis = vis;
            prog.fns.push(f);
        },
    }
    Ok(())
}

/// Where a `pub` or `export` is, if it's either.
fn vis_span(vis: Vis) -> Option<Span> {
    match vis {
        Vis::Private => None,
        Vis::Pub(at) => Some(at),
        Vis::Export(at) => Some(at),
    }
}

/// `pub` or `export`, or nothing.
fn vis_word(vis: Vis) -> &'static str {
    match vis {
        Vis::Private => "",
        Vis::Pub(_) => "pub",
        Vis::Export(_) => "export",
    }
}

/// `mod name { .. }` or `mod name;`, after its head and `pub` or
/// `export`, if it has one.
fn mod_decl(p: &mut Parser, prog: &mut Program, head: Head, vis: Vis) -> Result<(), Error> {
    let start = match vis_span(vis) {
        Some(at) => at,
        None => p.span(),
    };
    p.expect(Tok::Mod)?;
    let name = p.binder()?;
    if let "core" | "alloc" | "std" = name.name.as_str() {
        let lib = name.name.as_str();
        return Err(Error::owned(
            name.span,
            String::of(&f"a module can't be called `{lib}`: that's the name of the {lib} library"),
        ));
    }
    let in_file = p.peek() == Tok::Semi;
    // One place for a module's docs: in it, as for one in a file.
    if let Some(doc) = &head.doc {
        let first = doc.lines.first().expect("a line at least");
        let last = doc.lines.last().expect("a line at least");
        let span = first.span.to(last.span);
        if in_file {
            let n = name.name.as_str();
            return Err(Error::owned(
                span,
                String::of(
                    &f"a module's doc comment goes at the start of its file, as `//!` lines, not before `mod {n};`",
                ),
            ));
        }
        return Err(Error::syntax(
            span,
            "a module's doc comment goes inside it, as `//!` lines at the start",
        ));
    }
    let parent = Some(p.module);
    if in_file {
        let end = p.bump().span;
        prog.mods.push(ModDecl {
            doc: None,
            allows: head.allows,
            inner_allows: List::new(),
            span: start.to(end),
            name,
            parent,
            vis,
            in_file,
        });
        return Ok(());
    }
    p.expect(Tok::LBrace)?;
    let index = prog.mods.len();
    prog.mods.push(ModDecl {
        doc: None,
        allows: head.allows,
        inner_allows: List::new(),
        span: start,
        name,
        parent,
        vis,
        in_file,
    });
    let outer = p.module;
    p.module = index;
    let result = items(p, prog, Tok::RBrace);
    p.module = outer;
    result?;
    let m = module(prog, index);
    m.span = start.to(p.before().span);
    Ok(())
}

/// `use a::b;`, `use a::b as c;` or `use a::{b, c};`, after its `pub` or
/// `export`.
fn use_decl(p: &mut Parser, vis: Vis) -> Result<UseDecl, Error> {
    let start = match vis_span(vis) {
        Some(at) => at,
        None => p.span(),
    };
    p.expect(Tok::Use)?;
    let tree = use_tree(p)?;
    let end = p.expect(Tok::Semi)?;
    Ok(UseDecl { span: start.to(end), module: p.module, vis, tree })
}

/// `a::b`, `a::b as c` or `a::{..}`, in a `use`.
fn use_tree(p: &mut Parser) -> Result<UseTree, Error> {
    let start = p.span();
    let mut path = List::new();
    loop {
        match (p.peek(), path.is_empty()) {
            (Tok::LBrace, false) => {
                p.bump();
                let (trees, end) = p.comma_list(Tok::RBrace, use_tree)?;
                return Ok(UseTree { path, kind: UseKind::Group(trees), span: start.to(end) });
            },
            (Tok::Star, _) => {
                return Err(Error::syntax(
                    p.span(),
                    "glob imports (`*`) aren't supported: name each item, as in \
                     `use a::{b, c};`",
                ));
            },
            _ => path.push(p.segment()?),
        }
        if !p.eat(Tok::ColonColon) {
            break;
        }
    }
    let alias = match p.eat(Tok::As) {
        true => Some(p.binder()?),
        false => None,
    };
    let end = match &alias {
        Some(a) => a.span,
        None => path.last().expect("a name at least").span,
    };
    Ok(UseTree { path, kind: UseKind::Name(alias), span: start.to(end) })
}

/// A function, where only a `fn` can be, after its head.
pub fn fn_decl(p: &mut Parser, head: Head) -> Result<FnDecl, Error> {
    if p.peek() != Tok::Fn {
        return Err(p.unexpected(
            "`fn`, `const`, `static`, `struct`, `enum`, `type`, `trait` or `impl`",
        ));
    }
    Ok(function(p, head, false, false, None)?.0)
}

/// A function, after its head. A method (`method`) can take `self` and,
/// in a trait (`in_trait`), have no body. An `extern fn` (`ext` is where
/// its `extern` is) has none if it's an import. Says whether it has one.
fn function(
    p: &mut Parser,
    head: Head,
    method: bool,
    in_trait: bool,
    ext: Option<Span>,
) -> Result<(FnDecl, bool), Error> {
    let start = p.expect(Tok::Fn)?;
    let name = p.ident()?;
    let mut generics = generics(p)?;
    let open = p.expect(Tok::LParen)?;
    let mut first = true;
    let (params, close) = p.comma_list(Tok::RParen, |p| {
        let at_self = first && at_receiver(p);
        first = false;
        match (at_self, method) {
            (true, true) => receiver(p),
            (true, false) => Err(Error::syntax(
                p.span(),
                "only a method can take `self`: a function in a `trait` or `impl`",
            )),
            (false, _) => param(p),
        }
    })?;
    let ret = match p.eat(Tok::Arrow) {
        true => types::ty(p)?,
        false => TypeExpr { kind: TypeExprKind::Unit, span: close },
    };
    let effects = types::with_effects(p, Said::Fn)?;
    if p.peek() == Tok::Where {
        where_clause(p, &mut generics)?;
    }
    let mut ensures_ = List::new();
    if p.eat(Tok::Ensures) {
        loop {
            ensures_.push(p.structs(false, exprs::expr)?);
            if !p.eat(Tok::Comma) || p.peek() == Tok::LBrace || p.peek() == Tok::Semi {
                break;
            }
        }
    }
    let intrinsic = head.intrinsic;
    let bodiless = in_trait || intrinsic.is_some() || ext.is_some();
    let (body, provided) = match (p.peek(), bodiless, intrinsic) {
        (Tok::Semi, true, _) => {
            let span = p.bump().span;
            (Expr { kind: ExprKind::Block(List::new(), None), span }, false)
        },
        (Tok::Semi, false, _) => {
            return Err(Error::syntax(
                p.span(),
                "a function needs a body; only a method in a `trait` can have none",
            ));
        },
        (_, _, Some(_)) => {
            return Err(Error::syntax(
                p.span(),
                "an intrinsic has no body: the compiler provides it; end it with `;`",
            ));
        },
        _ => (exprs::block(p)?, true),
    };
    // An intrinsic's aborts are already shown where it's called, as an
    // operator's are; a trait's method without a body has no aborts of its
    // own; a test has no caller.
    if let Some(at) = head.blame_caller {
        if intrinsic.is_some() || !provided {
            return Err(Error::syntax(at, NOT_BLAMING));
        }
        if head.test.is_some() {
            return Err(Error::syntax(
                at,
                "a test can't blame its caller: it's run as a program of its own, which nothing \
                 in the program calls",
            ));
        }
    }
    let ext = match ext {
        Some(span) => Some(Extern { span, import: !provided }),
        None => None,
    };
    let f = FnDecl {
        doc: head.doc,
        allows: head.allows,
        span: start.to(body.span),
        module: p.module,
        vis: Vis::Private,
        name,
        generics,
        params,
        parens: open.to(close),
        ret,
        effects,
        body,
        intrinsic,
        measure: head.measure,
        ensures_,
        test: head.test,
        blame_caller: head.blame_caller,
        konst: None,
        is_static: false,
        ext,
    };
    Ok((f, provided))
}

/// `const N: usize = 4;`, after its head: a function of no parameters,
/// marked `konst`, whose result type is the const's and whose body is its
/// initializer. Or `static COUNT: Atomic<u32> = ..;`, the same, marked
/// `is_static` too.
fn const_decl(p: &mut Parser, head: Head) -> Result<FnDecl, Error> {
    let is_static = p.peek() == Tok::Static;
    let start = match is_static {
        true => p.expect(Tok::Static)?,
        false => p.expect(Tok::Const)?,
    };
    let name = p.ident()?;
    if p.peek() == Tok::Lt {
        let message = match is_static {
            true => "a static has no parameters: it's one place, the same wherever it's used",
            false => "a const has no parameters: it's one value, the same wherever it's used",
        };
        return Err(Error::syntax(p.span(), message));
    }
    p.expect(Tok::Colon)?;
    let ret = types::ty(p)?;
    p.expect(Tok::Eq)?;
    let body = exprs::expr(p)?;
    let end = p.expect(Tok::Semi)?;
    Ok(FnDecl {
        doc: head.doc,
        allows: head.allows,
        span: start.to(end),
        module: p.module,
        vis: Vis::Private,
        parens: name.span,
        name,
        generics: no_generics(),
        params: List::new(),
        ret,
        effects: None,
        body,
        intrinsic: None,
        measure: None,
        ensures_: List::new(),
        test: None,
        blame_caller: None,
        konst: Some(start),
        is_static,
        ext: None,
    })
}

/// The generics of what has none.
fn no_generics() -> Generics {
    Generics {
        lifetimes: List::new(),
        types: List::new(),
        bounds: List::new(),
        span: None,
        wheres: List::new(),
        where_span: None,
    }
}

/// `where T: Show, Self::Item: Discard` after a function's signature, or
/// an impl's type, added to its generics. The bounds go on while a `,` is
/// followed by something other than the body.
fn where_clause(p: &mut Parser, g: &mut Generics) -> Result<(), Error> {
    let start = p.expect(Tok::Where)?;
    let end = loop {
        let subject = types::ty(p)?;
        p.expect(Tok::Colon)?;
        let mut items = List::new();
        loop {
            items.push(match p.peek() {
                Tok::Lifetime(_) => types::plain(p.lifetime()?),
                _ => types::trait_bound(p)?,
            });
            if !p.eat(Tok::Plus) {
                break;
            }
        }
        let end = items.last().expect("a bound at least").span;
        g.wheres.push(WhereBound { subject, items });
        if !p.eat(Tok::Comma) {
            break end;
        }
        match p.peek() {
            Tok::LBrace | Tok::Semi | Tok::Ensures => break end,
            _ => {},
        }
    };
    g.where_span = Some(start.to(end));
    Ok(())
}

/// Is a receiver next: `self`, `mut self`, `&self`, `&'a mut self`..?
fn at_receiver(p: &Parser) -> bool {
    let mut i = 0;
    if p.peek() == Tok::Amp {
        i = 1;
        if let Tok::Lifetime(_) = p.peek2() {
            i = 2;
        }
    }
    if p.ahead(i).tok == Tok::Mut {
        i = i + 1;
    }
    is_word(p.ahead(i).tok, "self")
}

/// A method's receiver, as a parameter named `self` of type `Self`,
/// `&Self` or `&mut Self`, the type spanning what's written.
fn receiver(p: &mut Parser) -> Result<Param, Error> {
    let start = p.span();
    let by_ref = p.eat(Tok::Amp);
    let lifetime = match p.peek() {
        Tok::Lifetime(_) => Some(p.lifetime()?),
        _ => None,
    };
    let mut_span = match p.peek() {
        Tok::Mut => Some(p.bump().span),
        _ => None,
    };
    let name = p.ident()?;
    if p.peek() == Tok::Colon {
        return Err(Error::syntax(
            p.span(),
            "a receiver's type isn't written: it's `self`, `&self` or `&mut self`",
        ));
    }
    let self_ty = TypeExpr {
        kind: TypeExprKind::Named(String::from("Self"), List::new()),
        span: name.span,
    };
    let (mutable, ty) = match by_ref {
        false => (mut_span, self_ty),
        true => {
            let kind = TypeExprKind::Ref(lifetime, mut_span.is_some(), Box::new(self_ty));
            (None, TypeExpr { kind, span: start.to(name.span) })
        },
    };
    Ok(Param { doc: None, allows: List::new(), mutable, vis: Vis::Private, name, ty })
}

/// `trait Show: Super { .. }`, after its head.
fn trait_decl(p: &mut Parser, head: Head) -> Result<TraitDecl, Error> {
    let start = p.expect(Tok::Trait)?;
    let name = p.ident()?;
    if p.peek() == Tok::Lt {
        return Err(Error::syntax(
            p.span(),
            "a trait can't have type parameters (yet); its methods can",
        ));
    }
    let mut supers = List::new();
    if p.eat(Tok::Colon) {
        supers.push(p.path()?);
        while p.eat(Tok::Plus) {
            supers.push(p.path()?);
        }
    }
    p.expect(Tok::LBrace)?;
    let mut assoc = List::new();
    let mut effects = List::new();
    let mut methods = List::new();
    let mut laws = List::new();
    while p.peek() != Tok::RBrace {
        let h = read_head(p)?.no_derives()?.no_intrinsic()?.no_test()?;
        p.no_pub("a trait's methods are public wherever the trait is")?;
        match p.peek() {
            Tok::Law => {
                let law_ = p.bump().span;
                let h = h.no_blame_caller()?.no_measure(
                    "a law can't be a measure: it says what another trait's method promises",
                )?;
                if p.peek() != Tok::Fn {
                    return Err(p.unexpected("`fn` after `law`"));
                }
                let (decl, provided) = function(p, h, true, true, None)?;
                if provided {
                    return Err(Error::syntax(
                        decl.body.span,
                        "a law has no body: it says what each impl's method promises; end it with \
                         `;`",
                    ));
                }
                laws.push(Law { law_, decl });
            },
            Tok::Type => {
                let h = h.no_blame_caller()?.no_measure(NOT_METHOD)?;
                assoc.push(assoc_decl(p, h)?);
            },
            Tok::Effect => {
                let h = h.no_blame_caller()?.no_measure(NOT_METHOD)?;
                effects.push(effect_decl(p, h)?);
            },
            Tok::Fn => {
                let (decl, provided) = function(p, h, true, true, None)?;
                methods.push(TraitMethod { decl, provided });
            },
            Tok::Const | Tok::Static => {
                return Err(Error::syntax(
                    p.span(),
                    "a const or static is an item of a module: there are no associated ones yet",
                ));
            },
            Tok::Extern => return Err(Error::syntax(p.span(), NOT_EXTERN)),
            _ => return Err(p.unexpected("`fn`, `law`, `type`, `effect` or `}`")),
        }
    }
    let end = p.expect(Tok::RBrace)?;
    Ok(TraitDecl {
        doc: head.doc,
        allows: head.allows,
        intrinsic: head.intrinsic,
        sealed_: None,
        span: start.to(end),
        module: p.module,
        vis: Vis::Private,
        name,
        supers,
        assoc,
        effects,
        methods,
        laws,
    })
}

/// `type Item: Discard;` in a trait, after its head.
fn assoc_decl(p: &mut Parser, head: Head) -> Result<AssocDecl, Error> {
    let start = p.expect(Tok::Type)?;
    head.no_allows()?;
    let name = p.ident()?;
    let mut bounds = List::new();
    if p.eat(Tok::Colon) {
        bounds.push(p.path()?);
        while p.eat(Tok::Plus) {
            bounds.push(p.path()?);
        }
    }
    if p.peek() == Tok::Eq {
        return Err(Error::syntax(
            p.span(),
            "an associated type can't have a default: a default method could then be checked \
             knowing what it is, and an impl that picks another would make that wrong; each impl \
             says what it is",
        ));
    }
    let end = p.expect(Tok::Semi)?;
    Ok(AssocDecl { doc: head.doc, span: start.to(end), name, bounds })
}

/// `type Item = i64;` in an impl, after its head.
fn assoc_def(p: &mut Parser, head: Head) -> Result<AssocDef, Error> {
    let start = p.expect(Tok::Type)?;
    head.no_allows()?;
    let name = p.ident()?;
    p.expect(Tok::Eq)?;
    let ty = types::ty(p)?;
    let end = p.expect(Tok::Semi)?;
    Ok(AssocDef { doc: head.doc, span: start.to(end), name, ty })
}

/// `effect e;` in a trait, after its head.
fn effect_decl(p: &mut Parser, head: Head) -> Result<EffectDecl, Error> {
    let start = p.expect(Tok::Effect)?;
    head.no_allows()?;
    let name = p.ident()?;
    if p.peek() == Tok::Eq {
        return Err(Error::syntax(
            p.span(),
            "an associated effect can't have a default, as an associated type can't: each impl \
             says what it is",
        ));
    }
    let end = p.expect(Tok::Semi)?;
    Ok(EffectDecl { doc: head.doc, span: start.to(end), name })
}

/// `effect e = panic;` in an impl, after its head.
fn effect_def(p: &mut Parser, head: Head) -> Result<EffectDef, Error> {
    let start = p.expect(Tok::Effect)?;
    head.no_allows()?;
    let name = p.ident()?;
    p.expect(Tok::Eq)?;
    let effects = types::effect_set(p, None, Said::Binding)?;
    let end = p.expect(Tok::Semi)?;
    Ok(EffectDef { doc: head.doc, span: start.to(end), name, effects })
}

/// `impl<T> Show for Option<T> { .. }` or `impl Point { .. }`, after its
/// head.
fn impl_decl(p: &mut Parser, head: Head) -> Result<ImplDecl, Error> {
    let start = p.expect(Tok::Impl)?;
    let mut generics = generics(p)?;
    let first = types::ty(p)?;
    let (trait_name, self_ty) = match p.eat(Tok::For) {
        false => (None, first),
        true => match type_path(&first) {
            Some(name) => (Some(name), types::ty(p)?),
            None => {
                return Err(Error::syntax(first.span, "expected the name of a trait before `for`"));
            },
        },
    };
    if p.peek() == Tok::Where {
        where_clause(p, &mut generics)?;
    }
    p.expect(Tok::LBrace)?;
    let of_trait = trait_name.is_some();
    let mut assoc = List::new();
    let mut effects = List::new();
    let mut methods = List::new();
    while p.peek() != Tok::RBrace {
        let h = read_head(p)?.no_derives()?.no_test()?;
        let h = match of_trait {
            false => h,
            true => h.no_intrinsic()?,
        };
        let vis = match of_trait {
            true => {
                p.no_pub("a trait impl's methods are public wherever the trait is")?;
                Vis::Private
            },
            false => p.vis(),
        };
        match p.peek() {
            Tok::Type => {
                let h = h.no_blame_caller()?.no_measure(NOT_METHOD)?;
                assoc.push(assoc_def(p, h)?);
            },
            Tok::Effect => {
                let h = h.no_blame_caller()?.no_measure(NOT_METHOD)?;
                effects.push(effect_def(p, h)?);
            },
            Tok::Fn => {
                let mut f = function(p, h, true, false, None)?.0;
                f.vis = vis;
                methods.push(f);
            },
            Tok::Const | Tok::Static => {
                return Err(Error::syntax(
                    p.span(),
                    "a const or static is an item of a module: there are no associated ones yet",
                ));
            },
            Tok::Extern => return Err(Error::syntax(p.span(), NOT_EXTERN)),
            _ => return Err(p.unexpected("`fn`, `type`, `effect` or `}`")),
        }
    }
    let end = p.expect(Tok::RBrace)?;
    Ok(ImplDecl {
        doc: head.doc,
        allows: head.allows,
        span: start.to(end),
        module: p.module,
        generics,
        unsafe_: None,
        trait_name,
        self_ty,
        assoc,
        effects,
        methods,
    })
}

/// A type written as a plain path, `Show` or `a::Show`, as the one name
/// `Parser::path` would make of it: where a trait's name is expected.
fn type_path(t: &TypeExpr) -> Option<Ident> {
    match &t.kind {
        TypeExprKind::Named(name, args) => match args.is_empty() {
            true => Some(Ident { name: String::from(name.as_str()), span: t.span }),
            false => None,
        },
        TypeExprKind::Proj(inner, None, name) => match type_path(inner) {
            Some(inner) => Some(join(&inner, name)),
            None => None,
        },
        _ => None,
    }
}

/// `<'a, T: Show + 'a>` after the name of a function, struct or enum, or
/// after `impl`, if it's there.
pub fn generics(p: &mut Parser) -> Result<Generics, Error> {
    let mut g = no_generics();
    if p.peek() != Tok::Lt {
        return Ok(g);
    }
    let start = p.bump().span;
    let end = p.comma_list(Tok::Gt, |p| generic_param(p, &mut g))?.1;
    g.span = Some(start.to(end));
    Ok(g)
}

/// One of the parameters of `generics`, put in `g`, with its bounds.
fn generic_param(p: &mut Parser, g: &mut Generics) -> Result<(), Error> {
    let param = match p.peek() {
        Tok::Lifetime(_) => {
            if !g.types.is_empty() {
                return Err(Error::syntax(
                    p.span(),
                    "lifetime parameters must come before type parameters",
                ));
            }
            let l = p.lifetime()?;
            g.lifetimes.push(copied(&l));
            l
        },
        Tok::Const => {
            p.bump();
            let name = p.ident()?;
            p.expect(Tok::Colon)?;
            let ty = types::ty(p)?;
            g.types.push(TypeParam { name, kind: ParamKind::Const(ty) });
            return Ok(());
        },
        Tok::Unsized => {
            p.bump();
            if !is_ident(p.peek()) {
                return Err(p.unexpected("a type parameter after `unsized`"));
            }
            let name = p.ident()?;
            g.types.push(TypeParam { name: copied(&name), kind: ParamKind::Unsized });
            name
        },
        Tok::Effect => {
            p.bump();
            let name = p.ident()?;
            if p.peek() == Tok::Colon {
                return Err(Error::syntax(
                    p.span(),
                    "an effect parameter has no bounds: it stands for any effects",
                ));
            }
            g.types.push(TypeParam { name, kind: ParamKind::Effect });
            return Ok(());
        },
        _ => {
            let name = p.ident()?;
            g.types.push(TypeParam { name: copied(&name), kind: ParamKind::Type });
            name
        },
    };
    if p.eat(Tok::Colon) {
        // A lifetime outlives lifetimes; a type parameter can also
        // implement traits.
        let lifetime = param.name.as_str().starts_with('\'');
        let mut items = List::new();
        loop {
            let item = match (p.peek(), lifetime) {
                (Tok::Ident(_), false) | (Tok::Crate, false) | (Tok::Super, false) => {
                    types::trait_bound(p)?
                },
                (_, true) | (Tok::Lifetime(_), false) => types::plain(p.lifetime()?),
                _ => return Err(p.unexpected("a lifetime or a trait")),
            };
            items.push(item);
            if !p.eat(Tok::Plus) {
                break;
            }
        }
        g.bounds.push(Bound { subject: param, items });
    }
    Ok(())
}

/// A function parameter: `x: i64` or `mut x: i64`.
fn param(p: &mut Parser) -> Result<Param, Error> {
    let mutable = match p.peek() {
        Tok::Mut => Some(p.bump().span),
        _ => None,
    };
    let name = p.variable()?;
    p.expect(Tok::Colon)?;
    let ty = types::ty(p)?;
    Ok(Param { doc: None, allows: List::new(), mutable, vis: Vis::Private, name, ty })
}

/// `struct Point { x: i64, y: i64 }`, after its head.
pub fn struct_decl(p: &mut Parser, head: Head) -> Result<StructDecl, Error> {
    let start = p.expect(Tok::Struct)?;
    let name = p.ident()?;
    let generics = generics(p)?;
    p.expect(Tok::LBrace)?;
    let (fields, end) = p.comma_list(Tok::RBrace, field)?;
    if let (Some(_), Some(field)) = (head.intrinsic, fields.first()) {
        return Err(Error::syntax(
            field.name.span,
            "an intrinsic struct has no fields: what's in it is the compiler's business",
        ));
    }
    Ok(StructDecl {
        doc: head.doc,
        allows: head.allows,
        span: start.to(end),
        module: p.module,
        vis: Vis::Private,
        name,
        generics,
        derives: head.derives,
        fields,
        intrinsic: head.intrinsic,
    })
}

/// A struct's field, `pub x: i64`, with its head.
fn field(p: &mut Parser) -> Result<Param, Error> {
    let h = read_head(p)?.no_derives()?.no_test()?.no_blame_caller()?;
    let vis = p.vis();
    if p.peek() == Tok::Mut {
        return Err(Error::syntax(
            p.span(),
            "a field can't be `mut`: whether it can change depends on where its struct is",
        ));
    }
    let name = p.binder()?;
    p.expect(Tok::Colon)?;
    let ty = types::ty(p)?;
    Ok(Param { doc: h.doc, allows: h.allows, vis, mutable: None, name, ty })
}

/// `type Name<'a, T> = Type;`, whose parameters have no bounds: what it
/// stands for is checked where it's used, as if written there.
pub fn alias_decl(p: &mut Parser, head: Head) -> Result<AliasDecl, Error> {
    let start = p.expect(Tok::Type)?;
    let name = p.ident()?;
    let generics = generics(p)?;
    if let Some(b) = generics.bounds.first() {
        let at = match (b.items.first(), generics.span) {
            (Some(item), _) => item.span,
            (None, Some(span)) => span,
            (None, None) => name.span,
        };
        return Err(Error::syntax(
            at,
            "a type alias's parameters can't have bounds; what it stands for is checked where \
             it's used",
        ));
    }
    p.expect(Tok::Eq)?;
    let ty = types::ty(p)?;
    let end = p.expect(Tok::Semi)?;
    Ok(AliasDecl {
        doc: head.doc,
        allows: head.allows,
        span: start.to(end),
        module: p.module,
        vis: Vis::Private,
        name,
        generics,
        ty,
    })
}

/// `enum Shape { Dot, Rect(i64, i64) }`, after its head.
pub fn enum_decl(p: &mut Parser, head: Head) -> Result<EnumDecl, Error> {
    let start = p.expect(Tok::Enum)?;
    let name = p.ident()?;
    let generics = generics(p)?;
    p.expect(Tok::LBrace)?;
    let (variants, end) = p.comma_list(Tok::RBrace, variant)?;
    Ok(EnumDecl {
        doc: head.doc,
        allows: head.allows,
        span: start.to(end),
        module: p.module,
        vis: Vis::Private,
        name,
        generics,
        derives: head.derives,
        variants,
    })
}

/// An enum's variant, `Rect(i64, i64)`, with its head.
fn variant(p: &mut Parser) -> Result<Variant, Error> {
    let h = read_head(p)?.no_derives()?.no_test()?.no_blame_caller()?;
    p.no_pub("an enum's variants are public wherever it is")?;
    let name = p.ident()?;
    if !starts_upper(name.name.as_str()) {
        let n = name.name.as_str();
        return Err(Error::owned(
            name.span,
            String::of(
                &f"a variant's name starts with an uppercase letter: in a pattern, `{n}` would be a new variable",
            ),
        ));
    }
    let (fields, span) = match p.eat(Tok::LParen) {
        true => {
            let (fields, close) = p.comma_list(Tok::RParen, types::ty)?;
            (fields, name.span.to(close))
        },
        false => (List::new(), name.span),
    };
    Ok(Variant { doc: h.doc, allows: h.allows, span, name, fields })
}
