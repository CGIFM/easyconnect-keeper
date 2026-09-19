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
HC_INNER_HOST="${HC_INNER_HOST:-intranet.example.com}"
HC_INNER_IP="${HC_INNER_IP:-}"          # 留空则每次从 DNS 取，不写死
HC_INNER_URL="${HC_INNER_URL:-https://$HC_INNER_HOST/}"
HC_EC_PORT="${HC_EC_PORT:-54530}"
HC_FLCLASH_APP="${HC_FLCLASH_APP:-/Applications/FlClash.app}"
HC_PROXY_PORT="${HC_PROXY_PORT:-7890}"
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
    code=$(curl -sx "http://127.0.0.1:$HC_PROXY_PORT" --max-time 5 -o /dev/null -w '%{http_code}' "https://www.baidu.com" 2>/dev/null)
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
        echo "ok|经代理 HTTP $code"; return 0
    fi
    echo "fail|ping 不通且代理请求失败(code=$code)"; return 1
}

# ---------- L2 FlClash 进程 ----------
hc_l2_flclash() {
    if pgrep -f "FlClashCore" >/dev/null 2>&1; then
        echo "ok|FlClashCore 运行中"; return 0
    fi
    if pgrep -f "FlClash.app" >/dev/null 2>&1; then
        echo "warn|GUI 在但核心退出"; return 1
    fi
    echo "fail|FlClash 未运行"; return 1
}

# ---------- L3 代理端口 + 实际代理请求 ----------
# 单请求对分流节点抖动敏感，采用 2/3 表决
hc_l3_proxy() {
    if ! nc -z -w 2 127.0.0.1 "$HC_PROXY_PORT" >/dev/null 2>&1; then
        echo "fail|端口 $HC_PROXY_PORT 未监听"; return 1
    fi
    local i code ok=0 fail=0 last=""
    for i in 1 2 3; do
        code=$(curl -sx "http://127.0.0.1:$HC_PROXY_PORT" --max-time 5 -o /dev/null -w '%{http_code}' "https://www.baidu.com" 2>/dev/null)
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
    tun_ip=$(ifconfig 2>/dev/null | awk '/^utun[0-9]+:/{name=$1} /inet 28\.0\.0\.1/{print name; exit}' | tr -d ':')
    if [ -n "$tun_ip" ]; then
        echo "ok|FlClash TUN=$tun_ip (28.0.0.1)"; return 0
    fi
    # TUN 不在：只有当 FlClash 在运行时才是异常（用户可能关了 FlClash）
    if pgrep -f "FlClashCore" >/dev/null 2>&1; then
        echo "warn|FlClash 运行但 TUN 接口消失"; return 1
    fi
    echo "off|TUN 不存在（FlClash 未运行，可接受）"; return 0
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

# FlClash TUN 接口名（28.0.0.1 所在 utun），供 L7 区分"走 EC 隧道"还是"被 FlClash 截走"
hc_flclash_tun() {
    ifconfig 2>/dev/null | awk '/^utun[0-9]+:/{name=$1} /inet 28\.0\.0\.1 /{print name; exit}' | tr -d ':'
}

hc_l7_dns_route() {
    local t0 t1 ms ip iface sys_ms fltun
    t0=$(hc_now_ms)
    ip=$(dig +short +time=3 +tries=1 "$HC_INNER_HOST" 2>/dev/null | awk 'NR==1{print $1}')
    t1=$(hc_now_ms)
    ms=$((t1 - t0))
    if [ -z "$ip" ]; then
        echo "fail|$HC_INNER_HOST dig 解析失败"; return 1
    fi
    iface=$(route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2; exit}')
    fltun=$(hc_flclash_tun)
    case "$iface" in
        "")    echo "fail|无到 $ip 的路由"; return 1 ;;
        *)     if [ -n "$fltun" ] && [ "$iface" = "$fltun" ]; then
                   echo "fail|ip=$ip 被FlClash TUN($iface)截走（EC隧道未建立）"; return 1
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
    out=$(curl -4 -s --noproxy '*' --max-time 8 -o /dev/null \
        -w '%{http_code} %{errormsg} %{time_namelookup}' "$target" 2>/dev/null)
    code=$(printf '%s' "$out" | awk '{print $1}')
    err=$(printf '%s' "$out" | awk '{print $2}')
    dns=$(printf '%s' "$out" | awk '{print int($3*1000)}')
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        case "$code" in
            200|301|302|303|307|308|401|403|404)
                # 401/403=鉴权层通（服务端活着），404 也证明 HTTP 层通
                echo "ok|HTTP $code dns=${dns}ms"; return 0 ;;
            5*) echo "server|HTTP $code 服务端错误"; return 1 ;;
            *)  echo "ok|HTTP $code"; return 0 ;;
        esac
    fi
    # 连接失败细分
    case "$err" in
        *certificate*|*SSL*|*ssl*) echo "tls|$err"; return 1 ;;
        *timed\ out*|*time*|*"Resolving"*) echo "conn|超时(dns=${dns}ms)"; return 1 ;;
        *)                         echo "conn|$err"; return 1 ;;
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
    case "$l8" in
        conn*)
            # 内网不通但 EC 显示 18 → 假连接；EC 不是 18 → 未连接
            if [ "${l6%%|*}" = "18" ]; then
                echo "C6|$ev"
            elif [ "${l6%%|*}" = "000" ]; then
                echo "C5|$ev"    # EC 本地服务都不可达
            else
                echo "C5|$ev"
            fi
            return ;;
    esac
    # EC 隧道正常 + 内网 API ok → 健康（即便 FlClash 有小问题，内网通就不折腾）
    if [[ "$l3" == fail* ]]; then echo "C3|$ev"; return; fi
    if [[ "$l2" == fail* ]]; then echo "C2|$ev"; return; fi
    echo "C0|$ev"
}
