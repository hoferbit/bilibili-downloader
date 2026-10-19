// 生成应用图标：粉色圆角方块 + 小电视 + 下载箭头
// 用法：swift scripts/make-icon.swift <输出.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100
let bg = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.addPath(bgPath)
ctx.setFillColor(NSColor(red: 0.98, green: 0.45, blue: 0.60, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 1.0, green: 0.55, blue: 0.70, alpha: 1).cgColor,
                                   NSColor(red: 0.94, green: 0.33, blue: 0.52, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setFillColor(NSColor.white.cgColor)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// 天线
ctx.setLineWidth(40)
ctx.move(to: CGPoint(x: 400, y: 790)); ctx.addLine(to: CGPoint(x: 460, y: 710))
ctx.move(to: CGPoint(x: 624, y: 790)); ctx.addLine(to: CGPoint(x: 564, y: 710))
ctx.strokePath()

// 屏幕
let screen = CGRect(x: 240, y: 300, width: 544, height: 400)
ctx.setLineWidth(44)
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.strokePath()

// 下载箭头
ctx.setLineWidth(46)
ctx.move(to: CGPoint(x: 512, y: 610)); ctx.addLine(to: CGPoint(x: 512, y: 410))
ctx.move(to: CGPoint(x: 432, y: 480)); ctx.addLine(to: CGPoint(x: 512, y: 400)); ctx.addLine(to: CGPoint(x: 592, y: 480))
ctx.strokePath()

// 脚
ctx.setLineWidth(40)
ctx.move(to: CGPoint(x: 360, y: 250)); ctx.addLine(to: CGPoint(x: 360, y: 230))
ctx.move(to: CGPoint(x: 664, y: 250)); ctx.addLine(to: CGPoint(x: 664, y: 230))
ctx.strokePath()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
