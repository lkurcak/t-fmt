# Friction: writing `t fmt` in T

Raw notes from the port (2026-11-25/26), to triage into t-lang steps.

## Parser

# Friction: porting t-lang's parser to T

One entry per issue: what I wanted, what T made me write, a repro if it's a
checker problem, and a label (bug / gap / by design / unsure). Most
significant first.

## Generic helpers over closures must spell out every effect (gap)

Rust's parser leans on `comma_list(close, |p| ..)` and `structs(allowed,
Self::expr)`. The draft I resumed had written each out by hand instead
(15 copies of the comma loop, 6 of the save/set/restore of `no_struct`).
Writing them as helpers works, but costs ceremony:

```t
fn comma_list<
    effect e,
    T: Discard,
    F: FnMut(&mut Parser<'a, 's>) -> Result<T, Error> with e + Discard,
>(&mut self, close: Tok, mut item: F) -> Result<(List<T>, Span), Error>
    with {alloc, panic, e} { .. }
```

- Without `effect e`, passing a function that may panic (all of them: `+`
  can overflow) fails: "this function may panic, but `P::flagged` needs
  calls of it to fit `fn(&mut P) -> Result<&str, ()>`, which can't panic".
- Once `with e` is written, inference of the helper's own effects stops,
  and its `List::push` and `+` need `with {alloc, panic, e}` spelled out
  ("`push` may allocate, but `comma_list` doesn't say `with alloc`").
- `F: Discard` and `T: Discard` are needed too (linear by default).

Minimal repro of the first point (`T: Discard` aside):

```t
fn twice<T, F: FnMut() -> T + Discard>(mut f: F) -> (T, T) { (f(), f()) }
fn main() { let mut n = 0u32; let _ = twice(|| { n = n + 1; n }); }
```

"this closure may panic, but `twice` needs calls of it to fit `fn() ->
u32`, which can't panic".

For a private function, inferring "whatever `F` does, plus what my body
does" would make these helpers as cheap to write as in Rust. With the
helpers the parser is ~150 lines shorter and reads like the Rust. Label:
gap.

## Keywords as names (by design, but it bites constantly)

The Rust parser has functions `invariant`, `effect` and a method
`Lit::with`, and a local `sealed`; all are T keywords, so each was a syntax
error far from the definition (`expected a pattern, found 'sealed'` at the
`let`, `expected a name, found 'with'` at the call). Renamed to
`loop_invariant`, `one_effect`, `range_lit` (a free function), `sealed_at`.
The messages are clear enough; it's just a long list to remember (`with`,
`effect`, `invariant`, `sealed`, `law` are ordinary words a compiler
written in T wants as names). Label: by design.

## No match guards (by design, known)

Rust's `Tok::Semi if in_trait || .. =>`, `Tok::LBrace if !path.is_empty()
=>`, `Tok::Ident(n) if n == "allow" =>` became matches on tuples
(`match (p.peek(), path.is_empty())`, `match (p.peek(), bodiless,
intrinsic)`) or `if` chains inside an arm. It works and reads fine for one
condition; with two it gets cryptic (`(Tok::Ident(_), false) | (Tok::Crate,
false) | (Tok::Super, false) => ..` in `generic_param`). String patterns in
a variant, `Tok::Ident("allow")`, do work, which helped. Label: by design.

## Consts can't be patterns (gap)

Wanted `if let Some((_, CMP_PREC)) = next_binop(p) { .. }`. T says
"`CMP_PREC` is a const: a pattern can't name one yet". Wrote a `match` that
binds `next` and compares. The message is good and says what to do.
Label: gap.

**Fixed in t 0.108.0 (step 100):** consts and const parameters of an integer type, `bool`, `char` or `&str` are patterns.

## Can't assign through a call's result (gap)

Wanted `module(prog, i).doc = Some(doc);` (as Rust's
`prog.mods[i].doc = ..`, where `module` returns `&mut ModDecl`). T says
"can't assign to this: only to a variable, a field, or what `*` points
to". Wrote `let m = module(prog, i); m.doc = Some(doc);`. Label: gap.

## A function and a parameter can't share a name (by design, Rust-like)

The draft called `head(p)` inside `fn trait_decl(p, head: Head)`; T says
"`Head` is not a function" (the parameter shadows the function `head`).
Rust has no such clash since there it's a method, `self.head()`. Renamed the
function `read_head`. The message names the type, not the parameter, which
took a moment: "`head` is a parameter of type `Head`, not a function" would
be clearer. Label: unsure (message).

**Message fixed in t 0.108.0 (step 100):** "`head` is a parameter of type `Head`, not a function".

## Elided lifetimes of a `Tok` parameter (unsure)

`fn exprs(p: &mut Parser, close: Tok)` calling `p.expect(close)` where
`expect(&mut self, tok: Tok<'s>)`: "lifetime may not live long enough: this
needs the lifetime of `close` to outlive the lifetime of `p`, and the
signature doesn't say it does". Correct (the `'s` of a `&mut Parser<'a,
's>` is invariant), and fixed by giving `expect` and `eat` a `tok: Tok` of
its own lifetime, which compares fine with `Tok<'s>`. The message says
"the lifetime of `p`", which is ambiguous for a `&mut Parser<'a, 's>`
(which of its three?). Label: unsure (message).

**Message fixed in t 0.108.0 (step 100):** it marks which lifetime, "the lifetime `'1` in the type of `p`, `&mut Parser<'1, '_>`".

## Private types in public signatures (by design)

Making `Parser`'s fields and methods private (children of `parser` see
them anyway, which is nice) also made `struct Parser` private, and then
"`expr_in` is public, but its signature names `Parser`, which is private
to `parser`". The struct stays `pub`, its members private. Clear message.
Label: by design.

## No glob imports (by design)

`use crate::ast::*;` is refused (as t-lang's own parser refuses it). A file
that touches every AST type (a tree dumper I wrote to compare trees with
t-lang's) needs a 29-name import list, and `t fmt` puts each on its own
line. Label: by design.

## Check time

Whole project (`t check main.t`, with the printer as it is now): ~6.1 s.
With the stub printer: ~4.1-4.5 s; with the stub parser too, ~0.7 s, so
the parser's ~3700 lines cost ~3.5 s. No function takes near 2 s; stubbing
one at a time, the slowest are `exprs::block_inner` (~0.45-0.55 s, a long
`loop` with many early `return Err(..)`s), `items::item` (~0.25 s) and
`items::function` (~0.2 s); the rest ~0.1 s or less (noise is ~0.2 s).
Label: fine.

## Printer

# Friction: porting the printer (pretty.rs, doc.rs, trivia.rs, fmt.rs glue) to T

One entry per issue: what I wanted, what T made me write, repro if a checker
problem, label (bug / gap / by design / unsure).

## No `..` in tuple-variant patterns
Wanted `ExprKind::If(..) | ExprKind::Match(..) => ..` (Rust's printer has
~40 of these). T: "syntax error: expected an integer, found `)`". Wrote
every field as `_`: `ExprKind::While(_, _, _, _)`, which breaks each time
a variant gains a field. Label: gap.

**Fixed in t 0.108.0 (step 100):** `..` in variant, tuple and array patterns; the printer now writes `ExprKind::If(..)`.

## Keywords as names, again (`invariant`, `sealed`, `effect`, `with`, `ensures`)
Porting `fn invariant(..)`, `let sealed = ..`, `fn effect(..)`, `let with =
..` and a parameter `ensures` straight from pretty.rs: each is a syntax
error, e.g. "syntax error: expected a pattern, found `sealed`". Renamed to
`loop_invariant`, `seal`, `one_effect`, `has_with`, `posts`. Known (PORTING.md
lists them); the message could say "`sealed` is a keyword". Label: by design
(message: unsure).

**Message fixed in t 0.108.0 (step 100):** "`sealed` is a keyword, so it can't be a name".

## No `+` on documents: `a + b + "x"` is `a.add(b).text("x")`
pretty.rs builds every `Doc` with `+` (an `Add` impl, with `Into<Doc>` for
`&str`/`String`). T has no operator traits, so it's `add` / `text` / `owned`
method chains. Long chains then get laid out badly by `t fmt` itself (no
chain breaking: `.add(\n    Doc::HardLine,\n)`), so I split them into `let`s
to keep the files `t fmt`-clean. Evaluation order is left to right as in
Rust, which matters here (comments are handed out in call order). Label: by
design (no operator overloading).

## Inherent impls only in their type's module
The Rust printer is one `impl Printer` of ~60 methods. T keeps a type's own
methods in its module, so only the shared helpers (`element`, `lead`,
`trailing`, `dangling`, `list`, ..) are methods in `pretty.t`, and the rest
are free functions `fn expr(p: &mut Printer, ..)` in `pretty/{items,exprs,
types}.t`, as the parser does. Fine, just a different shape. Label: by
design.

## Generic `list` with two closures: verbose but worked first time
`list<effect e, effect f, T, S: Fn(&T) -> (usize, usize) with e + Discard,
F: FnMut(&mut Printer<'s>, &T) -> Doc with f + Discard>(..)`: two effect
parameters and two `+ Discard`s for what Rust writes as `impl Fn(&T) ->
(usize, usize)` and `impl FnMut(&mut Self, &T) -> Doc`. But `list` itself
needed no `with` (inferred), and every call site `p.list(.., |a| (a.span.start,
a.span.end), None, |p, a| expr(p, a, 0, ANY))` inferred its closure
parameter types. Label: by design (verbose).

## No let chains in `while let`
Wanted `while let ExprKind::Binary(inner, l, r) = &left.kind && prec(*inner)
== p && ..` (Rust 2024). T: "`&&` can't come at the top of what a `while
let` matches (yet)". Wrote `loop { let ExprKind::Binary(..) = &left.kind else
{ break }; if !(..) { break } .. }`. Clear message. Label: gap.

**Fixed in t 0.108.0 (step 100):** let chains in `if` and `while`.

## No `Clone`: `Doc::dup`, and a flag instead of `..f.clone()`
`Hug` needs each argument's doc twice (Rust clones them): a hand-written
`Doc::dup`. A trait `law fn` is printed from `FnDecl { doc: None, allows:
vec![], ..f.clone() }` in Rust; here `signature` takes a `lead: bool` instead.
Label: by design.

## `usize::MAX`
`p.dangling(usize::MAX, ..)`: T has no `usize::MAX`; it's
`core::num::greatest::<usize>()`, found by grepping core. Label: gap
(discoverability).

## No `join`, `map().collect()`, `matches!`
`names.join(", ")` over a `Vec<String>` built by `map().collect()`: a loop
filling a `List<String>` and a hand-written `join`. `matches!(e.kind, A(..) |
B(..))`: a `match` with `_ => false` (and, with no `..`, every field `_`).
Known from PORTING.md. Label: gap.

## ast.t: string literals keep no value, so `("a\x41")` can't be re-escaped
t-lang prints a literal as the source spells it, but where its expression's
span holds more than the literal (parentheses: `("a\x41")`, `(f"..")`,
`(b"..")`), it writes it from its value, re-escaped: `"aA"`. ast.t keeps no
value for `Str`, `ByteStr` or `FmtPiece::Text`, so the port writes the
source's literal there (`"a\x41"`); integers and chars, which keep values,
match. No corpus file has one. Label: gap (ast.t by design).

## Check time (none slow)
Full `t check main.t` of the project: 5.4-5.9 s (4.2 s before the printer;
the printer's ~2,700 lines add ~1.5 s). No function noticeably slow (all of
pretty/ together is under 2 s). `t build`: ~17.5 s. Label: none.

