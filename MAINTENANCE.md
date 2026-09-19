# 维护说明

## 排障入口

```bash
keeperctl status
keeperctl diag
keeperctl events
```

先根据 C0–C8 分类定位故障层级，再决定操作，避免连续修改网络配置。

## 维护模式

修改代理端口、VPN 配置、DNS 或路由前：

```bash
keeperctl maint on
# 执行维护
keeperctl diag
keeperctl maint off
```

维护锁默认两小时后自动过期。

## 安全边界

- 不结束或重启正在运行的 FlClashCore。
- 不自动修改 hosts、DNS、路由或系统代理。
- 不读取、保存或修改 EasyConnect 凭据。
- 服务端故障不触发 VPN 重启。

## 守护自检

- 主守护每轮更新心跳。
- watchdog 每分钟检查一次；心跳超过 120 秒未更新时由 launchd 重建主守护。
- 恢复锁使用原子目录，启动时会清理上个异常实例留下的锁。
