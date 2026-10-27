#!/bin/sh
# Run every tests/*.cla on the host with the installed clarusc.
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
    clarusc build -o "$D/prog" "$t"
    (cd "$D" && ./prog)
done
echo "all test suites passed"
