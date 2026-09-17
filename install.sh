#!/bin/bash
# =============================================================
# EasyConnect Keeper v3 安装 / 卸载 / 状态
# =============================================================
# 标准安装布局（与源码解耦，卸载干净）：
#   ~/Library/Application Support/EasyConnectKeeper/
#     ├── keeper.sh                       守护脚本（实际运行副本）
#     ├── KeeperBar.app                   菜单栏管理应用
#     └── com.cgifm.easyconnect-keeper.plist   LaunchAgent 模板
#   ~/Library/LaunchAgents/com.cgifm.easyconnect-keeper.plist  开机自启
#   ~/Library/Logs/easyconnect-keeper/     日志
# =============================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/EasyConnectKeeper"
PLIST_NAME="com.cgifm.easyconnect-keeper.plist"
DEST_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs/easyconnect-keeper"
BAR_APP="$APP_SUPPORT/KeeperBar.app"

install() {
    echo "📦 安装 EasyConnect Keeper v3 ..."

    # 1. 程序文件部署
    mkdir -p "$APP_SUPPORT" "$LOG_DIR"
    cp "$SRC_DIR/keeper.sh" "$APP_SUPPORT/keeper.sh"
    chmod +x "$APP_SUPPORT/keeper.sh"

    # 2. 编译菜单栏应用（有 Swift 编译器才装；没有则跳过仅装守护）
    if command -v swiftc >/dev/null 2>&1; then
        echo "🔧 编译菜单栏应用 KeeperBar.app ..."
        build_bar_app
    else
        echo "⚠️ 未检测到 swiftc，跳过菜单栏应用（守护功能不受影响）"
    fi

    # 3. LaunchAgent（指向安装目录的 keeper.sh）
    cat > "$DEST_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cgifm.easyconnect-keeper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$APP_SUPPORT/keeper.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF

    launchctl unload "$DEST_PLIST" 2>/dev/null || true
    launchctl load "$DEST_PLIST"

    # 4. 菜单栏应用设为开机自启（通过 LoginItem 的 LaunchAgent 方式）
    if [ -d "$BAR_APP" ]; then
        cat > "$HOME/Library/LaunchAgents/com.cgifm.keeperbar.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cgifm.keeperbar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BAR_APP/Contents/MacOS/KeeperBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
        launchctl unload "$HOME/Library/LaunchAgents/com.cgifm.keeperbar.plist" 2>/dev/null || true
        launchctl load "$HOME/Library/LaunchAgents/com.cgifm.keeperbar.plist"
        echo "✅ 菜单栏应用已启动并设为开机自启"
    fi

    echo ""
    echo "✅ EasyConnect Keeper v3 安装完成"
    echo "   状态栏找 🛡 盾牌图标可管理（暂停/自启开关/卸载）"
    echo "   日志：tail -f $LOG_DIR/keeper.log"
}

build_bar_app() {
    local build_dir
    build_dir=$(mktemp -d)
    swiftc -O -o "$build_dir/KeeperBar" "$SRC_DIR/KeeperBar.swift"

    local contents="$BAR_APP/Contents"
    mkdir -p "$contents/MacOS" "$contents/Resources"
    cp "$build_dir/KeeperBar" "$contents/MacOS/KeeperBar"
    cp "$SRC_DIR/$PLIST_NAME" "$contents/Resources/$PLIST_NAME"

    cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>KeeperBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.cgifm.keeperbar</string>
    <key>CFBundleExecutable</key>
    <string>KeeperBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>3.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
    rm -rf "$build_dir"
    echo "✅ KeeperBar.app 编译部署完成"
}

uninstall() {
    echo "🛑 卸载 EasyConnect Keeper ..."
    launchctl unload "$DEST_PLIST" 2>/dev/null || true
    rm -f "$DEST_PLIST"
    launchctl unload "$HOME/Library/LaunchAgents/com.cgifm.keeperbar.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.cgifm.keeperbar.plist"
    pkill -f "KeeperBar" 2>/dev/null || true
    rm -rf "$APP_SUPPORT"
    echo "✅ 已卸载（日志保留在 $LOG_DIR，如需删除：rm -rf '$LOG_DIR'）"
}

status() {
    echo "── 守护进程 ──"
    launchctl list | grep easyconnect-keeper || echo "未加载"
    echo "── 菜单栏应用 ──"
    launchctl list | grep keeperbar || echo "未加载"
    pgrep -f "KeeperBar" >/dev/null && echo "KeeperBar 运行中" || echo "KeeperBar 未运行"
    echo "── 实时状态 ──"
    cat "$APP_SUPPORT/state" 2>/dev/null || echo "无状态文件"
    echo "── 最近日志 ──"
    tail -5 "$LOG_DIR/keeper.log" 2>/dev/null || echo "暂无日志"
}

case "${1:-}" in
    install)   install ;;
    uninstall) uninstall ;;
    status)    status ;;
    *)         echo "用法：$0 {install|uninstall|status}" ;;
esac
