#!/bin/bash
# =============================================================
# EasyConnect Keeper —— EasyConnect VPN 断线自动重连守护程序
# =============================================================
# 原理：
#   1. 轮询 EasyConnect 本地 API（https://127.0.0.1:54530）
#      op=DoQueryService&arg1=QUERY QSTATE L3VPN
#      返回 result=18 (STATUS_START_SUCCESS) 即隧道正常；
#      其他值 / 超时 / ECAgent 挂了 都视为断开。
#   2. 连续 N 次检测失败（避免网络抖动误判）才触发重连。
#   3. 重连策略分层：
#      a) ECAgent 后台还在 → 优先重启 GUI（EasyConnect 配置了
#         auto_login=true，重启后自动用保存的密码登录）。
#      b) GUI 还活着但反复失败 → 彻底杀掉所有 EC 进程后重启。
#   4. 全程写日志到 $LOG_FILE，断开/重连事件可追溯。
# =============================================================

set -u

EC_PORT=54530
EC_API="https://127.0.0.1:${EC_PORT}/ECAgent"
EC_APP="/Applications/EasyConnect.app"
EC_SERVER="td.jlcerp.com"          # VPN 服务器主机（来自 CSClient 进程参数）
STATUS_OK=18                       # STATUS_START_SUCCESS
CHECK_INTERVAL=10                  # 正常时每 10 秒检测一次
FAIL_THRESHOLD=3                   # 连续失败 3 次（约 30 秒）判定断开
RETRY_INTERVAL=15                  # 触发重连后的轮询间隔
RESTART_GUI_CMD="open -a EasyConnect"

LOG_DIR="$HOME/Library/Logs/easyconnect-keeper"
LOG_FILE="$LOG_DIR/keeper.log"
MAX_LOG_SIZE=$((1024*1024*2))      # 日志超 2MB 轮转

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() { echo "[$(ts)] $1" >> "$LOG_FILE"; }

# 日志轮转
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        log "日志已轮转"
    fi
}

# 查询 L3VPN 隧道状态。输出 result 数字；查询失败输出 000
query_status() {
    local resp
    resp=$(curl -sk --connect-timeout 3 --max-time 6 \
        "${EC_API}?op=DoQueryService&arg1=QUERY%20QSTATE%20L3VPN" 2>/dev/null)
    if [ -z "$resp" ]; then
        echo 000; return
    fi
    # 提取 "result":"xx"
    local r
    r=$(printf '%s' "$resp" | sed -n 's/.*"result":"\{0,1\}\(-\{0,1\}[0-9]*\)"\{0,1\}.*/\1/p')
    if [ -z "$r" ]; then echo 000; else echo "$r"; fi
}

# 判断 EasyConnect 主程序 / ECAgent 是否存活
gui_alive() {
    pgrep -f "/Applications/EasyConnect.app/Contents/MacOS/EasyConnect" >/dev/null 2>&1
}
ecagent_alive() {
    pgrep -f "ECAgent" >/dev/null 2>&1
}

# 重启 GUI（自动登录接管）
restart_gui() {
    log "⚡ 重启 EasyConnect GUI..."
    osascript -e 'tell application "EasyConnect" to quit' >/dev/null 2>&1
    sleep 2
    pkill -f "/Applications/EasyConnect.app/Contents/MacOS/EasyConnect" 2>/dev/null
    sleep 1
    open "$EC_APP"
    log "🚀 GUI 已重新拉起，等待自动登录..."
}

# 深度重启：连 ECAgent / svpnservice 一起杀掉重来
hard_restart() {
    log "🔥 深度重启：终止所有 EasyConnect 进程..."
    pkill -f "/Applications/EasyConnect.app/Contents/MacOS/EasyConnect" 2>/dev/null
    sleep 1
    pkill -f "ECAgent" 2>/dev/null
    pkill -f "svpnservice" 2>/dev/null
    pkill -f "CSClient" 2>/dev/null
    sleep 2
    open "$EC_APP"
    log "🚀 已重新拉起 EasyConnect，等待自动登录..."
}

# 等待隧道恢复（最多等 max_wait 秒）
wait_recover() {
    local max_wait=$1 waited=0
    while [ $waited -lt $max_wait ]; do
        sleep $RETRY_INTERVAL
        waited=$((waited + RETRY_INTERVAL))
        local st
        st=$(query_status)
        if [ "$st" = "$STATUS_OK" ]; then
            log "✅ 隧道已恢复 (result=$st, 等待 ${waited}s)"
            return 0
        fi
        log "⏳ 等待重连中... (result=$st, ${waited}s/${max_wait}s)"
    done
    return 1
}

# 主循环
log "===== EasyConnect Keeper 启动 (pid=$$) ====="
log "检测间隔=${CHECK_INTERVAL}s, 失败阈值=${FAIL_THRESHOLD} 次, 状态OK=${STATUS_OK}"

fail_count=0
gui_restart_count=0

while true; do
    rotate_log
    st=$(query_status)

    if [ "$st" = "$STATUS_OK" ]; then
        fail_count=0
        gui_restart_count=0
        sleep $CHECK_INTERVAL
        continue
    fi

    fail_count=$((fail_count + 1))
    if [ $fail_count -lt $FAIL_THRESHOLD ]; then
        log "⚠️ 状态异常 (result=$st) 第 ${fail_count}/${FAIL_THRESHOLD} 次，继续观察"
        sleep $CHECK_INTERVAL
        continue
    fi

    log "❌ 连续 ${FAIL_THRESHOLD} 次状态异常 (result=$st)，触发重连"

    # 分层重连：GUI 不在 → 直接拉起；GUI 在但断线 → 先普通重启，反复失败再深度重启
    if ! gui_alive; then
        log "GUI 未运行，直接拉起"
        open "$EC_APP"
    else
        if [ $gui_restart_count -lt 1 ]; then
            restart_gui
            gui_restart_count=$((gui_restart_count + 1))
        else
            hard_restart
            gui_restart_count=0
        fi
    fi

    if wait_recover 120; then
        fail_count=0
        gui_restart_count=0
    else
        log "❌ 重连等待 120s 超时，将再次尝试"
        fail_count=$((FAIL_THRESHOLD - 1))   # 下一轮再失败 1 次即立刻重试
    fi
done
