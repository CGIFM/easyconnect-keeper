# EasyConnect Keeper v4

内网 API（claude.jlcops.com）链路无人值守守护。核心原则：**以 L8 内网 API 实测为准绳，不把「进程活着」或「显示已连接」当成功**。

## 架构

```
主守护 keeper.sh（LaunchAgent KeepAlive，/bin/bash 3.2 兼容）
├── lib/health.sh      8 层健康检查 → 故障分类 C0~C8（纯函数，可单测）
├── 恢复状态机          分类→动作，mkdir 原子锁互斥，冷却/退避/低频观察
├── 心跳               heartbeat 文件每轮更新（区分「进程在」与「循环推进」）
└── 事件记录            events.log（证据/分类/动作/耗时/验证结果，500条有界）

watchdog.sh（独立 LaunchAgent 每 60s）
└── 只认心跳：>120s 未更新 → 杀主守护，launchd 重建（单向，不互锁）

KeeperBar.app（菜单栏）
└── 状态图标（心跳过期→☠️）· 暂停/维护/UA开关 · 诊断/日志/事件 · 卸载

keeperctl（CLI，供人工与其他 AI 任务）
└── status/diag/pause[限时]/resume/maint/ua/events/export
```

## 8 层健康检查

| 层 | 检查项 | 手段与要点 |
|---|---|---|
| L1 | 本机网络 | ping 223.5.5.5 + 经代理 HTTP 双通道（**直连 curl 在 fake-ip/TUN 下有 TLS 假故障噪声，不可用**） |
| L2 | FlClash 核心 | pgrep FlClashCore（红线：只观察/拉起，绝不杀） |
| L3 | 代理端口+实请求 | nc 7890 + baidu 经代理，**2/3 表决抗分流节点抖动** |
| L4 | 系统代理 | scutil + 端口可达性；未启用不算故障 |
| L5 | TUN 接口 | 28.0.0.1/8 utun 存在性；FlClash 没跑时可接受 |
| L6 | EC 隧道 | 本地 API `QUERY QSTATE L3VPN`，18=正常 |
| L7 | DNS/路由 | dig 直查（dscacheutil 有 30s 卡死 pathology）+ route 出接口必须 utun |
| L8 | 内网 API | curl **-4 强制 IPv4**（系统 AAAA 查询 5s 超时会拖垮连接），302/401/404=通，5xx=服务端，细分 TLS/conn |

## 故障分类与恢复边界

| 分类 | 含义 | 恢复动作 | 边界 |
|---|---|---|---|
| C0 | 健康 | — | — |
| C1 | 本机断网 | 3s 级监听网络 | 不重启任何应用 |
| C2 | FlClash 缺失 | UA 模式下 `open` 拉起 | **绝不杀运行中的 FlClash**（全局红线） |
| C3 | 代理失效 | GUI 整个没了才拉起；核心在→通知 | 不杀核心 |
| C5 | EC 未连接/会话过期 | 识别到过期弹窗立即点击“好”并重启；否则连续 3 轮确认后强制重启，auto_login 重连 | 点击失败时强制重启兜底 |
| C6 | 假连接(18但内网不通) | 连续 3 轮确认→GUI 重启（auto_login） | API Logout 签名未逆向成功，降为实验性 |
| C7 | DNS/路由异常 | 记录证据+通知 | **不改 hosts/路由/系统 DNS**（人工范围） |
| C8 | 服务端/证书问题 | 记录+通知 | **不重启 VPN**，防重启风暴 |

防循环机制：恢复失败→冷却翻倍（60s→上限 30min）→同分类连败 3 次转低频观察（5min）→不放弃并持续重试；恢复后需连续 3 次内网验证通过才算成功。

## 模式与控制

- **无人值守（UA）**：`keeperctl ua on|off`，默认开。关=尊重手动关闭，只记录不拉起
- **暂停**：`keeperctl pause [分钟]`（限时自动恢复）/菜单栏开关
- **维护模式**：`keeperctl maint on|off`，TTL 2h 自动过期。安装/升级/网络维护前必开
- 所有暂停类机制互不冲突，维护期间完全不动组件

## 安装布局（版本化+原子切换+可回退）

```
~/Library/Application Support/EasyConnectKeeper/
├── releases/v3, v4/     版本目录
├── current -> releases/v4   原子软链（LaunchAgent 指向此处）
├── KeeperBar.app        菜单栏应用
├── state / heartbeat / events.log / pause / maintenance.lock / uamode
~/Library/LaunchAgents/
├── com.cgifm.easyconnect-keeper.plist            主守护
├── com.cgifm.easyconnect-keeper-watchdog.plist   看门狗
└── com.cgifm.keeperbar.plist                     菜单栏
```

```bash
./install.sh install            # 安装/升级（原子切换）
./install.sh rollback v3        # 回退
./install.sh uninstall          # 卸载（菜单栏也有入口）
keeperctl diag                  # 8 层诊断
keeperctl export                # 脱敏诊断包到桌面
```

## 已知环境事实（诊断依据）

- hosts 已有 `10.196.3.243 claude.jlcops.com`（两行重复，遗留），**系统 AAAA 查询路径 5s 超时**：所有走系统 DNS 的连接首建慢 5s；`curl -4` / hosts 命中后 0.4s。修复需改系统 DNS 配置，属人工范围
- dscacheutil 对内网域名卡 30s（mDNSResponder 层），dig 正常 15ms——L7 弃用 dscacheutil
- baidu 经 FlClash 代理偶发单次失败（分流节点抖动），L3 用 2/3 表决
- ECAgent Logout API：md5 签名被拒（-100）、原始 TWFID result=0 未断开——签名规则未完全逆向，假连接恢复主线走 GUI 重启（auto_login 已验证可靠）

## 迭代历史

- v1 2026-09-18：EC 本地 API 检测 + 断开重连，38s 恢复
- v2 2026-09-18：断网感知 + 持续监听 + 恢复秒连
- v3 2026-09-18：菜单栏管理 + 标准安装布局 + 暂停机制
- v4 2026-09-18：8 层健康检查/故障分类、有边界恢复状态机、维护锁/UA 模式、心跳+看门狗、事件记录、版本化部署。**实机验证抓到 3 个致命 bug 并修复**（bash3.2 关联数组、无 flock、L3 抖动误判）
