//! Printing items: modules, `use`s, types, traits, impls and functions,
//! with their generics, bounds, `where` clauses and effects.

use alloc::list::List;
use alloc::string::String;
use core::cmp::min;

use crate::ast::{
    Allow,
    AssocBoundKind,
    AssocDecl,
    AssocDef,
    BoundItem,
    DocComment,
    Effect,
    EffectDecl,
    EffectDef,
    EffectKind,
    EffectSet,
    Expr,
    FnDecl,
    Generics,
    Guard,
    Ident,
    ImplDecl,
    Law,
    ModDecl,
    Param,
    ParamKind,
    Program,
    TraitDecl,
    TypeDecl,
    TypeExprKind,
    TypeParam,
    UseDecl,
    UseKind,
    UseTree,
    Variant,
    Vis,
};
use crate::error::Span;
use crate::lexer::Tok;
use crate::pretty::doc::{flat, flat_width, group, if_break, nest, text, Doc, WIDTH};
use crate::pretty::exprs::expr;
use crate::pretty::trivia::sort;
use crate::pretty::types::{ty, types};
use crate::pretty::{join, Printer, ANGLES, ANY, BRACES, PARENS, USE};
use crate::text::item;

/// An item of a module.
#[derive(Copy, Discard)]
enum Item<'p> {
    Type(&'p TypeDecl),
    Trait(&'p TraitDecl),
    Impl(&'p ImplDecl),
    Fn(&'p FnDecl),
    /// With its index in `Program::mods`.
    Mod(usize, &'p ModDecl),
    Use(&'p UseDecl),
}

/// Something in the `{ .. }` of a trait or impl.
#[derive(Copy, Discard)]
enum BodyItem<'p> {
    /// A method, with whether it has a body.
    Fn(&'p FnDecl, bool),
    /// `law fn next(&mut self) -> ..;`, in a trait.
    Law(&'p Law),
    /// `type Item: Discard;`, in a trait.
    Decl(&'p AssocDecl),
    /// `type Item = i64;`, in an impl.
    Def(&'p AssocDef),
    /// `effect e;`, in a trait.
    EffectDecl(&'p EffectDecl),
    /// `effect e = panic;`, in an impl.
    EffectDef(&'p EffectDef),
}

/// A generic parameter: a lifetime, or a type, effect, `unsized` or const
/// parameter.
#[derive(Copy, Discard)]
enum GenericParam<'p> { Lifetime(&'p Ident), Type(&'p TypeParam) }

impl<'p> GenericParam<'p> {
    /// Its name: `'a`, `T`.
    fn name(self) -> &'p Ident {
        match self {
            GenericParam::Lifetime(l) => l,
            GenericParam::Type(t) => &t.name,
        }
    }
}

/// The items of module `module`, in the order they're written, and whether
/// it has none.
pub fn items(p: &mut Printer, program: &Program, module: usize) -> (Doc, bool) {
    let items = items_of(program, module);
    let mut doc = Doc::nil();
    let mut i = 0usize;
    for x in items.iter() {
        let (pos, it) = *x;
        if i > 0 {
            doc = doc.add(Doc::HardLine);
        }
        // It starts at its doc comment or attributes, or else at the
        // `pub`, `struct`, `enum` or `fn` before the name.
        let start = match it {
            Item::Type(d) => {
                let start = type_lead_start(d, p.before(pos));
                match vis_span(decl_vis(d)) {
                    Some(v) => min(start, v.start),
                    None => start,
                }
            },
            Item::Fn(f) => lead_start(&f.doc, &f.allows, fn_start(f)),
            Item::Trait(t) => {
                let start = match vis_span(t.vis) {
                    Some(v) => v.start,
                    None => t.span.start,
                };
                let start = match t.intrinsic {
                    Some(at) => min(at.start, start),
                    None => start,
                };
                lead_start(&t.doc, &t.allows, start)
            },
            Item::Impl(d) => lead_start(&d.doc, &d.allows, d.span.start),
            Item::Mod(_, m) => lead_start(&None, &m.allows, m.span.start),
            Item::Use(u) => u.span.start,
        };
        doc = doc.add(p.element(start, i == 0));
        let end = match it {
            Item::Type(_) => p.find(pos, Tok::RBrace) + 1,
            Item::Fn(f) => f.body.span.end,
            Item::Trait(t) => t.span.end,
            Item::Impl(d) => d.span.end,
            Item::Mod(_, m) => m.span.end,
            Item::Use(u) => u.span.end,
        };
        let printed = match it {
            Item::Type(d) => type_decl(p, d),
            Item::Trait(t) => trait_decl(p, t),
            Item::Impl(d) => impl_decl(p, d),
            Item::Fn(f) => fn_decl(p, f),
            Item::Mod(n, m) => mod_decl(p, program, n, m),
            Item::Use(u) => {
                let tree = use_tree(p, &u.tree);
                vis(u.vis).text("use ").add(tree).text(";")
            },
        };
        doc = doc.add(printed).add(p.trailing(end));
        i = i + 1;
    }
    (doc, items.is_empty())
}

/// The items of module `module`, each with where its name is in the
/// source, in that order.
fn items_of<'p>(program: &'p Program, module: usize) -> List<(usize, Item<'p>)> {
    let mut items = List::new();
    for d in program.types.iter() {
        if decl_module(d) == module {
            items.push((decl_name(d).span.start, Item::Type(d)));
        }
    }
    for t in program.traits.iter() {
        if t.module == module {
            items.push((t.span.start, Item::Trait(t)));
        }
    }
    for d in program.impls.iter() {
        if d.module == module {
            items.push((d.span.start, Item::Impl(d)));
        }
    }
    for f in program.fns.iter() {
        if f.module == module {
            items.push((f.name.span.start, Item::Fn(f)));
        }
    }
    let mut n = 0usize;
    for m in program.mods.iter() {
        if n > 0 && m.parent == Some(module) {
            items.push((m.name.span.start, Item::Mod(n, m)));
        }
        n = n + 1;
    }
    for u in program.uses.iter() {
        if u.module == module {
            items.push((u.span.start, Item::Use(u)));
        }
    }
    sort(&mut items, 0, |x| x.0);
    items
}

/// `mod name { .. }` or `mod name;`, module `n` of `program`.
fn mod_decl(p: &mut Printer, program: &Program, n: usize, m: &ModDecl) -> Doc {
    // Its doc comment is `//!` lines in it, first.
    let lead = p.lead(&None, &m.allows, m.span.start);
    let name = m.name.name.as_str();
    if m.in_file {
        return lead.add(vis(m.vis)).text("mod ").text(name).text(";");
    }
    let head = lead.add(vis(m.vis)).text("mod ").text(name).text(" ");
    let open = p.find(m.name.span.end, Tok::LBrace);
    let close = m.span.end - 1;
    let mut body = p.trailing(open + 1);
    let docs = match &m.doc {
        Some(d) => Some(crate::pretty::inner_doc(d)),
        None => None,
    };
    let docs = p.with_inner_allows(docs, &m.inner_allows);
    let (items, empty) = items(p, program, n);
    if empty && docs.is_none() && !p.comments_before(close) {
        return head.text("{}");
    }
    let has_docs = docs.is_some();
    if let Some(d) = docs {
        body = body.add(Doc::HardLine).add(d);
        if !empty {
            body = body.add(Doc::HardLine);
        }
    }
    if !empty {
        body = body.add(Doc::HardLine).add(items);
    }
    for c in p.dangling(close, empty && !has_docs) {
        body = body.add(Doc::HardLine).add(c);
    }
    head.text("{").add(nest(body)).add(Doc::HardLine).text("}")
}

/// `trait Ord: Eq { .. }`
fn trait_decl(p: &mut Printer, t: &TraitDecl) -> Doc {
    let mut doc = p.lead(&t.doc, &t.allows, t.span.start);
    if let Some(at) = t.intrinsic {
        doc = doc.text("#[intrinsic]").add(p.trailing(at.end)).add(Doc::HardLine);
        let before = p.before(t.span.start);
        doc = doc.add(p.element(before, true));
    }
    let mut supers = List::new();
    for s in t.supers.iter() {
        supers.push(String::from(s.name.as_str()));
    }
    let supers = match supers.is_empty() {
        true => String::new(),
        false => {
            let s = join(&supers, " + ");
            String::of(&f": {s}")
        },
    };
    let open = p.find(t.name.span.end, Tok::LBrace);
    let mut items = List::new();
    for a in t.assoc.iter() {
        items.push(BodyItem::Decl(a));
    }
    for e in t.effects.iter() {
        items.push(BodyItem::EffectDecl(e));
    }
    for m in t.methods.iter() {
        items.push(BodyItem::Fn(&m.decl, m.provided));
    }
    for l in t.laws.iter() {
        items.push(BodyItem::Law(l));
    }
    let body = methods(p, open, t.span.end - 1, items);
    let seal = if t.sealed_.is_some() { "sealed " } else { "" };
    let head = doc.add(vis(t.vis)).text(seal).text("trait ").text(t.name.name.as_str());
    head.owned(supers).text(" ").add(body)
}

/// `impl<T: Show> Show for Option<T> { .. }` or `impl Point { .. }`
fn impl_decl(p: &mut Printer, d: &ImplDecl) -> Doc {
    let doc = p.lead(&d.doc, &d.allows, d.span.start);
    let (unsafe_, at) = match d.unsafe_ {
        Some(u) => ("unsafe ", p.find(u.end, Tok::Impl)),
        None => ("", d.span.start),
    };
    let generics = generics(p, at + 4, &d.generics);
    let header = match &d.trait_name {
        Some(t) => Doc::Text(String::of(&f" {t.name} for ")),
        None => text(" "),
    };
    let open = p.find(d.self_ty.span.end, Tok::LBrace);
    let mut items = List::new();
    for a in d.assoc.iter() {
        items.push(BodyItem::Def(a));
    }
    for e in d.effects.iter() {
        items.push(BodyItem::EffectDef(e));
    }
    for f in d.methods.iter() {
        items.push(BodyItem::Fn(f, true));
    }
    let body = methods(p, open, d.span.end - 1, items);
    // A type short enough stays on the line, so a long header breaks
    // its `<..>` instead, as a function breaks its parameters before
    // its result.
    let self_ty = ty(p, &d.self_ty);
    let self_ty = match flat(&self_ty) {
        Some(f) => match flat_width(&f) {
            Some(w) => match w <= WIDTH / 2 {
                true => f,
                false => self_ty,
            },
            None => self_ty,
        },
        None => self_ty,
    };
    let wheres = wheres(p, &None, &d.generics, &List::new(), true);
    doc.text(unsafe_).text("impl").add(generics).add(header).add(self_ty).add(wheres).add(body)
}

/// Where something in the body of a trait or impl starts, its doc comment
/// and attributes and all, for putting them in the order written.
fn body_start(item: BodyItem) -> usize {
    match item {
        BodyItem::Fn(f, _) => lead_start(&f.doc, &f.allows, fn_start(f)),
        BodyItem::Law(l) => lead_start(&l.decl.doc, &l.decl.allows, l.law_.start),
        BodyItem::Decl(a) => a.span.start,
        BodyItem::Def(a) => a.span.start,
        BodyItem::EffectDecl(a) => a.span.start,
        BodyItem::EffectDef(a) => a.span.start,
    }
}

/// The `{ .. }` of a trait or impl, with the `{` at `open` and the `}`
/// at `close` in the source: its associated types and methods, in the
/// order written, one after another.
fn methods(p: &mut Printer, open: usize, close: usize, items: List<BodyItem>) -> Doc {
    if items.is_empty() && !p.comments_before(close) {
        return text("{}");
    }
    let mut items = items;
    sort(&mut items, 0, |m| body_start(*m));
    let mut body = p.trailing(open + 1);
    let mut i = 0usize;
    for x in items.iter() {
        let it = *x;
        let none = List::new();
        let (doc, allows, span) = match it {
            BodyItem::Fn(f, _) => (&f.doc, &f.allows, Span::new(fn_start(f), f.span.end)),
            BodyItem::Law(l) => {
                (&l.decl.doc, &l.decl.allows, Span::new(l.law_.start, l.decl.span.end))
            },
            BodyItem::Decl(a) => (&a.doc, &none, a.span),
            BodyItem::Def(a) => (&a.doc, &none, a.span),
            BodyItem::EffectDecl(a) => (&a.doc, &none, a.span),
            BodyItem::EffectDef(a) => (&a.doc, &none, a.span),
        };
        let start = lead_start(doc, allows, span.start);
        body = body.add(Doc::HardLine).add(p.element(start, i == 0));
        let doc = match it {
            BodyItem::Fn(f, true) => fn_decl(p, f),
            BodyItem::Fn(f, false) => {
                let sig = signature(p, f, true);
                sig.add(wheres(p, &f.effects, &f.generics, &f.ensures_, false)).text(";")
            },
            BodyItem::Law(l) => {
                let f = &l.decl;
                let lead = p.lead(&f.doc, &f.allows, l.law_.start);
                let sig = signature(p, f, false);
                let wheres = wheres(p, &f.effects, &f.generics, &f.ensures_, false);
                lead.text("law ").add(sig).add(wheres).text(";")
            },
            BodyItem::Decl(a) => {
                let lead = p.lead(&a.doc, &List::new(), a.span.start);
                let mut bounds = List::new();
                for b in a.bounds.iter() {
                    bounds.push(String::from(b.name.as_str()));
                }
                let bounds = match bounds.is_empty() {
                    true => String::new(),
                    false => {
                        let b = join(&bounds, " + ");
                        String::of(&f": {b}")
                    },
                };
                lead.text("type ").text(a.name.name.as_str()).owned(bounds).text(";")
            },
            BodyItem::Def(a) => {
                let lead = p.lead(&a.doc, &List::new(), a.span.start);
                let lead = lead.text("type ").text(a.name.name.as_str()).text(" = ");
                lead.add(ty(p, &a.ty)).text(";")
            },
            BodyItem::EffectDecl(a) => {
                let lead = p.lead(&a.doc, &List::new(), a.span.start);
                lead.text("effect ").text(a.name.name.as_str()).text(";")
            },
            BodyItem::EffectDef(a) => {
                let lead = p.lead(&a.doc, &List::new(), a.span.start);
                let lead = lead.text("effect ").text(a.name.name.as_str()).text(" = ");
                lead.add(effects(p, &a.effects)).text(";")
            },
        };
        body = body.add(doc).add(p.trailing(span.end));
        i = i + 1;
    }
    for c in p.dangling(close, items.is_empty()) {
        body = body.add(Doc::HardLine).add(c);
    }
    text("{").add(nest(body)).add(Doc::HardLine).text("}")
}

/// The bounds on `name`, a lifetime or type parameter of `g`: lifetimes
/// and traits.
fn bounds_of<'g>(g: &'g Generics, name: &str) -> List<&'g BoundItem> {
    let mut out = List::new();
    for b in g.bounds.iter() {
        if b.subject.name.as_str() == name {
            for i in b.items.iter() {
                out.push(i);
            }
        }
    }
    out
}

/// Where generic parameter `x` of `g` ends: after its bounds, if it has
/// any, or its type, if it's a const parameter.
fn param_end(g: &Generics, x: GenericParam) -> usize {
    if let GenericParam::Type(TypeParam { kind: ParamKind::Const(t), .. }) = x {
        return t.span.end;
    }
    let name = x.name();
    match bounds_of(g, name.name.as_str()).last() {
        Some(b) => b.span.end,
        None => name.span.end,
    }
}

/// `<'a, T: Show + 'a>` after the name of a generic function, struct or
/// enum, or after `impl`, which ends at `after`.
pub fn generics(p: &mut Printer, after: usize, g: &Generics) -> Doc {
    if g.lifetimes.is_empty() && g.types.is_empty() {
        return Doc::nil();
    }
    let mut params = List::new();
    for l in g.lifetimes.iter() {
        params.push(GenericParam::Lifetime(l));
    }
    for t in g.types.iter() {
        params.push(GenericParam::Type(t));
    }
    let last = match params.last() {
        Some(x) => Some(param_end(g, *x)),
        None => None,
    };
    let close = p.close(after, last, Tok::Gt);
    p.list(ANGLES, close, &params, |x| (x.name().span.start, param_end(g, *x)), None, |pp, x| {
        let name = x.name().name.as_str();
        let mut out = match *x {
            GenericParam::Type(TypeParam { kind: ParamKind::Const(t), .. }) => {
                text("const ").text(name).text(": ").add(ty(pp, t))
            },
            GenericParam::Type(TypeParam { kind: ParamKind::Effect, .. }) => {
                text("effect ").text(name)
            },
            GenericParam::Type(TypeParam { kind: ParamKind::Unsized, .. }) => {
                text("unsized ").text(name)
            },
            _ => text(name),
        };
        let mut i = 0usize;
        for b in bounds_of(g, name).iter() {
            let sep = if i == 0 { ": " } else { " + " };
            out = out.text(sep).add(bound(pp, b));
            i = i + 1;
        }
        out
    })
}

/// `Show`, `Iter<Item = i64>` or `Fn(i64) -> i64`.
pub fn bound(p: &mut Printer, b: &BoundItem) -> Doc {
    let mut out = text(b.name.name.as_str());
    if let Some(sig) = &b.sig {
        let open = p.find(b.name.span.end, Tok::LParen);
        let last = match sig.params.last() {
            Some(t) => Some(t.span.end),
            None => None,
        };
        let close = p.close(open, last, Tok::RParen);
        out = out.add(types(p, PARENS, close, &sig.params));
        if let Some(ret) = &sig.ret {
            out = out.text(" -> ").add(ty(p, ret));
        }
        if let Some(e) = &b.effects {
            out = out.text(" ").add(effects(p, e));
        }
        return out;
    }
    if b.assoc.is_empty() {
        return out;
    }
    let mut args = Doc::nil();
    let mut j = 0usize;
    for a in b.assoc.iter() {
        if j > 0 {
            args = args.text(", ");
        }
        args = args.text(a.name.name.as_str());
        args = match &a.kind {
            AssocBoundKind::Eq(t) => args.text(" = ").add(ty(p, t)),
            AssocBoundKind::Effects(e) => {
                let mut set = text("{");
                let mut i = 0usize;
                for x in e.items.iter() {
                    if i > 0 {
                        set = set.text(", ");
                    }
                    set = set.add(one_effect(p, x));
                    i = i + 1;
                }
                args.text(" = ").add(set).text("}")
            },
            AssocBoundKind::Bounds(ts) => {
                let mut names = List::new();
                for t in ts.iter() {
                    names.push(String::from(t.name.as_str()));
                }
                args.text(": ").owned(join(&names, " + "))
            },
        };
        j = j + 1;
    }
    out.text("<").add(args).text(">")
}

/// A struct, enum or type alias.
pub fn type_decl(p: &mut Printer, d: &TypeDecl) -> Doc {
    let name = decl_name(d);
    let before = p.before(name.span.start);
    let (doc, allows, derives, g) = match d {
        TypeDecl::Struct(s) => (&s.doc, &s.allows, &s.derives, &s.generics),
        TypeDecl::Enum(e) => (&e.doc, &e.allows, &e.derives, &e.generics),
        TypeDecl::Alias(a) => {
            let doc = p.lead_derives(&a.doc, &a.allows, &List::new(), before);
            let head = doc.add(vis(a.vis)).text("type ").text(name.name.as_str());
            let head = head.add(generics(p, name.span.end, &a.generics)).text(" = ");
            return head.add(ty(p, &a.ty)).text(";");
        },
    };
    let mut doc = p.lead_derives(doc, allows, derives, before);
    if let TypeDecl::Struct(s) = d {
        if let Some(at) = s.intrinsic {
            doc = doc.text("#[intrinsic]").add(p.trailing(at.end)).add(Doc::HardLine);
            let before = p.before(name.span.start);
            doc = doc.add(p.element(before, true));
        }
    }
    let open = p.find(name.span.end, Tok::LBrace);
    let close = p.find(open, Tok::RBrace);
    if !p.quiet {
        p.trivia.hold_docs(name.span.start, close);
    }
    let keyword = match d {
        TypeDecl::Struct(_) => "struct ",
        _ => "enum ",
    };
    let head = doc.add(vis(decl_vis(d))).text(keyword).text(name.name.as_str());
    let head = head.add(generics(p, name.span.end, g)).text(" ");
    let body = match d {
        TypeDecl::Struct(s) => p.list(
            BRACES,
            close,
            &s.fields,
            |f| (lead_start(&f.doc, &f.allows, field_start(f)), f.ty.span.end),
            None,
            |p, f| {
                let lead = p.lead(&f.doc, &f.allows, field_start(f));
                lead.add(vis(f.vis)).add(param(p, f))
            },
        ),
        TypeDecl::Enum(e) => {
            let mut variants = List::new();
            for v in e.variants.iter() {
                let end = match v.fields.last() {
                    Some(t) => p.find(t.span.end, Tok::RParen) + 1,
                    None => v.name.span.end,
                };
                variants.push((v, end));
            }
            p.list(
                BRACES,
                close,
                &variants,
                |x| (lead_start(&x.0.doc, &x.0.allows, x.0.name.span.start), x.1),
                None,
                |p, x| variant(p, x.0, x.1),
            )
        },
        TypeDecl::Alias(_) => Doc::nil(),
    };
    head.add(body)
}

/// Variant `v` of an enum, which ends at `end`.
fn variant(p: &mut Printer, v: &Variant, end: usize) -> Doc {
    let doc = p.lead(&v.doc, &v.allows, v.name.span.start);
    let fields = match v.fields.is_empty() {
        true => Doc::nil(),
        false => types(p, PARENS, end - 1, &v.fields),
    };
    doc.text(v.name.name.as_str()).add(fields)
}

/// Where a struct's field starts after its doc comment and attributes: at
/// its `pub`, if it has one.
fn field_start(f: &Param) -> usize {
    match vis_span(f.vis) {
        Some(v) => v.start,
        None => f.name.span.start,
    }
}

/// `name: type`, or `mut name: type`. A receiver as it's written:
/// `self`, `mut self`, `&self`, `&'a mut self`.
fn param(p: &mut Printer, x: &Param) -> Doc {
    if x.name.name.as_str() == "self" {
        let shorthand = match &x.ty.kind {
            TypeExprKind::Ref(lifetime, m, _) => {
                let mut s = String::from("&");
                if let Some(l) = lifetime {
                    s.push_str(l.name.as_str());
                    s.push(' ');
                }
                if *m {
                    s.push_str("mut ");
                }
                s.push_str("self");
                s
            },
            _ => match x.mutable {
                Some(_) => String::from("mut self"),
                None => String::from("self"),
            },
        };
        return Doc::Text(shorthand);
    }
    let name = match x.mutable {
        Some(_) => String::of(&f"mut {x.name.name}"),
        None => String::from(x.name.name.as_str()),
    };
    Doc::Text(name).text(": ").add(ty(p, &x.ty))
}

/// A function, `const` or `static`.
pub fn fn_decl(p: &mut Printer, f: &FnDecl) -> Doc {
    if f.konst.is_some() {
        let doc = p.lead(&f.doc, &f.allows, fn_start(f));
        let t = ty(p, &f.ret);
        let value = expr(p, &f.body, 0, ANY);
        let keyword = if f.is_static { "static " } else { "const " };
        let doc = doc.add(vis(f.vis)).text(keyword).text(f.name.name.as_str()).text(": ");
        return doc.add(t).text(" = ").add(value).text(";");
    }
    let import = match f.ext {
        Some(e) => e.import,
        None => false,
    };
    match f.intrinsic.is_some() || import {
        true => {
            let sig = signature(p, f, true);
            sig.add(wheres(p, &f.effects, &f.generics, &f.ensures_, false)).text(";")
        },
        // In order: comments are printed as what's after them is.
        false => {
            let sig = signature(p, f, true);
            let head = sig.add(wheres(p, &f.effects, &f.generics, &f.ensures_, true));
            head.add(expr(p, &f.body, 0, ANY))
        },
    }
}

/// A function's or impl's `where` clause, from `g`, if it has one, on
/// the signature's line if it fits there, and otherwise on lines of its
/// own, one bound to a line, as rustfmt does: then a body's `{` goes on
/// a line of its own too. With a space before the body after it, if
/// there's a `body`.
///
/// A function's `effects`, `with ..`, come first, and go on a line of
/// their own with it; its `ensures` last, laid out as `where` is.
fn wheres(
    p: &mut Printer,
    effects_: &Option<EffectSet>,
    g: &Generics,
    posts: &List<Expr>,
    body: bool,
) -> Doc {
    let after = if body { text(" ") } else { Doc::nil() };
    let has_with = effects_.is_some();
    let effects_ = match effects_ {
        Some(e) => Doc::Line.add(effects(p, e)),
        None => Doc::nil(),
    };
    let end = if body { Doc::Line } else { Doc::nil() };
    let has_ensures = !posts.is_empty();
    let posts_doc = match posts.is_empty() {
        true => Doc::nil(),
        false => {
            let mut preds = Doc::nil();
            let mut i = 0usize;
            for e in posts.iter() {
                if i > 0 {
                    preds = preds.text(",").add(Doc::Line);
                }
                preds = preds.add(expr(p, e, 0, ANY));
                i = i + 1;
            }
            let comma = if body { break_comma() } else { Doc::nil() };
            Doc::Line.text("ensures").add(nest(Doc::Line.add(preds).add(comma)))
        },
    };
    if g.wheres.is_empty() {
        return match has_with || has_ensures {
            false => after,
            true => group(effects_.add(posts_doc).add(end)),
        };
    }
    let mut preds = Doc::nil();
    let mut i = 0usize;
    for w in g.wheres.iter() {
        if i > 0 {
            preds = preds.text(",").add(Doc::Line);
        }
        preds = preds.add(ty(p, &w.subject));
        let mut j = 0usize;
        for b in w.items.iter() {
            let sep = if j == 0 { ": " } else { " + " };
            preds = preds.text(sep).add(bound(p, b));
            j = j + 1;
        }
        i = i + 1;
    }
    // No comma before a declaration's `;`, as for `ensures`.
    let comma = if body || has_ensures { break_comma() } else { Doc::nil() };
    let clause = Doc::Line.text("where").add(nest(Doc::Line.add(preds).add(comma)));
    group(effects_.add(clause).add(posts_doc).add(end))
}

/// A comma at the end of a list of bounds or predicates that breaks.
fn break_comma() -> Doc { if_break(text(","), Doc::nil()) }

/// Function `f`, up to its body: with its doc comment and `#[allow(..)]`s,
/// if `lead`.
fn signature(p: &mut Printer, f: &FnDecl, lead: bool) -> Doc {
    let mut doc = match lead {
        true => p.lead(&f.doc, &f.allows, fn_start(f)),
        false => Doc::nil(),
    };
    // `#[intrinsic]`, `#[measure]`, `#[test]` and `#[blame_caller]`, in
    // the order written.
    let mut attrs: List<(Span, &str)> = List::new();
    if let Some(at) = f.intrinsic {
        attrs.push((at, "#[intrinsic]"));
    }
    if let Some(at) = f.measure {
        attrs.push((at, "#[measure]"));
    }
    if let Some(at) = f.blame_caller {
        attrs.push((at, "#[blame_caller]"));
    }
    if let Some(t) = f.test {
        attrs.push((t.span, if t.panics { "#[test(panics)]" } else { "#[test]" }));
    }
    sort(&mut attrs, 0, |a| a.0.start);
    let after = match vis_span(f.vis) {
        Some(v) => v.start,
        None => f.span.start,
    };
    let mut i = 0usize;
    for a in attrs.iter() {
        let (at, t) = *a;
        let next = match attrs.get(i + 1) {
            Some(n) => n.0.start,
            None => after,
        };
        doc = doc.text(t).add(p.trailing(at.end)).add(Doc::HardLine);
        doc = doc.add(p.element(next, true));
        i = i + 1;
    }
    let doc = doc.add(vis(f.vis));
    let generics = generics(p, f.name.span.end, &f.generics);
    let open = p.find(f.name.span.end, Tok::LParen);
    let last = match f.params.last() {
        Some(x) => Some(x.ty.span.end),
        None => None,
    };
    let close = p.close(open, last, Tok::RParen);
    let params = p.list(
        PARENS,
        close,
        &f.params,
        |x| (param_start(x), x.ty.span.end),
        None,
        |p, x| param(p, x),
    );
    let ret = match f.ret.kind {
        TypeExprKind::Unit => Doc::nil(),
        // A refinement stays on one line, so the parameters break
        // first, rather than its predicate.
        TypeExprKind::Refined(_, _, _) => {
            let t = ty(p, &f.ret);
            let t = match flat(&t) {
                Some(flat) => flat,
                None => t,
            };
            text(" -> ").add(t)
        },
        _ => text(" -> ").add(ty(p, &f.ret)),
    };
    // The return type goes in the parameters' group, so that they stay
    // on one line only if it fits after them too. Otherwise they break,
    // one to a line, and it breaks only if it doesn't fit after the `)`
    // either: not `-> Result<` with its arguments on lines of their own.
    let head = match params {
        Doc::Group(d, hard) => Doc::Group(alloc::boxed::Box::new((*d).add(ret)), hard),
        params => params.add(ret),
    };
    let ext = match f.ext {
        Some(_) => text("extern "),
        None => Doc::nil(),
    };
    doc.add(ext).text("fn ").text(f.name.name.as_str()).add(generics).add(head)
}

/// `with panic`, `with {alloc, e}`, or `{}` after `effect e =`. One
/// effect isn't in braces.
pub fn effects(p: &mut Printer, e: &EffectSet) -> Doc {
    let mut items = List::new();
    for x in e.items.iter() {
        items.push(one_effect(p, x));
    }
    let out = if e.with_ { text("with ") } else { Doc::nil() };
    if items.len() == 1 {
        return out.add(items.pop().expect("one"));
    }
    let mut out = out.text("{");
    let mut i = 0usize;
    for x in items {
        if i > 0 {
            out = out.text(", ");
        }
        out = out.add(x);
        i = i + 1;
    }
    out.text("}")
}

/// An effect: `panic`, `I::e`, `panic if n == 0`, `panic unless I: Bounded`.
fn one_effect(p: &mut Printer, e: &Effect) -> Doc {
    let atom = match &e.kind {
        EffectKind::Named(n) => text(n.name.as_str()),
        EffectKind::Proj(t, Some(tr), name) => {
            let t = ty(p, t);
            text("<").add(t).text(" as ").text(tr.name.as_str()).text(">::").text(name.name.as_str())
        },
        EffectKind::Proj(t, None, name) => ty(p, t).text("::").text(name.name.as_str()),
    };
    let atom = match &e.cond {
        Some(c) => atom.text(" if ").add(expr(p, c, 0, ANY)),
        None => atom,
    };
    match &e.unless {
        Some(g) => atom.text(" unless ").add(guard(p, g)),
        None => atom,
    }
}

/// `T: Trait`, after a `where` or an `unless`.
pub fn guard(p: &mut Printer, g: &Guard) -> Doc {
    let subject = ty(p, &g.subject);
    subject.text(": ").add(bound(p, &g.bound))
}

/// `a::{b, c as d}` in a `use`: a list that doesn't fit breaks as any
/// other does, one name to a line.
fn use_tree(p: &mut Printer, t: &UseTree) -> Doc {
    let mut names = List::new();
    for s in t.path.iter() {
        names.push(String::from(s.name.as_str()));
    }
    let path = join(&names, "::");
    match &t.kind {
        UseKind::Name(None) => Doc::Text(path),
        UseKind::Name(Some(alias)) => Doc::Text(String::of(&f"{path} as {alias.name}")),
        UseKind::Group(trees) => {
            let head = match path.is_empty() {
                true => Doc::nil(),
                false => Doc::Text(String::of(&f"{path}::")),
            };
            let close = match t.span.end {
                0 => 0,
                n => n - 1,
            };
            let list = p.list(
                USE,
                close,
                trees,
                |t| (t.span.start, t.span.end),
                None,
                |p, t| use_tree(p, t),
            );
            head.add(list)
        },
    }
}

/// `pub ` or `export `, as `v` is.
pub fn vis(v: Vis) -> Doc {
    match v {
        Vis::Private => Doc::nil(),
        Vis::Pub(_) => text("pub "),
        Vis::Export(_) => text("export "),
    }
}

/// Where the keyword of `v` is, if it has one.
fn vis_span(v: Vis) -> Option<Span> {
    match v {
        Vis::Private => None,
        Vis::Pub(at) => Some(at),
        Vis::Export(at) => Some(at),
    }
}

/// Where a function parameter starts: at its `mut`, if it has one.
fn param_start(x: &Param) -> usize {
    let name = match x.mutable {
        Some(m) => m,
        None => x.name.span,
    };
    min(name.start, x.ty.span.start)
}

/// Where something with the doc comment `doc` and attributes `allows`
/// starts, if it starts at `pos` without them.
pub fn lead_start(doc: &Option<DocComment>, allows: &List<Allow>, pos: usize) -> usize {
    let pos = match doc {
        Some(d) => match d.lines.first() {
            Some(l) => min(pos, l.span.start),
            None => pos,
        },
        None => pos,
    };
    match allows.first() {
        Some(a) => min(pos, a.span.start),
        None => pos,
    }
}

/// Where struct or enum `d` starts, if it starts at `pos` without its doc
/// comment and attributes.
pub fn type_lead_start(d: &TypeDecl, pos: usize) -> usize {
    let (doc, allows, derive, intrinsic) = match d {
        TypeDecl::Struct(s) => (&s.doc, &s.allows, s.derives.first(), s.intrinsic),
        TypeDecl::Enum(e) => (&e.doc, &e.allows, e.derives.first(), None),
        TypeDecl::Alias(a) => (&a.doc, &a.allows, None, None),
    };
    let derive = match derive {
        Some(d) => d.span.start,
        None => pos,
    };
    let intrinsic = match intrinsic {
        Some(at) => at.start,
        None => pos,
    };
    min(min(lead_start(doc, allows, pos), derive), intrinsic)
}

/// Where function `f` starts without its doc comment and attributes: at its
/// `pub`, if it has one.
fn fn_start(f: &FnDecl) -> usize {
    let start = match vis_span(f.vis) {
        Some(v) => v.start,
        None => f.span.start,
    };
    let start = match f.intrinsic {
        Some(at) => min(at.start, start),
        None => start,
    };
    let start = match f.measure {
        Some(at) => min(at.start, start),
        None => start,
    };
    let start = match f.blame_caller {
        Some(at) => min(at.start, start),
        None => start,
    };
    match f.test {
        Some(t) => min(t.span.start, start),
        None => start,
    }
}

/// The name of a struct, enum or type alias.
pub fn decl_name(d: &TypeDecl) -> &Ident {
    match d {
        TypeDecl::Struct(s) => &s.name,
        TypeDecl::Enum(e) => &e.name,
        TypeDecl::Alias(a) => &a.name,
    }
}

/// Who sees a struct, enum or type alias.
fn decl_vis(d: &TypeDecl) -> Vis {
    match d {
        TypeDecl::Struct(s) => s.vis,
        TypeDecl::Enum(e) => e.vis,
        TypeDecl::Alias(a) => a.vis,
    }
}

/// The module a struct, enum or type alias is in.
fn decl_module(d: &TypeDecl) -> usize {
    match d {
        TypeDecl::Struct(s) => s.module,
        TypeDecl::Enum(e) => e.module,
        TypeDecl::Alias(a) => a.module,
    }
}
