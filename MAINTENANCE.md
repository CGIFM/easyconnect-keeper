# 网络维护操作说明（供其他 AI 任务 / 人工阅读）

> 本机有一条关键链路：**EasyConnect VPN → claude.jlcops.com（内网 AI API）**，
> Claude Code 等任务全靠它。守护程序 EasyConnect Keeper v4 常驻监控这条链路。

## 联网失败时的标准动作

1. **先查守护，别瞎猜**：
   ```bash
   keeperctl status      # 看状态/心跳/模式
   keeperctl diag        # 8 层诊断，直接给故障分类 C0~C8 和证据
   keeperctl events      # 最近故障与恢复记录
   ```
2. **分类含义速查**：C0 健康；C1 断网；C2 FlClash核心缺失；C3 代理失效；
   C5 EC未连接；C6 假连接；C7 DNS/路由异常；C8 服务端问题
3. **按分类行动**（不要跳过分类直接改配置）：
   - C1 → 等网络，别动配置
   - C6 → 守护会自动恢复（GUI 重启+auto_login），最多等 2 分钟
   - C7/C8 → 看证据里的具体信息，通常不是本机问题

## 严格禁止

- ❌ **kill/pkill/重启 FlClash 或 FlClashCore** —— 核心接管系统 DNS 和默认路由，一关整机断网，必须用户手动恢复
- ❌ 修改 hosts / 系统代理 / DNS / 路由表 —— 除非你确切知道在做什么，且走了维护流程
- ❌ 对着 symptom 乱试：连续改配置、反复重启应用、清路由表

## 需要动网络配置时（改 hosts、换代理端口、升级 FlClash 等）

```bash
keeperctl maint on      # ① 进入维护模式（守护停手，TTL 2h 自动过期）
# ...执行你的维护操作...
keeperctl diag          # ② 验证内网 API 通（C0 且 L8 ok）
keeperctl maint off     # ③ 退出维护模式
```

维护期间守护**完全不动任何组件**（不拉起、不重启、不重连），
只继续记录心跳，不会和你争抢。

## 守护自己的运维

- 暂停自动恢复：`keeperctl pause`（持续）或 `keeperctl pause 30`（30 分钟）
- 无人值守开关：`keeperctl ua off`（关后守护不自动拉起应用）
- 守护卡死：watchdog 2 分钟内自动重建，无需人工
- 守护误动作：`keeperctl pause` 后再排查，别直接 kill
- 诊断导出：`keeperctl export`（桌面生成脱敏诊断包）

## 边界与红线（守护自己遵守的，也适用于你）

| 组件 | 守护的权限 | 守护绝不做的 |
|---|---|---|
| FlClash | 拉起消失的进程、观察 | 杀/重启运行中的进程（红线） |
| EasyConnect | 拉起、GUI 重启（auto_login） | 碰凭据、改 EC 配置 |
| hosts/DNS/路由 | 只读观察+记录 | 任何修改 |
| 系统代理 | 只读观察 | 修改 |

## 2026-10-20：路由源地址失效案例

- 症状：EC=18、内网路由指向 VPN utun，但普通连接立即失败；Python socket 返回 errno 49（Can't assign requested address），实际选中源地址 10.10.200.1，而接口仅持有 10.10.200.5。
- 只读复核：同一 URL 使用当前 VPN 接口 IPv4 绑定请求返回 HTTP 302。此结果只能用于定位，不能当作普通业务连接恢复。
- 本次在维护模式、备份原路由后，经 macOS 原生管理员授权，仅更新内网目标 10.196.3.243 的现有路由接口地址：`route -n change -host 10.196.3.243 -ifa 10.10.200.5`。随后普通未绑定请求 HTTP 302，8 层诊断 C0。
- 上述接口地址会随 VPN 会话变化，不得照抄用于未来修复。每次必须重新核对目标出接口、该接口当前 IPv4、普通失败与绑定成功的对照证据。
- 守护目前没有管理员权限，不会自行修改路由；本次修复了永久停止重试缺陷，但不能承诺 GUI 重连能修复所有源地址异常。禁止为了无人值守而擅自增加宽泛 sudo 免密权限。
