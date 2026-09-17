#!/bin/bash
# =============================================================
# EasyConnect Keeper v4 安装 / 卸载 / 状态 / 回退
# =============================================================
# 布局（版本化发布，原子切换）：
#   ~/Library/Application Support/EasyConnectKeeper/
#     ├── releases/v4/            版本化程序目录（keeper.sh lib/ watchdog.sh keeperctl）
#     ├── current -> releases/v4  原子软链，LaunchAgent 指向 current
#     ├── KeeperBar.app           菜单栏应用
#     └── ...运行时状态文件
#   ~/Library/LaunchAgents/
#     ├── com.cgifm.easyconnect-keeper.plist      主守护（KeepAlive）
#     ├── com.cgifm.easyconnect-keeper-watchdog.plist  看门狗
#     └── com.cgifm.keeperbar.plist               菜单栏
# 回退: install.sh rollback [v3|v4]  重新指向旧版本软链并重载
# =============================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/EasyConnectKeeper"
REL_DIR="$APP_SUPPORT/releases"
VER="${VER:-v4}"
PLIST_NAME="com.cgifm.easyconnect-keeper.plist"
LOG_DIR="$HOME/Library/Logs/easyconnect-keeper"
BAR_APP="$APP_SUPPORT/KeeperBar.app"
LA="$HOME/Library/LaunchAgents"

install() {
    echo "📦 安装 EasyConnect Keeper $VER ..."

    mkdir -p "$APP_SUPPORT" "$LOG_DIR" "$REL_DIR/$VER" "$APP_SUPPORT/releases-v3-archive" 2>/dev/null || true

    # 0. 备份旧版运行脚本（回退用）
    if [ -f "$APP_SUPPORT/keeper.sh" ] && [ ! -d "$APP_SUPPORT/releases/v3" ]; then
        mkdir -p "$REL_DIR/v3"
        cp "$APP_SUPPORT/keeper.sh" "$REL_DIR/v3/keeper.sh" 2>/dev/null || true
        echo "🗄 旧版 v3 已归档到 releases/v3"
    fi

    # 1. 部署程序到版本目录（先装到临时目录再原子 mv）
    local stage
    stage=$(mktemp -d)
    cp -R "$SRC_DIR/keeper.sh" "$SRC_DIR/lib" "$SRC_DIR/watchdog.sh" "$SRC_DIR/keeperctl" "$stage/" 2>/dev/null || {
        cp "$SRC_DIR/keeper.sh" "$SRC_DIR/watchdog.sh" "$SRC_DIR/keeperctl" "$stage/"
        mkdir -p "$stage/lib"; cp "$SRC_DIR/lib/"* "$stage/lib/"
    }
    chmod +x "$stage/keeper.sh" "$stage/watchdog.sh" "$stage/keeperctl"
    rm -rf "$REL_DIR/$VER.new"
    mv "$stage" "$REL_DIR/$VER.new"
    rm -rf "$REL_DIR/$VER"
    mv "$REL_DIR/$VER.new" "$REL_DIR/$VER"
    # 原子切换
    ln -sfn "$REL_DIR/$VER" "$APP_SUPPORT/current"
    echo "✅ 程序部署: $APP_SUPPORT/current -> releases/$VER"

    # 2. 主守护 LaunchAgent（指向 current 软链，更新时无需改 plist）
    cat > "$LA/$PLIST_NAME" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.cgifm.easyconnect-keeper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$APP_SUPPORT/current/keeper.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>15</integer>
    <key>StandardOutPath</key><string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF

    # 3. 看门狗 LaunchAgent（每 60s 跑一次）
    cat > "$LA/com.cgifm.easyconnect-keeper-watchdog.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.cgifm.easyconnect-keeper-watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$APP_SUPPORT/current/watchdog.sh</string>
    </array>
    <key>StartInterval</key><integer>60</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR/watchdog.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/watchdog.err.log</string>
</dict>
</plist>
EOF

    launchctl unload "$LA/$PLIST_NAME" 2>/dev/null || true
    launchctl unload "$LA/com.cgifm.easyconnect-keeper-watchdog.plist" 2>/dev/null || true
    # 防多实例：清理可能残留的手动启动实例
    pkill -f "$APP_SUPPORT/keeper.sh" 2>/dev/null || true
    sleep 1
    launchctl load "$LA/$PLIST_NAME"
    launchctl load "$LA/com.cgifm.easyconnect-keeper-watchdog.plist"

    # 4. keeperctl 软链到 PATH 可及位置
    ln -sf "$APP_SUPPORT/current/keeperctl" /usr/local/bin/keeperctl 2>/dev/null \
        || ln -sf "$APP_SUPPORT/current/keeperctl" "$HOME/.local/bin/keeperctl" 2>/dev/null \
        || echo "⚠️ keeperctl 软链失败，请用 $APP_SUPPORT/current/keeperctl"

    # 5. 菜单栏应用
    if command -v swiftc >/dev/null 2>&1 && [ -f "$SRC_DIR/KeeperBar.swift" ]; then
        echo "🔧 编译菜单栏应用 KeeperBar.app ..."
        build_bar_app
        cat > "$LA/com.cgifm.keeperbar.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.cgifm.keeperbar</string>
    <key>ProgramArguments</key>
    <array><string>$BAR_APP/Contents/MacOS/KeeperBar</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
        launchctl unload "$LA/com.cgifm.keeperbar.plist" 2>/dev/null || true
        pkill -f "KeeperBar.app" 2>/dev/null || true
        launchctl load "$LA/com.cgifm.keeperbar.plist"
        echo "✅ 菜单栏应用已更新并自启"
    fi

    echo ""
    echo "✅ EasyConnect Keeper $VER 安装完成"
    echo "   命令行: keeperctl status|diag|pause|maint|ua|events|export"
    echo "   日志:   tail -f $LOG_DIR/keeper.log"
}

build_bar_app() {
    local build_dir
    build_dir=$(mktemp -d)
    swiftc -O -o "$build_dir/KeeperBar" "$SRC_DIR/KeeperBar.swift"
    local contents="$BAR_APP/Contents"
    rm -rf "$BAR_APP"
    mkdir -p "$contents/MacOS" "$contents/Resources"
    cp "$build_dir/KeeperBar" "$contents/MacOS/KeeperBar"
    cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>KeeperBar</string>
    <key>CFBundleIdentifier</key><string>com.cgifm.keeperbar</string>
    <key>CFBundleExecutable</key><string>KeeperBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>4.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
    rm -rf "$build_dir"
}

rollback() {
    local target="${1:-v3}"
    if [ ! -d "$REL_DIR/$target" ]; then
        echo "❌ 无 $target 版本可回退。可用: $(ls "$REL_DIR" 2>/dev/null)"
        exit 1
    fi
    launchctl unload "$LA/$PLIST_NAME" 2>/dev/null || true
    pkill -f "$APP_SUPPORT/keeper.sh" 2>/dev/null || true
    ln -sfn "$REL_DIR/$target" "$APP_SUPPORT/current"
    launchctl load "$LA/$PLIST_NAME"
    echo "⏪ 已回退到 $target 并重启守护"
}

uninstall() {
    echo "🛑 卸载 EasyConnect Keeper ..."
    launchctl unload "$LA/$PLIST_NAME" 2>/dev/null || true
    launchctl unload "$LA/com.cgifm.easyconnect-keeper-watchdog.plist" 2>/dev/null || true
    launchctl unload "$LA/com.cgifm.keeperbar.plist" 2>/dev/null || true
    rm -f "$LA/$PLIST_NAME" "$LA/com.cgifm.easyconnect-keeper-watchdog.plist" "$LA/com.cgifm.keeperbar.plist"
    pkill -f "KeeperBar" 2>/dev/null || true
    pkill -f "$APP_SUPPORT" 2>/dev/null || true
    rm -rf "$APP_SUPPORT"
    echo "✅ 已卸载（日志保留 $LOG_DIR，可 rm -rf）"
}

status() {
    "$APP_SUPPORT/current/keeperctl" status 2>/dev/null || echo "keeperctl 不可用"
}

case "${1:-install}" in
    install)   install ;;
    uninstall) uninstall ;;
    status)    status ;;
    rollback)  rollback "${2:-v3}" ;;
    *)         echo "用法: $0 {install|uninstall|status|rollback [ver]}" ;;
esac
