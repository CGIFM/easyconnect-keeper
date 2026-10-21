#!/bin/bash
# 恢复逻辑隔离测试：不操作真实 EasyConnect、FlClash 或网络。
set -u
cd "$(dirname "$0")"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
export KEEPER_LIB_ONLY=1
mkdir -p "$HOME"

source ./keeper.sh

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

echo "════ 恢复锁迁移测试 ════"
touch "$FLOCK_FILE"
if acquire_recover_lock && [ -d "$FLOCK_FILE" ]; then
    ok "旧版普通文件锁可自动迁移并取得目录锁"
else
    bad "旧版普通文件锁迁移失败"
fi
release_recover_lock
[ ! -e "$FLOCK_FILE" ] && ok "恢复结束后目录锁被释放" || bad "目录锁未释放"

echo "════ 会话过期恢复测试 ════"
ACTION_LOG="$TEST_ROOT/actions"
ec_gui_alive() { return 0; }
ec_gui_restart() { echo restart >> "$ACTION_LOG"; }
TEST_NOW=100
now() { echo "$TEST_NOW"; }
out=$(do_recover C5)
case "$out" in
    expired-session-restart\|*) ok "C5 会话过期进入强制重启路径" ;;
    *) bad "C5 恢复动作错误：$out" ;;
esac
[ "$(wc -l < "$ACTION_LOG" | tr -d ' ')" = 1 ] && ok "C5 确实执行重启动作" || bad "C5 没有执行动作"

echo "════ 连败后持续重试测试 ════"
notify() { :; }
verify_recovered() { return 1; }
fs_reset
PENDING_COUNT=3
: > "$ACTION_LOG"
for i in 1 2 3; do
    attempt_recovery C6 "隔离故障"
    eval "TEST_NOW=\$NA_C6"
done
[ "$FS_C6" = 3 ] && ok "前三次恢复均执行并记录失败" || bad "失败计数错误"
next=$NA_C6
TEST_NOW=$((next - 1))
if can_attempt C6; then bad "冷却未到期却允许重试"; else ok "冷却期间禁止重试"; fi
write_retry_state C6
write_retry_state C6
[ "$NA_C6" = "$next" ] && ok "刷新倒计时不会推迟重试时刻" || bad "重试时刻被推迟"
case "$(cat "$STATE_FILE")" in
    *恢复失败3次，1秒后自动重试*) ok "状态包含失败次数和重试倒计时" ;;
    *) bad "重试信息缺失" ;;
esac
TEST_NOW=$next
if can_attempt C6; then attempt_recovery C6 "隔离故障"; else bad "第4次重试被永久阻止"; fi
[ "$(wc -l < "$ACTION_LOG" | tr -d ' ')" = 4 ] && ok "连败3次后确实执行第4次恢复" || bad "第4次动作缺失"
for i in 5 6 7 8; do
    TEST_NOW=$NA_C6
    can_attempt C6 && attempt_recovery C6 "持续故障"
done
if [ "$(wc -l < "$ACTION_LOG" | tr -d ' ')" = 8 ] && [ "$CO_C6" = "$COOLDOWN_MAX" ]; then
    ok "长期失败仍持续动作，退避封顶"
else
    bad "长期重试停止或冷却无上限"
fi
[ ! -e "$FLOCK_FILE" ] && ok "失败后恢复锁释放" || bad "失败后遗留锁"
verify_recovered() { return 0; }
TEST_NOW=$NA_C6
attempt_recovery C6 "环境已恢复"
if [ "$FS_C6" = 0 ] && [ "$NA_C6" = 0 ] && [ "$CO_C6" = "$COOLDOWN_BASE" ]; then
    ok "验证成功后清空历史失败和退避"
else
    bad "成功后未重置历史"
fi
case "$(cat "$STATE_FILE")" in *'"status":"C0"'*) ok "验证成功立即发布健康状态" ;; *) bad "成功后状态不健康" ;; esac
[ ! -e "$FLOCK_FILE" ] && ok "成功后恢复锁释放" || bad "成功后遗留锁"
# 自然恢复分支与成功验证共用 fs_reset，避免间歇故障累积成连败。
FS_C6=3; NA_C6=9999; fs_reset
[ "$FS_C6" = 0 ] && [ "$NA_C6" = 0 ] && ok "自然恢复清理旧故障历史" || bad "重置失败"

echo "════ 结果: $PASS 通过, $FAIL 失败 ════"
[ "$FAIL" = "0" ]
