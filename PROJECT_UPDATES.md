PROJECT_UPDATES
===============

2026-09-18 v4（内网 API 链路无人值守守护）
- 8 层健康检查（lib/health.sh）：网络/FlClash/代理/系统代理/TUN/EC隧道/DNS路由/内网API
  分类 C0~C8；隔离模拟测试 11 场景全绿（test_health.sh，stub PATH 注���）
- 恢复状态机：分类→动作有边界；防抖(3轮)/冷却退避(60s→30min)/低频观察/连续3次验证
  mkdir 原子锁互斥+超时防死锁；C6 假连接=3轮确认后 GUI 重启
- 模式：UA 无人值守(默认开)/暂停(限时支持)/维护锁(TTL 2h 自动过期)
- 自我守护：心跳(每轮推进计数)+watchdog(心跳>120s 杀重建)+有界日志事件
- 部署：releases/ 版本化 + current 软链原子切换 + rollback 回退
- 实机验证抓到并修复 3 个致命 bug：
  1. /bin/bash 3.2 不支持 declare -A → 守护启动即崩、launchd 15s 死循环拉起
  2. macOS 无 flock 命令 → 恢复流程永远拿不到锁（EC 断了守护只刷"跳过"）
  3. L3 代理单请求被分流节点抖动误判 → 2/3 表决
- 环境发现：系统 AAAA 查询 5s 超时拖慢所有连接（L8 用 -4 规避）；dscacheutil
  对内网域名卡 30s（L7 改 dig）；ECAgent Logout 签名未逆向成功（C6 主线走 GUI 重启）
- 待人工验证场景：真实断开时的全自动恢复（用户明确要求不再断网实测，需等
  自然故障观察 events.log）；睡眠唤醒后的恢复速度；服务端 5xx 长时间表现

2026-09-18 v3（菜单栏管理应用）
- KeeperBar：状态图标/暂停恢复/自启开关/二次确认卸载
- 标准布局安装到 Application Support，双 LaunchAgent
- 暂停机制改删 pause 文件方案，修复 resume.touch 竞态

2026-09-18 v2（断网感知）
- ping 双公网 DNS，断网只监听不折腾 EC；网络恢复 15s 自愈窗口后跳防抖重连

2026-09-18 v1.0（初版）
- 逆向 app.asar 定位本地 API(54530)；QUERY QSTATE L3VPN 无 token，18=隧道正常
- 10s 轮询 + 分层重连 + LaunchAgent；两次实测（模拟+真实断开）38s 恢复
