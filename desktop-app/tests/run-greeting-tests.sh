#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
GREETING_STAGE=$(mktemp -d /private/tmp/pearl-greeting-tests.XXXXXX)
trap 'rm -rf "$GREETING_STAGE"' EXIT
sed '/\/\/ MARK: - Pet view/,$d' main.swift > "$GREETING_STAGE/main.swift"
cat tests/GreetingFramesTests.swift >> "$GREETING_STAGE/main.swift"
xcrun swiftc -module-cache-path "$GREETING_STAGE/modules" -o "$GREETING_STAGE/test-greeting" "$GREETING_STAGE/main.swift" -framework AppKit -framework ImageIO
"$GREETING_STAGE/test-greeting" ../bead-girl/spritesheet.webp waving-animation/design.png ../preview
