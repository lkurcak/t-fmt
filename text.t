//! Small helpers over bytes and text that `core` doesn't have.

use alloc::list::List;

/// Value `i` of `l`, which must have one: indexing, where the checker
/// can't prove the index is in range.
pub fn item<'a, T>(l: &'a List<T>, i: usize) -> &'a T {
    match l.get(i) {
        Some(x) => x,
        None => panic("index out of range"),
    }
}

/// Byte `i` of `b`, if there is one.
pub fn at(b: &[u8], i: usize) -> Option<u8> {
    match b.get(i) {
        Some(x) => Some(*x),
        None => None,
    }
}

/// Byte `i` of `b`, which must have one: indexing, where the checker
/// can't prove the index is in range.
pub fn byte(b: &[u8], i: usize) -> u8 {
    match b.get(i) {
        Some(x) => *x,
        None => panic("index out of range"),
    }
}

/// Bytes `lo` up to `hi` of `s`, which must be where characters start.
pub fn sub<'a>(s: &'a str, lo: usize, hi: usize) -> &'a str {
    match s.get(lo, hi) {
        Some(t) => t,
        None => panic("cut between characters"),
    }
}

/// The character starting at byte `i` of `s`, if one does.
pub fn char_at(s: &str, i: usize) -> Option<char> {
    match s.get(i, s.len()) {
        Some(rest) => rest.chars().next(),
        None => None,
    }
}

pub fn is_digit(b: u8) -> bool { b >= b'0' && b <= b'9' }

pub fn is_alpha(b: u8) -> bool { (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z') }

pub fn is_alnum(b: u8) -> bool { is_alpha(b) || is_digit(b) }

pub fn is_hex(b: u8) -> bool { is_digit(b) || (b >= b'a' && b <= b'f') || (b >= b'A' && b <= b'F') }

/// ASCII whitespace, as Rust's `u8::is_ascii_whitespace` says: space, tab,
/// line feed, form feed and carriage return.
pub fn is_ws(b: u8) -> bool { b == b' ' || b == b'\t' || b == b'\n' || b == 12 || b == b'\r' }
