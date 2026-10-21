// EasyConnect 控制台 — 图形化开关与状态面板
// 目的：不依赖终端命令，双击即可查看链路状态、开关 EasyConnect、暂停/恢复守护。

import Cocoa

let home = FileManager.default.homeDirectoryForCurrentUser
let runDir = home.appendingPathComponent("Library/Application Support/EasyConnectKeeper")
let stateFile = runDir.appendingPathComponent("state")
let pauseFile = runDir.appendingPathComponent("pause")
let heartbeatFile = runDir.appendingPathComponent("heartbeat")
let keeperctl = runDir.appendingPathComponent("current/keeperctl")
let keeperLog = home.appendingPathComponent("Library/Logs/easyconnect-keeper/keeper.log")

// ─────────────────────────── 基础工具 ───────────────────────────

/// 执行 shell 命令，带超时，返回 (退出码, 合并输出)。
func runShell(_ command: String, timeout: TimeInterval = 15) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", command]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (-1, "无法执行命令：\(error.localizedDescription)")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline {
        usleep(50_000)
    }
    if p.isRunning {
        p.terminate()
        return (-2, "命令超时")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func fileExists(_ path: URL) -> Bool {
    FileManager.default.fileExists(atPath: path.path)
}

// ─────────────────────────── 状态读取 ───────────────────────────

struct KeeperStatus {
    var code = "UNKNOWN"
    var desc = "无状态"
    var action = ""
    var time = "-"
    var heartbeatOK = false
    var paused = false
}

func readKeeperStatus() -> KeeperStatus {
    var s = KeeperStatus()
    s.paused = fileExists(pauseFile)
    if let raw = try? String(contentsOf: stateFile, encoding: .utf8),
       let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        s.code = (obj["status"] as? String) ?? "UNKNOWN"
        s.desc = (obj["desc"] as? String) ?? ""
        s.action = (obj["action"] as? String) ?? ""
        s.time = (obj["time"] as? String) ?? "-"
    }
    if let raw = try? String(contentsOf: heartbeatFile, encoding: .utf8),
       let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let epoch = obj["ts_epoch"] as? Double {
        s.heartbeatOK = (Date().timeIntervalSince1970 - epoch) < 120
    }
    return s
}

/// 读取 EasyConnect 本地 Agent 的隧道状态；18 = 已连接。
func readECTunnel() -> Int? {
    let cmd = "curl -sk --connect-timeout 2 --max-time 4 " +
        "'https://127.0.0.1:54530/ECAgent?op=DoQueryService&arg1=QUERY%20QSTATE%20L3VPN'"
    let (_, out) = runShell(cmd, timeout: 6)
    let pattern = "\"result\"\\s*:\\s*\"?(-?[0-9]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let m = regex.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
          let r = Range(m.range(at: 1), in: out) else { return nil }
    return Int(out[r])
}

/// 内网 API 是否可达（2xx/3xx/4xx 都算通，5xx 算服务端异常）。
func readInnerAPI() -> String {
    let cmd = "curl -4 -s --noproxy '*' --max-time 5 -o /dev/null " +
        "-w '%{http_code}' https://claude.jlcops.com/"
    let (_, out) = runShell(cmd, timeout: 8)
    let code = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if code.isEmpty { return "不通（无响应）" }
    guard let n = Int(code), (100...599).contains(n) else { return "异常（\(code)）" }
    if (200...499).contains(n) { return "通（HTTP \(n)）" }
    return "服务端异常（HTTP \(n)）"
}

func ecRunning() -> Bool {
    let (rc, _) = runShell("pgrep -x EasyConnect >/dev/null 2>&1", timeout: 3)
    return rc == 0
}

// ─────────────────────────── 主界面 ───────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var keeperValue: NSTextField!
    var recoveryValue: NSTextField!
    var ecValue: NSTextField!
    var apiValue: NSTextField!
    var pauseButton: NSButton!
    var diagPanel: NSPanel?
    var diagText: NSTextView?
    var timer: Timer?
    var refreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        refresh()
        // 状态轮询：10 秒一次，后台执行网络探测，不卡界面。
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 EasyConnect 控制台",
                        action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 EasyConnect 控制台",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        return l
    }

    func statusRow(_ title: String, value: NSTextField) -> NSStackView {
        let t = label(title, size: 13, weight: .medium)
        t.textColor = .secondaryLabelColor
        t.widthAnchor.constraint(equalToConstant: 96).isActive = true
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        let row = NSStackView(views: [t, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }

    func button(_ title: String, action: Selector, color: NSColor? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        if let c = color { b.contentTintColor = c }
        return b
    }

    func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 410),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "EasyConnect 控制台"
        window.delegate = self
        window.center()

        keeperValue = label("读取中…", size: 14, weight: .medium)
        recoveryValue = label("读取中…", size: 14, weight: .medium)
        ecValue = label("读取中…", size: 14, weight: .medium)
        apiValue = label("读取中…", size: 14, weight: .medium)

        pauseButton = button("⏸ 暂停守护", action: #selector(togglePause(_:)), color: .systemOrange)

        let openBtn = button("打开 EasyConnect", action: #selector(openEC(_:)), color: .systemGreen)
        let quitBtn = button("退出 EasyConnect", action: #selector(quitEC(_:)), color: .systemRed)
        let diagBtn = button("运行 8 层诊断", action: #selector(runDiag(_:)))
        let logBtn = button("打开日志", action: #selector(openLog(_:)))

        let row1 = NSStackView(views: [openBtn, quitBtn])
        row1.orientation = .horizontal
        row1.spacing = 12

        let row2 = NSStackView(views: [pauseButton, diagBtn, logBtn])
        row2.orientation = .horizontal
        row2.spacing = 12

        let hint = label("守护暂停后不会自动重连；退出 EasyConnect 会断开内网连接。",
                         size: 12)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            statusRow("守护", value: keeperValue),
            statusRow("自动恢复", value: recoveryValue),
            statusRow("EasyConnect", value: ecValue),
            statusRow("内网 API", value: apiValue),
            row1, row2, hint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    // ─────────────────────── 状态刷新 ───────────────────────

    func refresh() {
        if refreshing { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let k = readKeeperStatus()
            let running = ecRunning()
            let tunnel = running ? readECTunnel() : nil
            let api = readInnerAPI()
            DispatchQueue.main.async {
                self.apply(k, running: running, tunnel: tunnel, api: api)
                self.refreshing = false
            }
        }
    }

    func apply(_ k: KeeperStatus, running: Bool, tunnel: Int?, api: String) {
        if !k.heartbeatOK {
            keeperValue.stringValue = "☠️ 无响应（心跳过期）"
            keeperValue.textColor = .systemRed
        } else if k.paused {
            keeperValue.stringValue = "⏸ 已暂停 · \(k.time)"
            keeperValue.textColor = .systemOrange
        } else {
            let text: String
            switch k.code {
            case "C0": text = "🟢 正常（内网健康）"
            case "C5": text = "🔴 EasyConnect 未连接"
            case "C6": text = "🟡 假连接（隧道在但内网不通）"
            case "C1": text = "🟠 本机断网"
            case "C3": text = "🟠 代理链路异常"
            case "C7": text = "🟠 DNS/路由异常"
            case "C8": text = "🔵 服务端异常"
            default:   text = "🟢 \(k.desc.isEmpty ? k.code : k.desc)"
            }
            keeperValue.stringValue = text + " · " + k.time
            keeperValue.textColor = .labelColor
        }

        recoveryValue.stringValue = k.paused ? "已暂停，等待恢复守护" : k.desc
        recoveryValue.textColor = (k.action == "cooldown") ? .systemOrange : .secondaryLabelColor

        if !running {
            ecValue.stringValue = "⚫ 未运行"
            ecValue.textColor = .secondaryLabelColor
        } else if tunnel == 18 {
            ecValue.stringValue = api.hasPrefix("通") ? "🟢 已连接" : "🟡 隧道已连接，内网尚未通过验证"
            ecValue.textColor = api.hasPrefix("通") ? .systemGreen : .systemOrange
        } else if let t = tunnel {
            ecValue.stringValue = "🟠 运行中但未连接（result=\(t)）"
            ecValue.textColor = .systemOrange
        } else {
            ecValue.stringValue = "🟠 运行中 · 未登录或本地接口未响应"
            ecValue.textColor = .systemOrange
        }

        apiValue.stringValue = api
        if api.hasPrefix("通") {
            apiValue.textColor = .systemGreen
        } else if api.contains("服务端") {
            apiValue.textColor = .systemBlue
        } else {
            apiValue.textColor = .systemRed
        }

        pauseButton.title = k.paused ? "▶️ 恢复守护" : "⏸ 暂停守护"
        pauseButton.contentTintColor = k.paused ? .systemGreen : .systemOrange
    }

    // ─────────────────────── 动作 ───────────────────────

    @objc func togglePause(_ sender: Any?) {
        if fileExists(pauseFile) {
            try? FileManager.default.removeItem(at: pauseFile)
        } else {
            try? "manual".write(to: pauseFile, atomically: true, encoding: .utf8)
        }
        // 让守护下一轮（约 15 秒内）读到新状态，界面立即刷新。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
        }
    }

    @objc func openEC(_ sender: Any?) {
        runShell("open -a EasyConnect", timeout: 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refresh()
        }
    }

    @objc func quitEC(_ sender: Any?) {
        guard ecRunning() else {
            alert("EasyConnect 未在运行", "当前没有需要退出的 EasyConnect 进程。")
            return
        }
        let a = NSAlert()
        a.messageText = "退出 EasyConnect？"
        a.informativeText = "退出后会立即断开内网连接，正在使用内网资源的任务会中断。"
        a.alertStyle = .warning
        a.addButton(withTitle: "退出")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let (rc, out) = runShell("osascript -e 'tell application \"EasyConnect\" to quit'", timeout: 10)
        if rc != 0 {
            alert("退出失败", out.isEmpty ? "EasyConnect 没有响应退出请求。" : out)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refresh()
        }
    }

    @objc func runDiag(_ sender: Any?) {
        showDiagPanel("正在运行 8 层诊断…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (_, out) = runShell("'\(keeperctl.path)' diag", timeout: 60)
            DispatchQueue.main.async {
                self?.diagText?.string = out.isEmpty ? "诊断没有输出。" : out
            }
        }
    }

    func showDiagPanel(_ initial: String) {
        if diagPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            panel.title = "8 层链路诊断"
            panel.center()
            let scroll = NSScrollView(frame: panel.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.autoresizingMask = [.width]
            scroll.documentView = tv
            panel.contentView = scroll
            diagPanel = panel
            diagText = tv
        }
        diagText?.string = initial
        diagPanel?.makeKeyAndOrderFront(nil)
    }

    @objc func openLog(_ sender: Any?) {
        if fileExists(keeperLog) {
            runShell("open -t '\(keeperLog.path)'", timeout: 5)
        } else {
            alert("日志不存在", "尚未生成守护日志。")
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "EasyConnect 控制台"
        a.informativeText = """
        图形化查看内网链路，并开关 EasyConnect 与自动恢复守护。

        守护本体的菜单栏图标（盾牌）仍然保留，
        这里只是更直观的控制面板。

        源码：~/Projects/easyconnect-keeper
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "好")
        a.runModal()
    }

    func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

// ─────────────────────────── 入口 ───────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // 显示 Dock 图标，便于找到
app.run()
