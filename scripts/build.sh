#!/bin/sh
# Build the 68k Mac app with the PINNED toolchain (bin/clarusc +
# vendor/ runtime/toolbox snapshot) -- no dependency on the live
# compiler repo. Output: build/68kBBS.bin, build/68kBBSConfig.bin and
# build/68kBBSBench.bin (MacBinary).
set -e
cd "$(dirname "$0")/.."
mkdir -p build
bin/clarusc emit68k --rtdir vendor/runtime/clarus/ -o build/68kBBS.bin bbs.cla
bin/clarusc emit68k --rtdir vendor/runtime/clarus/ -o build/68kBBSConfig.bin bbsconfig.cla
bin/clarusc emit68k --rtdir vendor/runtime/clarus/ -o build/68kBBSBench.bin bench.cla
echo "built: build/68kBBS.bin build/68kBBSConfig.bin build/68kBBSBench.bin"
