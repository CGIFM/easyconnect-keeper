#!/bin/sh
# 构建「EasyConnect 控制台」图形应用，并放到 /Applications（不可写时退回 ~/Applications）。
# 用法： sh build-control-app.sh
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="EasyConnect 控制台"
DEST="/Applications/$APP_NAME.app"
if [ ! -w "/Applications" ]; then
    mkdir -p "$HOME/Applications"
    DEST="$HOME/Applications/$APP_NAME.app"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "🔨 编译 $APP_NAME ..."
swiftc -O "$DIR/ControlPanel.swift" -o "$TMP/EasyConnectControl" -framework Cocoa

CONTENTS="$DEST/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$TMP/EasyConnectControl" "$CONTENTS/MacOS/EasyConnectControl"
chmod +x "$CONTENTS/MacOS/EasyConnectControl"

# 生成图标（失败不影响构建）
if swiftc -O "$DIR/IconMaker.swift" -o "$TMP/iconmaker" -framework Cocoa >/dev/null 2>&1 \
   && "$TMP/iconmaker" "$TMP/icon.png" >/dev/null 2>&1 && [ -f "$TMP/icon.png" ]; then
    ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
        d=$((s * 2))
        sips -z "$d" "$d" "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns" >/dev/null 2>&1 || true
fi

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.cgifm.easyconnect-control</string>
    <key>CFBundleExecutable</key><string>EasyConnectControl</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><false/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
# 让 Launch Services 重新索引，启动台/聚焦能立即搜到
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" >/dev/null 2>&1 || true

# 桌面快捷方式（若桌面存在）
if [ -d "$HOME/Desktop" ]; then
    ln -sfn "$DEST" "$HOME/Desktop/$APP_NAME.app"
fi

echo "✅ 已安装: $DEST"
echo "   打开: open -a '$APP_NAME'"
