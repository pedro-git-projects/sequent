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

step "round trip"
# Import every golden back to source and recompile it. The importer checks its
# own work, so a clean exit is the assertion; what this adds is that the BPMN
# the recompiled source produces carries the same elements, which is the claim
# a reader actually cares about.
for golden in examples/*.bpmn; do
  name=$(basename "$golden" .bpmn)
  if ! cabal run -v0 sequent -- import "$golden" -o "$out/$name.sq" >/dev/null 2>"$out/$name.err"; then
    note "$golden: import FAILED"
    sed 's/^/    /' "$out/$name.err"
    fail=1
    continue
  fi
  if ! cabal run -v0 sequent -- build "$out/$name.sq" -o "$out/$name.bpmn" >/dev/null 2>&1; then
    note "$golden: the imported source does not compile"
    fail=1
    continue
  fi
  a=$(grep -oE '<bpmn:[a-zA-Z]+ [^>]*' "$golden" | sort | sha256sum)
  b=$(grep -oE '<bpmn:[a-zA-Z]+ [^>]*' "$out/$name.bpmn" | sort | sha256sum)
  if [ "$a" = "$b" ]; then note "$golden: ok"; else note "$golden: round trip changed the process"; fail=1; fi
done

printf '\n'
if [ "$fail" -eq 0 ]; then echo "check: PASS"; else echo "check: FAIL"; fi
exit "$fail"
