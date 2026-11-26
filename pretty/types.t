//! Printing types and patterns, and a derive's `where` clause as t-lang
//! shows one, on one line.

use alloc::list::List;
use alloc::string::String;
use core::cmp::min;

use crate::ast::{
    AssocBoundKind,
    BoundItem,
    Effect,
    EffectKind,
    EffectSet,
    Lit,
    Num,
    Pattern,
    PatternKind,
    TypeExpr,
    TypeExprKind,
    Where,
};
use crate::lexer::{byte_literal, char_literal, Tok};
use crate::pretty::doc::{group, text, Doc};
use crate::pretty::exprs::{expr, expr_text};
use crate::pretty::items::{bound, effects};
use crate::pretty::{join, Delims, Printer, ANGLES, ANY, BRACES, BRACKETS, PARENS};

/// `::<i64, bool>` after a name, or nothing if there are no type
/// arguments.
pub fn turbofish(p: &mut Printer, targs: &List<TypeExpr>) -> Doc {
    match targs.last() {
        None => Doc::nil(),
        Some(last) => {
            let close = p.find(last.span.end, Tok::Gt);
            text("::").add(types(p, ANGLES, close, targs))
        },
    }
}

/// Types `ts` as a list in `delims`, whose closing one is at `close`.
pub fn types(p: &mut Printer, delims: Delims, close: usize, ts: &List<TypeExpr>) -> Doc {
    p.list(delims, close, ts, |t| (t.span.start, t.span.end), None, |p, t| ty(p, t))
}

/// Type `t`: `Option<i64>`, `&'a mut [u8]`, `{ n: u64 | n > 0 }`.
pub fn ty(p: &mut Printer, t: &TypeExpr) -> Doc {
    match &t.kind {
        TypeExprKind::Refined(v, base, pred) => {
            let head = text("{ ").text(v.name.as_str()).text(": ").add(ty(p, base));
            group(head.text(" | ").add(expr(p, pred, 0, ANY)).text(" }"))
        },
        TypeExprKind::Named(name, args) => match args.last() {
            None => text(name.as_str()),
            Some(last) => {
                let close = p.find(last.span.end, Tok::Gt);
                text(name.as_str()).add(types(p, ANGLES, close, args))
            },
        },
        TypeExprKind::Unit => text("()"),
        TypeExprKind::Tuple(ts) => types(p, PARENS, t.span.end - 1, ts),
        TypeExprKind::Never => text("!"),
        TypeExprKind::Lifetime(name) => text(name.as_str()),
        TypeExprKind::Ref(lifetime, mutable, inner) => {
            let mut head = String::from("&");
            if let Some(l) = lifetime {
                head.push_str(l.name.as_str());
                head.push(' ');
            }
            if *mutable {
                head.push_str("mut ");
            }
            Doc::Text(head).add(ty(p, inner))
        },
        TypeExprKind::Slice(inner) => text("[").add(ty(p, inner)).text("]"),
        TypeExprKind::Array(inner, n) => {
            let inner = text("[").add(ty(p, inner)).text("; ");
            inner.add(ty(p, n)).text("]")
        },
        TypeExprKind::Nat(n) => p.spelled(t.span, String::of(n)),
        TypeExprKind::Proj(inner, Some(tr), name) => {
            let inner = text("<").add(ty(p, inner));
            inner.text(" as ").text(tr.name.as_str()).text(">::").text(name.name.as_str())
        },
        TypeExprKind::Proj(inner, None, name) => ty(p, inner).text("::").text(name.name.as_str()),
        TypeExprKind::Impl(bounds) => {
            let mut out = text("impl ");
            let mut i = 0usize;
            for b in bounds.iter() {
                if i > 0 {
                    out = out.text(" + ");
                }
                out = out.add(bound(p, b));
                i = i + 1;
            }
            out
        },
        TypeExprKind::Fn(params, ret, effects_) => {
            let open = p.find(t.span.start, Tok::LParen);
            let last = match params.last() {
                Some(x) => Some(x.span.end),
                None => None,
            };
            let close = p.close(open, last, Tok::RParen);
            let params = types(p, PARENS, close, params);
            let out = match ret.kind {
                TypeExprKind::Unit => text("fn").add(params),
                _ => text("fn").add(params).text(" -> ").add(ty(p, ret)),
            };
            match effects_ {
                Some(e) => out.text(" ").add(effects(p, e)),
                None => out,
            }
        },
    }
}

/// Pattern `pat`: `Some(x)`, `Point { x, .. }`, `1..=9`.
pub fn pattern(p: &mut Printer, pat: &Pattern) -> Doc {
    match &pat.kind {
        PatternKind::Wild => text("_"),
        PatternKind::Rest => text(".."),
        PatternKind::Bind(name, false) => text(name.as_str()),
        PatternKind::Bind(name, true) => Doc::Text(String::of(&f"mut {name}")),
        PatternKind::Int(n, lit) => p.spelled(pat.span, show(*lit, *n)),
        PatternKind::Range(lo, hi, inclusive, lit) => {
            p.spelled(pat.span, range(*lo, *hi, *inclusive, *lit))
        },
        PatternKind::Bool(b) => text(if *b { "true" } else { "false" }),
        PatternKind::Str => p.written(pat.span),
        PatternKind::Unit => text("()"),
        PatternKind::Path(name, args, _) => {
            if args.is_empty() {
                return text(name.name.as_str());
            }
            let close = pat.span.end - 1;
            text(name.name.as_str()).add(patterns(p, PARENS, close, args))
        },
        PatternKind::Variant(t, targs, variant, args) => {
            let head = text(t.name.as_str()).add(turbofish(p, targs));
            let head = head.text("::").text(variant.name.as_str());
            if args.is_empty() {
                return head;
            }
            let close = pat.span.end - 1;
            head.add(patterns(p, PARENS, close, args))
        },
        PatternKind::Struct(t, targs, fields, rest) => {
            let close = pat.span.end - 1;
            let rest = match rest {
                true => {
                    let from = match fields.last() {
                        Some(f) => f.pat.span.end,
                        None => t.span.end,
                    };
                    Some((p.find(from, Tok::DotDot), ".."))
                },
                false => None,
            };
            let fields = p.list(
                BRACES,
                close,
                fields,
                |f| (min(f.name.span.start, f.pat.span.start), f.pat.span.end),
                rest,
                |p, f| {
                    let short = match &f.pat.kind {
                        PatternKind::Bind(b, false) => match *b == f.name.name {
                            true => Some(text(b.as_str())),
                            false => None,
                        },
                        PatternKind::Bind(b, true) => match *b == f.name.name {
                            true => Some(Doc::Text(String::of(&f"mut {b}"))),
                            false => None,
                        },
                        _ => None,
                    };
                    match short {
                        Some(d) => d,
                        None => text(f.name.name.as_str()).text(": ").add(pattern(p, &f.pat)),
                    }
                },
            );
            text(t.name.as_str()).add(turbofish(p, targs)).text(" ").add(fields)
        },
        PatternKind::Array(pats) => patterns(p, BRACKETS, pat.span.end - 1, pats),
        PatternKind::Tuple(pats) => patterns(p, PARENS, pat.span.end - 1, pats),
        // Not indented when it breaks, so that in a `match` the body
        // stands out from the alternatives.
        PatternKind::Or(alts) => {
            let mut doc = Doc::nil();
            let mut i = 0usize;
            for alt in alts.iter() {
                doc = match i == 0 {
                    true => pattern(p, alt),
                    false => doc.add(Doc::Line).text("| ").add(pattern(p, alt)),
                };
                i = i + 1;
            }
            group(doc)
        },
    }
}

/// Patterns `pats` as a list in `delims`, whose closing one is at `close`.
fn patterns(p: &mut Printer, delims: Delims, close: usize, pats: &List<Pattern>) -> Doc {
    p.list(delims, close, pats, |a| (a.span.start, a.span.end), None, |p, a| pattern(p, a))
}

/// Value `n` as a literal of kind `lit`: `97`, `b'a'`, `'a'`.
fn show(lit: Lit, n: Num) -> String {
    let value = match n.neg {
        true => None,
        false => Some(n.abs),
    };
    let value = match (n.neg, n.abs) {
        (true, 0) => Some(0u64),
        _ => value,
    };
    match (lit, value) {
        (Lit::Byte, Some(v)) => {
            if v <= 255 {
                return byte_literal(v as u8);
            }
        },
        (Lit::Char, Some(v)) => {
            if v <= 0xFFFF_FFFF {
                if let Some(c) = char::from_u32(v as u32) {
                    return char_literal(c);
                }
            }
        },
        _ => {},
    }
    match value {
        Some(v) => String::of(&v),
        None => String::of(&f"-{n.abs}"),
    }
}

/// A range pattern as written: `1..=9`, `1..10`, `10..`.
fn range(lo: Option<Num>, hi: Option<Num>, inclusive: bool, lit: Lit) -> String {
    let lo = match lo {
        Some(lo) => show(lit, lo),
        None => String::new(),
    };
    match (hi, inclusive) {
        (None, _) => String::of(&f"{lo}.."),
        (Some(hi), true) => {
            let hi = show(lit, hi);
            String::of(&f"{lo}..={hi}")
        },
        (Some(hi), false) => {
            let hi = show(lit, hi);
            String::of(&f"{lo}..{hi}")
        },
    }
}

/// `where T: Discard, U: Eq` after a derived trait, as t-lang shows its
/// bounds, each on one line.
pub fn where_clause(p: &mut Printer, w: &Where) -> String {
    let mut bounds = List::new();
    for b in w.bounds.iter() {
        let mut items = List::new();
        for i in b.items.iter() {
            items.push(show_bound(p, i));
        }
        let items = join(&items, " + ");
        bounds.push(String::of(&f"{b.subject.name}: {items}"));
    }
    let bounds = join(&bounds, ", ");
    String::of(&f"where {bounds}")
}

/// Bound `b` as t-lang shows one: `Show`, `Iter<Item = i64>`,
/// `Fn(i64) -> i64`.
fn show_bound(p: &mut Printer, b: &BoundItem) -> String {
    let mut out = String::from(b.name.name.as_str());
    if let Some(sig) = &b.sig {
        out.push('(');
        out.push_str(show_types(p, &sig.params).as_str());
        out.push(')');
        if let Some(ret) = &sig.ret {
            out.push_str(" -> ");
            out.push_str(show_ty(p, ret).as_str());
        }
    }
    if let Some(e) = &b.effects {
        out.push(' ');
        out.push_str(show_effects(p, e).as_str());
    }
    if !b.assoc.is_empty() {
        let mut assoc = List::new();
        for a in b.assoc.iter() {
            let name = a.name.name.as_str();
            let shown = match &a.kind {
                AssocBoundKind::Eq(t) => {
                    let t = show_ty(p, t);
                    String::of(&f"{name} = {t}")
                },
                AssocBoundKind::Effects(e) => {
                    let e = show_effect_list(p, e);
                    String::of(&f"{name} = {{{e}}}")
                },
                AssocBoundKind::Bounds(ts) => {
                    let mut names = List::new();
                    for t in ts.iter() {
                        names.push(String::from(t.name.as_str()));
                    }
                    let ts = join(&names, " + ");
                    String::of(&f"{name}: {ts}")
                },
            };
            assoc.push(shown);
        }
        let assoc = join(&assoc, ", ");
        out.push_str(String::of(&f"<{assoc}>").as_str());
    }
    out
}

/// Types `ts`, with commas between them.
fn show_types(p: &mut Printer, ts: &List<TypeExpr>) -> String {
    let mut shown = List::new();
    for t in ts.iter() {
        shown.push(show_ty(p, t));
    }
    join(&shown, ", ")
}

/// Type `t` as t-lang shows one: `Option<i64>`, `fn(i64) -> bool`, `()`.
fn show_ty(p: &mut Printer, t: &TypeExpr) -> String {
    match &t.kind {
        TypeExprKind::Named(name, args) => match args.is_empty() {
            true => String::from(name.as_str()),
            false => {
                let args = show_types(p, args);
                String::of(&f"{name}<{args}>")
            },
        },
        TypeExprKind::Unit => String::from("()"),
        TypeExprKind::Fn(params, ret, effects_) => {
            let params = show_types(p, params);
            let ret = show_ty(p, ret);
            let mut out = String::of(&f"fn({params}) -> {ret}");
            if let Some(e) = effects_ {
                out.push(' ');
                out.push_str(show_effects(p, e).as_str());
            }
            out
        },
        TypeExprKind::Ref(lifetime, mutable, inner) => {
            let mut out = String::from("&");
            if let Some(l) = lifetime {
                out.push_str(l.name.as_str());
                out.push(' ');
            }
            if *mutable {
                out.push_str("mut ");
            }
            out.push_str(show_ty(p, inner).as_str());
            out
        },
        TypeExprKind::Slice(inner) => {
            let inner = show_ty(p, inner);
            String::of(&f"[{inner}]")
        },
        TypeExprKind::Tuple(ts) => {
            let ts = show_types(p, ts);
            String::of(&f"({ts})")
        },
        TypeExprKind::Array(inner, n) => {
            let inner = show_ty(p, inner);
            let n = show_ty(p, n);
            String::of(&f"[{inner}; {n}]")
        },
        TypeExprKind::Nat(n) => String::of(n),
        TypeExprKind::Lifetime(name) => String::from(name.as_str()),
        TypeExprKind::Never => String::from("!"),
        TypeExprKind::Proj(inner, Some(tr), name) => {
            let inner = show_ty(p, inner);
            String::of(&f"<{inner} as {tr.name}>::{name.name}")
        },
        TypeExprKind::Proj(inner, None, name) => {
            let inner = show_ty(p, inner);
            String::of(&f"{inner}::{name.name}")
        },
        TypeExprKind::Impl(bounds) => {
            let mut shown = List::new();
            for b in bounds.iter() {
                shown.push(show_bound(p, b));
            }
            let bounds = join(&shown, " + ");
            String::of(&f"impl {bounds}")
        },
        TypeExprKind::Refined(v, base, pred) => {
            let base = show_ty(p, base);
            let pred = expr_text(p, pred);
            String::of(&f"{{ {v.name}: {base} | {pred} }}")
        },
    }
}

/// An effect set as t-lang shows one: `with panic`, `with {alloc, e}`:
/// in braces unless it's one effect.
fn show_effects(p: &mut Printer, e: &EffectSet) -> String {
    let mut out = String::new();
    if e.with_ {
        out.push_str("with ");
    }
    let items = show_effect_list(p, e);
    match e.items.len() == 1 {
        true => out.push_str(items.as_str()),
        false => out.push_str(String::of(&f"{{{items}}}").as_str()),
    }
    out
}

/// The effects of `e`, with commas between them.
fn show_effect_list(p: &mut Printer, e: &EffectSet) -> String {
    let mut items = List::new();
    for x in e.items.iter() {
        items.push(show_effect(p, x));
    }
    join(&items, ", ")
}

/// An effect as t-lang shows one: `panic`, `I::e`, `panic if n == 0`,
/// without what it's `unless`.
fn show_effect(p: &mut Printer, e: &Effect) -> String {
    let mut out = match &e.kind {
        EffectKind::Named(n) => String::from(n.name.as_str()),
        EffectKind::Proj(t, Some(tr), name) => {
            let t = show_ty(p, t);
            String::of(&f"<{t} as {tr.name}>::{name.name}")
        },
        EffectKind::Proj(t, None, name) => {
            let t = show_ty(p, t);
            String::of(&f"{t}::{name.name}")
        },
    };
    if let Some(c) = &e.cond {
        out.push_str(" if ");
        out.push_str(expr_text(p, c).as_str());
    }
    out
}
