#!/bin/bash
# Runs the pure-logic tests. Wrapper exists because `swift test` alone does NOT work here:
# Klip builds on the Command Line Tools (no Xcode), and CLT ships swift-testing in a layout
# SwiftPM doesn't search — Testing.framework in Library/Developer/Frameworks and its
# lib_TestingInterop.dylib one level over in Library/Developer/usr/lib. So: -F to compile
# against the framework, plus an rpath for each so dyld can load them at run time.
# With Xcode installed, plain `swift test` works and this wrapper is harmless.
set -euo pipefail

# Prefer the Command Line Tools when a freshly-installed Xcode has an unaccepted license — that
# state makes every swift/xcrun call fail with "You have not agreed to the Xcode license
# agreements", which looks like a broken build. Only used if the CLT are actually present.
if [ -z "${DEVELOPER_DIR:-}" ] && ! /usr/bin/xcrun --find swift >/dev/null 2>&1 \
   && [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

cd "$(dirname "$0")"

CLT="${DEVELOPER_DIR:-$(xcode-select -p)}"
FW="$CLT/Library/Developer/Frameworks"
LIB="$CLT/Library/Developer/usr/lib"

# Command Line Tools 27: the macOS 27 SDK needs SwiftUI macros that ship only with Xcode (same fallback
# as build.sh), and swift-testing's macro plugin moved to host/plugins/testing, which SwiftPM doesn't search.
if [ -z "${SDKROOT:-}" ] && [ ! -d "$CLT/Platforms" ] \
   && [ ! -e "$CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
   && [ -d "$CLT/SDKs/MacOSX26.sdk" ]; then
    export SDKROOT="$(cd "$CLT/SDKs/MacOSX26.sdk" && pwd -P)"
fi
PLUGIN_ARGS=()
if [ -d "$CLT/usr/lib/swift/host/plugins/testing" ]; then
    PLUGIN_ARGS=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
fi

if [ ! -d "$FW/Testing.framework" ]; then
    echo "==> Testing.framework not found under $FW — running plain 'swift test'."
    exec swift test "$@"
fi

exec swift test \
    ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
