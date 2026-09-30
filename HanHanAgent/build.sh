#!/usr/bin/env bash
# 编译打包 HanHan Agent.app (临时 ad-hoc 签名)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/HanHan Agent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc main.swift -o "$APP/Contents/MacOS/HanHanAgent" -framework Cocoa -framework ApplicationServices
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
