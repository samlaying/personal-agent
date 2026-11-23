#!/bin/zsh
# Runs the test suite. Works without full Xcode: Command Line Tools ship swift-testing
# in a developer framework that is not on the default search path, so we pass -F and
# an rpath. When Xcode is installed its toolchain needs neither flag.
set -e
cd "$(dirname "$0")/.."

CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if xcode-select -p 2>/dev/null | grep -qv CommandLineTools; then
    exec swift test "$@"
fi

if [[ ! -d "$CLT_FW" ]]; then
    echo "error: no Xcode and no CommandLineTools Testing.framework found" >&2
    exit 1
fi

exec swift test \
    -Xswiftc -F -Xswiftc "$CLT_FW" \
    -Xlinker -rpath -Xlinker "$CLT_FW" \
    -Xlinker -rpath -Xlinker "$CLT_LIB" \
    "$@"
