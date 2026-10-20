#!/bin/bash
# =============================================================
# health.sh —— v4 健康检查库（纯函数，可独立 source 单测）
# =============================================================
# 8 层探测，每层返回 "状态码|详情"，最后汇总为故障分类 C0~C8：
#   C0 健康                 C1 本机断网            C2 FlClash 核心缺失
#   C3 代理端口/请求失效    C4 系统代理指向失效    C5 EC 隧道未建立
#   C6 假连接(EC=18 但内网不通)                    C7 DNS/路由异常
#   C8 服务端/证书/鉴权问题（不自动重启 VPN）
# 探测原则：轻量、带超时、不发业务数据；curl 全部 --noproxy 精确控制
# 链路；公网检测用 ping + 经代理 HTTP（直连 curl 在 fake-ip 环境有噪声）。
# =============================================================

# ---------- 可配置探测目标（避免写死 IP；由 keeper.sh 注入或用默认） ----------
HC_INNER_HOST="${HC_INNER_HOST:-claude.jlcops.com}"
HC_INNER_IP="${HC_INNER_IP:-}"          # 留空则每次从 DNS 取，不写死
HC_INNER_URL="${HC_INNER_URL:-https://claude.jlcops.com/}"
HC_EC_PORT="${HC_EC_PORT:-54530}"
HC_FLCLASH_APP="${HC_FLCLASH_APP:-/Applications/FlClash.app}"
# 空值表示跟随系统代理；每轮重新读取，切换客户端/端口后无需重启守护。
HC_PROXY_PORT="${HC_PROXY_PORT:-}"
hc_proxy_port() {
    if [ -n "$HC_PROXY_PORT" ]; then printf '%s\n' "$HC_PROXY_PORT"; return; fi
    local port
    port=$(scutil --proxy | awk '/HTTPSPort :/{print $NF; exit}')
    case "$port" in ''|*[!0-9]*) port=7890 ;; esac
    printf '%s\n' "$port"
}
HC_NET_PING_TARGET="${HC_NET_PING_TARGET:-223.5.5.5}"

# ---------- 工具 ----------
hc_now_ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || date +%s000; }

# 单次 ping，通=0
hc_ping() { ping -c 1 -W 2000 -t 3 "$1" >/dev/null 2>&1; }

# ---------- L1 本机网络 ----------
# 通=公网可达。判定：ping 通 或 经 FlClash 代理 HTTP 成功（任一）
hc_l1_network() {
    if hc_ping "$HC_NET_PING_TARGET"; then
        echo "ok|ping $HC_NET_PING_TARGET 通"; return 0
    fi
    # ping 失败可能是 ICMP 被禁，用代理 HTTP 复核
    local code
    code=$(curl -sx "http://127.0.0.1:$(hc_proxy_port)" --max-time 5 -o /dev/null -w '%{http_code}' "https://www.baidu.com" 2>/dev/null)
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
        echo "ok|经代理 HTTP $code"; return 0
    fi
    echo "fail|ping 不通且代理请求失败(code=$code)"; return 1
}

# ---------- L2 代理核心进程（兼容新旧客户端） ----------
hc_l2_flclash() {
    if pgrep -x "verge-mihomo" >/dev/null 2>&1; then
        echo "ok|Clash Verge 核心运行中"; return 0
    fi
    if pgrep -x "FlClashCore" >/dev/null 2>&1; then
        echo "ok|FlClashCore 运行中"; return 0
    fi
    if pgrep -x "clash-verge" >/dev/null 2>&1 || pgrep -f "[F]lClash.app" >/dev/null 2>&1; then
        echo "warn|代理 GUI 在但核心退出"; return 1
    fi
    echo "fail|未发现 Clash Verge / FlClash 核心"; return 1
}

# ---------- L3 代理端口 + 实际代理请求 ----------
# 单请求对分流节点抖动敏感，采用 2/3 表决
hc_l3_proxy() {
    if ! nc -z -w 2 127.0.0.1 "$(hc_proxy_port)" >/dev/null 2>&1; then
        echo "fail|端口 $(hc_proxy_port) 未监听"; return 1
    fi
    local i code ok=0 fail=0 last=""
    for i in 1 2 3; do
        code=$(curl -sx "http://127.0.0.1:$(hc_proxy_port)" --max-time 5 -o /dev/null -w '%{http_code}' "https://www.baidu.com" 2>/dev/null)
        case "$code" in
            200|301|302) ok=$((ok+1)); last="HTTP $code" ;;
            *)           fail=$((fail+1)); last="code=$code" ;;
        esac
        [ "$ok" -ge 2 ] && break
    done
    if [ "$ok" -ge 2 ]; then
        echo "ok|代理表决 $ok/3 ($last)"; return 0
    fi
    if [ "$fail" -ge 3 ]; then
        echo "fail|代理表决 0/3 ($last)"; return 1
    fi
    echo "ok|代理表决 $ok/3 边缘通过 ($last)"; return 0
}

# ---------- L4 系统代理配置 ----------
hc_l4_sysproxy() {
    local enabled port
    enabled=$(scutil --proxy | grep HTTPSEnable | awk '{print $NF}')
    port=$(scutil --proxy | grep HTTPSPort | awk '{print $NF}')
    if [ "$enabled" != "1" ]; then
        echo "off|系统代理未启用"; return 0   # 未启用不算故障（用户可能故意关）
    fi
    if nc -z -w 2 127.0.0.1 "$port" >/dev/null 2>&1; then
        echo "ok|系统代理 -> 127.0.0.1:$port 可达"; return 0
    fi
    echo "fail|系统代理指向 $port 但端口不可达"; return 1
}

# ---------- L5 TUN 接口 ----------
hc_l5_tun() {
    local tun_ip
    tun_ip=$(hc_proxy_tun)
    if [ -n "$tun_ip" ]; then
        echo "ok|代理 TUN=$tun_ip"; return 0
    fi
    echo "off|未发现代理 TUN（仅系统代理模式可接受）"; return 0
}

# ---------- L6 EasyConnect 本地服务与隧道 ----------
# 输出 result 数字：18=正常；000=本地服务不可达；其他=隧道异常
hc_l6_ec_tunnel() {
    local resp r
    resp=$(curl -sk --connect-timeout 3 --max-time 6 \
        "https://127.0.0.1:$HC_EC_PORT/ECAgent?op=DoQueryService&arg1=QUERY%20QSTATE%20L3VPN" 2>/dev/null)
    [ -z "$resp" ] && { echo "000"; return 1; }
    r=$(printf '%s' "$resp" | sed -n 's/.*"result":"\{0,1\}\(-\{0,1\}[0-9]*\)"\{0,1\}.*/\1/p')
    [ -z "$r" ] && r=000
    echo "$r"
    [ "$r" = "18" ]
}

# ---------- L7 DNS 与路由 ----------
# 检查内网域名解析 + 解析耗时 + 出接口是否为 EC 的 utun
# 注意：dscacheutil 在 fake-ip/TUN 环境有 30s 卡死 pathology，改用 dig 直查
# 上游 DNS；系统级 DNS 健康另用一次 curl 实测（业务视角）衡量。
HC_DNS_SLOW_MS="${HC_DNS_SLOW_MS:-3000}"

# 同时识别 FlClash 和 Clash Verge 的常用 TUN 地址，避免把 VPN 本身误当代理。
hc_proxy_tun() {
    ifconfig 2>/dev/null | awk '/^utun[0-9]+:/{name=$1} /inet (28\.0\.0\.1|198\.18\.0\.1) /{sub(/:$/, "", name); print name}'
}
# 保留旧函数名，兼容已有诊断脚本。
hc_flclash_tun() { hc_proxy_tun; }

hc_l7_dns_route() {
    local t0 t1 ms ip iface sys_ms fltun
    t0=$(hc_now_ms)
    ip=$(dig +short +time=3 +tries=1 "$HC_INNER_HOST" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}')
    t1=$(hc_now_ms)
    ms=$((t1 - t0))
    if [ -z "$ip" ]; then
        echo "fail|$HC_INNER_HOST dig 解析失败"; return 1
    fi
    iface=$(route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2; exit}')
    fltun=$(hc_proxy_tun)
    case "$iface" in
        "")    echo "fail|无到 $ip 的路由"; return 1 ;;
        *)     if [ -n "$fltun" ] && printf '%s\n' "$fltun" | grep -Fxq "$iface"; then
                   echo "fail|ip=$ip 被代理 TUN($iface)截走（EC隧道未建立）"; return 1
               fi ;;
    esac
    # sysDNS 耗时由 L8 的 dns=ms 覆盖（避免重复请求）
    echo "ok|dig=${ms}ms ip=$ip 接口=$iface"; return 0
}

# ---------- L8 内网 API 实际可达（分类最细） ----------
# 输出 "ok|HTTP 302" 或 "server|5xx" / "tls|..." / "conn|..."
# 单次 curl 同时取 http_code+errormsg+耗时（双次调用在慢DNS下成本翻倍）
hc_l8_inner_api() {
    local target="$HC_INNER_URL" out code err dns
    # 使用制表符分隔，保留含空格的错误详情；不把畸形/空响应当成健康。
    out=$(curl -4 -s --noproxy '*' --max-time 8 -o /dev/null \
        -w '%{http_code}\t%{errormsg}\t%{time_namelookup}' "$target" 2>/dev/null)
    code=$(printf '%s' "$out" | cut -f1)
    err=$(printf '%s' "$out" | cut -f2)
    dns=$(printf '%s' "$out" | awk -F '\t' '{print int($3*1000)}')
    case "$code" in
        [1-5][0-9][0-9])
            case "$code" in
                5*) echo "server|HTTP $code 服务端错误"; return 1 ;;
                *) echo "ok|HTTP $code dns=${dns}ms"; return 0 ;;
            esac ;;
    esac
    case "$err" in
        *certificate*|*SSL*|*ssl*) echo "tls|$err"; return 1 ;;
        *) echo "conn|${err:-未取得有效HTTP响应} dns=${dns}ms"; return 1 ;;
    esac
}

# ---------- 汇总健康检查 ----------
# 返回: "分类|证据串"。分类 C0~C8 见文件头。
hc_full_check() {
    local ev="" cls="C0"
    local l1 l2 l3 l4 l5 l6 l7 l8
    l1=$(hc_l1_network)   || true
    l2=$(hc_l2_flclash)   || true
    l3=$(hc_l3_proxy)     || true
    l4=$(hc_l4_sysproxy)  || true
    l5=$(hc_l5_tun)       || true
    l6=$(hc_l6_ec_tunnel) || true
    l7=$(hc_l7_dns_route) || true
    l8=$(hc_l8_inner_api) || true

    ev="L1[$l1] L2[$l2] L3[$l3] L4[$l4] L5[$l5] L6[$l6] L7[$l7] L8[$l8]"

    # 普通业务请求实测通是首要标准；附属代理进程/公网探测不可盖过它。
    case "$l8" in ok\|*) echo "C0|$ev"; return ;; esac
    # ── 分类决策（按因果链从底层到顶层）──
    case "$l1" in
        fail*) echo "C1|$ev"; return ;;
    esac
    # EC 隧道是内网 API 的前置条件。客户端关闭/未登录时，L8 常表现为
    # TLS 错误；必须先判 C5，否则会误归为 C8“服务端问题”而拒绝重启。
    case "${l6%%|*}" in
        18) ;;
        *) echo "C5|$ev"; return ;;
    esac
    case "$l7" in
        fail*|slow*) echo "C7|$ev"; return ;;
    esac
    # 只有 EC 隧道已确认正常时，TLS/5xx 才属于服务端问题。
    case "$l8" in
        server*|tls*) echo "C8|$ev"; return ;;
    esac
    # EC=18 且路由有效、但普通请求失败，是 VPN 假连接；公网代理失败
    # 不是内网直连的前置条件，不能阻止 C6 恢复（如源地址选择失效）。
    case "$l8" in
        conn*) echo "C6|$ev"; return ;;
    esac
    if [[ "$l3" == fail* ]]; then echo "C3|$ev"; return; fi
    if [[ "$l2" == fail* ]]; then echo "C2|$ev"; return; fi
    # 检查函数未返回合法状态时仅记录异常，不宣称健康、不盲目重连。
    echo "C7|检测结果异常 $ev"
}
