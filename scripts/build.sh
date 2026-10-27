#!/bin/sh
# Build the 68k Mac app with the installed clarusc. Output:
# build/68kBBS.bin, build/68kBBSConfig.bin and build/68kBBSBench.bin
# (MacBinary).
set -e
cd "$(dirname "$0")/.."
mkdir -p build
clarusc build68k -o build/68kBBS.bin bbs.cla
clarusc build68k -o build/68kBBSConfig.bin bbsconfig.cla
clarusc build68k -o build/68kBBSBench.bin bench.cla
echo "built: build/68kBBS.bin build/68kBBSConfig.bin build/68kBBSBench.bin"
