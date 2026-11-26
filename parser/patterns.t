//! Patterns: what a `let`, a `match` arm, an `if let` or a closure's
//! parameter matches.
//!
//! In a pattern, a name that starts with an uppercase letter is a path, a
//! variant or a const, never a new variable: `None`, `Dot(p)`, `MAX`.

use alloc::list::List;
use alloc::string::String;

use crate::ast::{FieldPat, Ident, Lit, Num, Pattern, PatternKind, TypeExpr};
use crate::error::{Error, Span};
use crate::lexer::Tok;
use crate::parser::{joined, no_targs, starts_upper, Parser, Segment};
use crate::text;

/// A pattern, which can't be `..`: that's only one of a tuple's, a
/// variant's or an array's (`element`).
pub fn pattern(p: &mut Parser) -> Result<Pattern, Error> {
    let pat = alternatives(p)?;
    if let PatternKind::Rest = pat.kind {
        return Err(Error::syntax(
            pat.span,
            "`..` stands for the values of a tuple, a variant or an array that the patterns beside it don't name, so it can only be one of those: `(a, ..)`",
        ));
    }
    Ok(pat)
}

/// One of the patterns of a tuple's, a variant's or an array's values: a
/// pattern, or `..`, for the values the others don't name.
fn element(p: &mut Parser) -> Result<Pattern, Error> { alternatives(p) }

/// The patterns of a tuple's, a variant's or an array's values, with at
/// most one `..`: with two, which values each stands for isn't said.
fn one_rest(pats: &List<Pattern>) -> Result<(), Error> {
    let mut seen = false;
    for q in pats {
        if let PatternKind::Rest = q.kind {
            if seen {
                return Err(Error::syntax(
                    q.span,
                    "only one `..` can be among a pattern's values: with two, which values each stands for isn't said",
                ));
            }
            seen = true;
        }
    }
    Ok(())
}

/// A pattern, or alternatives of them: `A | B`.
fn alternatives(p: &mut Parser) -> Result<Pattern, Error> {
    let first = pat_atom(p)?;
    if p.peek() == Tok::OrOr {
        return Err(Error::syntax(p.span(), "use `|` between pattern alternatives, not `||`"));
    }
    if p.peek() != Tok::Pipe {
        return Ok(first);
    }
    let start = first.span;
    let mut alts = List::new();
    alts.push(first);
    let mut end = start;
    while p.eat(Tok::Pipe) {
        let alt = pat_atom(p)?;
        end = alt.span;
        alts.push(alt);
    }
    for a in &alts {
        if let PatternKind::Rest = a.kind {
            return Err(Error::syntax(
                a.span,
                "`..` can't be an alternative: it stands for values, not one of them",
            ));
        }
    }
    Ok(Pattern { kind: PatternKind::Or(alts), span: start.to(end) })
}

/// A pattern with no `|` at its top.
pub fn pat_atom(p: &mut Parser) -> Result<Pattern, Error> {
    let start = p.span();
    let kind = match p.peek() {
        Tok::Str => PatternKind::Str,
        Tok::ByteStr => {
            return Err(Error::syntax(
                start,
                "a byte string literal can't be a pattern yet; compare with `==`",
            ));
        },
        Tok::Int(..) | Tok::Minus | Tok::Byte(_) | Tok::Char(_) => return literal(p),
        Tok::DotDot | Tok::DotDotEq => {
            // `..` alone: the values of a tuple, variant or array the
            // patterns beside it don't name.
            if p.peek() == Tok::DotDot && !starts_pat_int(p.peek2()) {
                p.bump();
                return Ok(Pattern { kind: PatternKind::Rest, span: start });
            }
            let inclusive = p.bump().tok == Tok::DotDotEq;
            let hi = pat_int(p)?;
            let kind = PatternKind::Range(None, Some(hi.num), inclusive, hi.lit);
            return Ok(Pattern { kind, span: start.to(hi.span) });
        },
        Tok::True => PatternKind::Bool(true),
        Tok::False => PatternKind::Bool(false),
        Tok::Mut => {
            p.bump();
            let name = p.variable()?;
            if name.name.as_str() == "_" {
                return Err(Error::syntax(name.span, "`_` binds nothing, so it can't be `mut`"));
            }
            let span = start.to(name.span);
            return Ok(Pattern { kind: PatternKind::Bind(name.name, true), span });
        },
        Tok::LParen => return parens(p),
        Tok::LBracket => {
            p.bump();
            let (pats, end) = p.comma_list(Tok::RBracket, element)?;
            one_rest(&pats)?;
            return Ok(Pattern { kind: PatternKind::Array(pats), span: start.to(end) });
        },
        Tok::Crate | Tok::Super => return path_pattern(p),
        Tok::Ident(name) => match p.peek2() {
            Tok::ColonColon => return path_pattern(p),
            Tok::LBrace => {
                let ty = p.ident()?;
                return struct_pattern(p, ty, List::new());
            },
            _ => {
                if name == "_" {
                    PatternKind::Wild
                } else if starts_upper(name) {
                    return upper_name(p);
                } else {
                    let name = p.binder()?;
                    return Ok(Pattern {
                        kind: PatternKind::Bind(name.name, false),
                        span: name.span,
                    });
                }
            },
        },
        _ => return Err(p.unexpected("a pattern")),
    };
    p.bump();
    Ok(Pattern { kind, span: start })
}

/// `5`, `-5`, `b'a'` or `'a'`, or a range from one: `1..10`, `1..`,
/// `'a'..='z'`.
fn literal(p: &mut Parser) -> Result<Pattern, Error> {
    let start = p.span();
    let lo = pat_int(p)?;
    let mut end = lo.span;
    let kind = match p.peek() {
        Tok::DotDot => {
            end = p.bump().span;
            if starts_pat_int(p.peek()) {
                let hi = pat_int(p)?;
                end = hi.span;
                let lit = range_lit(lo.lit, hi.lit, end)?;
                PatternKind::Range(Some(lo.num), Some(hi.num), false, lit)
            } else {
                PatternKind::Range(Some(lo.num), None, false, lo.lit)
            }
        },
        Tok::DotDotEq => {
            p.bump();
            let hi = pat_int(p)?;
            end = hi.span;
            let lit = range_lit(lo.lit, hi.lit, end)?;
            PatternKind::Range(Some(lo.num), Some(hi.num), true, lit)
        },
        _ => PatternKind::Int(lo.num, lo.lit),
    };
    Ok(Pattern { kind, span: start.to(end) })
}

/// `( .. )`: `()`, a pattern in parentheses, which only group it, or a
/// tuple's, of two or more.
fn parens(p: &mut Parser) -> Result<Pattern, Error> {
    let start = p.bump().span;
    let mut pats = List::new();
    let mut comma = None;
    while p.peek() != Tok::RParen {
        pats.push(element(p)?);
        if p.peek() != Tok::Comma {
            break;
        }
        let at = p.bump().span;
        if comma.is_none() {
            comma = Some(at);
        }
    }
    let end = p.close_parens(pats.len(), comma)?;
    let span = start.to(end);
    one_rest(&pats)?;
    if pats.len() >= 2 {
        return Ok(Pattern { kind: PatternKind::Tuple(pats), span });
    }
    if pats.len() == 1 {
        if let PatternKind::Rest = text::item(&pats, 0).kind {
            // `(..)`: any tuple.
            return Ok(Pattern { kind: PatternKind::Tuple(pats), span });
        }
    }
    match pats.pop() {
        None => Ok(Pattern { kind: PatternKind::Unit, span }),
        // Only grouped: `(a | b)`.
        Some(inner) => Ok(Pattern { kind: inner.kind, span }),
    }
}

/// `None`, `Dot(p)` or `MAX`: a name that starts with an uppercase
/// letter, and the patterns in its `(..)` if it's written with them.
fn upper_name(p: &mut Parser) -> Result<Pattern, Error> {
    let name = p.ident()?;
    let start = name.span;
    let (args, end, written) = match p.eat(Tok::LParen) {
        true => {
            let (args, end) = p.comma_list(Tok::RParen, element)?;
            one_rest(&args)?;
            (args, end, true)
        },
        false => (List::new(), name.span, false),
    };
    Ok(Pattern { kind: PatternKind::Path(name, args, written), span: start.to(end) })
}

/// `Shape::Dot(p)`, `a::Shape::Empty` or `a::P::<i64> { .. }`: a pattern
/// that starts with a path.
fn path_pattern(p: &mut Parser) -> Result<Pattern, Error> {
    let start = p.span();
    let mut segs = p.segments()?;
    let Segment { name: last, targs: last_targs, end } = segs.pop().expect("a segment at least");
    if p.peek() == Tok::LBrace {
        no_targs(&segs)?;
        let name = joined(&segs, &last);
        return struct_pattern(p, name, last_targs);
    }
    if segs.is_empty() {
        return Err(p.unexpected("`::` or `{`"));
    }
    if let Some(end) = end {
        return Err(Error::syntax(end, "a variant has no type arguments of its own"));
    }
    let Segment { name: ty_name, targs, end: _ } = segs.pop().expect("a segment at least");
    no_targs(&segs)?;
    let ty = joined(&segs, &ty_name);
    let (args, end) = match p.eat(Tok::LParen) {
        true => p.comma_list(Tok::RParen, element)?,
        false => (List::new(), last.span),
    };
    one_rest(&args)?;
    Ok(Pattern { kind: PatternKind::Variant(ty, targs, last, args), span: start.to(end) })
}

/// An integer, a byte or a character in a pattern, as it's written, how,
/// and where.
#[derive(Copy, Discard)]
struct PatInt { num: Num, lit: Lit, span: Span }

/// `5` or `-5` in a pattern, or `b'a'` or `'a'`.
fn pat_int(p: &mut Parser) -> Result<PatInt, Error> {
    let start = p.span();
    match p.peek() {
        Tok::Byte(b) => {
            let num = Num { neg: false, abs: b as u64 };
            return Ok(PatInt { num, lit: Lit::Byte, span: p.bump().span });
        },
        Tok::Char(c) => {
            let num = Num { neg: false, abs: c as u32 as u64 };
            return Ok(PatInt { num, lit: Lit::Char, span: p.bump().span });
        },
        _ => {},
    }
    let neg = p.eat(Tok::Minus);
    let Tok::Int(n, suffix) = p.peek() else {
        return Err(p.unexpected("an integer"));
    };
    let end = p.bump().span;
    if suffix.is_some() {
        return Err(Error::syntax(
            end,
            "an integer in a pattern can't have a suffix: its type is that of what it matches",
        ));
    }
    Ok(PatInt { num: Num { neg, abs: n }, lit: Lit::Int, span: start.to(end) })
}

/// Can a literal in a pattern start with `tok`?
fn starts_pat_int(tok: Tok) -> bool {
    match tok {
        Tok::Int(..) | Tok::Minus | Tok::Byte(_) | Tok::Char(_) => true,
        _ => false,
    }
}

/// The kind of a range from a literal of kind `a` to one of kind `b`,
/// which ends at `end`: characters go only with characters, and a byte
/// makes it a range of bytes.
fn range_lit(a: Lit, b: Lit, end: Span) -> Result<Lit, Error> {
    if a == b {
        return Ok(a);
    }
    match a == Lit::Char || b == Lit::Char {
        true => Err(Error::syntax(
            end,
            "a range of characters goes from a character to a character",
        )),
        false => Ok(Lit::Byte),
    }
}

/// `Point { x, y: 0, .. }`, from the `{`, after the name `ty` and its type
/// arguments.
fn struct_pattern(p: &mut Parser, ty: Ident, targs: List<TypeExpr>) -> Result<Pattern, Error> {
    p.expect(Tok::LBrace)?;
    let mut fields = List::new();
    let mut rest = false;
    loop {
        if p.peek() == Tok::RBrace {
            break;
        }
        if p.eat(Tok::DotDot) {
            rest = true;
            break;
        }
        fields.push(field_pat(p)?);
        if !p.eat(Tok::Comma) {
            break;
        }
    }
    let span = ty.span.to(p.expect(Tok::RBrace)?);
    Ok(Pattern { kind: PatternKind::Struct(ty, targs, fields, rest), span })
}

/// `x`, `mut x` or `y: 0` in a struct pattern. `x` is short for `x: x`,
/// and `mut x` for `x: mut x`; the pattern of either ends where the
/// field's name does.
fn field_pat(p: &mut Parser) -> Result<FieldPat, Error> {
    if p.peek() == Tok::Mut {
        let start = p.bump().span;
        let Tok::Ident(_) = p.peek() else {
            return Err(Error::syntax(p.span(), "expected a field name after `mut`"));
        };
        let name = p.ident()?;
        if starts_upper(name.name.as_str()) {
            let n = name.name.as_str();
            let lower = snake(n);
            return Err(Error::owned(
                name.span,
                String::of(
                    &f"a variable's name can't start with an uppercase letter: write `{n}: mut {lower}` to bind field `{n}`",
                ),
            ));
        }
        let kind = PatternKind::Bind(String::from(name.name.as_str()), true);
        let pat = Pattern { kind, span: start.to(name.span) };
        return Ok(FieldPat { name, pat });
    }
    let name = p.ident()?;
    if p.eat(Tok::Colon) {
        let pat = pattern(p)?;
        return Ok(FieldPat { name, pat });
    }
    if starts_upper(name.name.as_str()) {
        let n = name.name.as_str();
        let lower = snake(n);
        return Err(Error::owned(
            name.span,
            String::of(
                &f"a variable's name can't start with an uppercase letter: write `{n}: {lower}` to bind field `{n}`",
            ),
        ));
    }
    let pat = Pattern {
        kind: PatternKind::Bind(String::from(name.name.as_str()), false),
        span: name.span,
    };
    Ok(FieldPat { name, pat })
}

/// `name` in `snake_case`, as t-lang's `naming::snake` writes it: its
/// words, split at `_`s and where the case changes, in lowercase, with
/// `_`s between, and the `_`s around it kept. A name is ASCII.
fn snake(name: &str) -> String {
    let b = name.as_bytes();
    let mut lo = 0;
    while lo < b.len() && text::byte(b, lo) == b'_' {
        lo = lo + 1;
    }
    let mut hi = b.len();
    while hi > lo && text::byte(b, hi - 1) == b'_' {
        hi = hi - 1;
    }
    let mut out = String::from(text::sub(name, 0, lo));
    let mut first = true;
    let mut i = lo;
    while i < hi {
        if text::byte(b, i) == b'_' {
            i = i + 1;
            continue;
        }
        // A part between `_`s, split into words where the case changes.
        let mut end = i;
        while end < hi && text::byte(b, end) != b'_' {
            end = end + 1;
        }
        let mut k = i;
        while k < end {
            let c = text::byte(b, k);
            let split = k > i
                && is_upper(c)
                && {
                    let prev = text::byte(b, k - 1);
                    let next_lower = k + 1 < end && is_lower(text::byte(b, k + 1));
                    is_lower(prev) || text::is_digit(prev) || (is_upper(prev) && next_lower)
                };
            if split || k == i {
                if !first {
                    out.push('_');
                }
                first = false;
            }
            out.push(lower(c));
            k = k + 1;
        }
        i = end;
    }
    out.push_str(text::sub(name, hi, b.len()));
    out
}

/// Is `b` an ASCII uppercase letter?
fn is_upper(b: u8) -> bool { b >= b'A' && b <= b'Z' }

/// Is `b` an ASCII lowercase letter?
fn is_lower(b: u8) -> bool { b >= b'a' && b <= b'z' }

/// ASCII letter `b` in lowercase, as a character.
fn lower(b: u8) -> char {
    let c = if is_upper(b) { b + 32 } else { b };
    char::from_u32(c as u32).expect("ASCII")
}
