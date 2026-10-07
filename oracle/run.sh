#!/bin/sh
# Runs every test/*.rb under CRuby 4.0.2 twice and diffs it against its
# .expected: once with the real aws-sdk-core gem (the oracle) and once with this
# package and its spin dependencies. With --write, regenerates every .expected
# from the real gem. A run counts only if ruby exits 0; stdout alone is compared.
# SPIN names the spin binary (default: spin on PATH).
set -eu
CDPATH= cd "$(dirname "$0")/.."
export BUNDLE_GEMFILE="$PWD/oracle/Gemfile"
SPIN=${SPIN:-spin}
INCLUDES=$("$SPIN" flags | sed 's/--require-gate//')
ruby_gem() { mise exec ruby@4.0.2 -- bundle exec ruby "$1"; }
ruby_pkg() { mise exec ruby@4.0.2 -- ruby --disable-gems $INCLUDES "$1"; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

status=0
check() { # $1: label, $2: runner, $3: test
  if "$2" "$3" > "$tmp" && diff -u "$3.expected" "$tmp" > /dev/null; then
    echo "ok   $1  $3"
  else
    echo "FAIL $1  $3"
    diff -u "$3.expected" "$tmp" || true
    status=1
  fi
}

for t in test/*.rb; do
  [ -e "$t" ] || continue
  if [ "${1:-}" = "--write" ]; then
    ruby_gem "$t" > "$tmp" || { echo "the gem failed on $t; $t.expected left as it was" >&2; exit 1; }
    cp "$tmp" "$t.expected"
    echo "wrote $t.expected"
    continue
  fi
  check "gem    " ruby_gem "$t"
  check "package" ruby_pkg "$t"
done
exit $status
