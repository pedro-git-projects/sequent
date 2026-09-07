#!/usr/bin/env bash
#
# One command for a confidence signal after a change:
#
#   1. build the library, the executable and the test suite
#   2. run the whole test suite
#   3. compile every example, into a scratch directory so the committed
#      goldens are not touched, and diff each result against its golden
#
# Exits non-zero if any step fails, and prints a summary of what failed.

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
step() { printf '\n=== %s\n' "$1"; }
note() { printf '  %s\n' "$1"; }

step "build"
if cabal build all; then note "ok"; else note "FAILED"; fail=1; fi

step "test"
if cabal test; then note "ok"; else note "FAILED"; fail=1; fi

step "examples"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for src in examples/*.sq; do
  name=$(basename "$src" .sq)
  if ! cabal run -v0 sequent -- build "$src" -o "$out/$name.bpmn" >/dev/null; then
    note "$src: COMPILE FAILED"
    fail=1
    continue
  fi
  golden="examples/$name.bpmn"
  if [ ! -f "$golden" ]; then
    note "$src: compiled, but $golden is missing"
    fail=1
  elif cmp -s "$out/$name.bpmn" "$golden"; then
    note "$src: ok"
  else
    note "$src: DIFFERS from $golden (run SEQUENT_ACCEPT=1 cabal test to accept)"
    fail=1
  fi
done

step "determinism"
first=$(cabal run -v0 sequent -- build examples/order.sq -o "$out/d1.bpmn" >/dev/null; sha256sum < "$out/d1.bpmn")
second=$(cabal run -v0 sequent -- build examples/order.sq -o "$out/d2.bpmn" >/dev/null; sha256sum < "$out/d2.bpmn")
if [ "$first" = "$second" ]; then note "ok (byte-identical)"; else note "FAILED: repeated compilation differed"; fail=1; fi

printf '\n'
if [ "$fail" -eq 0 ]; then echo "check: PASS"; else echo "check: FAIL"; fi
exit "$fail"
