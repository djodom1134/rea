#!/bin/sh
# Runs `swift test`. With only the Command Line Tools installed (no Xcode),
# the Testing framework ships with the CLT but is not on the default search
# paths, so pass them explicitly.
set -eu
cd "$(dirname "$0")/.."
developer="$(xcode-select -p 2>/dev/null || true)"
case "$developer" in
*CommandLineTools*)
    frameworks="$developer/Library/Developer/Frameworks"
    libs="$developer/Library/Developer/usr/lib"
    exec swift test \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$libs" "$@"
    ;;
*)
    exec swift test "$@"
    ;;
esac
