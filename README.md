# EasyConnect Keeper

EasyConnect（深信服 SSL VPN）断线自动重连守护程序。检测到 VPN 隧道断开后自动重启客户端并等待恢复，全程留日志。

## 背景

EasyConnect 长时间连接后会自动断开（多网卡/代理软件干扰、服务器端单点登录互踢、运营商掐长连接等），断开后内网 AI 服务 token 全断。本程序持续监听，断开后立即自动重连。

## 原理

1. **状态检测**：轮询 EasyConnect 本地 API
   ```
   https://127.0.0.1:54530/ECAgent?op=DoQueryService&arg1=QUERY QSTATE L3VPN
   ```
   `result=18`（STATUS_START_SUCCESS）= 隧道正常；其他值/超时 = 异常。
   （端口读自 `/tmp/sangfor.ec.rundata` 前 2 字节 LE，默认 54530；接口逆向自
   `app.asar` 内 `common.js` / `https_com.js`。）
2. **防误判**：连续 3 次异常（约 30s）才触发重连，避免网络抖动。
3. **分层重连**：
   - GUI 未运行 → 直接 `open -a EasyConnect`
   - GUI 在但断线 → 先普通重启（配置了 `auto_login`，重启后自动登录）
   - 普通重启无效 → 深度重启（连 ECAgent / svpnservice 一起杀）
4. **常驻**：LaunchAgent `KeepAlive`，脚本崩溃自动拉起，开机自启。

## 文件结构

```
easyconnect-keeper/
├── keeper.sh                        # 守护脚本（主程序）
├── com.cgifm.easyconnect-keeper.plist  # LaunchAgent 配置
├── install.sh                       # 安装/卸载
└── README.md
```

## 使用

```bash
./install.sh install    # 安装并启动（开机自启）
./install.sh uninstall  # 停止并卸载
tail -f ~/Library/Logs/easyconnect-keeper/keeper.log   # 看日志
```

## 迭代历史

- 2026-09-18 v1.0 初版：本地 API 状态检测 + 分层重连 + LaunchAgent 常驻。
