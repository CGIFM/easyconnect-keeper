// 生成 EasyConnect 控制台的 1024×1024 图标 PNG（构建时调用）。
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = NSSize(width: 1024, height: 1024)
_ = NSApplication.shared
let img = NSImage(size: size)
img.lockFocus()
let rect = NSRect(origin: .zero, size: size)
let path = NSBezierPath(roundedRect: rect.insetBy(dx: 52, dy: 52),
                        xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.72, blue: 0.68, alpha: 1),
])!
gradient.draw(in: path, angle: -50)

let symbol = "⇄"
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 470, weight: .bold),
    .foregroundColor: NSColor.white,
]
let s = symbol.size(withAttributes: attrs)
symbol.draw(at: NSPoint(x: (size.width - s.width) / 2,
                        y: (size.height - s.height) / 2),
            withAttributes: attrs)
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("图标生成失败\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
