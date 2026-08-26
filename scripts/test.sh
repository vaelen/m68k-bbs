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
    # each suite gets its own fresh directory (databases and files it
    # creates never leak into the next suite), seeded with the fixtures
    D="$WORK/$(basename "$t" .cla)"
    mkdir -p "$D"
    cp tests/fixtures/* "$D"/
    bin/clarusc emit --rtdir vendor/runtime/clarus/ -o "$D/main.c" "$t"
    cc -O1 -I vendor/runtime/host -o "$D/prog" "$D/main.c" vendor/runtime/host/rt.c
    (cd "$D" && ./prog)
done
echo "all test suites passed"
