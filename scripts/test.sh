#!/bin/sh
# Runs the unit tests. Pass --coverage to also print a line-coverage report.
#
# With only the Command Line Tools installed (no Xcode), SwiftPM can't find the
# Swift Testing framework on its own, so this adds its location to the search paths.
set -e
cd "$(dirname "$0")/.."

FLAGS=""
DEV_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
    LIBS="$DEV_DIR/Library/Developer/usr/lib"
    FLAGS="-Xswiftc -F -Xswiftc $FRAMEWORKS -Xlinker -F -Xlinker $FRAMEWORKS \
           -Xlinker -rpath -Xlinker $FRAMEWORKS -Xlinker -rpath -Xlinker $LIBS"
fi

if [ "$1" = "--coverage" ]; then
    # shellcheck disable=SC2086
    swift test --enable-code-coverage $FLAGS
    BIN_DIR="$(swift build --show-bin-path)"
    xcrun llvm-cov report "$BIN_DIR/TempMonitorPackageTests.xctest/Contents/MacOS/TempMonitorPackageTests" \
        -instr-profile "$BIN_DIR/codecov/default.profdata" \
        -ignore-filename-regex '(\.build|Tests)/'
else
    # shellcheck disable=SC2086
    swift test $FLAGS
fi
