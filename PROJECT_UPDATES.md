PROJECT_UPDATES
===============

2026-09-18 v1.0
- 初版发布：EasyConnect VPN 断线自动重连守护程序
- 逆向 app.asar 确认本地 API：https://127.0.0.1:54530/ECAgent
  （QUERY QSTATE L3VPN 无需 token，result=18 为隧道正常）
- keeper.sh：10s 轮询检测、连续 3 次异常触发、分层重连
  （GUI 不在→拉起；断线→普通重启 auto_login 自动登录；无效→深度重启）
- install.sh：LaunchAgent 安装/卸载/状态
