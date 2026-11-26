# t-fmt

[T](https://github.com/lkurcak/t-lang)'s formatter, `t fmt`, written in T:
a port of t-lang's lexer, parser and printer (about 9,600 lines of T from
about 8,000 of Rust). For every T file in t-lang's tests, examples and
libraries, it prints byte for byte what `t fmt` does, and it formats its
own source unchanged.

Like the other T programs (tcalc, t-libs, t-nonograms, t-maze, t-metal,
t-life), it's here to find out what writing T is like: a compiler-shaped
program, with a big owned syntax tree, a Wadler-style document printer,
and many small recursive functions. What got in the way is in
[FRICTION.md](FRICTION.md).

## Use

```sh
t build -o t-fmt main.t
./t-fmt --print file.t    # what `t fmt` would make of it
./t-fmt --parse file.t    # `ok`, or the syntax error
./t-fmt --tokens file.t   # the tokens
```

A file that doesn't lex or parse prints `error <start>..<end>: <message>`,
byte offsets into the file.

## Tests

`tests/run.sh` checks it (`t check --deny-warnings`, `t fmt --check`),
builds it, checks that it formats itself unchanged, and compares
`--print` with `t fmt` on every `.t` file of the t-lang release the `t` on
`PATH` is (a shallow clone, or `T_LANG=<checkout>`). CI runs it with the
`t` pinned in `.github/workflows/t.yml`.

## Layout

- `main.t`: the command line.
- `lexer.t`: tokens. They're `Copy`: names are slices of the source, and a
  format string's pieces are in a side table (`Lexed::pieces`).
- `ast.t`: the syntax tree, owned (`Box`, `List`, `String`), with spans
  for the printer and no node ids.
- `parser.t` and `parser/`: the parser, with the same messages and spans
  as t-lang's.
- `pretty.t` and `pretty/`: the printer. `doc.t` is the document and its
  rendering at width 100, `trivia.t` the comments and blank lines kept,
  and `items.t`, `exprs.t`, `types.t` the syntax.
- `text.t`, `error.t`: small helpers.
