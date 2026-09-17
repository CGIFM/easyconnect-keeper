PROJECT_UPDATES
===============

2026-09-18 v3
- keeper.sh：新增状态文件上报（state JSON）+ 暂停支持（pause 文件，删文件即恢复，无竞态）
- KeeperBar.swift：菜单栏管理应用（🛡 图标随状态变色；暂停/恢复、立即重连、开机自启开关、打开日志、二次确认卸载）
- install.sh 重写：标准布局安装到 ~/Library/Application Support/EasyConnectKeeper，安装时现场 swiftc 编译 KeeperBar.app，双 LaunchAgent 开机自启（守护 KeepAlive + 菜单栏 RunAtLoad）
- 修复：v3 初版 resume.touch 恢复机制存在竞态（pause_loop 启动时误删恢复请求），改为「删 pause 文件即恢复」方案
- 全链路实测：状态上报 OK(18)、暂停→恢复、双自启加载、安装目录布局均验证通过
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
