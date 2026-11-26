# t-fmt

`t fmt` written in T, the language at `~/repos/tooling/t-lang` (GitHub:
lkurcak/t-lang): a faithful port of t-lang's `src/lexer.rs`,
`src/parser.rs`, `src/doc.rs`, `src/trivia.rs`, `src/pretty.rs` (the
`t fmt` path only) and the glue in `src/fmt.rs`. Like tcalc, t-libs,
t-nonograms, t-maze, t-metal and t-life, part of its purpose is to find out
what using T is like.

- The goal is byte-identical output to the `t fmt` of the pinned t-lang
  release, on every file. `tests/run.sh` checks exactly that over t-lang's
  `.t` files (about 3000), plus `--deny-warnings`, `t fmt --check`, and
  that t-fmt leaves its own source unchanged. When t-lang's formatter
  changes, port the change here in the same chat (see t-lang's
  "one chat, all repos").
- It doesn't verify its output as t-lang's `fmt::format` does (reparse and
  compare shapes and comments): the differential test replaces that.
- Known difference no corpus file has: a string literal with escapes in
  parentheses, `("a\x41")`, where t-lang re-spells the literal from its
  value and this port copies the source.
- CI pins a `t` release (`t-version` + `t-sha256` in
  .github/workflows/t.yml, which calls forge's shared t-ci.yml); forge
  bumps it after each t-lang release.
- `FRICTION.md` is the friction log: label entries gap / by design /
  unsure, with minimal repros for checker problems.
