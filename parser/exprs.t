//! Blocks, statements and expressions.
//!
//! Like Rust, an `if`, `match`, loop or block at the *start* of a statement
//! is the whole statement, so `if c { a } else { b } - x` is two
//! statements, not a subtraction.
//!
//! `return` and `break` take an expression after them if one can start
//! there (after `break`'s label, if it has one), and it runs as far right
//! as an expression can, as a closure's body does.

use alloc::boxed::Box;
use alloc::list::List;
use alloc::string::String;

use crate::ast::{
    Arm,
    BinOp,
    Chain,
    Cond,
    Expr,
    ExprKind,
    FieldInit,
    FmtHole,
    FmtPad,
    FmtPiece,
    FmtSpec,
    FmtWidth,
    ForLoop,
    Ident,
    IntTy,
    Invariant,
    Label,
    Lambda,
    LambdaParam,
    LetCond,
    LetStmt,
    Stmt,
    TypeDecl,
    TypeExpr,
    TypeExprKind,
    UnOp,
};
use crate::error::{Error, Span};
use crate::lexer::{FPiece, OpEq, Pieces, Tok, Token};
use crate::parser::{joined, no_targs, Parser, Segment};
use crate::parser::items::{self, NOT_EXTERN, NOT_METHOD};
use crate::parser::patterns;
use crate::parser::types;
use crate::text;

/// How tightly `&&` binds: a chain's conditions bind more tightly.
const AND_PREC: u8 = 2;

/// How tightly comparisons bind: they don't chain.
const CMP_PREC: u8 = 3;

/// How tightly `&`, `|`, `^`, `<<` and `>>` bind: more than comparisons,
/// and as `+`, though which of them comes first, or of them and
/// arithmetic, needs parentheses (`nests_in`).
const BITS_PREC: u8 = 4;

/// `{ .. }`, where struct literals are allowed again, whatever's around it.
pub fn block(p: &mut Parser) -> Result<Expr, Error> { p.structs(true, block_inner) }

/// `{ stmt; stmt; tail }`, its statements each a `let`, a local item, or
/// an expression.
fn block_inner(p: &mut Parser) -> Result<Expr, Error> {
    let start = p.expect(Tok::LBrace)?;
    let mut stmts = List::new();
    let tail = loop {
        match p.peek() {
            Tok::RBrace => break None,
            Tok::Let => {
                stmts.push(let_stmt(p)?);
                continue;
            },
            Tok::Const | Tok::Static => {
                let what = match p.peek() {
                    Tok::Static => "static",
                    _ => "const",
                };
                return Err(Error::owned(
                    p.span(),
                    String::of(
                        &f"a {what} is an item of a module, not of a block: declare it outside the function",
                    ),
                ));
            },
            Tok::Trait => {
                return Err(Error::syntax(
                    p.span(),
                    "a `trait` can only be at the top level, not in a block",
                ));
            },
            Tok::Impl => {
                return Err(Error::syntax(
                    p.span(),
                    "an `impl` can only be at the top level, not in a block",
                ));
            },
            Tok::Mod => {
                return Err(Error::syntax(
                    p.span(),
                    "a `mod` can't be in a function: a module's items are only in modules",
                ));
            },
            Tok::Use => {
                return Err(Error::syntax(
                    p.span(),
                    "a `use` can't be in a function, only in a module",
                ));
            },
            Tok::Pub => {
                return Err(Error::syntax(
                    p.span(),
                    "what's in a function can't be `pub`: only it can see it",
                ));
            },
            Tok::Export => {
                return Err(Error::syntax(
                    p.span(),
                    "what's in a function can't be `export`: only it can see it",
                ));
            },
            Tok::Extern => return Err(Error::syntax(p.span(), NOT_EXTERN)),
            Tok::Fn | Tok::Struct | Tok::Enum | Tok::Type | Tok::Hash => {
                stmts.push(local_item(p)?);
                continue;
            },
            _ => {},
        }
        let (e, block_like) = match p.peek() {
            Tok::If => (if_expr(p)?, true),
            Tok::Match => (match_expr(p)?, true),
            Tok::While | Tok::Loop | Tok::For | Tok::Lifetime(_) => (loop_expr(p)?, true),
            Tok::LBrace => (block(p)?, true),
            Tok::Unsafe => (unsafe_block(p)?, true),
            _ => (expr(p)?, false),
        };
        if p.eat(Tok::Semi) {
            stmts.push(Stmt::Expr(e));
        } else if p.peek() == Tok::RBrace {
            break Some(Box::new(e));
        } else if block_like {
            // The statement ends here, `;` or not.
            stmts.push(Stmt::BlockLike(e));
        } else {
            return Err(p.unexpected("`;` or `}`"));
        }
    };
    let end = p.expect(Tok::RBrace)?;
    Ok(Expr { kind: ExprKind::Block(stmts, tail), span: start.to(end) })
}

/// A `fn`, `struct`, `enum` or `type` in a block, local to it, with its
/// head.
fn local_item(p: &mut Parser) -> Result<Stmt, Error> {
    let h = items::read_head(p)?.no_intrinsic()?.no_measure(NOT_METHOD)?.no_test()?;
    let h = match p.peek() {
        Tok::Fn => h,
        _ => h.no_blame_caller()?,
    };
    match p.peek() {
        Tok::Fn => Ok(Stmt::Fn(Box::new(items::fn_decl(p, h.no_derives()?)?))),
        Tok::Struct => Ok(Stmt::Type(Box::new(TypeDecl::Struct(items::struct_decl(p, h)?)))),
        Tok::Enum => Ok(Stmt::Type(Box::new(TypeDecl::Enum(items::enum_decl(p, h)?)))),
        Tok::Type => {
            let d = items::alias_decl(p, h.no_derives()?)?;
            Ok(Stmt::Type(Box::new(TypeDecl::Alias(d))))
        },
        _ => Err(p.unexpected("`fn`, `struct`, `enum` or `type` after an attribute")),
    }
}

/// `unsafe { .. }`: a block that keeps the obligations of the unsafe
/// operations in it.
fn unsafe_block(p: &mut Parser) -> Result<Expr, Error> {
    let start = p.expect(Tok::Unsafe)?;
    if p.peek() != Tok::LBrace {
        return Err(p.unexpected("`{` after `unsafe`"));
    }
    let block = block(p)?;
    Ok(Expr { span: start.to(block.span), kind: ExprKind::Unsafe(Box::new(block)) })
}

/// `let pat: ty = init else { .. };`, each part but the pattern if it's
/// there.
fn let_stmt(p: &mut Parser) -> Result<Stmt, Error> {
    let start = p.expect(Tok::Let)?;
    let pat = patterns::pattern(p)?;
    let ty = match p.eat(Tok::Colon) {
        true => Some(types::ty(p)?),
        false => None,
    };
    let init = match p.eat(Tok::Eq) {
        true => Some(Box::new(expr(p)?)),
        false => None,
    };
    let els = match (&init, p.peek() == Tok::Else) {
        (Some(init), true) => {
            if p.before().tok == Tok::RBrace {
                return Err(Error::syntax(
                    p.span(),
                    "what's before the `else` of a `let .. else` can't end in `}`: put it in \
                     parentheses",
                ));
            }
            no_chain(init, "a `let .. else`")?;
            if let Some(ty) = &ty {
                return Err(Error::syntax(
                    ty.span,
                    "a `let .. else` can't have a type: give the pattern's type arguments \
                     instead, as in `Option::<i64>::Some(x)`",
                ));
            }
            p.bump();
            if p.peek() != Tok::LBrace {
                return Err(p.unexpected("`{` after `else`"));
            }
            Some(Box::new(block(p)?))
        },
        _ => None,
    };
    let end = p.expect(Tok::Semi)?;
    let ty = match ty {
        Some(t) => Some(Box::new(t)),
        None => None,
    };
    Ok(Stmt::Let(LetStmt { pat, ty, init, els, span: start.to(end) }))
}

/// `let pat = e`, a condition of a chain: `e` binds more tightly than
/// `&&`, which joins it to the next condition.
fn let_cond(p: &mut Parser) -> Result<LetCond, Error> {
    let let_span = p.expect(Tok::Let)?;
    let pat = patterns::pattern(p)?;
    p.expect(Tok::Eq)?;
    let expr = binary_op(p, AND_PREC + 1)?.0;
    Ok(LetCond { let_span, pat, expr })
}

/// What an `if` or a `while` tests.
#[derive(Discard)]
enum Condition { Is(Expr), Chain(Chain) }

/// What an `if` or a `while` tests: an expression, or a chain of
/// conditions with a `let` in it, joined by `&&`. Each condition binds
/// more tightly than `&&`; with no `let`, they're the operands of the
/// `&&`s, and the expression goes on from there as any other.
fn condition(p: &mut Parser) -> Result<Condition, Error> { p.structs(false, condition_in) }

fn condition_in(p: &mut Parser) -> Result<Condition, Error> {
    let mut conds = List::new();
    let mut lets = false;
    loop {
        match p.peek() {
            Tok::Let => {
                lets = true;
                conds.push(Cond::Let(let_cond(p)?));
            },
            _ => conds.push(Cond::Bool(binary_op(p, AND_PREC + 1)?.0)),
        }
        if !p.eat(Tok::AndAnd) {
            break;
        }
    }
    if lets {
        return match p.peek() {
            Tok::OrOr => Err(Error::syntax(
                p.span(),
                "`||` can't join a condition with a `let` in it: what the `let` binds would be there on one side and not the other; put the `||` in parentheses, or use an `if` inside",
            )),
            Tok::DotDot | Tok::Eq | Tok::OpEq(_) => Err(Error::syntax(
                p.span(),
                "in a condition with a `let`, put a range or an assignment in parentheses",
            )),
            _ => Ok(Condition::Chain(Chain { conds })),
        };
    }
    let mut lhs: Option<Expr> = None;
    let mut lhs_op = None;
    for c in conds {
        let Cond::Bool(e) = c else { continue };
        lhs = Some(match lhs {
            None => {
                if let ExprKind::Binary(op, _, _) = &e.kind {
                    lhs_op = Some(*op);
                }
                e
            },
            Some(l) => {
                lhs_op = Some(BinOp::And);
                let span = l.span.to(e.span);
                Expr { kind: ExprKind::Binary(BinOp::And, Box::new(l), Box::new(e)), span }
            },
        });
    }
    let lhs = lhs.expect("one condition at least");
    let lhs = binary_op_from(p, lhs, lhs_op, 0)?.0;
    let lhs = range_from(p, lhs)?;
    Ok(Condition::Is(expr_from(p, lhs)?))
}

/// Checks that `e`, what an `if let`, `while let` or `let .. else` (`what`)
/// matches, isn't an `&&` or `||` but in parentheses: chains of `let`s and
/// conditions may mean that one day.
fn no_chain(e: &Expr, what: &str) -> Result<(), Error> {
    if let ExprKind::Binary(op, l, _) = &e.kind {
        if (*op == BinOp::And || *op == BinOp::Or) && l.span.start == e.span.start {
            let op = op.symbol();
            return Err(Error::owned(
                e.span,
                String::of(
                    &f"`{op}` can't come at the top of what {what} matches (yet): put it in parentheses, or use an `if` inside",
                ),
            ));
        }
    }
    Ok(())
}

/// An expression, which may be an assignment: `x = 1`, `p.x += 2`.
/// Assignment binds less tightly than anything, and to the right.
pub fn expr(p: &mut Parser) -> Result<Expr, Error> {
    let lhs = range(p)?;
    expr_from(p, lhs)
}

/// `expr`, from its first operand, `lhs`, parsed already.
fn expr_from(p: &mut Parser, lhs: Expr) -> Result<Expr, Error> {
    let op = match p.peek() {
        Tok::Eq => None,
        Tok::OpEq(op) => Some(assign_op(op)),
        // `>>=`, which is lexed `>` `>=`: see `next_binop`.
        Tok::Gt => {
            if p.peek2() != Tok::Ge || !p.adjacent() {
                return Ok(lhs);
            }
            p.bump();
            Some(BinOp::Shr)
        },
        _ => return Ok(lhs),
    };
    p.bump();
    let rhs = expr(p)?;
    let span = lhs.span.to(rhs.span);
    let mut lhs = lhs;
    written(&mut lhs);
    Ok(Expr { kind: ExprKind::Assign(op, Box::new(lhs), Box::new(rhs)), span })
}

/// The operator of compound assignment `op`.
fn assign_op(op: OpEq) -> BinOp {
    match op {
        OpEq::Add => BinOp::Add,
        OpEq::Sub => BinOp::Sub,
        OpEq::Mul => BinOp::Mul,
        OpEq::Div => BinOp::Div,
        OpEq::Rem => BinOp::Rem,
        OpEq::And => BinOp::BitAnd,
        OpEq::Or => BinOp::BitOr,
        OpEq::Xor => BinOp::BitXor,
        OpEq::Shl => BinOp::Shl,
    }
}

/// Marks each `x[i]` place `e` is, or is inside of, through fields and
/// `*`s, as written to.
fn written(e: &mut Expr) {
    match &mut e.kind {
        ExprKind::Index(x, _, _, w) => {
            *w = true;
            written(x);
        },
        ExprKind::Field(x, _) => written(x),
        ExprKind::Unary(UnOp::Deref, x) => written(x),
        _ => {},
    }
}

/// `a..b`, or just `a`. A range binds less tightly than any operator, so
/// `0..n + 1` is `0..(n + 1)`, and doesn't chain.
fn range(p: &mut Parser) -> Result<Expr, Error> {
    let lhs = binary_op(p, 0)?.0;
    range_from(p, lhs)
}

/// `range`, from its first operand, `lhs`, parsed already.
fn range_from(p: &mut Parser, lhs: Expr) -> Result<Expr, Error> {
    match p.peek() {
        Tok::DotDot => {},
        Tok::DotDotEq => {
            return Err(Error::syntax(p.span(), "`a..=b` isn't supported (yet); write `a..b + 1`"));
        },
        _ => return Ok(lhs),
    }
    let dots = p.bump().span;
    if !starts_expr(p.peek()) || (p.no_struct && p.peek() == Tok::LBrace) {
        return Err(Error::syntax(
            dots,
            "a range needs an end: `a..b` (ranges with no end aren't supported yet)",
        ));
    }
    let rhs = binary_op(p, 0)?.0;
    if p.peek() == Tok::DotDot || p.peek() == Tok::DotDotEq {
        return Err(Error::syntax(p.span(), "ranges can't be chained: parenthesize one"));
    }
    let span = lhs.span.to(rhs.span);
    Ok(Expr { kind: ExprKind::Range(Box::new(lhs), Box::new(rhs)), span })
}

/// Precedence climbing: an expression whose operators all bind at least
/// as tightly as `min_prec`, and its operator if it's a binary operation,
/// not in parentheses: whether it may be the operand of another is
/// `nests_in`.
fn binary_op(p: &mut Parser, min_prec: u8) -> Result<(Expr, Option<BinOp>), Error> {
    let lhs = cast(p)?;
    binary_op_from(p, lhs, None, min_prec)
}

/// `binary_op`, from its first operand, `lhs`, parsed already, and its
/// operator, `lhs_op`.
fn binary_op_from(
    p: &mut Parser,
    lhs: Expr,
    lhs_op: Option<BinOp>,
    min_prec: u8,
) -> Result<(Expr, Option<BinOp>), Error> {
    let mut lhs = lhs;
    let mut lhs_op = lhs_op;
    while let Some((op, prec)) = next_binop(p) {
        if prec < min_prec {
            break;
        }
        let at = p.span();
        if op == BinOp::Shr {
            p.bump();
        }
        p.bump();
        let (rhs, rhs_op) = binary_op(p, prec + 1)?;
        if let Some(inner) = lhs_op {
            nested(inner, op, at)?;
        }
        if let Some(inner) = rhs_op {
            nested(inner, op, at)?;
        }
        let span = lhs.span.to(rhs.span);
        lhs = Expr { kind: ExprKind::Binary(op, Box::new(lhs), Box::new(rhs)), span };
        lhs_op = Some(op);
        let chained = match next_binop(p) {
            Some((_, next)) => prec == CMP_PREC && next == CMP_PREC,
            None => false,
        };
        if chained {
            return Err(Error::syntax(
                p.span(),
                "comparison operators cannot be chained; use `&&` (e.g. `a < b && b < c`)",
            ));
        }
    }
    Ok((lhs, lhs_op))
}

/// Checks that `inner` may be an operand of `outer`, at `at`, without
/// parentheses.
fn nested(inner: BinOp, outer: BinOp, at: Span) -> Result<(), Error> {
    if nests_in(inner, outer) {
        return Ok(());
    }
    let (a, b) = (inner.symbol(), outer.symbol());
    Err(Error::owned(
        at,
        String::of(
            &f"use parentheses to say which of `{a}` and `{b}` comes first: there's no precedence between them",
        ),
    ))
}

/// Whether `inner` may be an operand of `outer` without parentheses.
/// Comparisons and `&&` and `||` take anything that binds more tightly;
/// arithmetic, by its precedence. But how a bitwise operator or a shift
/// goes with another, or with arithmetic, has no precedence.
fn nests_in(inner: BinOp, outer: BinOp) -> bool {
    if outer.is_bitwise() {
        inner == outer
    } else if is_arith(outer) {
        !inner.is_bitwise()
    } else {
        true
    }
}

/// Whether `op` is one of `+`, `-`, `*`, `/` and `%`.
fn is_arith(op: BinOp) -> bool {
    match op {
        BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => true,
        _ => false,
    }
}

/// The binary operator next, and how tightly it binds. `>>` is two `>`s
/// with nothing between them, and `>>=` a `>` and a `>=`, which isn't a
/// binary operator but an assignment.
fn next_binop(p: &Parser) -> Option<(BinOp, u8)> {
    if p.peek() == Tok::Gt && p.adjacent() {
        return match p.peek2() {
            Tok::Gt => Some((BinOp::Shr, BITS_PREC)),
            Tok::Ge => None,
            _ => binop(p.peek()),
        };
    }
    binop(p.peek())
}

/// The binary operator `tok` is, if it's one, and how tightly it binds.
fn binop(tok: Tok) -> Option<(BinOp, u8)> {
    match tok {
        Tok::OrOr => Some((BinOp::Or, 1)),
        Tok::AndAnd => Some((BinOp::And, 2)),
        Tok::EqEq => Some((BinOp::Eq, CMP_PREC)),
        Tok::NotEq => Some((BinOp::Ne, CMP_PREC)),
        Tok::Lt => Some((BinOp::Lt, CMP_PREC)),
        Tok::Le => Some((BinOp::Le, CMP_PREC)),
        Tok::Gt => Some((BinOp::Gt, CMP_PREC)),
        Tok::Ge => Some((BinOp::Ge, CMP_PREC)),
        Tok::Plus => Some((BinOp::Add, 4)),
        Tok::Minus => Some((BinOp::Sub, 4)),
        Tok::Star => Some((BinOp::Mul, 5)),
        Tok::Slash => Some((BinOp::Div, 5)),
        Tok::Percent => Some((BinOp::Rem, 5)),
        Tok::Amp => Some((BinOp::BitAnd, BITS_PREC)),
        Tok::Pipe => Some((BinOp::BitOr, BITS_PREC)),
        Tok::Caret => Some((BinOp::BitXor, BITS_PREC)),
        Tok::Shl => Some((BinOp::Shl, BITS_PREC)),
        _ => None,
    }
}

/// Can an expression start with `tok`?
fn starts_expr(tok: Tok) -> bool {
    match tok {
        Tok::Int(..)
        | Tok::Byte(_)
        | Tok::Char(_)
        | Tok::Str
        | Tok::ByteStr
        | Tok::Ident(_) => true,
        Tok::True | Tok::False | Tok::LParen | Tok::LBrace | Tok::If | Tok::Match => true,
        Tok::While | Tok::Loop | Tok::Unsafe | Tok::For | Tok::Lifetime(_) => true,
        Tok::Return | Tok::Break | Tok::Continue | Tok::Move | Tok::Pipe | Tok::OrOr => true,
        Tok::Minus | Tok::Bang | Tok::Star | Tok::Amp | Tok::AndAnd => true,
        _ => false,
    }
}

/// `x as u8 as i64`, or just `x`. `as` binds more tightly than any binary
/// operator, and less than a prefix one: `-x as u8` is `(-x) as u8`, and
/// `a * b as u8` is `a * (b as u8)`, as in Rust. What follows it is a
/// type's name, as only an integer type or a type parameter can be: so
/// `x as u8 < y` is a comparison, where it would otherwise start `u8`'s
/// type arguments.
fn cast(p: &mut Parser) -> Result<Expr, Error> {
    let mut e = unary(p)?;
    while p.eat(Tok::As) {
        let name = p.ident()?;
        let ty = TypeExpr { kind: TypeExprKind::Named(name.name, List::new()), span: name.span };
        let span = e.span.to(ty.span);
        e = Expr { kind: ExprKind::As(Box::new(e), Box::new(ty)), span };
    }
    Ok(e)
}

/// `-x`, `!x`, `*x`, `&x` or `&mut x`, or what `postfix` reads.
fn unary(p: &mut Parser) -> Result<Expr, Error> {
    let op = match p.peek() {
        Tok::Minus => UnOp::Neg,
        Tok::Bang => UnOp::Not,
        Tok::Star => UnOp::Deref,
        Tok::Amp => UnOp::Ref,
        // `&&x` is `&(&x)`.
        Tok::AndAnd => {
            let start = p.bump().span;
            let inner = borrow(p, Span::new(start.start + 1, start.end))?;
            let span = start.to(inner.span);
            return Ok(Expr { kind: ExprKind::Unary(UnOp::Ref, Box::new(inner)), span });
        },
        _ => return postfix(p),
    };
    let start = p.bump().span;
    if op == UnOp::Ref {
        return borrow(p, start);
    }
    let operand = unary(p)?;
    let span = start.to(operand.span);
    Ok(Expr { kind: ExprKind::Unary(op, Box::new(operand)), span })
}

/// `&x` or `&mut x`, after the `&`, which is at `start`.
fn borrow(p: &mut Parser, start: Span) -> Result<Expr, Error> {
    let op = match p.eat(Tok::Mut) {
        true => UnOp::RefMut,
        false => UnOp::Ref,
    };
    let mut operand = unary(p)?;
    if op == UnOp::RefMut {
        written(&mut operand);
    }
    let span = start.to(operand.span);
    Ok(Expr { kind: ExprKind::Unary(op, Box::new(operand)), span })
}

/// What `primary` reads, then its calls, method calls, fields, indexes
/// and `?`s.
fn postfix(p: &mut Parser) -> Result<Expr, Error> {
    let mut e = primary(p)?;
    loop {
        if p.peek() == Tok::LBracket {
            let open = p.bump().span;
            let i = expr(p)?;
            let close = p.expect(Tok::RBracket)?;
            let span = e.span.to(close);
            e = Expr {
                kind: ExprKind::Index(Box::new(e), Box::new(i), open.to(close), false),
                span,
            };
        } else if p.eat(Tok::LParen) {
            let (args, end) = args(p)?;
            let span = e.span.to(end);
            e = Expr { kind: ExprKind::Call(Box::new(e), args), span };
        } else if p.eat(Tok::Dot) {
            // `t.0`: a tuple's field, by its index, in plain digits.
            if let Tok::Int(n, suffix) = p.peek() {
                let at = p.bump().span;
                let digits = String::of(&n);
                if suffix.is_some() || at.end - at.start != digits.len() {
                    return Err(Error::syntax(
                        at,
                        "a tuple's field is written as plain digits, as in `.0`",
                    ));
                }
                let span = e.span.to(at);
                e = Expr {
                    kind: ExprKind::Field(Box::new(e), Ident { name: digits, span: at }),
                    span,
                };
                continue;
            }
            let name = p.ident()?;
            let (targs, _) = p.turbofish()?;
            if p.eat(Tok::LParen) {
                let (args, end) = args(p)?;
                let span = e.span.to(end);
                e = Expr { kind: ExprKind::MethodCall(Box::new(e), name, targs, args), span };
            } else if !targs.is_empty() {
                return Err(p.unexpected("`(`: only a method call has type arguments"));
            } else {
                let span = e.span.to(name.span);
                e = Expr { kind: ExprKind::Field(Box::new(e), name), span };
            }
        } else if p.peek() == Tok::Question {
            let q = p.bump().span;
            let span = e.span.to(q);
            e = Expr { kind: ExprKind::Try(Box::new(e), q), span };
        } else {
            return Ok(e);
        }
    }
}

/// Call arguments, after the `(`, and where the `)` is.
fn args(p: &mut Parser) -> Result<(List<Expr>, Span), Error> {
    p.structs(true, |p| p.comma_list(Tok::RParen, expr))
}

/// A literal, a name or a path, or what starts with a bracket or a
/// keyword: a block, an `if`, a loop, a closure ..
fn primary(p: &mut Parser) -> Result<Expr, Error> {
    let span = p.span();
    let kind = match p.peek() {
        Tok::Int(n, suffix) => ExprKind::Int(n, suffix),
        Tok::Byte(b) => ExprKind::Int(b as u64, Some(IntTy::U8)),
        Tok::Char(c) => ExprKind::Char(c),
        Tok::Str => ExprKind::Str,
        Tok::ByteStr => ExprKind::ByteStr,
        Tok::FStr(pieces) => ExprKind::Format(format_pieces(p, pieces)?),
        Tok::True => ExprKind::Bool(true),
        Tok::False => ExprKind::Bool(false),
        Tok::Crate | Tok::Super => return path_expr(p),
        Tok::Ident(name) => match (p.peek2(), p.no_struct) {
            (Tok::ColonColon, _) => return path_expr(p),
            (Tok::LBrace, false) => {
                let name = p.ident()?;
                return struct_lit(p, name, List::new());
            },
            _ => ExprKind::Var(String::from(name), List::new()),
        },
        Tok::LParen => {
            p.bump();
            let (mut items, end) = p.structs(true, in_parens)?;
            let kind = match items.len() >= 2 {
                true => ExprKind::Tuple(items),
                false => match items.pop() {
                    None => ExprKind::Unit,
                    Some(inner) => inner.kind,
                },
            };
            return Ok(Expr { kind, span: span.to(end) });
        },
        Tok::LBracket => return array(p),
        Tok::LBrace => return block(p),
        Tok::Unsafe => return unsafe_block(p),
        Tok::If => return if_expr(p),
        Tok::Match => return match_expr(p),
        Tok::While | Tok::Loop | Tok::For | Tok::Lifetime(_) => return loop_expr(p),
        Tok::Return | Tok::Break | Tok::Continue => return jump(p),
        Tok::Pipe | Tok::OrOr | Tok::Move => return lambda(p),
        Tok::Let => {
            return Err(Error::syntax(
                p.span(),
                "a `let` can only be a condition of an `if` or a `while`, joined to the others by `&&`",
            ));
        },
        _ => return Err(p.unexpected("an expression")),
    };
    p.bump();
    Ok(Expr { kind, span })
}

/// What's in `( .. )`, after the `(`, and where the `)` is.
fn in_parens(p: &mut Parser) -> Result<(List<Expr>, Span), Error> {
    let mut items = List::new();
    let mut comma = None;
    while p.peek() != Tok::RParen {
        items.push(expr(p)?);
        if p.peek() != Tok::Comma {
            break;
        }
        let at = p.bump().span;
        if comma.is_none() {
            comma = Some(at);
        }
    }
    let end = p.close_parens(items.len(), comma)?;
    Ok((items, end))
}

/// The pieces of a format string, its holes' expressions read from their
/// tokens.
fn format_pieces(p: &Parser, pieces: Pieces) -> Result<List<FmtPiece>, Error> {
    let all = p.pieces;
    let mut out = List::new();
    let mut i = pieces.first;
    while i < pieces.first + pieces.len {
        match text::item(all, i) {
            FPiece::Text => out.push(FmtPiece::Text),
            FPiece::Hole(h) => {
                let value = hole(p, &h.toks)?;
                // `w` of `{x:>w$}`, a variable.
                let width = match (&h.spec.pad, h.width_at) {
                    (Some(pad), Some(at)) => match &pad.width {
                        FmtWidth::Var(w) => {
                            let kind = ExprKind::Var(String::from(w.as_str()), List::new());
                            Some(Box::new(Expr { kind, span: at }))
                        },
                        FmtWidth::Lit(_) => None,
                    },
                    _ => None,
                };
                out.push(FmtPiece::Hole(FmtHole {
                    value,
                    spec: spec_of(&h.spec),
                    width,
                    span: h.span,
                }));
            },
        }
        i = i + 1;
    }
    Ok(out)
}

/// The expression of a format string's hole, from its tokens, which end
/// with an `Eof`.
fn hole(p: &Parser, toks: &List<Token>) -> Result<Expr, Error> {
    let mut q = Parser::new(toks, p.pieces, p.module);
    let e = expr(&mut q)?;
    if q.peek() != Tok::Eof {
        return Err(Error::syntax(
            q.span(),
            "a hole in a format string holds one expression; this is after it",
        ));
    }
    Ok(e)
}

/// Another of `spec`.
fn spec_of(spec: &FmtSpec) -> FmtSpec {
    let pad = match &spec.pad {
        Some(pad) => {
            let width = match &pad.width {
                FmtWidth::Lit(n) => FmtWidth::Lit(*n),
                FmtWidth::Var(v) => FmtWidth::Var(String::from(v.as_str())),
            };
            Some(FmtPad { fill: pad.fill, align: pad.align, width })
        },
        None => None,
    };
    FmtSpec { kind: spec.kind, pad }
}

/// `[a, b, c]` or `[v; n]`.
fn array(p: &mut Parser) -> Result<Expr, Error> {
    let start = p.expect(Tok::LBracket)?;
    let kind = p.structs(true, array_items)?;
    let end = p.expect(Tok::RBracket)?;
    Ok(Expr { kind, span: start.to(end) })
}

/// What's in `[ .. ]`, up to the `]`.
fn array_items(p: &mut Parser) -> Result<ExprKind, Error> {
    let mut items = List::new();
    if p.peek() == Tok::RBracket {
        return Ok(ExprKind::Array(items));
    }
    let first = expr(p)?;
    if p.eat(Tok::Semi) {
        let n = expr(p)?;
        return Ok(ExprKind::Repeat(Box::new(first), Box::new(n)));
    }
    items.push(first);
    if p.eat(Tok::Comma) {
        while p.peek() != Tok::RBracket {
            items.push(expr(p)?);
            if !p.eat(Tok::Comma) {
                break;
            }
        }
    }
    Ok(ExprKind::Array(items))
}

/// `if c { .. } else { .. }` or `if let p = e { .. }`, with an `else if`
/// after it, or more.
fn if_expr(p: &mut Parser) -> Result<Expr, Error> {
    let start = p.expect(Tok::If)?;
    let cond = condition(p)?;
    let then = block(p)?;
    let els = match p.eat(Tok::Else) {
        true => match p.peek() {
            Tok::If => Some(Box::new(if_expr(p)?)),
            _ => Some(Box::new(block(p)?)),
        },
        false => None,
    };
    let end = match &els {
        Some(e) => e.span,
        None => then.span,
    };
    let kind = match cond {
        Condition::Is(c) => ExprKind::If(Box::new(c), Box::new(then), els),
        Condition::Chain(c) => ExprKind::IfLet(Box::new(c), Box::new(then), els),
    };
    Ok(Expr { kind, span: start.to(end) })
}

/// `while c { .. }`, `loop { .. }` or `for x in it { .. }`, maybe after a
/// label, `'a:`.
fn loop_expr(p: &mut Parser) -> Result<Expr, Error> {
    let start = p.span();
    let label = match p.peek() {
        Tok::Lifetime(_) => {
            let name = p.lifetime()?;
            p.expect(Tok::Colon)?;
            let head = Span::new(name.span.start, p.span().start);
            Some(Label { name, head })
        },
        _ => None,
    };
    if p.peek() == Tok::For {
        p.bump();
        let pat = patterns::pattern(p)?;
        let in_span = p.expect(Tok::In)?;
        // `it:` names the iterator: no expression starts with a name and
        // one `:`.
        let name = match (p.peek(), p.peek2()) {
            (Tok::Ident(_), Tok::Colon) => {
                let name = p.ident()?;
                p.bump();
                Some(name)
            },
            _ => None,
        };
        let iter = p.structs(false, expr)?;
        let invariant_ = loop_invariant(p)?;
        let body = block(p)?;
        let span = start.to(body.span);
        let f = ForLoop { label, pat, in_span, name, iter, invariant_, body };
        return Ok(Expr { kind: ExprKind::For(Box::new(f)), span });
    }
    match (p.peek(), p.peek2()) {
        (Tok::While, _) => {
            p.bump();
            let c = condition(p)?;
            let inv = loop_invariant(p)?;
            let body = block(p)?;
            let span = start.to(body.span);
            let kind = match c {
                Condition::Is(c) => ExprKind::While(label, Box::new(c), inv, Box::new(body)),
                Condition::Chain(c) => ExprKind::WhileLet(label, Box::new(c), inv, Box::new(body)),
            };
            Ok(Expr { kind, span })
        },
        (Tok::Loop, _) => {
            p.bump();
            let inv = loop_invariant(p)?;
            let body = block(p)?;
            let span = start.to(body.span);
            Ok(Expr { kind: ExprKind::Loop(label, inv, Box::new(body)), span })
        },
        _ => Err(p.unexpected("`loop`, `while` or `for` after a label")),
    }
}

/// A loop's `invariant p`, between its head and its body, if it has one:
/// an expression, as a condition is, with no struct literal. A clause may
/// end `where T: Trait`, to be said only where that holds, and there may
/// be several, each after its own `invariant`.
fn loop_invariant(p: &mut Parser) -> Result<Invariant, Error> {
    let mut clauses = List::new();
    while p.eat(Tok::Invariant) {
        let c = p.structs(false, expr)?;
        let c = match p.eat(Tok::Where) {
            true => {
                let guard = types::guard(p)?;
                let span = c.span.to(guard.span);
                Expr { kind: ExprKind::Where(Box::new(c), Box::new(guard)), span }
            },
            false => c,
        };
        clauses.push(c);
    }
    if clauses.len() < 2 {
        return Ok(match clauses.pop() {
            Some(c) => Some(Box::new(c)),
            None => None,
        });
    }
    let first = clauses.first().expect("two clauses").span;
    let last = clauses.last().expect("two clauses").span;
    Ok(Some(Box::new(Expr { kind: ExprKind::Clauses(clauses), span: first.to(last) })))
}

/// `return e`, `break 'a e` or `continue 'a`, where the label is there if
/// a lifetime comes next, and `e` if an expression can start after that.
fn jump(p: &mut Parser) -> Result<Expr, Error> {
    let keyword = p.bump();
    let label = match (keyword.tok, p.peek()) {
        (Tok::Break, Tok::Lifetime(_)) | (Tok::Continue, Tok::Lifetime(_)) => Some(p.lifetime()?),
        _ => None,
    };
    let value = match keyword.tok != Tok::Continue && starts_expr(p.peek()) {
        true => Some(Box::new(expr(p)?)),
        false => None,
    };
    let end = match (&value, &label) {
        (Some(v), _) => v.span,
        (None, Some(l)) => l.span,
        (None, None) => keyword.span,
    };
    let kind = match keyword.tok {
        Tok::Return => ExprKind::Return(value),
        Tok::Break => ExprKind::Break(label, value),
        _ => ExprKind::Continue(label),
    };
    Ok(Expr { kind, span: keyword.span.to(end) })
}

/// `match e { pat => e, .. }`. The `,` after an arm can be left out if it's
/// a block, an `if`, a `match`, a `while` or a `loop`.
fn match_expr(p: &mut Parser) -> Result<Expr, Error> {
    let start = p.expect(Tok::Match)?;
    let scrutinee = p.structs(false, expr)?;
    p.expect(Tok::LBrace)?;
    let mut arms = List::new();
    while p.peek() != Tok::RBrace {
        let pat = patterns::pattern(p)?;
        p.expect(Tok::FatArrow)?;
        let body = p.structs(true, expr)?;
        let block_like = match &body.kind {
            ExprKind::Block(..) | ExprKind::If(..) | ExprKind::Match(..) => true,
            ExprKind::While(..) | ExprKind::Loop(..) => true,
            _ => false,
        };
        arms.push(Arm { pat, body });
        if !p.eat(Tok::Comma) && !block_like && p.peek() != Tok::RBrace {
            return Err(p.unexpected("`,` or `}`"));
        }
    }
    let end = p.expect(Tok::RBrace)?;
    Ok(Expr { kind: ExprKind::Match(Box::new(scrutinee), arms), span: start.to(end) })
}

/// A name followed by `::`: `Shape::Rect(2, 3)`, `Shape::Empty`,
/// `Option::<i64>::None`, `id::<i64>`, `Pair::<i64, bool> { .. }`, or a
/// path that starts with a module: `geometry::origin()`,
/// `crate::a::Point { .. }`. Which of a path's names are modules isn't
/// known yet: `a::f(1)` is read as a variant `f` of an `a`.
fn path_expr(p: &mut Parser) -> Result<Expr, Error> {
    let start = p.span();
    let mut segs = p.segments()?;
    let Segment { name: last, targs, end } = segs.pop().expect("a segment at least");
    if p.peek() == Tok::LBrace && !p.no_struct {
        no_targs(&segs)?;
        let name = joined(&segs, &last);
        return struct_lit(p, name, targs);
    }
    if segs.is_empty() || end.is_some() {
        no_targs(&segs)?;
        let span = match end {
            Some(end) => start.to(end),
            None => start.to(last.span),
        };
        return Ok(Expr { kind: ExprKind::Var(joined(&segs, &last).name, targs), span });
    }
    let Segment { name: ty_name, targs: ty_targs, end: _ } = segs.pop().expect(
        "a segment at least",
    );
    no_targs(&segs)?;
    let ty = joined(&segs, &ty_name);
    let parens = p.eat(Tok::LParen);
    let (args, end) = match parens {
        true => args(p)?,
        false => (List::new(), last.span),
    };
    Ok(Expr { kind: ExprKind::Variant(ty, ty_targs, last, args, parens), span: start.to(end) })
}

/// `Point { x: 1, y }`, from the `{`, after the name and any type
/// arguments.
fn struct_lit(p: &mut Parser, name: Ident, targs: List<TypeExpr>) -> Result<Expr, Error> {
    p.expect(Tok::LBrace)?;
    let (fields, end) = p.structs(true, |p| p.comma_list(Tok::RBrace, field_init))?;
    let span = name.span.to(end);
    Ok(Expr { kind: ExprKind::StructLit(name, targs, fields), span })
}

/// `x: 1` in a struct literal, or `x` alone, for `x: x`.
fn field_init(p: &mut Parser) -> Result<FieldInit, Error> {
    let name = p.ident()?;
    let value = match p.eat(Tok::Colon) {
        true => expr(p)?,
        false => {
            let kind = ExprKind::Var(String::from(name.name.as_str()), List::new());
            Expr { kind, span: name.span }
        },
    };
    Ok(FieldInit { name, value })
}

/// `|x, y: i64| x + y`, `|x| -> i64 { x }` or `|| 1`. As in Rust, the body
/// runs as far right as an expression can, and a return type needs a
/// block after it.
fn lambda(p: &mut Parser) -> Result<Expr, Error> {
    let start = p.span();
    let moves = match p.peek() {
        Tok::Move => Some(p.bump().span),
        _ => None,
    };
    let params = match p.eat(Tok::OrOr) {
        true => List::new(),
        false => {
            p.expect(Tok::Pipe)?;
            let mut n = 0usize;
            let (params, _) = p.comma_list(Tok::Pipe, |p| {
                let param = lambda_param(p, n);
                n = n + 1;
                param
            })?;
            params
        },
    };
    let (ret, body) = match p.eat(Tok::Arrow) {
        true => {
            let ret = types::ty(p)?;
            if p.peek() != Tok::LBrace {
                return Err(p.unexpected("`{` (a closure with a return type needs a block)"));
            }
            (Some(ret), block(p)?)
        },
        false => (None, expr(p)?),
    };
    let span = start.to(body.span);
    Ok(Expr { kind: ExprKind::Lambda(Box::new(Lambda { moves, params, ret, body })), span })
}

/// Closure parameter `n`: a name, maybe `mut`, or a pattern if it's other
/// than a name: `(a, b)`, `Point { x, y }`, `[a, b]`. A name alone is a
/// name, uppercase or not, so that `|X|` gets the error a variable named
/// so does.
fn lambda_param(p: &mut Parser, n: usize) -> Result<LambdaParam, Error> {
    let named = match (p.peek(), p.peek2()) {
        (Tok::Mut, _) => true,
        (Tok::Ident(_), Tok::ColonColon)
        | (Tok::Ident(_), Tok::LBrace)
        | (Tok::Ident(_), Tok::LParen) => false,
        (Tok::Ident(_), _) => true,
        _ => false,
    };
    let (mutable, name, pat) = match named {
        true => {
            let mutable = match p.peek() {
                Tok::Mut => Some(p.bump().span),
                _ => None,
            };
            (mutable, p.variable()?, None)
        },
        false => {
            let pat = patterns::pat_atom(p)?;
            let name = Ident { name: String::of(&f"{{param {n}}}"), span: pat.span };
            (None, name, Some(pat))
        },
    };
    let ty = match p.eat(Tok::Colon) {
        true => Some(types::ty(p)?),
        false => None,
    };
    Ok(LambdaParam { mutable, name, ty, pat })
}
