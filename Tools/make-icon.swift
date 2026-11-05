// 生成 轻阅 的 App 图标（1024×1024 PNG）。纯 CoreGraphics，无第三方依赖。
//
//   xcrun swiftc -O Tools/make-icon.swift -o build/make-icon
//   ./build/make-icon out.png                       # 默认满幅不透明（macOS 26+ 的样子）
//   ICON_STYLE=squircle ./build/make-icon out.png   # 旧式 824 圆角留白版
//
// 为什么要两种：macOS 26 起，系统会给"四周带透明留白的旧式图标"自动套一层灰色底板，
// 图标缩在灰块里很难看（实测 macOS 27：824 版被加灰底板，满幅不透明版不加）。
// 旧系统反过来：满幅方块会显得比系统图标大一圈。所以按目标系统挑一种出图。
import AppKit
import CoreGraphics

let SIZE: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let style = ProcessInfo.processInfo.environment["ICON_STYLE"] ?? "square"
let squareBody = style != "squircle"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil,
                          width: Int(SIZE), height: Int(SIZE),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("无法创建位图上下文")
}
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

let cx: CGFloat = SIZE / 2, cy: CGFloat = SIZE / 2
// 内容一律按"824 见方"的视觉尺寸排版，满幅时整体放大一点，两种形态观感一致。
let k: CGFloat = squareBody ? 1.10 : 1.0

// MARK: - 底：满幅方块 / 超椭圆

let bodySide: CGFloat = squareBody ? SIZE : 824
let a = bodySide / 2
let n: CGFloat = 4.6        // 指数越大越方；4.6 接近 macOS 图标外形
let body = CGMutablePath()
if squareBody {
    body.addRect(CGRect(x: 0, y: 0, width: SIZE, height: SIZE))
} else {
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = a * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { body.move(to: CGPoint(x: cx + x, y: cy + y)) }
        else { body.addLine(to: CGPoint(x: cx + x, y: cy + y)) }
    }
    body.closeSubpath()
}

ctx.saveGState()
ctx.addPath(body)
ctx.clip()
let bg = CGGradient(colorsSpace: cs,
                    colors: [rgb(158, 214, 255), rgb(97, 159, 246), rgb(60, 88, 222)] as CFArray,
                    locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg,
                       start: CGPoint(x: cx - 300, y: SIZE),
                       end: CGPoint(x: cx + 320, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// 左上角一层柔光，避免大色块发闷
let glow = CGGradient(colorsSpace: cs,
                      colors: [rgb(255, 255, 255, 0.34), rgb(255, 255, 255, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: cx - 150, y: SIZE - 150), startRadius: 0,
                       endCenter: CGPoint(x: cx - 150, y: SIZE - 150), endRadius: 640,
                       options: [])
ctx.restoreGState()

// MARK: - 页面形状（右上角折角，其余三个角圆角）

let pageW: CGFloat = 470 * k
let pageH: CGFloat = 570 * k
let px0 = cx - pageW / 2
let px1 = cx + pageW / 2
let py0: CGFloat = cy - pageH / 2 - 14 * k          // 略偏下，上方多留一点呼吸
let py1 = py0 + pageH
let pageR: CGFloat = 36 * k
let fold: CGFloat = 104 * k

let page = CGMutablePath()
page.move(to: CGPoint(x: px0 + pageR, y: py1))
page.addLine(to: CGPoint(x: px1 - fold, y: py1))
page.addLine(to: CGPoint(x: px1, y: py1 - fold))
page.addLine(to: CGPoint(x: px1, y: py0 + pageR))
page.addArc(tangent1End: CGPoint(x: px1, y: py0), tangent2End: CGPoint(x: px0, y: py0), radius: pageR)
page.addLine(to: CGPoint(x: px0 + pageR, y: py0))
page.addArc(tangent1End: CGPoint(x: px0, y: py0), tangent2End: CGPoint(x: px0, y: py1), radius: pageR)
page.addLine(to: CGPoint(x: px0, y: py1 - pageR))
page.addArc(tangent1End: CGPoint(x: px0, y: py1), tangent2End: CGPoint(x: px1, y: py1), radius: pageR)
page.closeSubpath()

// 只留一张纸：试过在后面叠一张错开的纸，但折角那块是缺口，叠上去的纸会从缺口透出来，
// 看着像"两个折角"，小尺寸下更糊。
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16 * k),
              blur: 44 * k,
              color: rgb(16, 38, 88, 0.30))
ctx.addPath(page)
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()

// 折角：三角面稍暗，折痕留一道白线
ctx.saveGState()
ctx.addPath(page)
ctx.clip()
let tri = CGMutablePath()
tri.move(to: CGPoint(x: px1 - fold, y: py1))
tri.addLine(to: CGPoint(x: px1, y: py1 - fold))
tri.addLine(to: CGPoint(x: px1 - fold, y: py1 - fold))
tri.closeSubpath()
ctx.saveGState()
ctx.addPath(tri)
ctx.clip()
let foldGrad = CGGradient(colorsSpace: cs,
                          colors: [rgb(205, 221, 240), rgb(233, 241, 250)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(foldGrad,
                       start: CGPoint(x: px1 - fold, y: py1),
                       end: CGPoint(x: px1, y: py1 - fold),
                       options: [])
ctx.restoreGState()

ctx.move(to: CGPoint(x: px1 - fold, y: py1))
ctx.addLine(to: CGPoint(x: px1 - fold, y: py1 - fold))
ctx.setStrokeColor(rgb(255, 255, 255, 0.9))
ctx.setLineWidth(3 * k)
ctx.strokePath()
ctx.restoreGState()

// MARK: - 正文线条（第二行用暖色，像划了重点）

let lineX = px0 + 68 * k
let lineRight = px1 - 68 * k
let full = lineRight - lineX
let lineH: CGFloat = 30 * k
let gap: CGFloat = 30 * k
let widths: [CGFloat] = [full, 205 * k, full, full, 152 * k]
let blockTop = py1 - 168 * k

for (i, w) in widths.enumerated() {
    let y = blockTop - CGFloat(i) * (lineH + gap)
    let bar = CGPath(roundedRect: CGRect(x: lineX, y: y - lineH, width: w, height: lineH),
                     cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil)
    ctx.addPath(bar)
    ctx.setFillColor(i == 1 ? rgb(255, 174, 60) : rgb(198, 211, 227))
    ctx.fillPath()
}

// MARK: - 导出

guard let image = ctx.makeImage() else { fatalError("渲染失败") }
let url = URL(fileURLWithPath: outPath)
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: SIZE, height: SIZE)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("编码失败") }
try data.write(to: url)
print("✓ \(outPath)  \(style)  \(Int(SIZE))×\(Int(SIZE))  \(data.count / 1024) KB")
