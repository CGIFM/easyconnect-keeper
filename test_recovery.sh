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
RESTART_CALLED=0
ec_gui_alive() { return 0; }
ec_gui_restart() { RESTART_CALLED=1; }
now() { echo 100; }
out=$(do_recover C5)
case "$out" in
    expired-session-restart\|*) ok "C5 会话过期进入强制重启路径" ;;
    *) bad "C5 恢复动作错误：$out" ;;
esac

echo "════ 结果: $PASS 通过, $FAIL 失败 ════"
[ "$FAIL" = "0" ]
