//! Types, and what's said of them: trait bounds, effects, and the
//! `T: Trait` of a `where` or `unless`.

use alloc::boxed::Box;
use alloc::list::List;
use alloc::string::String;

use crate::ast::{
    AssocBound,
    AssocBoundKind,
    BoundItem,
    Effect,
    EffectKind,
    EffectSet,
    Expr,
    ExprKind,
    FnSig,
    Guard,
    Ident,
    TypeExpr,
    TypeExprKind,
};
use crate::error::{Error, Span};
use crate::lexer::Tok;
use crate::parser::{copied, is_ident, is_word, Parser};
use crate::text;
use crate::parser::exprs;

/// Where effects are said, which decides what each may say besides
/// itself.
#[derive(Copy, Discard, Eq)]
pub enum Said {
    /// A function's own signature: a condition, `if P`, or an `unless`.
    Fn,
    /// An impl's associated effect, `effect e = ..;`: an `unless`.
    Binding,
    /// A type's, or a bound's: neither.
    Other,
}

/// A type, with the projections after it: `T::Item::Other`.
pub fn ty(p: &mut Parser) -> Result<TypeExpr, Error> {
    let mut t = ty_head(p)?;
    // `T::Item`, `T::Item::Other`: projections without the trait.
    loop {
        let path = match &t.kind {
            TypeExprKind::Named(_, _) | TypeExprKind::Proj(_, _, _) => true,
            _ => false,
        };
        if p.peek() != Tok::ColonColon || !path {
            return Ok(t);
        }
        p.bump();
        let name = p.ident()?;
        let span = t.span.to(name.span);
        t = TypeExpr { kind: TypeExprKind::Proj(Box::new(t), None, name), span };
    }
}

/// A type, but for any projections without a trait after it.
fn ty_head(p: &mut Parser) -> Result<TypeExpr, Error> {
    let start = p.span();
    match p.peek() {
        // `<T as Iter>::Item`
        Tok::Lt => {
            p.bump();
            let inner = ty(p)?;
            p.expect(Tok::As)?;
            let tr = p.path()?;
            p.expect(Tok::Gt)?;
            p.expect(Tok::ColonColon)?;
            let name = p.ident()?;
            let span = start.to(name.span);
            Ok(TypeExpr { kind: TypeExprKind::Proj(Box::new(inner), Some(tr), name), span })
        },
        Tok::Ident(_) | Tok::Crate | Tok::Super => named(p, start),
        Tok::LParen => {
            p.bump();
            let mut ts = List::new();
            let mut comma = None;
            while p.peek() != Tok::RParen {
                ts.push(ty(p)?);
                if p.peek() != Tok::Comma {
                    break;
                }
                let at = p.bump().span;
                if comma.is_none() {
                    comma = Some(at);
                }
            }
            let end = p.close_parens(ts.len(), comma)?;
            let span = start.to(end);
            if ts.len() >= 2 {
                return Ok(TypeExpr { kind: TypeExprKind::Tuple(ts), span });
            }
            match ts.pop() {
                None => Ok(TypeExpr { kind: TypeExprKind::Unit, span }),
                Some(inner) => Ok(TypeExpr { kind: inner.kind, span }),
            }
        },
        Tok::Fn => {
            p.bump();
            p.expect(Tok::LParen)?;
            let (params, close) = p.comma_list(Tok::RParen, ty)?;
            let ret = match p.eat(Tok::Arrow) {
                true => ty(p)?,
                false => TypeExpr { kind: TypeExprKind::Unit, span: close },
            };
            let effects = with_effects(p, Said::Other)?;
            let end = match &effects {
                Some(e) => e.span,
                None => ret.span,
            };
            Ok(TypeExpr {
                kind: TypeExprKind::Fn(params, Box::new(ret), effects),
                span: start.to(end),
            })
        },
        Tok::Amp => {
            p.bump();
            ref_type(p, start)
        },
        // `&&T` is `&(&T)`.
        Tok::AndAnd => {
            p.bump();
            let inner = ref_type(p, Span::new(start.start + 1, start.end))?;
            let span = start.to(inner.span);
            Ok(TypeExpr { kind: TypeExprKind::Ref(None, false, Box::new(inner)), span })
        },
        // `[T]`, a slice, or `[T; N]`, an array.
        Tok::LBracket => {
            p.bump();
            let inner = ty(p)?;
            let kind = match p.eat(Tok::Semi) {
                true => TypeExprKind::Array(Box::new(inner), Box::new(ty(p)?)),
                false => TypeExprKind::Slice(Box::new(inner)),
            };
            let end = p.expect(Tok::RBracket)?;
            Ok(TypeExpr { kind, span: start.to(end) })
        },
        // `3`, a length.
        Tok::Int(n, None) => Ok(TypeExpr { kind: TypeExprKind::Nat(n), span: p.bump().span }),
        // `{ v: i64 | v > 0 }`
        Tok::LBrace => {
            p.bump();
            let binder = p.ident()?;
            p.expect(Tok::Colon)?;
            let base = ty(p)?;
            p.expect(Tok::Pipe)?;
            let pred = p.structs(true, exprs::expr)?;
            // `where I: Trait`, of a struct's field: said only where that
            // holds.
            let pred = match p.eat(Tok::Where) {
                true => {
                    let guard = guard(p)?;
                    let span = pred.span.to(guard.span);
                    Expr { kind: ExprKind::Where(Box::new(pred), Box::new(guard)), span }
                },
                false => pred,
            };
            let end = p.expect(Tok::RBrace)?;
            let kind = TypeExprKind::Refined(binder, Box::new(base), Box::new(pred));
            Ok(TypeExpr { kind, span: start.to(end) })
        },
        Tok::Bang => Ok(TypeExpr { kind: TypeExprKind::Never, span: p.bump().span }),
        Tok::Impl => {
            p.bump();
            let mut bounds = List::new();
            loop {
                match p.peek() {
                    Tok::Ident(_) | Tok::Crate | Tok::Super => bounds.push(trait_bound(p)?),
                    _ => return Err(p.unexpected("a trait after `impl`")),
                }
                if !p.eat(Tok::Plus) {
                    break;
                }
            }
            let span = start.to(bounds.last().expect("a bound at least").span);
            Ok(TypeExpr { kind: TypeExprKind::Impl(bounds), span })
        },
        _ => Err(p.unexpected("a type")),
    }
}

/// A type that starts with a name, at `start`: `i64`, `a::B<T>`, or
/// `T::Item`, a projection.
fn named(p: &mut Parser, start: Span) -> Result<TypeExpr, Error> {
    let mut segs = List::new();
    segs.push(p.segment()?);
    while p.peek() == Tok::ColonColon && is_ident(p.peek2()) {
        p.bump();
        segs.push(p.ident()?);
    }
    // There's no `<` operator in a type, so this can only start type
    // arguments.
    let (args, span) = match p.eat(Tok::Lt) {
        true => {
            let (args, end) = p.comma_list(Tok::Gt, type_arg)?;
            (args, start.to(end))
        },
        false => (List::new(), start.to(segs.last().expect("a name at least").span)),
    };
    // `T::Item` is a projection, unless `T` turns out to be a module, which
    // only resolving names can tell. With type arguments at the end, or
    // starting at `crate`, `super` or `self`, it can only be a path to a
    // type.
    let first = text::item(&segs, 0);
    let path = match first.name.as_str() {
        "crate" | "super" | "self" => true,
        _ => !args.is_empty(),
    };
    if segs.len() == 1 || path {
        let mut name = String::from(first.name.as_str());
        for s in segs.iter().skip(1) {
            name.push_str("::");
            name.push_str(s.name.as_str());
        }
        return Ok(TypeExpr { kind: TypeExprKind::Named(name, args), span });
    }
    let mut t = TypeExpr {
        kind: TypeExprKind::Named(String::from(first.name.as_str()), List::new()),
        span: first.span,
    };
    for name in segs.iter().skip(1) {
        let span = t.span.to(name.span);
        t = TypeExpr { kind: TypeExprKind::Proj(Box::new(t), None, copied(name)), span };
    }
    Ok(t)
}

/// `&'a mut T`, after the `&`, which is at `start`.
fn ref_type(p: &mut Parser, start: Span) -> Result<TypeExpr, Error> {
    let lifetime = match p.peek() {
        Tok::Lifetime(_) => Some(p.lifetime()?),
        _ => None,
    };
    let mutable = p.eat(Tok::Mut);
    let inner = ty(p)?;
    let span = start.to(inner.span);
    Ok(TypeExpr { kind: TypeExprKind::Ref(lifetime, mutable, Box::new(inner)), span })
}

/// A type argument: a type, or a lifetime.
pub fn type_arg(p: &mut Parser) -> Result<TypeExpr, Error> {
    match p.peek() {
        Tok::Lifetime(name) => {
            Ok(TypeExpr { kind: TypeExprKind::Lifetime(String::from(name)), span: p.bump().span })
        },
        _ => ty(p),
    }
}

/// A lifetime, or a trait with nothing said of its associated types, as a
/// bound.
pub fn plain(name: Ident) -> BoundItem {
    BoundItem { span: name.span, name, assoc: List::new(), sig: None, effects: None }
}

/// `Show`, `Iter<Item = i64, Other: Discard>` or `Fn(i64) -> i64 with e`,
/// after a `:` in generics.
pub fn trait_bound(p: &mut Parser) -> Result<BoundItem, Error> {
    let name = p.path()?;
    if p.peek() == Tok::LParen {
        p.bump();
        let (params, close) = p.comma_list(Tok::RParen, ty)?;
        let mut end = close;
        let ret = match p.eat(Tok::Arrow) {
            true => {
                let t = ty(p)?;
                end = t.span;
                Some(Box::new(t))
            },
            false => None,
        };
        let effects = with_effects(p, Said::Other)?;
        if let Some(e) = &effects {
            end = e.span;
        }
        let span = name.span.to(end);
        return Ok(BoundItem {
            span,
            name,
            assoc: List::new(),
            sig: Some(FnSig { params, ret }),
            effects,
        });
    }
    if p.peek() != Tok::Lt {
        return Ok(plain(name));
    }
    p.bump();
    let (assoc, end) = p.comma_list(Tok::Gt, assoc_bound)?;
    Ok(BoundItem { span: name.span.to(end), name, assoc, sig: None, effects: None })
}

/// `Item = i64`, `Item: Discard + Eq` or `e = {panic}`, in a bound's `<..>`.
fn assoc_bound(p: &mut Parser) -> Result<AssocBound, Error> {
    let name = p.ident()?;
    let kind = match p.peek() {
        Tok::Eq => {
            p.bump();
            // `{alloc}`, `{}`: an associated effect's; `{ t: u8 | .. }` is a
            // refined type.
            let refined = is_ident(p.peek2()) && p.peek3() == Tok::Colon;
            match p.peek() == Tok::LBrace && !refined {
                true => AssocBoundKind::Effects(effect_set(p, None, Said::Other)?),
                false => AssocBoundKind::Eq(ty(p)?),
            }
        },
        Tok::Colon => {
            p.bump();
            let mut traits = List::new();
            traits.push(p.path()?);
            while p.eat(Tok::Plus) {
                traits.push(p.path()?);
            }
            AssocBoundKind::Bounds(traits)
        },
        _ => {
            return Err(Error::syntax(
                name.span,
                "a trait has no type parameters; this can only say what one of its associated \
                 types is, as in `Iter<Item = i64>`, or what it implements, as in \
                 `Iter<Item: Discard>`",
            ));
        },
    };
    Ok(AssocBound { name, kind })
}

/// `T: Trait`, after a `where` in an invariant or a field's refinement,
/// or an `unless` in an effect: one bound, on one type.
pub fn guard(p: &mut Parser) -> Result<Guard, Error> {
    let subject = ty(p)?;
    p.expect(Tok::Colon)?;
    let bound = trait_bound(p)?;
    Ok(Guard { span: subject.span.to(bound.span), subject, bound })
}

/// `with panic` or `with {alloc, e}`, if a `with` is next, said where
/// `said` says.
pub fn with_effects(p: &mut Parser, said: Said) -> Result<Option<EffectSet>, Error> {
    match p.peek() == Tok::With {
        true => {
            let with_at = p.bump().span;
            Ok(Some(effect_set(p, Some(with_at), said)?))
        },
        false => Ok(None),
    }
}

/// One effect, or a set of them in braces, after the `with` at `with_at`
/// if there is one, each with a condition or an `unless` if `said`
/// allows.
pub fn effect_set(p: &mut Parser, with_at: Option<Span>, said: Said) -> Result<EffectSet, Error> {
    let start = match with_at {
        Some(at) => at,
        None => p.span(),
    };
    if p.eat(Tok::LBrace) {
        let (items, end) = p.comma_list(Tok::RBrace, |p| one_effect(p, said))?;
        return Ok(EffectSet { items, span: start.to(end), with_: with_at.is_some() });
    }
    let item = one_effect(p, said)?;
    let span = start.to(item.span);
    let mut items = List::new();
    items.push(item);
    Ok(EffectSet { items, span, with_: with_at.is_some() })
}

/// `panic`, `alloc`, `unsafe`, an effect parameter `e`, or an associated
/// effect `I::e` or `<I as Iterator>::e`, with a condition or an `unless`
/// if `said` allows one.
fn one_effect(p: &mut Parser, said: Said) -> Result<Effect, Error> {
    if p.peek() == Tok::Unsafe {
        let span = p.bump().span;
        let name = Ident { name: String::from("unsafe"), span };
        let e = Effect { kind: EffectKind::Named(name), span, unless: None, cond: None };
        return effect_cond(p, e, said);
    }
    let t = ty(p)?;
    let span = t.span;
    let kind = match t.kind {
        TypeExprKind::Named(name, args) => match args.is_empty() && !name.as_str().contains("::") {
            true => Some(EffectKind::Named(Ident { name, span })),
            false => None,
        },
        TypeExprKind::Proj(base, tr, name) => Some(EffectKind::Proj(base, tr, name)),
        _ => None,
    };
    let Some(kind) = kind else {
        return Err(Error::syntax(
            span,
            "expected an effect: `panic`, `alloc`, `unsafe`, an effect parameter like `e`, or an \
             associated effect like `I::e`",
        ));
    };
    effect_cond(p, Effect { kind, span, unless: None, cond: None }, said)
}

/// Effect `e`'s condition, `if x > 3`, if one is next: an expression, with
/// no struct literal, as a function's body may follow it. Only a
/// function's own effects can have one: a type's are of whatever has it,
/// whose parameters aren't named, and an impl's associated effect is of
/// no call. Or its `unless T: Trait`, which an impl's associated effect
/// can say too, of the impl's type parameters.
fn effect_cond(p: &mut Parser, e: Effect, said: Said) -> Result<Effect, Error> {
    let mut e = e;
    if p.peek() == Tok::If && said != Said::Fn {
        let message = match said {
            Said::Binding => {
                "an associated effect can't have a condition: it's of no call, whose parameters \
                 it could say; it can say `unless` a bound holds"
            },
            _ => "only a function's own effects can have a condition, not a type's or a bound's",
        };
        return Err(Error::syntax(p.span(), message));
    }
    if p.eat(Tok::If) {
        let cond = p.structs(false, exprs::expr)?;
        e.span = e.span.to(cond.span);
        e.cond = Some(Box::new(cond));
    }
    // `unless T: Trait`: `unless` is a word only here, after an effect.
    if is_word(p.peek(), "unless") {
        if said == Said::Other {
            return Err(Error::syntax(
                p.span(),
                "only a function's own effects, or an impl's associated effect, can say \
                 `unless`, not a type's or a bound's",
            ));
        }
        p.bump();
        let guard = guard(p)?;
        e.span = e.span.to(guard.span);
        e.unless = Some(Box::new(guard));
    }
    Ok(e)
}
