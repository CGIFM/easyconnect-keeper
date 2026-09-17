#!/bin/bash
# EasyConnect Keeper 安装 / 卸载
set -euo pipefail

PLIST_NAME="com.cgifm.easyconnect-keeper.plist"
SRC_PLIST="$(cd "$(dirname "$0")" && pwd)/$PLIST_NAME"
DEST_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs/easyconnect-keeper"

install() {
    mkdir -p "$LOG_DIR"
    chmod +x "$(cd "$(dirname "$0")" && pwd)/keeper.sh"
    cp "$SRC_PLIST" "$DEST_PLIST"
    launchctl unload "$DEST_PLIST" 2>/dev/null || true
    launchctl load "$DEST_PLIST"
    echo "✅ 已安装并启动：$DEST_PLIST"
    echo "   日志：tail -f $LOG_DIR/keeper.log"
}

uninstall() {
    if [ -f "$DEST_PLIST" ]; then
        launchctl unload "$DEST_PLIST" 2>/dev/null || true
        rm "$DEST_PLIST"
        echo "🛑 已卸载"
    else
        echo "未安装"
    fi
}

status() {
    launchctl list | grep easyconnect-keeper || echo "未在运行"
    tail -5 "$LOG_DIR/keeper.log" 2>/dev/null || echo "暂无日志"
}

case "${1:-}" in
    install)   install ;;
    uninstall) uninstall ;;
    status)    status ;;
    *)         echo "用法：$0 {install|uninstall|status}" ;;
esac
