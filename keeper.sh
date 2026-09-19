#!/bin/bash
# =============================================================
# EasyConnect Keeper v4 —— 内网 API 链路无人值守守护
# =============================================================
# 目标：claude.jlcops.com 内网 API 持续可用。不把「进程活着/显示
#       已连接」当成功——以 L8 内网 API 实测为准绳。
#
# 恢复状态机（分类→动作，有边界不重启风暴）：
#   C1 断网        → wait_net：3s 级监听，恢复后走验证，不重启任何应用
#   C2 核心缺失    → 仅当无人值守模式开：open FlClash（拉起，绝不杀）
#   C3 代理失效    → 观察 2 轮（可能自愈）→ 通知；无人值守+FlClash GUI
#                    也没了才拉起 FlClash；绝不杀核心（全局红线）
#   C5 EC 未连接   → GUI 不在则拉起；GUI 在则等 1 轮自愈 → API Logout
#                    (受支持断开) → auto_login 重连 → 无 token 才 GUI 重启
#   C6 假连接      → 连续 3 轮确认 → API Logout 重连 → 深度重启兜底
#   C7 DNS/路由    → 记录证据+通知，不动全局网络配置（hosts/路由是
#                    其他任务的领地）；sysDNS 慢属环境问题仅告警
#   C8 服务端      → 记录+通知，绝不重启 VPN（避免重启风暴）
#
# 边界机制：维护锁(maintenance.lock,带TTL) / 无人值守模式开关(默认开)
#           暂停(pause,支持限时) / 分类级冷却 / 连续失败退避
#           / 同类故障 30 分钟内 3 次恢复失败 → 低频观察不放弃
# 自我守护：每轮心跳(含推进计数)；外部 watchdog 检测心跳过期杀重建
# =============================================================

set -u

RUN_DIR="$HOME/Library/Application Support/EasyConnectKeeper"
STATE_FILE="$RUN_DIR/state"
HEARTBEAT_FILE="$RUN_DIR/heartbeat"
PAUSE_FILE="$RUN_DIR/pause"
MAINT_FILE="$RUN_DIR/maintenance.lock"
UAMODE_FILE="$RUN_DIR/uamode"            # 存在=无人值守开（默认开）
EVENTS_FILE="$RUN_DIR/events.log"
FLOCK_FILE="$RUN_DIR/recover.lock"

LOG_DIR="$HOME/Library/Logs/easyconnect-keeper"
LOG_FILE="$LOG_DIR/keeper.log"
MAX_LOG_SIZE=$((1024*1024*3))

mkdir -p "$RUN_DIR" "$LOG_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/health.sh"

# ── 阈值 ──
CHECK_INTERVAL=15            # 常态检测间隔
FAIL_CONFIRM=3               # C5/C6 链路异常需连续确认次数
VERIFY_COUNT=3               # 恢复后需连续成功次数
VERIFY_INTERVAL=10
COOLDOWN_BASE=60             # 分类冷却基数（秒）
COOLDOWN_MAX=1800            # 冷却上限（30min）
RECOVER_FAIL_LIMIT=3         # 同类连续失败上限→转低频观察
LOWFREQ_INTERVAL=300         # 低频观察间隔
MAINT_TTL=7200               # 维护锁默认 TTL 2h
EVENTS_MAX=500               # 事件记录条数上限

# ── 状态（内存；bash 3.2 兼容，不用关联数组，按分类命名变量）──
PENDING_CLASS=""             # 连续异常计数用的当前分类
PENDING_COUNT=0

# 分类状态变量（C2 C3 C5 C6 C7 C8）：FS_<cls>=失败连击 NA_<cls>=下次允许 CO_<cls>=当前冷却
fs_reset() {
    for c in C2 C3 C5 C6 C7 C8; do
        eval "FS_$c=0"
        eval "NA_$c=0"
        eval "CO_$c=$COOLDOWN_BASE"
    done
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }
now() { date +%s; }
log() { echo "[$(ts)] $1" >> "$LOG_FILE"; }

# ── 心跳：区分「进程在」与「循环在推进」──
HEART_COUNT=0
heartbeat() {
    HEART_COUNT=$((HEART_COUNT+1))
    printf '{"ts_epoch":%s,"time":"%s","count":%d,"phase":"%s","pid":%d}\n' \
        "$(now)" "$(ts)" "$HEART_COUNT" "${1:-idle}" $$ > "$HEARTBEAT_FILE"
}

write_state() {   # $1=分类 $2=简述 $3=动作(可空)
    printf '{"status":"%s","desc":"%s","action":"%s","time":"%s","ua":"%s"}\n' \
        "$1" "${2//\"/}" "${3//\"/}" "$(ts)" \
        "$( [ -e "$UAMODE_FILE" ] && echo on || echo off )" > "$STATE_FILE"
}

# ── 事件记录（证据/分类/动作/耗时/验证）+ 有界 ──
record_event() {  # $1=分类 $2=动作 $3=耗时s $4=验证结果 $5=证据摘要
    local line
    line="$(ts) | ${1} | action=${2:-none} | ${3:-0}s | verify=${4:-pending} | ${5:-}"
    echo "$line" >> "$EVENTS_FILE"
    # 有界：超过 EVENTS_MAX 行则砍掉前一半
    if [ -f "$EVENTS_FILE" ] && [ "$(wc -l < "$EVENTS_FILE")" -gt "$EVENTS_MAX" ]; then
        tail -n $((EVENTS_MAX / 2)) "$EVENTS_FILE" > "$EVENTS_FILE.tmp"
        mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
    fi
    log "📅 $line"
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        log "日志已轮转"
    fi
}

notify() {
    osascript -e "display notification \"$1\" with title \"EasyConnect Keeper\" sound name \"Glass\"" >/dev/null 2>&1
}

# ── 模式与锁 ──
ua_enabled() { [ -e "$UAMODE_FILE" ]; }
in_maintenance() {
    [ -e "$MAINT_FILE" ] || return 1
    # TTL 检查
    local mtime; mtime=$(stat -f%m "$MAINT_FILE" 2>/dev/null || echo 0)
    if [ $(( $(now) - mtime )) -gt "$MAINT_TTL" ]; then
        rm -f "$MAINT_FILE"
        log "🧹 维护锁超 TTL 自动过期"
        return 1
    fi
    return 0
}
enter_maintenance() {   # 供外部任务调用: keeper.sh maint on|off [ttl]
    case "${1:-}" in
        on)
            echo "maintainer=$(whoami) at=$(ts)" > "$MAINT_FILE"
            log "🔧 进入维护模式（TTL ${MAINT_TTL}s）"
            notify "进入维护模式，守护暂停自动恢复"
            ;;
        off) rm -f "$MAINT_FILE"; log "🔧 退出维护模式"; notify "维护模式已退出" ;;
    esac
}

# ── 恢复操作互斥（mkdir 原子锁；macOS 无 flock 命令，flock 缺失曾致恢复永不执行）──
acquire_recover_lock() {
    # v4 早期版本使用 exec 重定向创建过同名普通文件。升级后若不迁移，
    # mkdir 会永远失败，所有恢复都会被误判成“另一恢复流程进行中”。
    if [ -e "$FLOCK_FILE" ] && [ ! -d "$FLOCK_FILE" ]; then
        rm -f "$FLOCK_FILE"
        log "🧹 清除旧版普通文件恢复锁"
    fi
    # 死锁防线：锁目录 mtime 超 600s 视为上次恢复崩溃残留，自动清除
    if [ -d "$FLOCK_FILE" ]; then
        local mt
        mt=$(stat -f%m "$FLOCK_FILE" 2>/dev/null || echo 0)
        [ $(( $(now) - mt )) -gt 600 ] && { rm -rf "$FLOCK_FILE"; log "🧹 清除超时恢复锁"; }
    fi
    mkdir "$FLOCK_FILE" 2>/dev/null
}
release_recover_lock() {
    rmdir "$FLOCK_FILE" 2>/dev/null
}

# ── EC 重连原语 ──
ec_token() {
    # 从 rundata 提取 currToken（3 个重复字符串段中取一个）
    strings /tmp/sangfor.ec.rundata 2>/dev/null | grep -E '^[0-9a-f]{32}$' | head -1
}

ec_logout_api() {   # 受支持断开（实验性）：ECAgent 对 token 签名规则未完全逆向成功，
    # 实测 md5 签名被拒(-100)、原始值 result=0(未断开)。故保留尝试但
    # 不依赖它：失败自动落回 GUI 重启路线（已实机验证 auto_login 可靠）。
    local token salt sign resp
    token=$(ec_token)
    [ -z "$token" ] && return 1
    salt="__md5_salt_for_ecagent_session__"
    sign=$(printf '%s' "${token}${salt}" | md5 -q)
    resp=$(curl -sk --max-time 6 "https://127.0.0.1:$HC_EC_PORT/ECAgent?op=Logout&token=$sign" 2>/dev/null)
    [[ "$resp" == *'"result":"1"'* ]] || [[ "$resp" == *'"result":1'* ]]
}

ec_logout_api_raw() {
    # 备选签名：原始 TWFID 直传（ECAgent result=0 表达已收到但未证实断开）
    local token resp
    token=$(ec_token)
    [ -z "$token" ] && return 1
    resp=$(curl -sk --max-time 6 "https://127.0.0.1:$HC_EC_PORT/ECAgent?op=Logout&token=$token" 2>/dev/null)
    # 视为成功需随后隧道确实变化；这里只返回请求是否被接受（result 0/1）
    [[ "$resp" == *'"result":"0"'* ]] || [[ "$resp" == *'"result":"1"'* ]]
}

ec_gui_alive() { pgrep -x "EasyConnect" >/dev/null 2>&1; }

ec_launch() { open "/Applications/EasyConnect.app"; }

# macOS 自动化/辅助功能权限请求可能让 osascript 无限等待。任何 UI 操作
# 最多允许 2 秒，超时只终止本次脚本，不影响 System Events 或网络应用。
wait_ui_script() {
    local pid=$1 i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge 8 ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 1
        fi
        sleep 0.25
        i=$((i+1))
    done
    wait "$pid"
}

# 会话过期弹窗优先点击“好”，但不依赖辅助功能权限；无论点击是否成功，
# 后续都会强制退出 GUI 并重开，确保模态窗口无法阻塞自动登录。
ec_dismiss_expired_dialog() {
    local osa_pid
    osascript <<'APPLESCRIPT' >/dev/null 2>&1 &
tell application "System Events"
    if not (exists process "EasyConnect") then error number 1
    tell process "EasyConnect"
        repeat with w in windows
            try
                repeat with t in (value of every static text of w)
                    if (t as text) contains "会话已过期" then
                        if exists button "好" of w then click button "好" of w
                        return
                    end if
                end repeat
            end try
        end repeat
    end tell
end tell
error number 1
APPLESCRIPT
    osa_pid=$!
    wait_ui_script "$osa_pid"
}

ec_gui_restart() {
    local osa_pid
    ec_dismiss_expired_dialog || true
    osascript -e 'tell application "EasyConnect" to quit' >/dev/null 2>&1 &
    osa_pid=$!
    wait_ui_script "$osa_pid" || true
    sleep 2
    pkill -x "EasyConnect" 2>/dev/null || true
    sleep 1
    ec_launch
}

ec_deep_restart() {
    log "🔥 深度重启：终止 EC 全部进程后重拉"
    pkill -x "EasyConnect" 2>/dev/null
    sleep 1
    pkill -f "ECAgent" 2>/dev/null
    pkill -f "svpnservice" 2>/dev/null
    pkill -f "CSClient" 2>/dev/null
    sleep 2
    ec_launch
}

# ── FlClash 拉起（红线：只拉起消失的，绝不杀）──
flclash_launch() {
    if pgrep -f "FlClash.app" >/dev/null 2>&1; then
        log "🔒 FlClash 仍在运行，按红线不干预"
        return 1
    fi
    open "$HC_FLCLASH_APP"
    log "🚀 FlClash 未运行，已拉起"
}

# ── 验证：恢复后连续 VERIFY_COUNT 次内网通才算成功 ──
verify_recovered() {
    local ok=0 i st
    for i in $(seq 1 "$VERIFY_COUNT"); do
        sleep "$VERIFY_INTERVAL"
        st=$(hc_l8_inner_api)
        if [[ "$st" == ok* ]]; then
            ok=$((ok+1))
        else
            log "⚠️ 验证第 ${i} 次失败: $st"
            return 1
        fi
    done
    [ "$ok" -ge "$VERIFY_COUNT" ]
}

# ── 分层恢复动作（输入分类，输出: 0=恢复流程已执行 1=无动作）──
do_recover() {
    local cls=$1
    local t0=$(now)
    local action="none" rc=0

    case "$cls" in
        C1)  # 断网：交给 wait_net，不算恢复动作
            wait_net
            action="wait-net"; rc=0 ;;
        C2)
            if ua_enabled; then
                flclash_launch; action="launch-flclash"; rc=$?
                sleep 20
            else action="skip(ua-off)"; rc=0; fi ;;
        C3)
            # 代理失效：先观察，FlClash GUI 整个没了才拉起；核心在则通知（红线）
            if ! pgrep -f "FlClash.app" >/dev/null 2>&1; then
                if ua_enabled; then
                    flclash_launch; action="launch-flclash"; rc=$?
                    sleep 20
                else action="skip(ua-off)"; rc=0; fi
            else
                action="notify-only(core-alive)"; rc=0
                notify "代理端口异常但 FlClash 核心在运行，请人工检查（守护按红线不杀核心）"
            fi ;;
        C5)
            if ! ec_gui_alive; then
                ec_launch; action="launch-ec"; rc=0
            else
                # GUI 仍在但隧道未连接，常见于“会话已过期”模态弹窗。
                # 先点“好”再强制重启；点击受权限限制时，强制重启仍可兜底。
                ec_gui_restart; action="expired-session-restart"; rc=0
            fi ;;
        C6)
            # 主线：GUI 重启（受支持且已验证 auto_login 自动登录）。
            # API Logout 为实验性尝试（签名规则未完全逆向），失败不影响主线。
            action="gui-restart"
            ec_gui_restart
            rc=0 ;;
        C7)
            action="evidence-only(no-touch)"; rc=0   # DNS/路由：只记录不碰
            notify "DNS/路由异常：$(hc_l7_dns_route)。守护不改全局网络配置，请检查（hosts/系统DNS 属人工范围）" ;;
        C8)
            action="none(server-side)"; rc=0
            notify "内网服务端异常（5xx/证书），不属于本机故障，不重启 VPN" ;;
        *)
            action="none"; rc=0 ;;
    esac

    local dur=$(( $(now) - t0 ))
    echo "$action|$dur"
}

# ── 断网等待 ──
wait_net() {
    log "🌐 断网，进入持续网络监听（3s 级）"
    write_state "C1" "断网监听中" ""
    while ! hc_ping "$HC_NET_PING_TARGET"; do
        [ -e "$PAUSE_FILE" ] && break
        in_maintenance && break
        sleep 3
    done
    log "✅ 网络恢复"
}

# ── 冷却与退避（bash 3.2 兼容：eval 动态变量）──
can_attempt() {   # $1=分类
    local t
    eval "t=\$NA_$1"
    [ "$(now)" -ge "${t:-0}" ]
}
bump_fail() {   # 恢复失败：退避翻倍
    local cls=$1 cur f
    eval "f=\$FS_$cls"; f=$(( ${f:-0} + 1 ))
    eval "cur=\$CO_$cls"; cur=${cur:-$COOLDOWN_BASE}
    cur=$(( cur * 2 )); [ "$cur" -gt "$COOLDOWN_MAX" ] && cur=$COOLDOWN_MAX
    eval "CO_$cls=$cur"
    eval "NA_$cls=$(( $(now) + cur ))"
    eval "FS_$cls=$f"
    log "📉 $cls 恢复失败第 $f 次，冷却 ${cur}s"
}
mark_success() {
    local cls=$1
    eval "FS_$cls=0"
    eval "CO_$cls=$COOLDOWN_BASE"
    eval "NA_$cls=0"
}

# 测试模式只加载函数，不启动无限循环；用于隔离验证锁迁移和恢复动作。
if [ "${KEEPER_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ── 主循环 ──
log "===== EasyConnect Keeper v4 启动 (pid=$$) ====="
log "UA模式=$(ua_enabled && echo on || echo off) 检测=${CHECK_INTERVAL}s 假连接确认=${FAIL_CONFIRM}次"
# 默认无人值守开启（空文件）
touch "$UAMODE_FILE"
fs_reset
# launchd 保证主守护单实例；若上个实例被 SIGKILL，启动时立即清除其目录锁，
# 不再等待 600 秒超时。正常运行期间仍由 acquire/release 保证互斥。
if [ -d "$FLOCK_FILE" ]; then
    rmdir "$FLOCK_FILE" 2>/dev/null || true
    log "🧹 启动时清除上个实例遗留的恢复锁"
fi
trap 'release_recover_lock' EXIT INT TERM

while true; do
    rotate_log
    heartbeat "check"

    # 暂停（持续）
    if [ -e "$PAUSE_FILE" ]; then
        write_state "PAUSED" "守护已暂停" ""
        log "⏸️ 已暂停（删除 pause 文件恢复）"
        while [ -e "$PAUSE_FILE" ]; do
            heartbeat "paused"
            sleep 5
        done
        log "▶️ 恢复"
        continue
    fi

    # 维护模式
    if in_maintenance; then
        write_state "MAINT" "维护模式中" ""
        heartbeat "maintenance"
        sleep $CHECK_INTERVAL
        continue
    fi

    # 明确的“会话已过期”无需等待健康检查连续确认：立即确认弹窗并重启。
    # 若辅助功能权限不可用，下面的常规 C5/C6 路径仍会强制重启兜底。
    if ec_dismiss_expired_dialog; then
        write_state "C5" "检测到会话过期，立即重启" ""
        if acquire_recover_lock; then
            log "🚨 检测到‘会话已过期’，已点击‘好’，立即重启 EasyConnect"
            ec_gui_restart
            release_recover_lock
            PENDING_COUNT=0; PENDING_CLASS=""
            sleep 5
            continue
        fi
        log "⏳ 会话过期弹窗已确认，另一恢复流程正在执行"
    fi

    # 用户关闭或客户端崩溃时走最高优先级快速拉起，不依赖 L8 错误形态。
    # UA 关闭时尊重用户意图，不自动打开。
    if ua_enabled && ! ec_gui_alive; then
        write_state "C5" "EasyConnect 已关闭，立即拉起" ""
        if acquire_recover_lock; then
            log "🚨 EasyConnect 进程消失，立即拉起"
            ec_launch
            release_recover_lock
            PENDING_COUNT=0; PENDING_CLASS=""
            sleep 5
            continue
        fi
        log "⏳ EasyConnect 已关闭，另一恢复流程正在执行"
    fi

    # 健康检查
    local_result=$(hc_full_check 2>/dev/null) || local_result="C0|check-error"
    cls="${local_result%%|*}"
    evidence="${local_result#*|}"

    case "$cls" in
        C0)
            PENDING_COUNT=0; PENDING_CLASS=""
            write_state "C0" "内网 API 健康" ""
            sleep $CHECK_INTERVAL
            continue ;;
        C1)
            PENDING_COUNT=0
            write_state "C1" "本机断网" ""
            wait_net
            continue ;;
    esac

    # C5/C6 类需要连续确认（防抖：单轮异常可能是瞬时抖动）
    if [ "$cls" = "$PENDING_CLASS" ]; then
        PENDING_COUNT=$((PENDING_COUNT+1))
    else
        PENDING_CLASS=$cls; PENDING_COUNT=1
    fi

    need_recover=0
    case "$cls" in
        C5|C6) [ "$PENDING_COUNT" -ge "$FAIL_CONFIRM" ] && need_recover=1 ;;
        C2|C3|C7|C8) need_recover=1 ;;   # 这些分类单轮即反应（有各自冷却）
        *) need_recover=0 ;;
    esac

    if [ "$need_recover" = "1" ] && can_attempt "$cls" && ! in_maintenance; then
        write_state "$cls" "触发恢复" ""
        if acquire_recover_lock; then
            eval "streak=\$FS_$cls"; streak=${streak:-0}
            if [ "$streak" -lt "$RECOVER_FAIL_LIMIT" ]; then
                log "🚨 $cls 连续${PENDING_COUNT}轮异常，执行恢复。证据: $evidence"
                out=$(do_recover "$cls")
                action="${out%%|*}"; dur="${out#*|}"
                # 验证
                if verify_recovered; then
                    mark_success "$cls"
                    PENDING_COUNT=0
                    record_event "$cls" "$action" "$dur" "PASS" "$evidence"
                    log "✅ 恢复成功并验证通过 ($action, ${dur}s)"
                    notify "内网 API 已恢复（$cls → ${action}）"
                else
                    bump_fail "$cls"
                    record_event "$cls" "$action" "$dur" "FAIL" "$evidence"
                fi
            else
                # 低频观察模式：不放弃，仅拉长间隔等环境变化
                write_state "$cls" "低频观察(${streak}次失败)" ""
                log "👀 $cls 已连续 $streak 次恢复失败，进入低频观察（${LOWFREQ_INTERVAL}s）"
                # 低频冷却后自动重试（条件改善自动恢复正常节奏）
                eval "NA_$cls=$(( $(now) + LOWFREQ_INTERVAL ))"
                if [ "$streak" -ge $((RECOVER_FAIL_LIMIT * 2)) ]; then
                    eval "FS_$cls=$RECOVER_FAIL_LIMIT"   # 允许后续环境改善后继续重试
                fi
                # 不在持锁状态下长睡；主循环继续心跳，can_attempt 负责冷却。
            fi
            release_recover_lock
        else
            log "⏳ 另一恢复流程进行中，跳过本轮"
        fi
    else
        write_state "$cls" "观察中(${PENDING_COUNT})" ""
    fi

    sleep $CHECK_INTERVAL
done
