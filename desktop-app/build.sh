#!/bin/zsh
# 构建独立桌宠 App（不依赖 Codex），并放到桌面
# 用法: ./build.sh
set -e
cd "$(dirname "$0")"

STAGING="$(mktemp -d /private/tmp/pearl-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/珍珠小子.app"
xcrun swiftc -O -o "$STAGING/PearlPet" main.swift ChatServiceManager.swift ChatWindowController.swift -framework AppKit -framework WebKit

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X "$STAGING/PearlPet" "$APP/Contents/MacOS/PearlPet"
# 优先使用扩展雪碧图（含第 10 行抱抱动画），没有则用标准 9 行版
if [ -f ../bead-girl/spritesheet-extended.webp ]; then
  cp -X ../bead-girl/spritesheet-extended.webp "$APP/Contents/Resources/spritesheet.webp"
else
  cp -X ../bead-girl/spritesheet.webp "$APP/Contents/Resources/spritesheet.webp"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>珍珠小子</string>
	<key>CFBundleDisplayName</key><string>珍珠小子</string>
	<key>CFBundleIdentifier</key><string>com.ceci.pearl-guy-pet</string>
	<key>CFBundleExecutable</key><string>PearlPet</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
EOF

xattr -cr "$APP"
codesign --force -s - "$APP"
codesign --verify --strict "$APP"
mkdir -p build
rm -rf "build/珍珠小子.app"
ditto --noextattr --norsrc "$APP" "build/珍珠小子.app"

# Build only by default, so verification precedes desktop replacement.
if [[ "${1:-}" == "--install" ]]; then
  DESKTOP_APP="$HOME/Desktop/珍珠小子.app"
  if [[ -e "$DESKTOP_APP" ]]; then
    BACKUP="$HOME/Desktop/珍珠小子备份-$(date +%Y%m%d-%H%M%S)-$$.app"
    mv "$DESKTOP_APP" "$BACKUP"
    echo "旧版备份：$BACKUP"
  fi
  ditto --noextattr --norsrc "$APP" "$DESKTOP_APP"
  # Preserve the previous Finder custom icon after installing the signed bundle.
  if [[ -n "${BACKUP:-}" && -f "$BACKUP/"$'Icon\r' ]]; then
    ditto "$BACKUP/"$'Icon\r' "$DESKTOP_APP/"$'Icon\r'
    ICON_INFO="$(xattr -px com.apple.FinderInfo "$BACKUP" 2>/dev/null || true)"
    if [[ -n "$ICON_INFO" ]]; then
      xattr -wx com.apple.FinderInfo "$ICON_INFO" "$DESKTOP_APP"
    fi
    touch "$DESKTOP_APP"
  fi
  echo "已更新：$DESKTOP_APP"
else
  echo "已构建：$PWD/build/珍珠小子.app（验证后使用 ./build.sh --install 备份并更新桌面 App）"
fi
