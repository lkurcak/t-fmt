#!/bin/sh
# Checks t-fmt: it type-checks with no warnings, it's formatted (by `t fmt`
# and by itself), and on every T file of the t-lang release whose `t` is on
# PATH (its tests, examples and libraries: about 3000 files), it does what
# that `t` does: `--print` writes what `t fmt` would make of the file, or
# an error where `t fmt` fails.
# Run from anywhere; `t` and git must be on PATH. Needs the network for the
# t-lang checkout, unless T_LANG names a checkout of that release already.
set -eu
cd "$(dirname "$0")/.."

t check --deny-warnings main.t
t fmt --check ./*.t parser/*.t pretty/*.t

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
t build -o "$work/t-fmt" main.t

# It formats itself as `t fmt` does: unchanged.
for f in ./*.t parser/*.t pretty/*.t; do
    if ! "$work/t-fmt" --print "$f" | cmp -s - "$f"; then
        echo "FAIL: t-fmt changes $f, which t fmt leaves as it is"
        exit 1
    fi
done

# The corpus: the t-lang release the `t` on PATH is.
version=$(t --version | cut -d' ' -f2)
lang=${T_LANG:-}
if [ -z "$lang" ]; then
    lang="$work/t-lang"
    git clone -q --depth 1 --branch "v$version" https://github.com/lkurcak/t-lang "$lang"
fi
find "$lang/tests" "$lang/examples" "$lang/core" "$lang/alloc" "$lang/std" \
    -name '*.t' -type f | sort > "$work/corpus"

# Each file, as `t fmt` leaves a copy of it and as t-fmt prints it.
fails=0
count=0
while IFS= read -r f; do
    count=$((count + 1))
    cp "$f" "$work/copy.t"
    printed=$("$work/t-fmt" --print "$f")
    if t fmt "$work/copy.t" > /dev/null 2>&1; then
        if [ "$printed" != "$(cat "$work/copy.t")" ]; then
            echo "FAIL: --print differs from t fmt: ${f#"$lang"/}"
            fails=$((fails + 1))
        fi
    else
        case "$printed" in
            error\ *) ;;
            *)
                echo "FAIL: t fmt fails on ${f#"$lang"/}, t-fmt doesn't"
                fails=$((fails + 1))
                ;;
        esac
    fi
done < "$work/corpus"
if [ "$fails" -ne 0 ]; then
    echo "FAIL: $fails of $count files"
    exit 1
fi
echo "ok: $count files of t-lang v$version formatted as t fmt does"
