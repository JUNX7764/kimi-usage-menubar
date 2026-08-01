#!/bin/bash
# 编译并打包 KimiUsage 菜单栏小工具
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/KimiUsage.app"

echo "== 编译 Swift 源码 =="
swiftc -O -o "$DIR/KimiUsage-bin" "$DIR/KimiUsage.swift"

echo "== 打包 .app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mv "$DIR/KimiUsage-bin" "$APP/Contents/MacOS/KimiUsage"
chmod +x "$APP/Contents/MacOS/KimiUsage"

echo "== ad-hoc 签名 =="
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "== 完成: $APP =="
