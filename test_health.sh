#!/bin/bash
# =============================================================
# test_health.sh —— 健康检查与恢复逻辑的隔离模拟测试
# 原则：不碰真实网络/不重启真实应用，通过 stub 环境变量与
#       PATH 注入模拟故障。验证分类与决策的正确性。
# =============================================================
set -u
cd "$(dirname "$0")"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
check_eq() { [ "$1" = "$2" ] && ok "$3" || bad "$3 (期望 $1, 实际 $2)"; }

# stub 目录：模拟命令行为
STUB=$(mktemp -d)
export PATH="$STUB:$PATH"

# 默认 stub：一切正常
cat > "$STUB/ping" <<'EOF'
#!/bin/bash
[ "$PING_FAIL" = "1" ] && exit 1
exit 0
EOF
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
# 模拟 curl：参数里有 https://intranet.example.com → 内网；baidu → 公网代理
# -w 参数含 time_namelookup 时额外输出耗时行（stub 不产生真实耗时）
has_w=0
for a in "$@"; do
  [[ "$a" == *time_namelookup* ]] && has_w=1
done
for a in "$@"; do
  case "$a" in
    *intranet.example.com*)
        [ "$INNER_MODE" = "conn" ] && { echo -n "000"; exit 0; }
        [ "$INNER_MODE" = "server" ] && { echo -n "502"; exit 0; }
        [ "$INNER_MODE" = "tls" ] && { echo -n "000 SSL 0.010"; exit 0; }
        [ "$has_w" = "1" ] && { echo -n "0.010"; exit 0; }
        echo -n "302"; exit 0 ;;
    *baidu.com*)
        [ "$PROXY_MODE" = "fail" ] && { echo -n "000"; exit 0; }
        echo -n "200"; exit 0 ;;
  esac
done
echo -n "200"; exit 0
EOF
cat > "$STUB/pgrep" <<'EOF'
#!/bin/bash
case "$PGREP_MODE" in
  no-flclash) echo "$*" | grep -q FlClash && exit 1 ;;
  no-ec)      echo "$*" | grep -q "EasyConnect" && exit 1 ;;
  none)       exit 1 ;;
esac
exit 0
EOF
cat > "$STUB/nc" <<'EOF'
#!/bin/bash
[ "$NC_MODE" = "fail" ] && exit 1
exit 0
EOF
cat > "$STUB/scutil" <<'EOF'
#!/bin/bash
[ "$SYSPROXY_OFF" = "1" ] && { echo "  HTTPEnable : 0"; exit 0; }
cat <<'EOP'
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPSEnable : 1
  HTTPSPort : 7890
EOP
EOF
cat > "$STUB/dig" <<'EOF'
#!/bin/bash
[ "$DNS_MODE" = "fail" ] && exit 1
echo "10.0.0.10"
EOF
cat > "$STUB/route" <<'EOF'
#!/bin/bash
[ "$ROUTE_MODE" = "wrong" ] && { echo "   interface: en0"; exit 0; }
[ "$ROUTE_MODE" = "flclash-tun" ] && { echo "   interface: utun9"; exit 0; }
[ "$ROUTE_MODE" = "none" ] && exit 1
echo "   interface: utun10"
EOF
cat > "$STUB/ifconfig" <<'EOF'
#!/bin/bash
[ "$TUN_MODE" = "none" ] && exit 0
echo "utun9: flags=8051<UP>"
echo "	inet 28.0.0.1 --> 28.0.0.1 netmask 0xfffffffc"
EOF
cat > "$STUB/curl-ec" <<'EOF'
#!/bin/bash
echo '{"type":"DoQueryService","result":"18","message":"","debug":""}'
EOF
chmod +x "$STUB/"*

# EC tunnel curl 特殊处理：hc_l6 用 curl 访问 127.0.0.1:54530
cat > "$STUB/curl-real" <<EOF
#!/bin/bash
exit 0
EOF

echo "════ 健康检查分类测试 ════"

# 用子 shell 加载 health.sh 并跑 full check
run_check() {
    bash -c '
    export PATH="'"$STUB"':$PATH"
    HC_EC_PORT=54530
    hc_ec_stub() { echo "18"; }
    source lib/health.sh
    # 覆盖 L6 不真的发请求（stub curl 已处理，但 54530 URL 与内网域名不同分支）
    '
}

# 直接 source 跑
run_full() {
    (
    export PATH="$STUB:$PATH"
    export HC_EC_PORT=54530
    source lib/health.sh
    # L6 stub: 拦截 EC API 请求
    hc_l6_ec_tunnel_orig=$(declare -f hc_l6_ec_tunnel)
    hc_l6_ec_tunnel() {
        local m="${EC_MODE:-ok}"
        case "$m" in
            down)  echo "000"; return 1 ;;
            other) echo "2"; return 1 ;;
            *)     echo "18"; return 0 ;;
        esac
    }
    hc_full_check
    )
}

echo "── 场景1: 全链路健康 → C0"
r=$(run_full); check_eq "C0" "${r%%|*}" "全正常分类为C0"

echo "── 场景2: 断网 → C1"
export PING_FAIL=1; export PROXY_MODE=fail
r=$(run_full); check_eq "C1" "${r%%|*}" "断网分类为C1"
unset PING_FAIL PROXY_MODE

echo "── 场景3: FlClash 全没 → C2"
export PGREP_MODE=no-flclash; export TUN_MODE=none
r=$(run_full); check_eq "C2" "${r%%|*}" "FlClash缺失分类为C2"
unset PGREP_MODE TUN_MODE

echo "── 场景4: 代理端口失效 → C3"
export NC_MODE=fail
r=$(run_full); check_eq "C3" "${r%%|*}" "代理端口失效分类为C3"
unset NC_MODE

echo "── 场景5: EC 未连接(result=2) → C5"
export EC_MODE=other; export INNER_MODE=conn
r=$(run_full); check_eq "C5" "${r%%|*}" "EC异常分类为C5"

echo "── 场景6: 假连接(EC=18但内网不通) → C6"
export EC_MODE=ok; export INNER_MODE=conn
r=$(run_full); check_eq "C6" "${r%%|*}" "假连接分类为C6"

echo "── 场景7: 服务端 5xx → C8 (不重启VPN)"
export INNER_MODE=server
r=$(run_full); check_eq "C8" "${r%%|*}" "服务端错误分类为C8"
unset INNER_MODE EC_MODE

echo "── 场景8: DNS 失败 → C7"
export DNS_MODE=fail
r=$(run_full); check_eq "C7" "${r%%|*}" "DNS失败分类为C7"
unset DNS_MODE

echo "── 场景9: 路由走其他接口但内网实测通 → C0（内网通则不折腾）"
export ROUTE_MODE=wrong
r=$(run_full); check_eq "C0" "${r%%|*}" "路由偏差但API通判C0"
unset ROUTE_MODE

echo "── 场景9b: EC自称18+路由被FlClash TUN截走+内网不通 → C7（DNS路由归因）"
export ROUTE_MODE=flclash-tun
export INNER_MODE=conn
export EC_MODE=ok
r=$(run_full); check_eq "C7" "${r%%|*}" "TUN截走内网不通判C7"
unset ROUTE_MODE INNER_MODE EC_MODE

echo "── 场景10: TUN 消失但 FlClash 在 → 不误判（内网通则C0）"
export TUN_MODE=none
r=$(run_full); check_eq "C0" "${r%%|*}" "TUN消失但内网通仍为C0"
unset TUN_MODE

echo ""
echo "════ 恢复边界逻辑测试 ════"

echo "── 场景11: 系统代理关闭不算故障（用户可能故意关）"
export SYSPROXY_OFF=1
r=$(run_full); check_eq "C0" "${r%%|*}" "系统代理关闭不影响内网通"
unset SYSPROXY_OFF

echo "── 场景12: EC关闭且L8报TLS → C5（不得误判C8）"
export EC_MODE=down; export INNER_MODE=tls
r=$(run_full); check_eq "C5" "${r%%|*}" "EC关闭时TLS错误优先分类为C5"
unset EC_MODE INNER_MODE

echo "── 场景13: EC未连接且服务端表象5xx → C5"
export EC_MODE=other; export INNER_MODE=server
r=$(run_full); check_eq "C5" "${r%%|*}" "EC未连接时优先分类为C5"
unset EC_MODE INNER_MODE

rm -rf "$STUB"
echo ""
echo "════ 结果: $PASS 通过, $FAIL 失败 ════"
[ "$FAIL" = "0" ]
