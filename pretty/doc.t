//! A layout engine after Wadler's "A prettier printer": the printer
//! describes a program as a `Doc`, with places it may break a line, and
//! `render` picks where to break so that lines fit in `WIDTH` columns. A
//! port of t-lang's `src/doc.rs`.
//!
//! The key part is a `Group`. It prints *flat*, with each `Line` in it as a
//! space, if all of it fits on the rest of the line; otherwise it *breaks*,
//! and each `Line` directly in it starts a new line. Groups nest, and each
//! decides for itself, outermost first, so an outer group can break while
//! the groups inside it stay flat. This is the algorithm Prettier uses: it
//! looks only at the rest of the current line to decide, so it runs in
//! linear time, unlike Wadler's lazy original that keeps alternatives open.
//!
//! T has no `+` on documents, as t-lang's has: `add` and `text` join them
//! the same way. Nor `Clone`: `dup` copies one.

use alloc::boxed::Box;
use alloc::list::List;
use alloc::string::String;
use core::cmp::{max, min};

use crate::text::item;

/// The longest a line should be. A line can still be longer if there's no
/// place to break it, or because of a comment at its end.
pub const WIDTH: usize = 100;

const INDENT: &str = "    ";

#[derive(Discard)]
pub enum Doc {
    /// Text with no newlines in it.
    Text(String),
    Concat(List<Doc>),
    /// Lines in it start one level further in.
    Nest(Box<Doc>),
    /// Prints flat if it fits, and otherwise breaks. The `bool` is set if
    /// there's a `HardLine` or `Comment` somewhere inside, so it can never
    /// be flat.
    Group(Box<Doc>, bool),
    /// A space if the group it's in is flat, or else a new line.
    Line,
    /// Nothing if the group it's in is flat, or else a new line.
    SoftLine,
    /// Always a new line.
    HardLine,
    /// Nothing, but the groups around it break: after a comment on a line
    /// of its own, which the next thing mustn't follow on that line.
    BreakParent,
    /// The first if the group it's in breaks, the second if it's flat.
    IfBreak(Box<Doc>, Box<Doc>),
    /// A comment that goes at the end of the line, after everything else on
    /// it. It doesn't count toward the width, so whether there's a comment
    /// doesn't change how the code around it is laid out.
    Comment(String),
    /// The arguments of a call whose last argument is a closure, block,
    /// `match` or struct literal (see `Hug`).
    Hug(Box<Hug>),
}

/// The arguments of a call whose last argument is a closure, block,
/// `match` or struct literal: `normal`, unless that doesn't fit on one
/// line, and `prefix` (the other arguments, flat) and the start of `last`
/// do. Then the arguments stay on the call's line and the last one breaks
/// inside:
///
/// ```text
/// apply(x, |y| {
///     ..
/// })
/// ```
#[derive(Discard)]
pub struct Hug { pub normal: Doc, pub prefix: Doc, pub last: Doc, pub close: Doc }

/// `s` as a document: text, with no newlines in it.
pub fn text(s: &str) -> Doc { Doc::Text(String::from(s)) }

/// `d`, with the lines in it one level further in.
pub fn nest(d: Doc) -> Doc { Doc::Nest(Box::new(d)) }

/// `d` as a group: flat if it fits, and otherwise broken.
pub fn group(d: Doc) -> Doc {
    let hard = d.hard();
    Doc::Group(Box::new(d), hard)
}

/// `broken` if the group it's in breaks, `flat` if it's flat.
pub fn if_break(broken: Doc, flat: Doc) -> Doc { Doc::IfBreak(Box::new(broken), Box::new(flat)) }

impl Doc {
    /// Nothing: an empty `Concat`, which what's added to it goes into.
    pub fn nil() -> Doc { Doc::Concat(List::new()) }

    /// Does this force the groups around it to break?
    pub fn hard(&self) -> bool {
        match self {
            Doc::HardLine | Doc::BreakParent | Doc::Comment(_) => true,
            Doc::Group(_, hard) => *hard,
            Doc::Concat(docs) => {
                for d in docs.iter() {
                    if d.hard() {
                        return true;
                    }
                }
                false
            },
            Doc::Nest(d) => d.hard(),
            // A hard line in `broken` only shows if the group breaks anyway.
            Doc::IfBreak(_, flat) => flat.hard(),
            Doc::Hug(h) => h.normal.hard(),
            Doc::Text(_) | Doc::Line | Doc::SoftLine => false,
        }
    }

    /// `self`, then `other`, as `+` joins them in t-lang: a `Concat` takes
    /// in what follows it, or what's in a `Concat` that follows it.
    pub fn add(self, other: Doc) -> Doc {
        match (self, other) {
            (Doc::Concat(mut a), Doc::Concat(b)) => {
                for d in b {
                    a.push(d);
                }
                Doc::Concat(a)
            },
            (Doc::Concat(mut a), b) => {
                a.push(b);
                Doc::Concat(a)
            },
            (a, b) => {
                let mut docs = List::new();
                docs.push(a);
                docs.push(b);
                Doc::Concat(docs)
            },
        }
    }

    /// `self`, then text `s`.
    pub fn text(self, s: &str) -> Doc { self.add(text(s)) }

    /// `self`, then text `s`, which is moved in.
    pub fn owned(self, s: String) -> Doc { self.add(Doc::Text(s)) }

    /// A copy of this, as it is.
    pub fn dup(&self) -> Doc {
        match self {
            Doc::Text(s) => Doc::Text(String::from(s.as_str())),
            Doc::Concat(docs) => {
                let mut out = List::new();
                for d in docs.iter() {
                    out.push(d.dup());
                }
                Doc::Concat(out)
            },
            Doc::Nest(d) => Doc::Nest(Box::new(d.dup())),
            Doc::Group(d, hard) => Doc::Group(Box::new(d.dup()), *hard),
            Doc::Line => Doc::Line,
            Doc::SoftLine => Doc::SoftLine,
            Doc::HardLine => Doc::HardLine,
            Doc::BreakParent => Doc::BreakParent,
            Doc::IfBreak(broken, flat) => if_break(broken.dup(), flat.dup()),
            Doc::Comment(s) => Doc::Comment(String::from(s.as_str())),
            Doc::Hug(h) => {
                let hug = Hug {
                    normal: h.normal.dup(),
                    prefix: h.prefix.dup(),
                    last: h.last.dup(),
                    close: h.close.dup(),
                };
                Doc::Hug(Box::new(hug))
            },
        }
    }
}

#[derive(Copy, Discard, Eq)]
enum Mode { Flat, Break }

/// Something left to print: a document, how far in its lines go, and
/// whether the group it's in is flat.
#[derive(Copy, Discard)]
struct Frame<'a> { indent: usize, mode: Mode, doc: &'a Doc }

/// One line of output: the code, and the comment at its end, if any.
#[derive(Discard)]
struct OutLine { code: String, comment: Option<String> }

/// Lays `doc` out in `WIDTH` columns, and lines up the comments at the ends
/// of lines (see `align_comments`).
pub fn render(doc: &Doc) -> String {
    let mut lines: List<OutLine> = List::new();
    let mut code = String::new();
    let mut comment: Option<String> = None;
    let mut column = 0usize;
    // What's left to print, last first.
    let mut stack: List<Frame> = List::new();
    stack.push(Frame { indent: 0, mode: Mode::Break, doc });
    while let Some(f) = stack.pop() {
        let indent = f.indent;
        let mode = f.mode;
        match f.doc {
            Doc::Text(s) => {
                code.push_str(s.as_str());
                column = column + s.as_str().chars().count();
            },
            Doc::Concat(docs) => {
                let mut i = docs.len();
                while i > 0 {
                    i = i - 1;
                    stack.push(Frame { indent, mode, doc: item(docs, i) });
                }
            },
            Doc::Nest(d) => stack.push(Frame { indent: indent + 1, mode, doc: &**d }),
            Doc::Group(d, hard) => {
                let mode = match (mode, *hard) {
                    (Mode::Flat, _) => Mode::Flat,
                    (Mode::Break, false) => {
                        match fits(WIDTH - min(column, WIDTH), &**d, &stack) {
                            true => Mode::Flat,
                            false => Mode::Break,
                        }
                    },
                    (Mode::Break, true) => Mode::Break,
                };
                stack.push(Frame { indent, mode, doc: &**d });
            },
            Doc::Hug(h) => {
                let width = WIDTH - min(column, WIDTH);
                let hug = mode == Mode::Break
                    && (h.normal.hard() || !fits(width, &h.normal, &stack))
                    && !h.prefix.hard()
                    && match flat_width(&h.prefix) {
                        Some(w) => first_line_fits(width, w, &h.last),
                        None => false,
                    };
                if hug {
                    stack.push(Frame { indent, mode: Mode::Break, doc: &h.close });
                    stack.push(Frame { indent, mode: Mode::Break, doc: &h.last });
                    stack.push(Frame { indent, mode: Mode::Flat, doc: &h.prefix });
                } else {
                    stack.push(Frame { indent, mode, doc: &h.normal });
                }
            },
            Doc::IfBreak(broken, flat) => {
                let d = match mode {
                    Mode::Break => &**broken,
                    Mode::Flat => &**flat,
                };
                stack.push(Frame { indent, mode, doc: d });
            },
            Doc::BreakParent => {},
            Doc::Comment(c) => {
                comment = match comment.take() {
                    Some(before) => Some(String::of(&f"{before} {c}")),
                    None => Some(String::from(c.as_str())),
                };
            },
            Doc::Line | Doc::SoftLine | Doc::HardLine => {
                let (line, hard) = match f.doc {
                    Doc::Line => (true, false),
                    Doc::HardLine => (false, true),
                    _ => (false, false),
                };
                if mode == Mode::Flat && !hard {
                    if line {
                        code.push(' ');
                        column = column + 1;
                    }
                } else {
                    lines.push(OutLine { code, comment: comment.take() });
                    code = String::new();
                    let mut i = 0usize;
                    while i < indent {
                        code.push_str(INDENT);
                        i = i + 1;
                    }
                    column = indent * INDENT.len();
                }
            },
        }
    }
    lines.push(OutLine { code, comment });
    align_comments(&mut lines);

    let mut out = String::new();
    for line in lines.iter() {
        out.push_str(line.code.as_str().trim_end());
        out.push('\n');
    }
    // One newline at the end of the file, whatever the doc ended with.
    let end = out.as_str().trim_end().len();
    let _ = out.truncate(end);
    if !out.is_empty() {
        out.push('\n');
    }
    out
}

/// What `fits` has left to look at: a document, and whether it's flat.
#[derive(Copy, Discard)]
struct Todo<'a> { mode: Mode, doc: &'a Doc }

/// Would `doc` fit in `width` columns, flat, followed by `rest` up to its
/// first line break?
fn fits(width: usize, doc: &Doc, rest: &List<Frame>) -> bool {
    let mut width = width as isize;
    let mut todo: List<Todo> = List::new();
    todo.push(Todo { mode: Mode::Flat, doc });
    // `rest` is a stack: what's printed next is at its end.
    let mut next = rest.len();
    loop {
        let t = match todo.pop() {
            Some(t) => t,
            None => {
                if next == 0 {
                    return true;
                }
                next = next - 1;
                let f = item(rest, next);
                Todo { mode: f.mode, doc: f.doc }
            },
        };
        let mode = t.mode;
        match t.doc {
            Doc::Text(s) => width = width - s.as_str().chars().count() as isize,
            Doc::Concat(docs) => {
                let mut i = docs.len();
                while i > 0 {
                    i = i - 1;
                    todo.push(Todo { mode, doc: item(docs, i) });
                }
            },
            Doc::Nest(d) => todo.push(Todo { mode, doc: &**d }),
            Doc::Group(d, hard) => {
                let mode = if *hard { Mode::Break } else { mode };
                todo.push(Todo { mode, doc: &**d });
            },
            Doc::Hug(h) => todo.push(Todo { mode, doc: &h.normal }),
            Doc::IfBreak(broken, flat) => {
                let d = match mode {
                    Mode::Break => &**broken,
                    Mode::Flat => &**flat,
                };
                todo.push(Todo { mode, doc: d });
            },
            Doc::Comment(_) | Doc::BreakParent => {},
            Doc::Line => {
                if mode == Mode::Break {
                    return true;
                }
                width = width - 1;
            },
            Doc::SoftLine => {
                if mode == Mode::Break {
                    return true;
                }
            },
            Doc::HardLine => return true,
        }
        if width < 0 {
            return false;
        }
    }
}

/// `doc` as it prints flat, which can't break, if it can go on one line.
pub fn flat(doc: &Doc) -> Option<Doc> {
    match doc {
        Doc::Text(s) => Some(Doc::Text(String::from(s.as_str()))),
        Doc::Concat(docs) => {
            let mut out = Doc::nil();
            for d in docs.iter() {
                out = out.add(flat(d)?);
            }
            Some(out)
        },
        Doc::Nest(d) => flat(d),
        Doc::Group(d, _) => flat(d),
        Doc::Hug(h) => flat(&h.normal),
        Doc::IfBreak(_, d) => flat(d),
        Doc::Line => Some(text(" ")),
        Doc::SoftLine => Some(Doc::nil()),
        Doc::HardLine | Doc::BreakParent | Doc::Comment(_) => None,
    }
}

/// How wide `doc` is on one line, if it can go on one.
pub fn flat_width(doc: &Doc) -> Option<usize> {
    let mut width = 0usize;
    let mut todo: List<&Doc> = List::new();
    todo.push(doc);
    while let Some(d) = todo.pop() {
        match d {
            Doc::Text(s) => width = width + s.as_str().chars().count(),
            Doc::Concat(docs) => {
                let mut i = docs.len();
                while i > 0 {
                    i = i - 1;
                    todo.push(item(docs, i));
                }
            },
            Doc::Nest(d) => todo.push(&**d),
            Doc::Group(d, _) => todo.push(&**d),
            Doc::Hug(h) => todo.push(&h.normal),
            Doc::IfBreak(_, flat) => todo.push(&**flat),
            Doc::Line => width = width + 1,
            Doc::SoftLine => {},
            Doc::HardLine | Doc::BreakParent | Doc::Comment(_) => return None,
        }
    }
    Some(width)
}

/// Does `doc`, broken, fit in `width` columns up to its first line break,
/// after `used` columns? Groups in it are taken as broken too, so this is
/// how much has to go on the first line at the least.
fn first_line_fits(width: usize, used: usize, doc: &Doc) -> bool {
    let mut width = width as isize - used as isize;
    let mut todo: List<&Doc> = List::new();
    todo.push(doc);
    while let Some(d) = todo.pop() {
        match d {
            Doc::Text(s) => width = width - s.as_str().chars().count() as isize,
            Doc::Concat(docs) => {
                let mut i = docs.len();
                while i > 0 {
                    i = i - 1;
                    todo.push(item(docs, i));
                }
            },
            Doc::Nest(d) => todo.push(&**d),
            Doc::Group(d, _) => todo.push(&**d),
            Doc::Hug(h) => todo.push(&h.normal),
            Doc::IfBreak(broken, _) => todo.push(&**broken),
            Doc::Comment(_) | Doc::BreakParent => {},
            Doc::Line | Doc::SoftLine | Doc::HardLine => return width >= 0,
        }
        if width < 0 {
            return false;
        }
    }
    true
}

/// How many characters `l`'s code has, without the blanks at its end.
fn code_width(l: &OutLine) -> usize { l.code.as_str().trim_end().chars().count() }

/// Lines up the comments at the ends of consecutive lines, one space after
/// the longest line's code:
///
/// ```text
/// print(add5(1));                       // expect: 6
/// print(compose(add5, |x| x + 100, 0)); // expect: 105
/// ```
///
/// Why line them up: in T's tests, and in examples, a run of statements with
/// `// expect:` after each reads as a table, code on the left and what it
/// prints on the right, and that only works if the right column is
/// straight. Why only consecutive lines: a line without a comment, or a
/// blank one, ends the run (as in gofmt), so one long line moves the
/// comments of its own run and no others, and an edit causes a small diff.
///
/// A line that would push a comment in its run past `WIDTH` starts a new
/// run instead (as in clang-format), so lining comments up never makes a
/// line too long that wasn't already. A comment alone on its line in a run,
/// continuing the one above, stays in that run.
fn align_comments(lines: &mut List<OutLine>) {
    let mut i = 0usize;
    while i < lines.len() {
        if item(lines, i).comment.is_none() {
            i = i + 1;
            continue;
        }
        // The run is `i` up to `end`; its comments go at `column`.
        let mut column = code_width(item(lines, i)) + 1;
        let mut longest = 0usize;
        let mut end = i;
        loop {
            let Some(line) = lines.get(end) else { break };
            let Some(comment) = &line.comment else { break };
            let continues = line.code.as_str().trim().is_empty();
            let col = if continues { column } else { max(column, code_width(line) + 1) };
            let len = max(longest, comment.as_str().chars().count());
            if end > i && !continues && col + len > WIDTH {
                break;
            }
            column = col;
            longest = len;
            end = end + 1;
        }
        let mut k = i;
        while k < end {
            if let Some(line) = lines.get_mut(k) {
                let comment = line.comment.take().expect("each line of the run has a comment");
                let mut code = String::from(line.code.as_str().trim_end());
                let mut n = code.as_str().chars().count();
                while n < column {
                    code.push(' ');
                    n = n + 1;
                }
                code.push_str(comment.as_str());
                line.code = code;
            }
            k = k + 1;
        }
        i = end;
    }
}
