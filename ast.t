//! The syntax tree the parser makes and the printer prints: t-lang's
//! `src/ast.rs`, with what only the checker needs left out (node ids,
//! measures, packages, a closure's captures). Names are `String`s, not
//! slices of the source, since a path's is joined, `a::b`; spans are kept,
//! as the printer finds comments and blank lines by them.
//!
//! Where t-lang marks generic parameters by node id (`effects`,
//! `unsized_`, `consts`), each parameter here says its kind (`TypeParam`).
//! A literal's value is kept where the parser needs it, and not otherwise:
//! the printer writes literals as the source spells them.

use alloc::boxed::Box;
use alloc::list::List;
use alloc::string::String;

use crate::error::Span;

/// The root module's index in `Program::mods`.
pub const ROOT: usize = 0;

/// A file, parsed: its modules (the root first, then those written in it,
/// `mod m { .. }` or `mod m;`), and each module's items, which say which
/// module they're in by its index in `mods`. Each kind of item is in the
/// order it's written.
#[derive(Discard)]
pub struct Program {
    pub mods: List<ModDecl>,
    pub uses: List<UseDecl>,
    pub types: List<TypeDecl>,
    pub traits: List<TraitDecl>,
    pub impls: List<ImplDecl>,
    pub fns: List<FnDecl>,
    /// Doc comments that document nothing.
    pub stray_docs: List<DocComment>,
}

/// A run of `///` (or `//!`) lines.
#[derive(Discard)]
pub struct DocComment {
    pub lines: List<DocLine>,
    /// `//!`: it documents the module it's in.
    pub inner: bool,
}

/// A doc comment line: the text after its `///` or `//!`, and where the
/// whole line is.
#[derive(Discard)]
pub struct DocLine { pub text: String, pub span: Span }

/// `#[allow(a, b)]` or `#[warn(a)]`.
#[derive(Discard)]
pub struct Allow {
    pub span: Span,
    pub lints: List<Ident>,
    /// `warn` rather than `allow`.
    pub warn: bool,
}

#[derive(Copy, Discard, Eq)]
pub enum Vis {
    Private,
    /// `pub`, where the keyword is.
    Pub(Span),
    /// `export`, where the keyword is.
    Export(Span),
}

/// `mod name { .. }`, or `mod name;` in a file of its own. The root
/// module, `mods[ROOT]`, has an empty name and no parent.
#[derive(Discard)]
pub struct ModDecl {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    /// `#![allow(..)]` at the start of the module.
    pub inner_allows: List<Allow>,
    pub span: Span,
    pub name: Ident,
    pub parent: Option<usize>,
    pub vis: Vis,
    /// `mod name;`: its items are in a file of their own.
    pub in_file: bool,
}

/// `use a::b::{c, d as e};`
#[derive(Discard)]
pub struct UseDecl {
    pub span: Span,
    pub module: usize,
    pub vis: Vis,
    pub tree: UseTree,
}

/// `a::b`, `a::b as c` or `a::{..}`.
#[derive(Discard)]
pub struct UseTree {
    pub path: List<Ident>,
    pub kind: UseKind,
    pub span: Span,
}

#[derive(Discard)]
pub enum UseKind {
    /// The last name of the path, `as` another if that's there.
    Name(Option<Ident>),
    /// `::{a, b}` after the path.
    Group(List<UseTree>),
}

#[derive(Discard)]
pub enum TypeDecl {
    Struct(StructDecl),
    Enum(EnumDecl),
    Alias(AliasDecl),
}

/// `<'a, 'b: 'a, T: Show + 'a, effect e, unsized D, const N: usize>` after
/// the name of a function, struct or enum, or after `impl`; and a
/// function's or impl's `where` clause.
#[derive(Discard)]
pub struct Generics {
    /// With their `'`: `'a`.
    pub lifetimes: List<Ident>,
    /// Type, effect, `unsized` and const parameters, in order.
    pub types: List<TypeParam>,
    /// `'b: 'a` and `T: Show + 'a`, in the order written, each with what's
    /// before its `:` and the lifetimes and traits after it.
    pub bounds: List<Bound>,
    /// From the `<` to the `>`, if they're there.
    pub span: Option<Span>,
    /// `where Self: Discard, I::Item: Eq`.
    pub wheres: List<WhereBound>,
    /// From the `where` to the end of its last bound, if it's there.
    pub where_span: Option<Span>,
}

/// A type parameter and its kind.
#[derive(Discard)]
pub struct TypeParam { pub name: Ident, pub kind: ParamKind }

#[derive(Discard)]
pub enum ParamKind {
    /// `T`
    Type,
    /// `effect e`
    Effect,
    /// `unsized D`
    Unsized,
    /// `const N: usize`, with the type after the `:`.
    Const(TypeExpr),
}

/// `T: Show + 'a` or `'b: 'a` in a list of generic parameters.
#[derive(Discard)]
pub struct Bound { pub subject: Ident, pub items: List<BoundItem> }

/// `I::Item: Eq` in a `where` clause.
#[derive(Discard)]
pub struct WhereBound { pub subject: TypeExpr, pub items: List<BoundItem> }

/// What's after a `:` in a bound: a lifetime, or a trait, maybe saying
/// something of its associated types, as in `Iter<Item = i64>` or
/// `Iter<Item: Discard>`, or `Fn(i64) -> i64 with e`.
#[derive(Discard)]
pub struct BoundItem {
    pub name: Ident,
    pub assoc: List<AssocBound>,
    /// `Fn(A, B) -> R`: the parameters, and the result if it's written.
    pub sig: Option<FnSig>,
    /// `with ..` after a `Fn(..)` bound.
    pub effects: Option<EffectSet>,
    pub span: Span,
}

#[derive(Discard)]
pub struct FnSig { pub params: List<TypeExpr>, pub ret: Option<Box<TypeExpr>> }

/// `Item = i64`, `Item: Discard + Eq` or `e = {panic}` in a bound.
#[derive(Discard)]
pub struct AssocBound { pub name: Ident, pub kind: AssocBoundKind }

#[derive(Discard)]
pub enum AssocBoundKind {
    Eq(TypeExpr),
    Bounds(List<Ident>),
    Effects(EffectSet),
}

/// `#[derive(A, B where T: C)]`
#[derive(Discard)]
pub struct Derive {
    pub span: Span,
    pub names: List<Ident>,
    /// For each of `names`, its `where`, if it has one.
    pub wheres: List<Option<Where>>,
}

/// `where T: Copy, U: Eq` in a derive.
#[derive(Discard)]
pub struct Where { pub span: Span, pub bounds: List<Bound> }

#[derive(Discard)]
pub struct StructDecl {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    pub span: Span,
    pub module: usize,
    pub vis: Vis,
    pub name: Ident,
    pub generics: Generics,
    pub derives: List<Derive>,
    pub fields: List<Param>,
    /// `#[intrinsic]`, where it's written.
    pub intrinsic: Option<Span>,
}

/// `type Name<T> = Type;`
#[derive(Discard)]
pub struct AliasDecl {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    pub span: Span,
    pub module: usize,
    pub vis: Vis,
    pub name: Ident,
    pub generics: Generics,
    pub ty: TypeExpr,
}

#[derive(Discard)]
pub struct EnumDecl {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    pub span: Span,
    pub module: usize,
    pub vis: Vis,
    pub name: Ident,
    pub generics: Generics,
    pub derives: List<Derive>,
    pub variants: List<Variant>,
}

/// A piece of a format string: text, or a hole.
#[derive(Discard)]
pub enum FmtPiece {
    /// Text. What it means isn't kept: the printer writes the source's.
    Text,
    Hole(FmtHole),
}

/// `{value:spec}`, with `width` the expression of the variable a `w$`
/// width names.
#[derive(Discard)]
pub struct FmtHole {
    pub value: Expr,
    pub spec: FmtSpec,
    pub width: Option<Box<Expr>>,
    pub span: Span,
}

/// How a hole is written: `Display`, `?`, `x`, `08x`, `05`, and maybe a
/// fill, a side and a width.
#[derive(Discard)]
pub struct FmtSpec { pub kind: FmtKind, pub pad: Option<FmtPad> }

#[derive(Copy, Discard, Eq)]
pub enum FmtKind {
    Display,
    Debug,
    /// `x`, or `08x` with at least that many digits.
    Hex(usize),
    /// `05`: decimal, with at least that many characters.
    Dec(usize),
}

#[derive(Discard)]
pub struct FmtPad { pub fill: Option<char>, pub align: FmtAlign, pub width: FmtWidth }

#[derive(Copy, Discard, Eq)]
pub enum FmtAlign { Left, Center, Right }

#[derive(Discard)]
pub enum FmtWidth {
    Lit(usize),
    /// `w$`: the variable's name.
    Var(String),
}

#[derive(Discard)]
pub struct Variant {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    pub span: Span,
    pub name: Ident,
    pub fields: List<TypeExpr>,
}

/// A function, method, `const` or `static` item: a `const` is a function
/// with no parameters whose body is its value, `konst` saying where its
/// keyword is.
#[derive(Discard)]
pub struct FnDecl {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    pub span: Span,
    pub module: usize,
    pub vis: Vis,
    pub name: Ident,
    pub generics: Generics,
    pub params: List<Param>,
    /// From the `(` to the `)` of the parameters.
    pub parens: Span,
    pub ret: TypeExpr,
    /// `with {..}`, if it's written.
    pub effects: Option<EffectSet>,
    pub body: Expr,
    /// `#[intrinsic]`
    pub intrinsic: Option<Span>,
    /// `#[measure]`
    pub measure: Option<Span>,
    /// `ensures p, q`
    pub ensures_: List<Expr>,
    /// `#[test]` or `#[test(panics)]`
    pub test: Option<Test>,
    /// `#[blame_caller]`
    pub blame_caller: Option<Span>,
    /// `const`: where the keyword is.
    pub konst: Option<Span>,
    /// `static` rather than `const`.
    pub is_static: bool,
    /// `extern fn`
    pub ext: Option<Extern>,
}

/// `extern fn`: where `extern` is, and whether it's an import (no body).
#[derive(Copy, Discard)]
pub struct Extern { pub span: Span, pub import: bool }

#[derive(Copy, Discard)]
pub struct Test { pub span: Span, pub panics: bool }

#[derive(Discard)]
pub struct TraitDecl {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    pub intrinsic: Option<Span>,
    /// `sealed trait`: where `sealed` is.
    pub sealed_: Option<Span>,
    pub span: Span,
    pub module: usize,
    pub vis: Vis,
    pub name: Ident,
    pub supers: List<Ident>,
    pub assoc: List<AssocDecl>,
    pub effects: List<EffectDecl>,
    pub methods: List<TraitMethod>,
    pub laws: List<Law>,
}

/// `law fn ..;` in a trait: where `law` is, and the function.
#[derive(Discard)]
pub struct Law { pub law_: Span, pub decl: FnDecl }

/// `type Item: Bound;` in a trait.
#[derive(Discard)]
pub struct AssocDecl {
    pub doc: Option<DocComment>,
    pub span: Span,
    pub name: Ident,
    pub bounds: List<Ident>,
}

/// `type Item = i64;` in an impl.
#[derive(Discard)]
pub struct AssocDef {
    pub doc: Option<DocComment>,
    pub span: Span,
    pub name: Ident,
    pub ty: TypeExpr,
}

/// `effect e;` in a trait.
#[derive(Discard)]
pub struct EffectDecl { pub doc: Option<DocComment>, pub span: Span, pub name: Ident }

/// `effect e = {..};` in an impl.
#[derive(Discard)]
pub struct EffectDef {
    pub doc: Option<DocComment>,
    pub span: Span,
    pub name: Ident,
    pub effects: EffectSet,
}

/// `with {panic, alloc}`, `with e`, or `{..}` where a set is written alone.
#[derive(Discard)]
pub struct EffectSet {
    pub items: List<Effect>,
    pub span: Span,
    /// Written after `with`.
    pub with_: bool,
}

/// `unless T: Bound` after an effect.
#[derive(Discard)]
pub struct Guard { pub subject: TypeExpr, pub bound: BoundItem, pub span: Span }

#[derive(Discard)]
pub struct Effect {
    pub kind: EffectKind,
    pub span: Span,
    /// `panic unless I: BoundedIterator`
    pub unless: Option<Box<Guard>>,
    /// `panic if n == 0`
    pub cond: Option<Box<Expr>>,
}

#[derive(Discard)]
pub enum EffectKind {
    /// `panic`, `alloc`, `e`.
    Named(Ident),
    /// `I::e` or `<T as Trait>::e`.
    Proj(Box<TypeExpr>, Option<Ident>, Ident),
}

/// A method of a trait: with a default body, `provided`, or none.
#[derive(Discard)]
pub struct TraitMethod { pub decl: FnDecl, pub provided: bool }

#[derive(Discard)]
pub struct ImplDecl {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    pub span: Span,
    pub module: usize,
    pub generics: Generics,
    /// `unsafe impl`: where `unsafe` is.
    pub unsafe_: Option<Span>,
    pub trait_name: Option<Ident>,
    pub self_ty: TypeExpr,
    pub assoc: List<AssocDef>,
    pub effects: List<EffectDef>,
    pub methods: List<FnDecl>,
}

/// A function's parameter, or a struct's field.
#[derive(Discard)]
pub struct Param {
    pub doc: Option<DocComment>,
    pub allows: List<Allow>,
    /// `mut`: where it's written.
    pub mutable: Option<Span>,
    pub vis: Vis,
    pub name: Ident,
    pub ty: TypeExpr,
}

#[derive(Discard)]
pub struct Ident { pub name: String, pub span: Span }

#[derive(Discard)]
pub struct TypeExpr { pub kind: TypeExprKind, pub span: Span }

#[derive(Discard)]
pub enum TypeExprKind {
    /// `i64`, `Point`, `Option<T>`, `a::B<'a, T>`
    Named(String, List<TypeExpr>),
    /// `()`
    Unit,
    /// `(A, B)`
    Tuple(List<TypeExpr>),
    /// `fn(A) -> B with e`
    Fn(List<TypeExpr>, Box<TypeExpr>, Option<EffectSet>),
    /// `&'a mut T`: the lifetime, whether it's `mut`, and `T`.
    Ref(Option<Ident>, bool, Box<TypeExpr>),
    /// `[T]`
    Slice(Box<TypeExpr>),
    /// `[T; N]`
    Array(Box<TypeExpr>, Box<TypeExpr>),
    /// A length, `3`, in `[T; 3]` or as a type argument.
    Nat(u64),
    /// `'a` as a type argument.
    Lifetime(String),
    /// `!`
    Never,
    /// `T::Item` or `<T as Trait>::Item`.
    Proj(Box<TypeExpr>, Option<Ident>, Ident),
    /// `impl Iterator<Item = u8>` in a return type.
    Impl(List<BoundItem>),
    /// `{ v: T | p }`
    Refined(Ident, Box<TypeExpr>, Box<Expr>),
}

#[derive(Discard)]
pub struct Expr { pub kind: ExprKind, pub span: Span }

#[derive(Discard)]
pub enum ExprKind {
    /// An integer literal, `42`, or a byte literal, `b'a'`, which is a `u8`.
    Int(u64, Option<IntTy>),
    Bool(bool),
    Char(char),
    /// `"hi"`
    Str,
    /// `b"hi"`
    ByteStr,
    /// `f"x = {x}"`
    Format(List<FmtPiece>),
    Unit,
    /// `x`, or `id::<i64>` with type arguments.
    Var(String, List<TypeExpr>),
    Unary(UnOp, Box<Expr>),
    /// `x as u8`
    As(Box<Expr>, Box<TypeExpr>),
    /// `p where T: Trait`, a clause of a loop's invariant.
    Where(Box<Expr>, Box<Guard>),
    /// `invariant p invariant q`: the clauses, as written.
    Clauses(List<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    Call(Box<Expr>, List<Expr>),
    /// `x.m::<T>(a, b)`
    MethodCall(Box<Expr>, Ident, List<TypeExpr>, List<Expr>),
    /// `if c { .. } else { .. }`
    If(Box<Expr>, Box<Expr>, Option<Box<Expr>>),
    /// `if let p = e { .. } else { .. }`
    IfLet(Box<LetCond>, Box<Expr>, Option<Box<Expr>>),
    /// `[a, b, c]`
    Array(List<Expr>),
    /// `(a, b)`
    Tuple(List<Expr>),
    /// `[v; n]`
    Repeat(Box<Expr>, Box<Expr>),
    /// `{ stmt; stmt; tail }`
    Block(List<Stmt>, Option<Box<Expr>>),
    /// `unsafe { .. }`
    Unsafe(Box<Expr>),
    /// `Point { x: 1, y }`, or `Pair::<i64, bool> { .. }`
    StructLit(Ident, List<TypeExpr>, List<FieldInit>),
    /// `p.x`
    Field(Box<Expr>, Ident),
    /// `Shape::Rect(2, 3)`, `Shape::Empty`, `Option::<i64>::None`, or a
    /// path, `Point::new(1, 2)`: the type, its type arguments, the name
    /// after `::`, the arguments, and whether the `(..)` is there.
    Variant(Ident, List<TypeExpr>, Ident, List<Expr>, bool),
    /// `match e { pat => e, .. }`
    Match(Box<Expr>, List<Arm>),
    /// `|x, y: i64| x + y`
    Lambda(Box<Lambda>),
    /// `place = value`, or `place += value` with the operator.
    Assign(Option<BinOp>, Box<Expr>, Box<Expr>),
    /// `'a: while c invariant p { .. }`
    While(Option<Label>, Box<Expr>, Invariant, Box<Expr>),
    /// `'a: while let p = e invariant q { .. }`
    WhileLet(Option<Label>, Box<LetCond>, Invariant, Box<Expr>),
    /// `'a: loop invariant p { .. }`
    Loop(Option<Label>, Invariant, Box<Expr>),
    /// `for p in it { .. }`
    For(Box<ForLoop>),
    /// `a..b`
    Range(Box<Expr>, Box<Expr>),
    /// `x[i]`, with the span of the `[..]`, and whether it's written to.
    Index(Box<Expr>, Box<Expr>, Span, bool),
    /// `e?`, with the span of the `?`.
    Try(Box<Expr>, Span),
    /// `return e`, or `return`.
    Return(Option<Box<Expr>>),
    /// `break 'a e`
    Break(Option<Ident>, Option<Box<Expr>>),
    /// `continue 'a`
    Continue(Option<Ident>),
}

/// `let pat = expr`, what an `if let` or `while let` matches.
#[derive(Discard)]
pub struct LetCond { pub let_span: Span, pub pat: Pattern, pub expr: Expr }

/// `for pat in iter { body }`, or with a label.
#[derive(Discard)]
pub struct ForLoop {
    pub label: Option<Label>,
    pub pat: Pattern,
    /// Where the `in` is.
    pub in_span: Span,
    /// `it` in `for x in it: e`.
    pub name: Option<Ident>,
    pub iter: Expr,
    pub invariant_: Invariant,
    pub body: Expr,
}

/// A loop's `invariant p`.
pub type Invariant = Option<Box<Expr>>;

/// `'a:` before a loop.
#[derive(Discard)]
pub struct Label {
    /// With its `'`: `'a`.
    pub name: Ident,
    /// From the label to the loop's keyword, `:` and all.
    pub head: Span,
}

/// `move |x: i64| -> i64 { x + 1 }`
#[derive(Discard)]
pub struct Lambda {
    /// Where the `move` is, if it's there.
    pub moves: Option<Span>,
    pub params: List<LambdaParam>,
    pub ret: Option<TypeExpr>,
    pub body: Expr,
}

#[derive(Discard)]
pub struct LambdaParam {
    pub mutable: Option<Span>,
    /// The name, or, for a parameter written as a pattern, one no program
    /// can write.
    pub name: Ident,
    pub ty: Option<TypeExpr>,
    /// `|(a, b)| ..`: the pattern, if it's written as one.
    pub pat: Option<Pattern>,
}

/// `x: e` in a struct literal, or `x` alone for `x: x`.
#[derive(Discard)]
pub struct FieldInit { pub name: Ident, pub value: Expr }

#[derive(Discard)]
pub struct Arm { pub pat: Pattern, pub body: Expr }

#[derive(Discard)]
pub enum Stmt {
    Let(LetStmt),
    /// `e;`
    Expr(Expr),
    /// An `if`, `match`, loop or block statement with no `;` after it.
    BlockLike(Expr),
    /// A nested function.
    Fn(Box<FnDecl>),
    /// A local `struct`, `enum` or `type`.
    Type(Box<TypeDecl>),
}

/// `let pat: ty = init else { .. };`
#[derive(Discard)]
pub struct LetStmt {
    pub pat: Pattern,
    pub ty: Option<Box<TypeExpr>>,
    /// `None` for `let x;`.
    pub init: Option<Box<Expr>>,
    /// The `else` block of a `let .. else`.
    pub els: Option<Box<Expr>>,
    /// From the `let` to the `;`.
    pub span: Span,
}

#[derive(Discard)]
pub struct Pattern { pub kind: PatternKind, pub span: Span }

/// How a literal pattern is written: as an integer, `97`, a byte, `b'a'`,
/// or a character, `'a'`.
#[derive(Copy, Discard, Eq)]
pub enum Lit { Int, Byte, Char }

/// An integer in a pattern: `-5` is `Num { neg: true, abs: 5 }`. T has no
/// `i128`, which t-lang's parser keeps these in.
#[derive(Copy, Discard, Eq)]
pub struct Num { pub neg: bool, pub abs: u64 }

#[derive(Discard)]
pub enum PatternKind {
    /// `_`
    Wild,
    /// `x`, or `mut x` if the `bool` is set.
    Bind(String, bool),
    /// `5`, `b'a'` or `'a'`.
    Int(Num, Lit),
    /// `1..=9`, `1..10`, `10..`, `..=-1`: the bounds as written, whether
    /// it's written with `..=`, and how its literals are written.
    Range(Option<Num>, Option<Num>, bool, Lit),
    Bool(bool),
    Unit,
    /// `"help"`
    Str,
    /// `Shape::Rect(w, _)`, or `Option::<i64>::Some(x)`.
    Variant(Ident, List<TypeExpr>, Ident, List<Pattern>),
    /// `Point { x, y: 0 }`, or `Point { x, .. }` (the `bool`).
    Struct(Ident, List<TypeExpr>, List<FieldPat>, bool),
    /// `None`, `Dot(p)` or `MAX`: a name that starts with an uppercase
    /// letter, with the patterns in its `(..)` if it's written with them
    /// (the `bool`).
    Path(Ident, List<Pattern>, bool),
    /// `[a, b, c]`
    Array(List<Pattern>),
    /// `(a, b)`
    Tuple(List<Pattern>),
    /// `A | B`
    Or(List<Pattern>),
}

/// `y: 0` in a struct pattern. Plain `x` is short for `x: x`.
#[derive(Discard)]
pub struct FieldPat { pub name: Ident, pub pat: Pattern }

#[derive(Copy, Discard, Eq)]
pub enum UnOp {
    Neg,
    Not,
    /// `*x`
    Deref,
    /// `&x`
    Ref,
    /// `&mut x`
    RefMut,
}

#[derive(Copy, Discard, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
}

impl BinOp {
    pub fn symbol(self) -> &'static str {
        match self {
            BinOp::Add => "+",
            BinOp::Sub => "-",
            BinOp::Mul => "*",
            BinOp::Div => "/",
            BinOp::Rem => "%",
            BinOp::Eq => "==",
            BinOp::Ne => "!=",
            BinOp::Lt => "<",
            BinOp::Le => "<=",
            BinOp::Gt => ">",
            BinOp::Ge => ">=",
            BinOp::And => "&&",
            BinOp::Or => "||",
            BinOp::BitAnd => "&",
            BinOp::BitOr => "|",
            BinOp::BitXor => "^",
            BinOp::Shl => "<<",
            BinOp::Shr => ">>",
        }
    }

    /// Whether it's one of `&`, `|`, `^`, `<<` and `>>`.
    pub fn is_bitwise(self) -> bool {
        match self {
            BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr => true,
            _ => false,
        }
    }
}

impl UnOp {
    pub fn symbol(self) -> &'static str {
        match self {
            UnOp::Neg => "-",
            UnOp::Not => "!",
            UnOp::Deref => "*",
            UnOp::Ref => "&",
            UnOp::RefMut => "&mut ",
        }
    }
}

/// The integer types, as a literal's suffix names them.
#[derive(Copy, Discard, Eq)]
pub enum IntTy { I8, I16, I32, I64, Isize, U8, U16, U32, U64, Usize }

impl IntTy {
    pub fn name(self) -> &'static str {
        match self {
            IntTy::I8 => "i8",
            IntTy::I16 => "i16",
            IntTy::I32 => "i32",
            IntTy::I64 => "i64",
            IntTy::Isize => "isize",
            IntTy::U8 => "u8",
            IntTy::U16 => "u16",
            IntTy::U32 => "u32",
            IntTy::U64 => "u64",
            IntTy::Usize => "usize",
        }
    }

    pub fn named(s: &str) -> Option<IntTy> {
        match s {
            "i8" => Some(IntTy::I8),
            "i16" => Some(IntTy::I16),
            "i32" => Some(IntTy::I32),
            "i64" => Some(IntTy::I64),
            "isize" => Some(IntTy::Isize),
            "u8" => Some(IntTy::U8),
            "u16" => Some(IntTy::U16),
            "u32" => Some(IntTy::U32),
            "u64" => Some(IntTy::U64),
            "usize" => Some(IntTy::Usize),
            _ => None,
        }
    }
}
