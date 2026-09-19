# EasyConnect Keeper

面向 macOS 的 EasyConnect VPN 无人值守守护程序，同时监控 FlClash、本机代理、VPN 隧道、DNS/路由和目标内网 HTTP 服务。

核心原则：以目标内网服务的真实 HTTP 响应为准，不把“进程仍在”或“客户端显示已连接”当作成功。

## 功能

- EasyConnect 被关闭或崩溃后自动打开
- 会话过期、未连接或假连接时重启客户端并持续验证
- FlClash 消失时自动拉起；绝不结束或重启仍在运行的 FlClashCore
- 8 层链路检查与 C0–C8 故障分类
- 冷却退避、原子恢复锁、心跳和独立 watchdog
- 原生菜单栏状态与“立即重连”操作
- `/bin/bash` 3.2 兼容，适用于 macOS 自带 Bash

## 前提

- macOS
- `/Applications/EasyConnect.app`
- `/Applications/FlClash.app`（如果不使用，可按需调整健康检查）
- EasyConnect 已配置可自动登录
- 命令行工具：`curl`、`dig`、`nc`、`python3`

## 配置

```bash
mkdir -p ~/.config/easyconnect-keeper
cp config.example ~/.config/easyconnect-keeper/config
```

编辑配置中的目标内网地址：

```bash
HC_INNER_HOST="intranet.example.com"
HC_INNER_URL="https://intranet.example.com/"
```

不要把包含真实内部域名、IP、凭据或 Token 的配置提交到 Git。

## 安装

```bash
./install.sh install
```

安装器会部署版本化运行目录、主守护 LaunchAgent、watchdog 和菜单栏应用。未创建配置时，安装器会生成配置文件并安全退出，填写后再次运行即可。

常用命令：

```bash
keeperctl status
keeperctl diag
keeperctl events
keeperctl pause 30
keeperctl resume
keeperctl maint on
keeperctl maint off
keeperctl ua on
keeperctl ua off
```

卸载：

```bash
./install.sh uninstall
```

## 健康检查

| 层 | 检查项 |
|---|---|
| L1 | 本机公网连通性 |
| L2 | FlClashCore 进程 |
| L3 | 本地代理端口和真实代理请求 |
| L4 | macOS 系统代理配置 |
| L5 | FlClash TUN 接口 |
| L6 | EasyConnect 本地 API 与隧道状态 |
| L7 | 目标域名 DNS 与路由出口 |
| L8 | 目标内网 HTTP 服务 |

当 EasyConnect 主进程消失时，UA 模式会在下一个巡检周期内直接拉起，不依赖 L8 错误类型。

## 恢复边界

- FlClash 未运行：只执行 `open` 拉起。
- FlClashCore 仍在：只记录和通知，绝不强制结束。
- EasyConnect 未运行：立即打开。
- EasyConnect 会话过期或假连接：重启 GUI，依赖客户端已有的自动登录配置恢复。
- DNS/路由异常：只记录，不修改系统网络配置。
- 服务端 5xx/证书故障：不重启 VPN，避免重启风暴。

## 测试

测试不会主动断开真实网络：

```bash
./test_health.sh
./test_recovery.sh
```

## 隐私与安全

诊断日志可能包含网络状态和目标地址。公开 Issue 前请先脱敏。参见 [SECURITY.md](SECURITY.md)。

## 许可证

[MIT](LICENSE)
