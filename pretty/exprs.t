//! Printing expressions and blocks: where they need parentheses, where
//! they break, and the comments between their statements and arms.

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
    FmtAlign,
    FmtKind,
    FmtPiece,
    FmtSpec,
    FmtWidth,
    Invariant,
    Label,
    LetCond,
    Pattern,
    PatternKind,
    Stmt,
};
use crate::error::Span;
use crate::lexer::{char_literal, Tok};
use crate::pretty::doc::{flat, group, nest, render, text, Doc, Hug};
use crate::pretty::items::{decl_name, fn_decl, guard, lead_start, type_decl, type_lead_start};
use crate::pretty::types::{pattern, turbofish, ty};
use crate::pretty::{Ctx, Printer, ANY, BRACES, BRACKETS, PARENS, PIPES};
use crate::text::item;

/// How tightly a binary operator binds, as in the parser.
fn prec(op: BinOp) -> u8 {
    match op {
        BinOp::Or => 1,
        BinOp::And => 2,
        BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => CMP,
        BinOp::Add | BinOp::Sub => 4,
        BinOp::Mul | BinOp::Div | BinOp::Rem => 5,
        // As in the parser, though which comes first of these and the
        // others above needs parentheses: see `nests_in`.
        BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr => 4,
    }
}

/// How tightly comparisons bind, which don't chain: `a < b < c` needs
/// parentheses.
const CMP: u8 = 3;

/// `as`: tighter than any binary operator, looser than a unary one.
const AS: u8 = 6;

/// Binds tighter than any binary operator or `as`: unary operators, calls
/// and everything else.
const UNARY: u8 = 7;

/// Whether `inner` may be an operand of `outer` without parentheses.
/// Comparisons and `&&` and `||` take anything that binds more tightly;
/// arithmetic, by its precedence. But how a bitwise operator or a shift
/// goes with another, or with arithmetic, has no precedence to remember:
/// it's said with parentheses, `(a & b) | c`. A chain of one is fine: `a |
/// b | c`.
fn nests_in(inner: BinOp, outer: BinOp) -> bool {
    if outer.is_bitwise() {
        return inner == outer;
    }
    match outer {
        BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => !inner.is_bitwise(),
        _ => true,
    }
}

/// What `min` an operand `e` of `op` needs: more than any, so
/// parentheses, if it's an operator that can't be `op`'s operand without
/// them (`nests_in`).
fn apart(e: &Expr, op: BinOp, min: u8) -> u8 {
    match e.kind {
        ExprKind::Binary(inner, _, _) => match nests_in(inner, op) {
            true => min,
            false => UNARY + 1,
        },
        _ => min,
    }
}

/// Is `e` an `if`, `match`, loop or block, which ends a statement it
/// starts?
fn block_like(e: &Expr) -> bool {
    match e.kind {
        ExprKind::If(..)
        | ExprKind::IfLet(..)
        | ExprKind::Match(..)
        | ExprKind::While(..)
        | ExprKind::WhileLet(..)
        | ExprKind::Loop(..)
        | ExprKind::For(_)
        | ExprKind::Block(..)
        | ExprKind::Unsafe(_) => true,
        _ => false,
    }
}

/// Does `e` end in a `}` when printed? Then it needs parentheses before
/// the `else` of a `let .. else`, which would otherwise be read as an
/// `if`'s.
fn ends_in_brace(e: &Expr) -> bool {
    if block_like(e) {
        return true;
    }
    match &e.kind {
        ExprKind::StructLit(..) => true,
        ExprKind::Lambda(l) => ends_in_brace(&l.body),
        ExprKind::Binary(_, _, r) | ExprKind::Assign(_, _, r) | ExprKind::Range(_, r) => {
            ends_in_brace(r)
        },
        ExprKind::Unary(_, x) => ends_in_brace(x),
        ExprKind::Return(Some(x)) | ExprKind::Break(_, Some(x)) => ends_in_brace(x),
        _ => false,
    }
}

/// Is `e` an `&&` or `||`, which needs parentheses as what an `if let`,
/// `while let` or `let .. else` matches?
fn chain_like(e: &Expr) -> bool {
    match e.kind {
        ExprKind::Binary(BinOp::And, _, _) | ExprKind::Binary(BinOp::Or, _, _) => true,
        _ => false,
    }
}

/// `'a: ` before a loop, if it has a label.
fn label_doc(label: &Option<Label>) -> Doc {
    match label {
        Some(l) => Doc::Text(String::of(&f"{l.name.name}: ")),
        None => Doc::nil(),
    }
}

/// Is the last of `args` worth breaking inside rather than between the
/// arguments? See `Doc::Hug`.
fn huggable(args: &List<Expr>) -> bool {
    let Some(last) = args.last() else { return false };
    match &last.kind {
        ExprKind::If(..)
        | ExprKind::IfLet(..)
        | ExprKind::Match(..)
        | ExprKind::Block(..)
        | ExprKind::Unsafe(_) => true,
        ExprKind::StructLit(_, _, inits) => !inits.is_empty(),
        ExprKind::Array(items) => !items.is_empty(),
        ExprKind::Lambda(l) => match l.body.kind {
            ExprKind::Block(..) => true,
            _ => false,
        },
        // `f(g(..))`, but not `f(x, g(..))`, which would hide `x` at the end
        // of the line.
        ExprKind::Call(..) | ExprKind::MethodCall(..) => args.len() == 1,
        ExprKind::Variant(_, _, _, inner, _) => args.len() == 1 && !inner.is_empty(),
        _ => false,
    }
}

/// Invariant `inv`, if it has several clauses, or one with a `where`:
/// then it's printed clause by clause (`clauses`).
fn clauses_of(inv: &Invariant) -> Option<&Expr> {
    match inv {
        Some(e) => match e.kind {
            ExprKind::Clauses(_) | ExprKind::Where(..) => Some(&**e),
            _ => None,
        },
        None => None,
    }
}

/// Prints `e`, in parentheses if it binds less tightly than `min`, or if
/// `ctx` needs them.
pub fn expr(p: &mut Printer, e: &Expr, min: u8, ctx: Ctx) -> Doc {
    let own = match e.kind {
        ExprKind::Binary(op, _, _) => prec(op),
        ExprKind::As(..) => AS,
        // A closure's body runs as far right as it can, and so do the
        // value of an assignment, `return` and `break`. Even without a
        // value they need parentheses as an operand: `return - 1`
        // returns `-1`.
        ExprKind::Lambda(_)
        | ExprKind::Assign(..)
        | ExprKind::Return(_)
        | ExprKind::Break(..)
        | ExprKind::Range(..) => 0,
        _ => UNARY,
    };
    let struct_lit = match e.kind {
        ExprKind::StructLit(..) => true,
        _ => false,
    };
    if own < min || (ctx.no_struct && struct_lit) || (ctx.stmt && block_like(e)) {
        return text("(").add(expr_inner(p, e, ANY)).text(")");
    }
    expr_inner(p, e, ctx)
}

/// `e` without parentheses around it.
fn expr_inner(p: &mut Printer, e: &Expr, ctx: Ctx) -> Doc {
    match &e.kind {
        ExprKind::Int(n, None) => p.spelled(e.span, String::of(n)),
        ExprKind::Int(n, Some(t)) => {
            let t = t.name();
            p.spelled(e.span, String::of(&f"{n}{t}"))
        },
        ExprKind::Bool(b) => text(if *b { "true" } else { "false" }),
        ExprKind::Char(c) => p.spelled(e.span, char_literal(*c)),
        ExprKind::Str | ExprKind::ByteStr => p.written(e.span),
        ExprKind::Format(pieces) => match p.quiet {
            false => match p.trivia.spelled(e.span) {
                Some(s) => Doc::Text(s),
                None => Doc::Text(format_literal(p, e.span, pieces)),
            },
            true => Doc::Text(format_literal(p, e.span, pieces)),
        },
        ExprKind::Unit => text("()"),
        ExprKind::Var(name, targs) => text(name.as_str()).add(turbofish(p, targs)),
        ExprKind::Unary(op, x) => text(op.symbol()).add(expr(p, x, UNARY, ctx.inner())),
        ExprKind::As(x, t) => {
            let x = expr(p, x, AS, ctx.inner());
            x.text(" as ").add(ty(p, t))
        },
        ExprKind::Where(x, g) => {
            let x = expr(p, x, 0, ctx);
            x.text(" where ").add(guard(p, g))
        },
        ExprKind::Clauses(clauses) => {
            let mut doc = text("");
            let mut i = 0usize;
            for c in clauses.iter() {
                if i > 0 {
                    doc = doc.text(" invariant ");
                }
                doc = doc.add(expr(p, c, 0, ctx));
                i = i + 1;
            }
            doc
        },
        ExprKind::Binary(op, _, _) => binary(p, e, *op, ctx),
        ExprKind::Call(f, args) => {
            // Something more than a name or a call needs parentheses to
            // be called: `(|x| x)(1)`, and `(s.f)(1)`, as `s.f(1)` is a
            // method call.
            let min = match f.kind {
                ExprKind::Var(..) | ExprKind::Call(..) | ExprKind::MethodCall(..) => UNARY,
                _ => UNARY + 1,
            };
            let callee = expr(p, f, min, ctx);
            callee.add(call_args(p, f.span.end, args))
        },
        ExprKind::Field(x, field) => receiver(p, x, ctx).text(".").text(field.name.as_str()),
        ExprKind::Try(x, _) => receiver(p, x, ctx).text("?"),
        ExprKind::Index(x, i, _, _) => {
            let x = receiver(p, x, ctx);
            x.text("[").add(expr(p, i, 0, ANY)).text("]")
        },
        ExprKind::MethodCall(x, method, targs, args) => {
            let end = match targs.last() {
                Some(t) => t.span.end,
                None => method.span.end,
            };
            let x = receiver(p, x, ctx).text(".").text(method.name.as_str());
            let x = x.add(turbofish(p, targs));
            x.add(call_args(p, end, args))
        },
        ExprKind::If(..) | ExprKind::IfLet(..) => if_chain(p, e),
        ExprKind::While(label, c, inv, body) => {
            let head = label_doc(label).text("while ");
            let head = match clauses_of(inv) {
                Some(inv) => {
                    let c = bare_head(p, c);
                    head.add(c).add(clauses(p, inv))
                },
                None => {
                    let c = head_of(p, c);
                    head.add(c).add(loop_invariant(p, inv))
                },
            };
            group(head.add(block_or_expr(p, body)))
        },
        ExprKind::WhileLet(label, c, inv, body) => {
            let head = label_doc(label).text("while ");
            let head = match clauses_of(inv) {
                Some(inv) => {
                    let c = chain(p, c, true);
                    head.add(c).add(clauses(p, inv))
                },
                None => {
                    let c = chain(p, c, false);
                    head.add(c).add(loop_invariant(p, inv))
                },
            };
            group(head.add(block_or_expr(p, body)))
        },
        ExprKind::Loop(label, inv, body) => {
            let head = match clauses_of(inv) {
                Some(inv) => label_doc(label).text("loop").add(clauses(p, inv)),
                None => label_doc(label).text("loop ").add(loop_invariant(p, inv)),
            };
            group(head.add(block_or_expr(p, body)))
        },
        ExprKind::For(f) => {
            let head = label_doc(&f.label).text("for ").add(pattern(p, &f.pat)).text(" in ");
            let head = match &f.name {
                Some(n) => head.owned(String::of(&f"{n.name}: ")),
                None => head,
            };
            let head = match clauses_of(&f.invariant_) {
                Some(inv) => {
                    let it = bare_head(p, &f.iter);
                    head.add(it).add(clauses(p, inv))
                },
                None => {
                    let it = head_of(p, &f.iter);
                    head.add(it).add(loop_invariant(p, &f.invariant_))
                },
            };
            group(head.add(block_or_expr(p, &f.body)))
        },
        // Its ends bind more tightly than it, whatever they are but an
        // assignment or a closure.
        ExprKind::Range(l, r) => {
            let l = expr(p, l, 1, ctx.inner());
            l.text("..").add(expr(p, r, 1, ctx.inner()))
        },
        ExprKind::Return(value) => jump(p, String::from("return"), value, ctx),
        ExprKind::Break(label, value) => {
            let head = match label {
                Some(l) => String::of(&f"break {l.name}"),
                None => String::from("break"),
            };
            jump(p, head, value, ctx)
        },
        ExprKind::Continue(label) => match label {
            Some(l) => Doc::Text(String::of(&f"continue {l.name}")),
            None => text("continue"),
        },
        ExprKind::Assign(op, place, value) => {
            let op = match op {
                Some(op) => op.symbol(),
                None => "",
            };
            let place = expr(p, place, 1, ctx);
            place.owned(String::of(&f" {op}= ")).add(expr(p, value, 0, ctx.inner()))
        },
        ExprKind::Block(stmts, tail) => group(block(p, stmts, tail, e.span)),
        ExprKind::Unsafe(b) => group(text("unsafe ").add(block_or_expr(p, b))),
        ExprKind::StructLit(name, targs, inits) => {
            let close = e.span.end - 1;
            let fields = p.list(
                BRACES,
                close,
                inits,
                |i| (i.name.span.start, i.value.span.end),
                None,
                |p, init| {
                    let shorthand = match &init.value.kind {
                        ExprKind::Var(v, t) => *v == init.name.name && t.is_empty(),
                        _ => false,
                    };
                    match shorthand {
                        true => text(init.name.name.as_str()),
                        false => {
                            let name = text(init.name.name.as_str()).text(": ");
                            name.add(expr(p, &init.value, 0, ANY))
                        },
                    }
                },
            );
            text(name.name.as_str()).add(turbofish(p, targs)).text(" ").add(fields)
        },
        ExprKind::Variant(t, targs, variant, args, parens) => {
            let head = text(t.name.as_str()).add(turbofish(p, targs));
            let head = head.text("::").text(variant.name.as_str());
            match parens {
                false => head,
                true => head.add(call_args(p, variant.span.end, args)),
            }
        },
        ExprKind::Array(items) => p.list(
            BRACKETS,
            e.span.end - 1,
            items,
            |a| (a.span.start, a.span.end),
            None,
            |p, a| expr(p, a, 0, ANY),
        ),
        ExprKind::Tuple(items) => p.list(
            PARENS,
            e.span.end - 1,
            items,
            |a| (a.span.start, a.span.end),
            None,
            |p, a| expr(p, a, 0, ANY),
        ),
        ExprKind::Repeat(v, n) => {
            let v = text("[").add(expr(p, v, 0, ANY)).text("; ");
            group(v.add(expr(p, n, 0, ANY)).text("]"))
        },
        ExprKind::Match(scrutinee, arms) => {
            let head = text("match ").add(head_of(p, scrutinee));
            let close = e.span.end - 1;
            if arms.is_empty() && !p.comments_before(close) {
                return head.text("{}");
            }
            let open = p.find(scrutinee.span.end, Tok::LBrace);
            let mut body = p.trailing(open + 1);
            let mut i = 0usize;
            for a in arms.iter() {
                let lead = p.element(a.pat.span.start, i == 0);
                let doc = arm(p, a);
                body = body.add(Doc::HardLine).add(lead).add(doc).text(",");
                body = body.add(p.trailing(a.body.span.end));
                i = i + 1;
            }
            for c in p.dangling(close, arms.is_empty()) {
                body = body.add(Doc::HardLine).add(c);
            }
            head.text("{").add(nest(body)).add(Doc::HardLine).text("}")
        },
        ExprKind::Lambda(l) => {
            let params = match l.params.last() {
                None => text("||"),
                Some(last) => {
                    let last_end = match &last.ty {
                        Some(t) => t.span.end,
                        None => last.name.span.end,
                    };
                    let close = p.find(last_end, Tok::Pipe);
                    p.list(
                        PIPES,
                        close,
                        &l.params,
                        |x| {
                            let end = match &x.ty {
                                Some(t) => t.span.end,
                                None => x.name.span.end,
                            };
                            let start = match x.mutable {
                                Some(m) => m.start,
                                None => x.name.span.start,
                            };
                            (start, end)
                        },
                        None,
                        |p, x| {
                            let name = match (&x.pat, x.mutable) {
                                (Some(pat), _) => lambda_pattern(p, pat),
                                (None, Some(_)) => Doc::Text(String::of(&f"mut {x.name.name}")),
                                (None, None) => text(x.name.name.as_str()),
                            };
                            match &x.ty {
                                Some(t) => name.text(": ").add(ty(p, t)),
                                None => name,
                            }
                        },
                    )
                },
            };
            let params = match l.moves {
                Some(_) => text("move ").add(params),
                None => params,
            };
            match &l.ret {
                Some(t) => {
                    let ret = ty(p, t);
                    params.text(" -> ").add(ret).text(" ").add(expr(p, &l.body, 0, ANY))
                },
                None => params.text(" ").add(expr(p, &l.body, 0, ctx.inner())),
            }
        },
    }
}

/// A closure's parameter written as a pattern: alternatives in
/// parentheses, so their `|` isn't the closure's.
fn lambda_pattern(p: &mut Printer, pat: &Pattern) -> Doc {
    match pat.kind {
        PatternKind::Or(_) => text("(").add(pattern(p, pat)).text(")"),
        _ => pattern(p, pat),
    }
}

/// `return`, or `break` with its label, `head`, and its value if it has
/// one.
fn jump(p: &mut Printer, head: String, value: &Option<Box<Expr>>, ctx: Ctx) -> Doc {
    match value {
        Some(v) => Doc::Text(head).text(" ").add(expr(p, v, 0, ctx.inner())),
        None => Doc::Text(head),
    }
}

/// A run of binary operators that bind equally tightly, like
/// `a + b - c`, breaks before each operator, all or none:
///
/// ```text
/// a
///     + b
///     - c
/// ```
///
/// `op` is `e`'s operator.
fn binary(p: &mut Printer, e: &Expr, op: BinOp, ctx: Ctx) -> Doc {
    let level = prec(op);
    // Collect the run down its left side: ((a + b) - c) is a, b, c.
    let mut rights: List<(BinOp, &Expr)> = List::new();
    let mut left = e;
    loop {
        let ExprKind::Binary(inner, l, r) = &left.kind else { break };
        if prec(*inner) != level || !nests_in(*inner, op) || (level == CMP && !rights.is_empty()) {
            break;
        }
        rights.push((*inner, &**r));
        left = &**l;
    }
    // Left-associative, so the right side must bind tighter, and so must
    // the left side of a comparison, as they don't chain. `&&` inside
    // `||` gets parentheses, though it needn't: `(a && b) || c`.
    let min = match (op, level == CMP) {
        (BinOp::Or, _) => prec(BinOp::And) + 1,
        (_, true) => level + 1,
        _ => level,
    };
    let first = expr(p, left, apart(left, op, min), ctx);
    let mut rest = Doc::nil();
    let inner = ctx.inner();
    let mut i = rights.len();
    while i > 0 {
        i = i - 1;
        let (op, r) = *item(&rights, i);
        let min = if op == BinOp::Or { min } else { level + 1 };
        let right = expr(p, r, apart(r, op, min), inner);
        rest = rest.add(Doc::Line).text(op.symbol()).text(" ").add(right);
    }
    group(first.add(nest(rest)))
}

/// What's before the `.` of a field or method call, in parentheses if
/// it binds less tightly than the `.`, or would be hard to read without
/// them: `(*r).x`, `(a + b).len()`, `(P { x: 1 }).x`.
fn receiver(p: &mut Printer, x: &Expr, ctx: Ctx) -> Doc {
    let min = match x.kind {
        ExprKind::Unary(..)
        | ExprKind::StructLit(..)
        | ExprKind::Block(..)
        | ExprKind::Unsafe(_)
        | ExprKind::If(..)
        | ExprKind::IfLet(..)
        | ExprKind::Match(..)
        | ExprKind::While(..)
        | ExprKind::WhileLet(..)
        | ExprKind::Loop(..)
        | ExprKind::For(_) => UNARY + 1,
        _ => UNARY,
    };
    expr(p, x, min, ctx)
}

/// Call arguments, after the callee or variant that ends at `after`.
fn call_args(p: &mut Printer, after: usize, args: &List<Expr>) -> Doc {
    let last = match args.last() {
        Some(a) => Some(a.span.end),
        None => None,
    };
    let close = p.close(after, last, Tok::RParen);
    if p.comments_before(close) || !huggable(args) {
        return p.list(
            PARENS,
            close,
            args,
            |a| (a.span.start, a.span.end),
            None,
            |p, a| expr(p, a, 0, ANY),
        );
    }
    let mut docs = List::new();
    for a in args.iter() {
        docs.push(expr(p, a, 0, ANY));
    }
    let mut indexes = List::new();
    let mut i = 0usize;
    while i < args.len() {
        indexes.push(i);
        i = i + 1;
    }
    let normal = p.list(
        PARENS,
        close,
        &indexes,
        |i| (item(args, *i).span.start, item(args, *i).span.end),
        None,
        |_, i| item(&docs, *i).dup(),
    );
    let last = docs.pop().expect("an argument");
    let mut prefix = text("(");
    for d in docs {
        prefix = prefix.add(d.text(", "));
    }
    Doc::Hug(Box::new(Hug { normal, prefix, last, close: text(")") }))
}

/// `if a { .. } else if b { .. } else { .. }`, in one group: all on one
/// line, or every block broken.
fn if_chain(p: &mut Printer, e: &Expr) -> Doc {
    let mut doc = Doc::nil();
    let mut e = e;
    loop {
        let (head, then, els) = match &e.kind {
            ExprKind::If(c, then, els) => (head_of(p, c), then, els),
            ExprKind::IfLet(c, then, els) => (chain(p, c, false), then, els),
            _ => {
                doc = doc.add(block_or_expr(p, e));
                break;
            },
        };
        doc = doc.text("if ").add(head);
        doc = doc.add(block_or_expr(p, then));
        match els {
            None => break,
            Some(els) => {
                doc = doc.text(" else ");
                e = els;
            },
        }
    }
    group(doc)
}

/// The head of an `if` or `match`, and the space before its `{`. If it's
/// a run of operators that has to break, the `{` goes on a line of its
/// own, so the head doesn't run into the block:
///
/// ```text
/// if aaaa
///     || bbbb
/// {
/// ```
fn head_of(p: &mut Printer, e: &Expr) -> Doc {
    match bare_head(p, e) {
        Doc::Group(d, _) => group((*d).add(Doc::Line)),
        d => d.text(" "),
    }
}

/// `e` before a block, as `head_of` prints it, without the space after.
fn bare_head(p: &mut Printer, e: &Expr) -> Doc {
    expr(p, e, 0, Ctx { no_struct: true, stmt: false })
}

/// The clauses of invariant `inv`, which has several or one with a
/// `where`, after a loop's head and before its body: all on the
/// head's line, or else each on a line of its own, and the body's `{`
/// on the next.
fn clauses(p: &mut Printer, inv: &Expr) -> Doc {
    let mut doc = Doc::nil();
    match &inv.kind {
        ExprKind::Clauses(cs) => {
            for c in cs.iter() {
                doc = doc.add(Doc::Line).text("invariant ").add(clause(p, c));
            }
        },
        _ => doc = doc.add(Doc::Line).text("invariant ").add(clause(p, inv)),
    }
    group(nest(doc).add(Doc::Line))
}

/// A clause of an invariant, with its `where` if it has one.
fn clause(p: &mut Printer, c: &Expr) -> Doc {
    match &c.kind {
        ExprKind::Where(x, g) => {
            let x = bare_head(p, x);
            x.text(" where ").add(guard(p, g))
        },
        _ => bare_head(p, c),
    }
}

/// A loop's `invariant p `, with the space before the `{`, if it has
/// one.
fn loop_invariant(p: &mut Printer, inv: &Invariant) -> Doc {
    match inv {
        Some(x) => text("invariant ").add(head_of(p, x)),
        None => text(""),
    }
}

/// `let pat = e ` after an `if` or `while`, with the space before the
/// `{`, or without it, if `bare`. An `&&` or `||` there has to be in
/// parentheses.
/// The conditions of a chain after an `if` or `while`, with the space
/// before the `{`, or without it, if `bare`: as `let_cond` prints a `let`
/// alone, and several as `&&`'s operands, each on a line of its own if
/// they don't fit on one, and then the `{` on the next.
fn chain(p: &mut Printer, c: &Chain, bare: bool) -> Doc {
    if c.conds.len() == 1 {
        if let Cond::Let(l) = item(&c.conds, 0) {
            return let_cond(p, l, bare);
        }
    }
    let ctx = Ctx { no_struct: true, stmt: false };
    let min = prec(BinOp::And) + 1;
    let mut first = Doc::nil();
    let mut rest = Doc::nil();
    let mut i = 0;
    while i < c.conds.len() {
        let d = match item(&c.conds, i) {
            Cond::Let(l) => {
                let value = expr(p, &l.expr, min, ctx);
                text("let ").add(pattern(p, &l.pat)).text(" = ").add(value)
            },
            Cond::Bool(e) => expr(p, e, min, ctx),
        };
        if i == 0 {
            first = d;
        } else {
            rest = rest.add(Doc::Line).text("&& ").add(d);
        }
        i = i + 1;
    }
    match bare {
        true => group(first.add(nest(rest))),
        false => group(first.add(nest(rest)).add(Doc::Line)),
    }
}

fn let_cond(p: &mut Printer, c: &LetCond, bare: bool) -> Doc {
    let head = match (chain_like(&c.expr), bare) {
        (true, false) => text("(").add(expr_inner(p, &c.expr, ANY)).text(") "),
        (true, true) => text("(").add(expr_inner(p, &c.expr, ANY)).text(")"),
        (false, false) => head_of(p, &c.expr),
        (false, true) => bare_head(p, &c.expr),
    };
    text("let ").add(pattern(p, &c.pat)).text(" = ").add(head)
}

/// The block of an `if` or `else`, ungrouped so that the `if` decides
/// for all its blocks at once.
fn block_or_expr(p: &mut Printer, e: &Expr) -> Doc {
    match &e.kind {
        ExprKind::Block(stmts, tail) => block(p, stmts, tail, e.span),
        _ => expr(p, e, 0, ANY),
    }
}

/// Where statement `s` starts, comments and attributes and all, and where
/// it ends.
fn stmt_span(p: &Printer, s: &Stmt) -> (usize, usize) {
    match s {
        Stmt::Let(l) => {
            let end = match (&l.els, &l.init, &l.ty) {
                (Some(els), _, _) => els.span.end,
                (None, Some(init), _) => init.span.end,
                (None, None, Some(t)) => t.span.end,
                (None, None, None) => l.pat.span.end,
            };
            (p.before(l.pat.span.start), end)
        },
        Stmt::Expr(e) => (e.span.start, e.span.end),
        Stmt::BlockLike(e) => (e.span.start, e.span.end),
        Stmt::Fn(f) => (lead_start(&f.doc, &f.allows, f.span.start), f.span.end),
        Stmt::Type(d) => {
            let name = decl_name(d).span;
            let start = type_lead_start(d, p.before(name.start));
            (start, p.find(name.end, Tok::RBrace) + 1)
        },
    }
}

/// A block, which can go on one line if it's only an expression, and
/// that isn't a block itself: `{ x + 1 }`, but not `{ let y = x; y }`
/// or `{ if c { 1 } else { 2 } }`.
fn block(p: &mut Printer, stmts: &List<Stmt>, tail: &Option<Box<Expr>>, span: Span) -> Doc {
    let close = span.end - 1;
    if stmts.is_empty() && tail.is_none() && !p.comments_before(close) {
        return text("{}");
    }
    let soft = match tail {
        Some(t) => stmts.is_empty() && !block_like(t),
        None => false,
    };
    let mut body = p.trailing(span.start + 1);
    let mut i = 0usize;
    for s in stmts.iter() {
        let (start, end) = stmt_span(p, s);
        body = body.add(line(soft)).add(p.element(start, i == 0));
        let doc = match s {
            Stmt::Let(l) => {
                let t = match &l.ty {
                    Some(t) => text(": ").add(ty(p, t)),
                    None => Doc::nil(),
                };
                let head = text("let ").add(pattern(p, &l.pat)).add(t);
                match (&l.init, &l.els) {
                    (Some(init), Some(els)) => {
                        let init = match ends_in_brace(init) || chain_like(init) {
                            true => text("(").add(expr_inner(p, init, ANY)).text(")"),
                            false => expr(p, init, 0, ANY),
                        };
                        let head = head.text(" = ").add(init).text(" else ");
                        group(head.add(block_or_expr(p, els))).text(";")
                    },
                    (Some(init), None) => head.text(" = ").add(expr(p, init, 0, ANY)).text(";"),
                    (None, _) => head.text(";"),
                }
            },
            Stmt::Expr(e) => statement(p, e).text(";"),
            Stmt::BlockLike(e) => expr(p, e, 0, ANY),
            Stmt::Fn(f) => fn_decl(p, f),
            Stmt::Type(d) => type_decl(p, d),
        };
        body = body.add(doc).add(p.trailing(end));
        i = i + 1;
    }
    if let Some(t) = tail {
        body = body.add(line(soft)).add(p.element(t.span.start, stmts.is_empty()));
        body = body.add(statement(p, t)).add(p.trailing(t.span.end));
    }
    for c in p.dangling(close, stmts.is_empty() && tail.is_none()) {
        body = body.add(Doc::HardLine).add(c);
    }
    text("{").add(nest(body)).add(line(soft)).text("}")
}

/// Where a block breaks: where it may, if it's only an expression that
/// isn't a block, and else always.
fn line(soft: bool) -> Doc {
    match soft {
        true => Doc::Line,
        false => Doc::HardLine,
    }
}

/// `e` at the start of a statement, where an `if`, `match` or block
/// ends the statement.
fn statement(p: &mut Printer, e: &Expr) -> Doc {
    expr_inner(p, e, Ctx { no_struct: false, stmt: true })
}

/// `pat => body`, an arm of a `match`.
fn arm(p: &mut Printer, a: &Arm) -> Doc {
    let pat = pattern(p, &a.pat);
    pat.text(" => ").add(expr(p, &a.body, 0, ANY))
}

/// Format string `pieces`, at `span`, as written, but for spacing:
/// `f"x = {p.x:?}"`. A hole's expression is on one line, as a format
/// string is. Its text is the source's: t-lang writes it from what it
/// means, which the tree doesn't keep, so this differs from t-lang's where
/// they differ, as `\x41` against `A`.
fn format_literal(p: &mut Printer, span: Span, pieces: &List<FmtPiece>) -> String {
    let token = p.trivia.fstring(span);
    let mut out = String::from("f\"");
    let mut at = token.start + 2;
    let mut i = 0usize;
    for piece in pieces.iter() {
        match piece {
            FmtPiece::Text => {
                let to = match pieces.get(i + 1) {
                    Some(FmtPiece::Hole(h)) => h.span.start,
                    _ => token.end - 1,
                };
                out.push_str(p.trivia.source(at, to));
            },
            FmtPiece::Hole(h) => {
                let quiet = p.quiet;
                p.quiet = true;
                let doc = expr(p, &h.value, 0, ANY);
                p.quiet = quiet;
                let one_line = match flat(&doc) {
                    Some(d) => render(&d),
                    None => {
                        let rendered = render(&doc);
                        let mut words = String::new();
                        for w in rendered.as_str().split_whitespace() {
                            if !words.is_empty() {
                                words.push(' ');
                            }
                            words.push_str(w);
                        }
                        words
                    },
                };
                out.push('{');
                out.push_str(one_line.as_str().trim_end());
                out.push_str(suffix(&h.spec).as_str());
                out.push('}');
                at = h.span.end;
            },
        }
        i = i + 1;
    }
    out.push('"');
    out
}

/// What's written after a hole's `:`, with the `:`, if anything.
fn suffix(spec: &FmtSpec) -> String {
    let mut out = String::new();
    if let Some(pad) = &spec.pad {
        if let Some(c) = pad.fill {
            out.push(c);
        }
        out.push(match pad.align {
            FmtAlign::Left => '<',
            FmtAlign::Center => '^',
            FmtAlign::Right => '>',
        });
        match &pad.width {
            FmtWidth::Lit(n) => out.push_str(String::of(n).as_str()),
            FmtWidth::Var(w) => {
                out.push_str(w.as_str());
                out.push('$');
            },
        }
    }
    match spec.kind {
        FmtKind::Display => {},
        FmtKind::Debug => out.push('?'),
        FmtKind::Hex(0) => out.push('x'),
        FmtKind::Hex(n) => out.push_str(String::of(&f"0{n}x").as_str()),
        FmtKind::Dec(n) => out.push_str(String::of(&f"0{n}").as_str()),
    }
    match out.is_empty() {
        true => out,
        false => String::of(&f":{out}"),
    }
}

/// The text of an expression on one line, if it fits, as t-lang shows one
/// in a derive's `where` clause: with no comments.
pub fn expr_text(p: &mut Printer, e: &Expr) -> String {
    let quiet = p.quiet;
    p.quiet = true;
    let doc = expr(p, e, 0, ANY);
    p.quiet = quiet;
    String::from(render(&doc).as_str().trim_end())
}
