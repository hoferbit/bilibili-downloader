#!/bin/bash
# 编译并打包 BiliDownloader.app 和命令行工具 bilidl，输出到 build/
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="B站下载器"
APP="build/${APP_NAME}.app"
BUNDLE_ID="local.bilidownloader"
VERSION="1.0.0"

echo "==> 编译 (release)"
swift build -c release --product BiliDownloader
swift build -c release --product bilidl
BIN="$(swift build -c release --show-bin-path)"

echo "==> 打包 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BiliDownloader" "$APP/Contents/MacOS/BiliDownloader"
cp "$BIN/bilidl" build/bilidl

if [ ! -f build/AppIcon.icns ]; then
  echo "==> 生成图标"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  rm -rf "$ICONSET" build/icon-1024.png
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>BiliDownloader</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 本地临时签名，避免“已损坏”提示
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> 完成"
echo "    App:  $(pwd)/$APP"
echo "    CLI:  $(pwd)/build/bilidl"
