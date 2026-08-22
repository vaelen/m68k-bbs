#!/bin/sh
# Run every tests/*.cla on the host with the PINNED toolchain
# (bin/clarusc emits C, cc compiles it against vendor/runtime/host).
# Exits nonzero on the first failing suite.
set -e
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
for t in tests/*.cla; do
    echo "== $t"
    bin/clarusc emit --rtdir vendor/runtime/clarus/ -o "$WORK/main.c" "$t"
    cc -O1 -I vendor/runtime/host -o "$WORK/prog" "$WORK/main.c" vendor/runtime/host/rt.c
    # run from the scratch dir so tests that create files stay out of the repo
    (cd "$WORK" && ./prog)
done
echo "all test suites passed"
