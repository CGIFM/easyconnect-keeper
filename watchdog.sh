#!/bin/bash
# =============================================================
# watchdog.sh —— 主守护的外部健康检查（单向看门狗）
# =============================================================
# 原则：只认心跳文件，不做网络探测（与主守护职责分离，不互相重启）。
#   心跳 > HEARTBEAT_STALE 秒未更新 → 判定检测循环卡死/假死
#   → 杀掉主守护进程，launchd KeepAlive 自动拉起新实例。
# 自身由 launchd 独立拉起，间隔运行，天然不会和主守护互锁。
# =============================================================

set -u

RUN_DIR="$HOME/Library/Application Support/EasyConnectKeeper"
HEARTBEAT_FILE="$RUN_DIR/heartbeat"
LOG_FILE="$HOME/Library/Logs/easyconnect-keeper/watchdog.log"

HEARTBEAT_STALE=120      # 心跳超过 120s 未更新视为卡死
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $1" >> "$LOG_FILE"; }

log "--- watchdog 运行 ---"

# 主守护进程存在吗
main_pids=$(pgrep -f "Application Support/EasyConnectKeeper/keeper.sh" 2>/dev/null)
if [ -z "$main_pids" ]; then
    log "ℹ️ 主守护未运行（launchd 应会拉起，本次不动）"
    exit 0
fi

# 心跳检查
if [ ! -f "$HEARTBEAT_FILE" ]; then
    log "⚠️ 心跳文件不存在，等待下轮再判（新实例可能刚启动）"
    exit 0
fi

hb_ts=$(python3 -c "
import json,sys
try:
    with open('$HEARTBEAT_FILE') as f: d=json.load(f)
    print(d.get('ts_epoch',0))
except: print(0)
")

now=$(date +%s)
age=$(( now - hb_ts ))

if [ "$age" -gt "$HEARTBEAT_STALE" ]; then
    log "🚨 心跳过期 ${age}s（阈值 ${HEARTBEAT_STALE}s），杀掉主守护 pid=$main_pids 交 launchd 重建"
    kill -9 $main_pids 2>/dev/null
    exit 0
fi

log "✅ 心跳正常（${age}s 前）"
