#!/bin/zsh
# 构建独立桌宠 App（不依赖 Codex），并放到桌面
# 用法: ./build.sh
set -e
cd "$(dirname "$0")"

APP="build/珍珠小子.app"
xcrun swiftc -O -o PearlPet main.swift -framework AppKit

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp PearlPet "$APP/Contents/MacOS/PearlPet"
# 优先使用扩展雪碧图（含第 10 行抱抱动画），没有则用标准 9 行版
if [ -f ../bead-girl/spritesheet-extended.webp ]; then
  cp ../bead-girl/spritesheet-extended.webp "$APP/Contents/Resources/spritesheet.webp"
else
  cp ../bead-girl/spritesheet.webp "$APP/Contents/Resources/spritesheet.webp"
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

rm -rf ~/Desktop/珍珠小子.app
cp -R "$APP" ~/Desktop/
echo "完成：~/Desktop/珍珠小子.app（双击启动，右键宠物可退出）"
