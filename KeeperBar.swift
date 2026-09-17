// KeeperBar — EasyConnect Keeper 菜单栏管理应用
// 状态栏盾牌图标实时显示守护状态，提供暂停/恢复、开机自启、卸载入口。

import Cocoa

// 运行目录（与 keeper.sh 约定一致）
let runDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/EasyConnectKeeper")
let stateFile = runDir.appendingPathComponent("state")
let pauseFile = runDir.appendingPathComponent("pause")
let maintFile = runDir.appendingPathComponent("maintenance.lock")
let heartbeatFile = runDir.appendingPathComponent("heartbeat")
let eventsFile = runDir.appendingPathComponent("events.log")
let launchAgentPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/com.cgifm.easyconnect-keeper.plist")

var statusItem: NSStatusItem!

func readState() -> (status: String, desc: String, action: String, time: String) {
    guard let raw = try? String(contentsOf: stateFile, encoding: .utf8),
          let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ("NO_AGENT", "无状态", "-", "-")
    }
    return (
        (obj["status"] as? String) ?? "UNKNOWN",
        (obj["desc"] as? String) ?? "",
        (obj["action"] as? String) ?? "",
        (obj["time"] as? String) ?? "-"
    )
}

// 心跳是否过期（>120s 判定守护无响应）
func heartbeatAlive() -> Bool {
    guard let raw = try? String(contentsOf: heartbeatFile, encoding: .utf8),
          let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let epoch = obj["ts_epoch"] as? Double else { return false }
    return (Date().timeIntervalSince1970 - epoch) < 120
}

func run(_ launchPath: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    try? p.run()
}

func shell(_ command: String) {
    run("/bin/bash", ["-c", command])
}

func statusIcon(_ s: String) -> String {
    // 守护无响应优先级最高：状态再好也显示红色
    if !heartbeatAlive() { return "☠️" }
    switch s {
    case "C0":           return "🛡"
    case "C1":           return "🌐"
    case "C2", "C3":     return "🟠"
    case "C5":           return "🔴"
    case "C6":           return "🟡"
    case "C7":           return "🧭"
    case "C8":           return "🖥"
    case "PAUSED":       return "⏸"
    case "MAINT":        return "🔧"
    default:             return "❓"
    }
}

func statusText(_ s: String, _ desc: String) -> String {
    if !heartbeatAlive() { return "守护无响应（心跳过期，watchdog 会重建）" }
    switch s {
    case "C0":           return desc.isEmpty ? "内网 API 健康" : desc
    case "C1":           return "本机断网 · 监听网络中"
    case "C2":           return "FlClash 核心异常"
    case "C3":           return "代理链路异常"
    case "C5":           return "EasyConnect 未连接"
    case "C6":           return "假连接（EC=18 但内网不通）"
    case "C7":           return "DNS/路由异常"
    case "C8":           return "服务端/证书问题（需人工）"
    case "PAUSED":       return "守护已暂停"
    case "MAINT":        return "维护模式中"
    default:             return desc.isEmpty ? "状态未知" : desc
    }
}

// ────────────────────────────── AppDelegate ──────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self          // 打开菜单时实时重建
        statusItem.menu = menu
        rebuild(menu: menu)
        refreshIcon()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
    }

    func refreshIcon() {
        let st = readState()
        statusItem.button?.title = statusIcon(st.status)
    }
    func rebuild(menu m: NSMenu) {
        m.removeAllItems()
        let st = readState()

        let title = NSMenuItem(title: "\(statusIcon(st.status)) \(statusText(st.status, st.desc))",
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)

        let detail = NSMenuItem(title: "   状态时间：\(st.time) · 动作:\(st.action)",
                                action: nil, keyEquivalent: "")
        detail.isEnabled = false
        m.addItem(detail)
        m.addItem(.separator())

        let paused = FileManager.default.fileExists(atPath: pauseFile.path)
        let pauseItem = NSMenuItem(
            title: paused ? "▶️ 恢复守护" : "⏸ 暂停自动恢复",
            action: #selector(togglePause(_:)), keyEquivalent: "p")
        pauseItem.target = self
        m.addItem(pauseItem)

        // 维护模式开关（安装/升级/网络维护时用）
        let maint = FileManager.default.fileExists(atPath: maintFile.path)
        let maintItem = NSMenuItem(
            title: maint ? "🔧 退出维护模式" : "🔧 进入维护模式（网络维护前开启）",
            action: #selector(toggleMaint(_:)), keyEquivalent: "m")
        maintItem.target = self
        m.addItem(maintItem)

        let reconnect = NSMenuItem(title: "⚡ 立即重连一次",
                                   action: #selector(reconnectNow(_:)), keyEquivalent: "r")
        reconnect.target = self
        m.addItem(reconnect)
        m.addItem(.separator())

        // 无人值守模式开关
        let uaOn = FileManager.default.fileExists(atPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/EasyConnectKeeper/uamode").path)
        let uaItem = NSMenuItem(
            title: uaOn ? "🤖 无人值守模式：开（点击关闭）" : "🤖 无人值守模式：关（点击开启）",
            action: #selector(toggleUA(_:)), keyEquivalent: "")
        uaItem.target = self
        m.addItem(uaItem)

        let agentInstalled = FileManager.default.fileExists(atPath: launchAgentPlist.path)
        let autostart = NSMenuItem(
            title: agentInstalled ? "✅ 开机自启：已开启（点击关闭）" : "⭕ 开机自启：已关闭（点击开启）",
            action: #selector(toggleAutoStart(_:)), keyEquivalent: "")
        autostart.target = self
        m.addItem(autostart)

        m.addItem(.separator())
        let diagItem = NSMenuItem(title: "🩺 运行诊断（8层检查）",
                                  action: #selector(runDiag(_:)), keyEquivalent: "d")
        diagItem.target = self
        m.addItem(diagItem)

        let logItem = NSMenuItem(title: "📄 打开日志",
                                 action: #selector(openLog(_:)), keyEquivalent: "l")
        logItem.target = self
        m.addItem(logItem)

        let eventsItem = NSMenuItem(title: "📅 查看事件记录",
                                    action: #selector(openEvents(_:)), keyEquivalent: "e")
        eventsItem.target = self
        m.addItem(eventsItem)

        let about = NSMenuItem(title: "ℹ️ 关于 EasyConnect Keeper",
                               action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        m.addItem(about)

        m.addItem(.separator())
        let uninstall = NSMenuItem(title: "🗑 卸载 EasyConnect Keeper…",
                                   action: #selector(uninstallAll(_:)), keyEquivalent: "")
        uninstall.target = self
        m.addItem(uninstall)

        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "退出菜单栏图标",
                             action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // ────────────────────── 动作 ──────────────────────

    @objc func togglePause(_ sender: NSMenuItem) {
        let paused = FileManager.default.fileExists(atPath: pauseFile.path)
        if paused {
            try? FileManager.default.removeItem(at: pauseFile)
        } else {
            try? "manual".write(to: pauseFile, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshIcon()
        }
    }

    @objc func toggleMaint(_ sender: NSMenuItem) {
        let has = FileManager.default.fileExists(atPath: maintFile.path)
        if has {
            try? FileManager.default.removeItem(at: maintFile)
        } else {
            try? "maintainer=keeperbar".write(to: maintFile, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshIcon()
        }
    }

    @objc func toggleUA(_ sender: NSMenuItem) {
        let uaFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EasyConnectKeeper/uamode")
        let on = FileManager.default.fileExists(atPath: uaFile.path)
        if on {
            try? FileManager.default.removeItem(at: uaFile)
        } else {
            try? "on".write(to: uaFile, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshIcon()
        }
    }

    @objc func runDiag(_ sender: NSMenuItem) {
        shell("""
        out=/tmp/keeper-diag-$(date +%s).txt
        echo "### 诊断 $(date)" > $out
        '\(runDir.path)/current/keeperctl' diag >> $out 2>&1
        open -t $out
        """)
    }

    @objc func openEvents(_ sender: NSMenuItem) {
        run("/usr/bin/open", ["-t", eventsFile.path])
    }

    @objc func reconnectNow(_ sender: NSMenuItem) {
        // 若处于暂停先恢复；杀掉 GUI 由守护立即接管重连
        try? FileManager.default.removeItem(at: pauseFile)
        shell("pkill -f '/Applications/EasyConnect.app/Contents/MacOS/EasyConnect'")
    }

    @objc func toggleAutoStart(_ sender: NSMenuItem) {
        let installed = FileManager.default.fileExists(atPath: launchAgentPlist.path)
        if installed {
            shell("launchctl unload '\(launchAgentPlist.path)' 2>/dev/null; rm -f '\(launchAgentPlist.path)'")
        } else {
            let embeddedPlist = Bundle.main.resourceURL?.appendingPathComponent("com.cgifm.easyconnect-keeper.plist")
            if let p = embeddedPlist, FileManager.default.fileExists(atPath: p.path) {
                try? FileManager.default.copyItem(atPath: p.path, toPath: launchAgentPlist.path)
            }
            shell("launchctl load '\(launchAgentPlist.path)'")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshIcon()
        }
    }

    @objc func openLog(_ sender: NSMenuItem) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/easyconnect-keeper/keeper.log")
        run("/usr/bin/open", ["-t", logPath.path])
    }

    @objc func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "EasyConnect Keeper"
        alert.informativeText = """
        EasyConnect VPN 断线自动重连守护。

        原理：轮询 EasyConnect 本地 API 检测隧道状态，
        断开后自动重启客户端并等待恢复（auto_login 自动登录）。

        源码：~/Projects/easyconnect-keeper
        日志：~/Library/Logs/easyconnect-keeper/keeper.log
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc func uninstallAll(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "确认卸载 EasyConnect Keeper？"
        alert.informativeText = """
        将执行以下操作（EasyConnect 本体不受影响）：
        1. 停止并删除守护 LaunchAgent（不再开机自启）
        2. 退出菜单栏应用自身
        3. 删除程序文件与日志

        以后如需重装：源码在 ~/Projects/easyconnect-keeper，
        运行 ./install.sh install 即可。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确认卸载")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            shell("""
            launchctl unload '\(launchAgentPlist.path)' 2>/dev/null
            rm -f '\(launchAgentPlist.path)'
            rm -rf "$HOME/Library/Application Support/EasyConnectKeeper"
            rm -rf "$HOME/Library/Logs/easyconnect-keeper"
            """)
            NSApplication.shared.terminate(self)
        }
    }
}

// 菜单打开时实时重建（保证状态/开关文案最新）
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu: menu)
    }
}

// ────────────────────────────── 入口 ──────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏应用：不显示 Dock 图标
app.run()
