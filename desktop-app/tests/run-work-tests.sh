#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
TEST_STAGE=$(mktemp -d /private/tmp/pearl-work-tests.XXXXXX)
trap 'rm -rf "$TEST_STAGE"' EXIT
sed '/\/\/ MARK: - Entry point/,$d' main.swift > "$TEST_STAGE/main.swift"
cat tests/PetWorkTests.swift >> "$TEST_STAGE/main.swift"
xcrun swiftc -module-cache-path "$TEST_STAGE/modules" -o "$TEST_STAGE/test-work" "$TEST_STAGE/main.swift" ChatServiceManager.swift ChatWindowController.swift -framework AppKit -framework WebKit
"$TEST_STAGE/test-work" ../bead-girl/spritesheet.webp
