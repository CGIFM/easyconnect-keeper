#!/bin/bash
# =============================================================
# EasyConnect Keeper v3 —— EasyConnect VPN 断线自动重连守护程序
# =============================================================
# 原理（三层状态机）：
#   1. 联网检测：每轮先 ping 双公网目标（223.5.5.5 / 119.29.29.29），
#      任一通即判定「本机有网」。断网时只持续监听网络（3s 级），
#      绝不重启 EasyConnect（避免断网时白白杀客户端）。
#   2. 隧道检测：有网时轮询 EasyConnect 本地 API
#      https://127.0.0.1:54530/ECAgent?op=DoQueryService&arg1=QUERY QSTATE L3VPN
#      result=18 (STATUS_START_SUCCESS) 即隧道正常；其他值/超时 = 异常。
#   3. 分层重连：连续 N 次异常才触发（防抖）；网络刚恢复时跳过防抖
#      给 EasyConnect 一个自愈窗口，没自己连上就立即重启客户端。
#
# 状态上报与控制（供菜单栏应用 KeeperBar 使用）：
#   $RUN_DIR/state       实时状态（一行 JSON）
#   $RUN_DIR/pause       存在此文件 = 守护暂停中
#   $RUN_DIR/resume.touch  菜单栏写入此文件 = 请求恢复
#   LaunchAgent KeepAlive 保证 keeper 进程本身永不退出。
# =============================================================

set -u

EC_PORT=54530
EC_API="https://127.0.0.1:${EC_PORT}/ECAgent"
EC_APP="/Applications/EasyConnect.app"
STATUS_OK=18                       # STATUS_START_SUCCESS
CHECK_INTERVAL=10                  # 有网时每 10 秒检测一次隧道
NET_PROBE_INTERVAL=3               # 断网/刚恢复时每 3 秒探测网络
FAIL_THRESHOLD=3                   # 连续失败 3 次（约 30 秒）判定断开
SELF_HEAL_WINDOW=15                # 网络恢复后给 EasyConnect 的自愈窗口(秒)
RETRY_INTERVAL=15                  # 触发重连后的轮询间隔
NET_PROBE_TARGETS=("223.5.5.5" "119.29.29.29")   # 阿里/腾讯公共 DNS 双目标

RUN_DIR="$HOME/Library/Application Support/EasyConnectKeeper"
STATE_FILE="$RUN_DIR/state"
PAUSE_FILE="$RUN_DIR/pause"
LOG_DIR="$HOME/Library/Logs/easyconnect-keeper"
LOG_FILE="$LOG_DIR/keeper.log"
MAX_LOG_SIZE=$((1024*1024*2))      # 日志超 2MB 轮转

mkdir -p "$RUN_DIR" "$LOG_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() { echo "[$(ts)] $1" >> "$LOG_FILE"; }

# 上报实时状态给菜单栏（last_result 供排障）
write_state() {
    printf '{"status":"%s","time":"%s","last_result":"%s"}\n' \
        "$1" "$(ts)" "${2:--}" > "$STATE_FILE"
}

# 日志轮转
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        log "日志已轮转"
    fi
}

# 联网检测：任一目标 ping 通即算有网
net_up() {
    local t
    for t in "${NET_PROBE_TARGETS[@]}"; do
        if ping -c 1 -W 1500 -t 2 "$t" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# 查询 L3VPN 隧道状态。输出 result 数字；查询失败输出 000
query_status() {
    local resp
    resp=$(curl -sk --connect-timeout 3 --max-time 6 \
        "${EC_API}?op=DoQueryService&arg1=QUERY%20QSTATE%20L3VPN" 2>/dev/null)
    if [ -z "$resp" ]; then
        echo 000; return
    fi
    local r
    r=$(printf '%s' "$resp" | sed -n 's/.*"result":"\{0,1\}\(-\{0,1\}[0-9]*\)"\{0,1\}.*/\1/p')
    if [ -z "$r" ]; then echo 000; else echo "$r"; fi
}

# 判断 EasyConnect 主程序是否存活
gui_alive() {
    pgrep -f "/Applications/EasyConnect.app/Contents/MacOS/EasyConnect" >/dev/null 2>&1
}

# 重启 GUI（自动登录接管）
restart_gui() {
    log "⚡ 重启 EasyConnect GUI..."
    write_state RECONNECTING
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
    write_state RECONNECTING
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

# ===== 网络状态机：断网→持续监听→恢复后处理隧道 =====
wait_net_then_heal() {
    log "🌐 检测到断网，进入持续网络监听（每 ${NET_PROBE_INTERVAL}s 探测，不重启 EasyConnect）"
    write_state OFFLINE
    while ! net_up; do
        sleep $NET_PROBE_INTERVAL
    done
    log "✅ 网络已恢复，先给 ${SELF_HEAL_WINDOW}s 自愈窗口再检查隧道"
    write_state RECONNECTING "net-back"
    local waited=0
    while [ $waited -lt $SELF_HEAL_WINDOW ]; do
        sleep $NET_PROBE_INTERVAL
        waited=$((waited + NET_PROBE_INTERVAL))
        local st
        st=$(query_status)
        if [ "$st" = "$STATUS_OK" ]; then
            log "✅ EasyConnect 在网络恢复后自愈成功 (result=$st)"
            return 0
        fi
    done
    log "⚡ 自愈窗口内隧道未恢复 (result=$(query_status))，立即触发重连"
    return 2
}

# 立即重连（跳过防抖计数）：拉起→普通重启→深度重启
force_reconnect() {
    write_state RECONNECTING
    if ! gui_alive; then
        log "GUI 未运行，直接拉起"
        open "$EC_APP"
    else
        restart_gui
    fi
    if wait_recover 120; then
        return 0
    fi
    log "❌ 重连等待 120s 超时，升级深度重启"
    hard_restart
    if wait_recover 120; then
        return 0
    fi
    log "❌ 深度重启仍未恢复，回到主循环继续监测"
    return 1
}

# ===== 暂停模式：盯住 pause 文件被删除 =====
# 暂停期间不干预用户操作。菜单栏「恢复守护」= 直接删除 pause 文件，
# 本循环检测到文件消失即退出暂停（无竞态）。
pause_loop() {
    log "⏸️ 守护已暂停（不检测、不重启；删除 pause 文件即恢复）"
    write_state PAUSED
    while [ -e "$PAUSE_FILE" ]; do
        sleep 1
    done
    log "▶️ pause 文件已移除，退出暂停"
}

# 主循环
log "===== EasyConnect Keeper v3 启动 (pid=$$) ====="
log "检测间隔=${CHECK_INTERVAL}s, 失败阈值=${FAIL_THRESHOLD}, 网络探测=${NET_PROBE_INTERVAL}s, 状态OK=${STATUS_OK}"

fail_count=0
gui_restart_count=0
offline_count=0

while true; do
    rotate_log

    # 暂停检查（菜单栏控制）
    if [ -e "$PAUSE_FILE" ]; then
        pause_loop
        fail_count=0
        gui_restart_count=0
        offline_count=0
        continue
    fi

    # 第一优先：联网检测
    if ! net_up; then
        offline_count=$((offline_count + 1))
        if [ $offline_count -ge 2 ]; then
            wait_net_then_heal     # 阻塞在网络监听里，恢复后返回
            if [ $? -eq 2 ]; then
                force_reconnect    # 自愈失败，立即重连
            fi
            offline_count=0
            fail_count=0
            gui_restart_count=0
            continue
        fi
        sleep $NET_PROBE_INTERVAL
        continue
    fi
    offline_count=0

    # 第二优先：隧道检测
    st=$(query_status)

    if [ "$st" = "$STATUS_OK" ]; then
        fail_count=0
        gui_restart_count=0
        write_state OK "$st"
        sleep $CHECK_INTERVAL
        continue
    fi

    fail_count=$((fail_count + 1))
    if [ $fail_count -lt $FAIL_THRESHOLD ]; then
        log "⚠️ 状态异常 (result=$st) 第 ${fail_count}/${FAIL_THRESHOLD} 次，继续观察"
        write_state ABNORMAL "$st"
        sleep $CHECK_INTERVAL
        continue
    fi

    log "❌ 连续 ${FAIL_THRESHOLD} 次状态异常 (result=$st)，触发重连"
    write_state RECONNECTING "$st"

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
