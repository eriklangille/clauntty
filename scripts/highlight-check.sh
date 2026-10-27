#!/bin/sh
# Build and run HighlightKit's check on this Mac, with the app's Highlighter.swift:
#   scripts/highlight-check.sh queries                 every grammar's query compiles
#   scripts/highlight-check.sh html out.html FILE...   files rendered to look at
# Needs scripts/build-highlightkit.py to have run.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
kit=$root/build/highlightkit
bin=$kit/highlight-check
if [ ! -x "$bin" ] || [ -n "$(find "$root/Clauntty/Core/Session/Highlighter.swift" "$root/HighlightKit/check" "$kit/lib/macos-arm64_x86_64/libHighlightKit.a" -newer "$bin")" ]; then
  xcrun swiftc -O -I "$kit/headers/HighlightKit" -L "$kit/lib/macos-arm64_x86_64" -lHighlightKit \
    -module-cache-path "$kit/module-cache" \
    "$root/Clauntty/Core/Session/Highlighter.swift" "$root/HighlightKit/check/main.swift" -o "$bin"
fi
exec "$bin" "$@"
