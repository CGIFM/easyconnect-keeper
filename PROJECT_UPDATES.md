PROJECT_UPDATES
===============

2026-09-18 v2
- 断网感知：ping 双公网 DNS（223.5.5.5/119.29.29.29），断网时只持续监听网络（3s 级）不折腾 EasyConnect
- 网络恢复后 15s 自愈窗口，自愈失败跳过防抖立即重连
- 分层重连收敛为 force_reconnect（拉起→普通重启→深度重启）
- LaunchAgent KeepAlive 双保险：keeper 进程崩溃自动拉起，检测永不中断
- 逆向 app.asar 确认本地 API：https://127.0.0.1:54530/ECAgent
  （QUERY QSTATE L3VPN 无需 token，result=18 为隧道正常）
- keeper.sh：10s 轮询检测、连续 3 次异常触发、分层重连
  （GUI 不在→拉起；断线→普通重启 auto_login 自动登录；无效→深度重启）
- install.sh：LaunchAgent 安装/卸载/状态
- 实测验证：
  - 00:28 模拟退出 GUI → 38s 自动恢复（auto_login 自动登录生效）
  - 00:33 真实自发断开（result=2 STATUS_LOGOUT）→ 38s 自动恢复
  - 恢复后 utun10 虚拟网卡 (10.10.200.47) 正常回到内网
- 关键发现：本机 FlClash TUN(utun9) 与 EasyConnect 长连接冲突是断开主要诱因
