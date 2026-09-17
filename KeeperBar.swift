// KeeperBar — EasyConnect Keeper 菜单栏管理应用
// 状态栏盾牌图标实时显示守护状态，提供暂停/恢复、开机自启、卸载入口。

import Cocoa

// 运行目录（与 keeper.sh 约定一致）
let runDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/EasyConnectKeeper")
let stateFile = runDir.appendingPathComponent("state")
let pauseFile = runDir.appendingPathComponent("pause")
let resumeFile = runDir.appendingPathComponent("resume.touch")
let launchAgentPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/com.cgifm.easyconnect-keeper.plist")

var statusItem: NSStatusItem!

func readState() -> (status: String, time: String, lastResult: String) {
    guard let raw = try? String(contentsOf: stateFile, encoding: .utf8),
          let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ("NO_AGENT", "-", "-")
    }
    let s = (obj["status"] as? String) ?? "UNKNOWN"
    let t = (obj["time"] as? String) ?? "-"
    let r = (obj["last_result"] as? String) ?? "-"
    return (s, t, r)
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
    switch s {
    case "OK":           return "🛡"
    case "ABNORMAL":     return "🟡"
    case "RECONNECTING": return "🟠"
    case "OFFLINE":      return "🌐"
    case "PAUSED":       return "⏸"
    case "NO_AGENT":     return "🔴"
    default:             return "❓"
    }
}

func statusText(_ s: String) -> String {
    switch s {
    case "OK":           return "守护中 · VPN 已连接"
    case "ABNORMAL":     return "隧道异常 · 观察中"
    case "RECONNECTING": return "正在重连 VPN…"
    case "OFFLINE":      return "本机断网 · 监听网络中"
    case "PAUSED":       return "守护已暂停"
    case "NO_AGENT":     return "守护未运行"
    default:             return "状态未知"
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

        let title = NSMenuItem(title: "\(statusIcon(st.status)) \(statusText(st.status))",
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)

        let detail = NSMenuItem(title: "   最近检测：\(st.time) · code=\(st.lastResult)",
                                action: nil, keyEquivalent: "")
        detail.isEnabled = false
        m.addItem(detail)
        m.addItem(.separator())

        let paused = FileManager.default.fileExists(atPath: pauseFile.path)
        let pauseItem = NSMenuItem(
            title: paused ? "▶️ 恢复守护" : "⏸ 暂停守护（不自动重连）",
            action: #selector(togglePause(_:)), keyEquivalent: "p")
        pauseItem.target = self
        m.addItem(pauseItem)

        let reconnect = NSMenuItem(title: "⚡ 立即重连一次",
                                   action: #selector(reconnectNow(_:)), keyEquivalent: "r")
        reconnect.target = self
        m.addItem(reconnect)
        m.addItem(.separator())

        let agentInstalled = FileManager.default.fileExists(atPath: launchAgentPlist.path)
        let autostart = NSMenuItem(
            title: agentInstalled ? "✅ 开机自启：已开启（点击关闭）" : "⭕ 开机自启：已关闭（点击开启）",
            action: #selector(toggleAutoStart(_:)), keyEquivalent: "")
        autostart.target = self
        m.addItem(autostart)

        m.addItem(.separator())
        let logItem = NSMenuItem(title: "📄 打开日志",
                                 action: #selector(openLog(_:)), keyEquivalent: "l")
        logItem.target = self
        m.addItem(logItem)

        let about = NSMenuItem(title: "ℹ️ 关于 EasyConnect Keeper",
                               action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        m.addItem(about)

        m.addItem(.separator())
        let stopKeeper = NSMenuItem(title: "🛑 退出守护进程（仅本次开机）",
                                    action: #selector(stopKeeperAgent(_:)), keyEquivalent: "")
        stopKeeper.target = self
        m.addItem(stopKeeper)

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
            // 恢复 = 直接删除 pause 文件，keeper 检测到文件消失即退出暂停
            try? FileManager.default.removeItem(at: pauseFile)
        } else {
            try? "".write(to: pauseFile, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshIcon()
        }
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

    @objc func stopKeeperAgent(_ sender: NSMenuItem) {
        shell("launchctl unload '\(launchAgentPlist.path)' 2>/dev/null")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshIcon()
        }
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
