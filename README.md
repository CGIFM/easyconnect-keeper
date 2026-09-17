# EasyConnect Keeper

EasyConnect（深信服 SSL VPN）断线自动重连守护程序。**三层状态机**：先判断本机是否有网（断网时不折腾客户端），再查 VPN 隧道状态，异常后自动重启客户端等待恢复，全程留日志，7×24 持续监听。

## 工作流程（v2）

```
┌─ 每 3s ping 双公网 DNS ──→ 断网？──是──→ 持续监听网络（不重启 EC）
│                                        │ 网络恢复
│                                        ▼
└─ 有网 ──→ 查本地 API 隧道状态 ──→ result=18 正常 ──→ 10s 后再查
              │ 异常
              ▼ 连续 3 次（防抖）
        触发重连 ──→ GUI 不在？直接拉起
              │ GUI 在          │ 网络刚恢复
              ▼                 ▼
        普通重启 GUI      先给 15s 自愈窗口，失败跳过防抖立即重连
              │ 还不行
              ▼
        深度重启（连 ECAgent/svpnservice 一起杀）
```

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

## 实测记录（2026-09-18）

| 事件 | 类型 | 检测到恢复耗时 |
|---|---|---|
| 00:28 主动退出 GUI | 模拟测试 | ~38s（3 次确认 + 重启 + 15s 登录） |
| 00:33 自发断开 (result=2 STATUS_LOGOUT) | 真实场景 | ~38s |

恢复后 `utun10 10.10.200.47` 虚拟网卡正常，`QUERY QSTATE L3VPN` 回到 18。

## 已知断开诱因（排查参考）

- **FlClash TUN 模式冲突**：FlClash 的 utun9（28.0.0.1）接管大部分路由，EasyConnect 到
  `td.jlcerp.com:443` 的 SSL 长连接走代理通道，节点切换/超时会掐断长连接——本机最常见的诱因。
- 服务器端「隧道自身路由」策略 / 单账号互踢（`result=2` 登出）。
- 运营商对长连接的定时回收、系统休眠。

## 迭代历史

- 2026-09-18 v1.0 初版：本地 API 状态检测 + 分层重连 + LaunchAgent 常驻。两次实测（1 模拟 + 1 真实断开）均 38s 内恢复。
