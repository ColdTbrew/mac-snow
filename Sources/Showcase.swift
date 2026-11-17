// Showcase: renders the real snow engine on a virtual, code-drawn desktop (no screen capture).
// `MacSnow --showcase <dir>` writes frames/fNNNN.png plus a few stills into <dir>.
import AppKit
import QuartzCore

/// Scripted fake windows standing in for CGWindowList.
final class FakeWindows: WindowProvider {
    struct W {
        let id: CGWindowID
        var frame: CGRect
        let title: String
        let kind: Kind
        var visible = true
    }
    enum Kind { case finder, music, notes }
    var list: [W] = []   // front-to-back

    func fetch() -> [Win] {
        list.filter { $0.visible }.enumerated().map { Win(id: $1.id, frame: $1.frame, z: $0, surface: true) }
    }
    func frame(of id: CGWindowID) -> CGRect? { list.first { $0.id == id && $0.visible }?.frame }
    func index(_ id: CGWindowID) -> Int { list.firstIndex { $0.id == id }! }
}

enum Showcase {
    static let size = CGSize(width: 1440, height: 900)
    static let menuH: CGFloat = 24
    static let dockRect = CGRect(x: 455, y: 6, width: 530, height: 64)

    static func run(outDir: String) {
        // fixed settings for the run only (argument domain: never written to disk)
        UserDefaults.standard.setVolatileDomain(["snowOn": true, "intensity": 1, "snowmenOn": true, "autoPlow": false, "flakesOnTop": false],
                                                forName: UserDefaults.argumentDomain)
        S = 1.15
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir + "/frames", withIntermediateDirectories: true)

        let fake = FakeWindows()
        fake.list = [
            .init(id: 3, frame: CGRect(x: 360, y: 150, width: 440, height: 270), title: "메모", kind: .notes),
            .init(id: 2, frame: CGRect(x: 690, y: 330, width: 560, height: 380), title: "Music", kind: .music),
            .init(id: 1, frame: CGRect(x: 110, y: 300, width: 640, height: 360), title: "Finder", kind: .finder),
        ]
        let engine = Engine()
        let ov = Overlay(virtualFrame: CGRect(origin: .zero, size: size))
        engine.overlays = [ov]
        engine.windowSource = fake
        engine.dockSource = { _ in (dockRect.minX + 10, dockRect.maxX - 10, dockRect.maxY) }
        engine.lowPower = false
        engine.forceFast = true            // re-read (fake) window geometry every step
        var t: CFTimeInterval = 0
        engine.virtualNow = t; engine.last = t; engine.lastPlow = t
        engine.refreshGeometry()

        let dt = 1.0 / 30
        var frameNo = 0
        func step(_ n: Int = 1, record: Bool = false, each: ((Int) -> Void)? = nil) {
            for i in 0..<n {
                each?(i)
                t += dt
                engine.virtualNow = t
                engine.tick()
                if record && i % 2 == 0 {          // 15 fps output
                    render(engine, fake, t, scale: 0.6, path: String(format: "%@/frames/f%04d.png", outDir, frameNo))
                    frameNo += 1
                }
            }
        }
        func still(_ name: String, scale: CGFloat = 1, crop: CGRect? = nil) {
            render(engine, fake, t, scale: scale, crop: crop, path: "\(outDir)/\(name).png")
        }

        // 0) snow has been falling for a while (not recorded)
        engine.demoBoost = 10
        step(30 * 30)
        engine.demoBoost = 3
        // 1) snowfall + accumulation
        step(30 * 3, record: true)
        // 2) drag the front window ("메모") — its snow comes along and keeps collecting
        let notes = fake.index(3)
        let from = fake.list[notes].frame.origin
        step(30 * 2, record: true) { i in
            let k = CGFloat(i + 1) / 60, e = k * k * (3 - 2 * k)
            fake.list[notes].frame.origin = CGPoint(x: from.x + 330 * e, y: from.y + 60 * e)
        }
        step(30 * 1, record: true)
        still("still-1-snow")
        still("pile-end-zoom", scale: 3, crop: CGRect(x: 80, y: 610, width: 260, height: 80))
        still("pile-occlusion-zoom", scale: 3, crop: CGRect(x: 600, y: 610, width: 200, height: 120))
        // 3) roll a snowball along Finder's snow, release -> snowman
        engine.demoBoost = 1
        let finder = fake.list[fake.index(1)].frame
        let y = finder.maxY + 4
        let x0 = finder.minX + 140
        engine.rollBegin(at: CGPoint(x: x0, y: y))
        step(30 * 4, record: true) { i in
            let tt = CGFloat(i) / 30
            engine.rollMove(to: CGPoint(x: x0 + 150 * sin(tt * 2.6) + 30 * tt, y: y))
            if i == 70 { still("still-2-rolling") }
        }
        _ = engine.rollEnd()
        step(30 * 1, record: true)
        // 4) click the title bar of "메모" -> snowman drops in; the rolled one jumps
        let nf = fake.list[notes].frame
        engine.spawnSnowman(onSurface: UInt64(fake.list[notes].id), atX: nf.minX + nf.width * 0.4, fromY: nf.maxY + 30 * S)
        step(20, record: true)
        engine.props.filter { $0.host == 1 }.forEach(engine.jump)
        step(8, record: true)
        still("still-3-snowmen")
        step(30 * 1, record: true)
        // 5) close "메모" -> its snowman falls off
        fake.list[notes].visible = false
        step(30 * 2, record: true)
        // 6) snowplow pushes the Dock snow into a mound
        engine.piles[Engine.dockKey(0)]?.fill()
        engine.startPlow()
        var shot = false
        step(30 * 10, record: true) { _ in
            if !shot, let p = engine.plows.first, p.x > dockRect.midX + 40 { still("still-4-plow"); shot = true }
        }
        print("showcase: \(frameNo) frames -> \(outDir)")
    }

    // MARK: - drawing the virtual desktop

    static func render(_ e: Engine, _ fake: FakeWindows, _ t: CFTimeInterval, scale: CGFloat, crop: CGRect? = nil, path: String) {
        let area = crop ?? CGRect(origin: .zero, size: size)
        let W = Int(area.width * scale), H = Int(area.height * scale)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        drawWallpaper(ctx)
        e.overlays[0].backRoot.render(in: ctx)          // falling flakes: behind the windows and the Dock
        for w in fake.list.reversed() where w.visible { drawWindow(ctx, w) }
        drawDock(ctx)
        // plow beacon blink (the real app does this with a CA animation)
        for p in e.plows { p.layer.sublayers?.last?.opacity = Int(t * 3) % 2 == 0 ? 1 : 0.25 }
        e.overlays[0].root.render(in: ctx)
        drawMenuBar(ctx)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static func drawWallpaper(_ c: CGContext) {
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            rgb(0.07, 0.10, 0.25), rgb(0.20, 0.24, 0.50), rgb(0.55, 0.60, 0.82)] as CFArray, locations: [0, 0.55, 1])!
        c.drawLinearGradient(grad, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
        // stars (fixed pseudo-random)
        var seed: UInt32 = 7
        func rnd() -> CGFloat { seed = seed &* 1664525 &+ 1013904223; return CGFloat(seed >> 8) / CGFloat(1 << 24) }
        for _ in 0..<140 {
            let x = rnd() * size.width, y = size.height * (0.45 + 0.55 * rnd()), r = 0.5 + rnd() * 1.1
            c.setFillColor(rgb(1, 1, 1, 0.35 + 0.5 * rnd())); c.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }
        // moon
        c.setFillColor(rgb(1, 0.97, 0.88, 0.95)); c.fillEllipse(in: CGRect(x: 1220, y: 760, width: 56, height: 56))
        // mountains with snowy caps
        func mountain(_ pts: [(CGFloat, CGFloat)], _ col: CGColor) {
            c.move(to: CGPoint(x: 0, y: 0))
            for (x, y) in pts { c.addLine(to: CGPoint(x: x, y: y)) }
            c.addLine(to: CGPoint(x: size.width, y: 0)); c.closePath(); c.setFillColor(col); c.fillPath()
        }
        mountain([(0, 330), (220, 520), (420, 380), (650, 600), (900, 400), (1120, 560), (1440, 360)], rgb(0.30, 0.35, 0.60))
        mountain([(0, 220), (300, 380), (560, 250), (820, 420), (1080, 260), (1300, 380), (1440, 300)], rgb(0.22, 0.27, 0.50))
        for (px, py, w) in [(650.0, 600.0, 70.0), (220, 520, 60), (1120, 560, 60)] as [(CGFloat, CGFloat, CGFloat)] {
            c.move(to: CGPoint(x: px, y: py)); c.addLine(to: CGPoint(x: px - w / 2, y: py - w * 0.6))
            c.addLine(to: CGPoint(x: px - w / 6, y: py - w * 0.45)); c.addLine(to: CGPoint(x: px + w / 8, y: py - w * 0.62))
            c.addLine(to: CGPoint(x: px + w / 2, y: py - w * 0.55)); c.closePath()
            c.setFillColor(rgb(0.93, 0.95, 1)); c.fillPath()
        }
    }

    static func text(_ s: String, _ p: CGPoint, size: CGFloat, color: NSColor, bold: Bool = false) {
        let a: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color]
        NSAttributedString(string: s, attributes: a).draw(at: p)
    }

    static func drawWindow(_ c: CGContext, _ w: FakeWindows.W) {
        let f = w.frame, R: CGFloat = 12
        let dark = w.kind == .music
        let shape = CGPath(roundedRect: f, cornerWidth: R, cornerHeight: R, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0, 0, 0, 0.45))
        c.addPath(shape); c.setFillColor(dark ? rgb(0.13, 0.13, 0.15) : rgb(0.98, 0.98, 0.99)); c.fillPath()
        c.restoreGState()
        c.saveGState(); c.addPath(shape); c.clip()
        // title bar
        c.setFillColor(dark ? rgb(0.19, 0.19, 0.21) : rgb(0.93, 0.93, 0.95)); c.fill(CGRect(x: f.minX, y: f.maxY - 34, width: f.width, height: 34))
        for (i, col) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.78, 0.25)].enumerated() {
            c.setFillColor(col); c.fillEllipse(in: CGRect(x: f.minX + 14 + CGFloat(i) * 20, y: f.maxY - 23, width: 12, height: 12))
        }
        text(w.title, CGPoint(x: f.minX + 82, y: f.maxY - 25), size: 13, color: dark ? .white : NSColor(white: 0.25, alpha: 1), bold: true)
        let body = CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height - 34)
        switch w.kind {
        case .finder:
            c.setFillColor(rgb(0.95, 0.95, 0.97)); c.fill(CGRect(x: body.minX, y: body.minY, width: 150, height: body.height))
            for i in 0..<6 {
                c.setFillColor(rgb(0.80, 0.82, 0.88)); c.fill(CGRect(x: body.minX + 18, y: body.maxY - 30 - CGFloat(i) * 26, width: 90, height: 9))
            }
            for i in 0..<8 {
                let y = body.maxY - 34 - CGFloat(i) * 32
                guard y > body.minY + 8 else { break }
                c.setFillColor(rgb(0.36, 0.62, 0.95)); c.addPath(CGPath(roundedRect: CGRect(x: body.minX + 172, y: y, width: 20, height: 16), cornerWidth: 3, cornerHeight: 3, transform: nil)); c.fillPath()
                c.setFillColor(rgb(0.78, 0.80, 0.85)); c.fill(CGRect(x: body.minX + 204, y: y + 4, width: 160 + CGFloat((i * 37) % 120), height: 8))
            }
        case .music:
            let cols = [rgb(0.95, 0.30, 0.35), rgb(0.98, 0.62, 0.25), rgb(0.40, 0.55, 0.95), rgb(0.55, 0.35, 0.80), rgb(0.25, 0.70, 0.65), rgb(0.95, 0.45, 0.65)]
            for i in 0..<6 {
                let x = body.minX + 24 + CGFloat(i % 3) * 172, y = body.maxY - 170 - CGFloat(i / 3) * 175
                c.setFillColor(cols[i]); c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 150, height: 150), cornerWidth: 10, cornerHeight: 10, transform: nil)); c.fillPath()
            }
        case .notes:
            c.setFillColor(rgb(1.0, 0.85, 0.30)); c.fill(CGRect(x: body.minX, y: body.maxY - 6, width: body.width, height: 6))
            text("크리스마스 준비", CGPoint(x: body.minX + 20, y: body.maxY - 44), size: 18, color: NSColor(white: 0.15, alpha: 1), bold: true)
            for i in 0..<6 {
                c.setFillColor(rgb(0.80, 0.80, 0.83)); c.fill(CGRect(x: body.minX + 20, y: body.maxY - 76 - CGFloat(i) * 26, width: 260 + CGFloat((i * 53) % 110), height: 8))
            }
        }
        c.restoreGState()
        c.addPath(shape); c.setStrokeColor(rgb(0, 0, 0, 0.25)); c.setLineWidth(0.8); c.strokePath()
    }

    static func drawDock(_ c: CGContext) {
        let d = dockRect
        c.addPath(CGPath(roundedRect: d, cornerWidth: 18, cornerHeight: 18, transform: nil))
        c.setFillColor(rgb(1, 1, 1, 0.28)); c.fillPath()
        c.addPath(CGPath(roundedRect: d, cornerWidth: 18, cornerHeight: 18, transform: nil))
        c.setStrokeColor(rgb(1, 1, 1, 0.45)); c.setLineWidth(1); c.strokePath()
        let cols = [rgb(0.30, 0.60, 0.98), rgb(0.98, 0.35, 0.40), rgb(1.0, 0.80, 0.25), rgb(0.35, 0.80, 0.45),
                    rgb(0.60, 0.45, 0.95), rgb(0.98, 0.55, 0.25), rgb(0.25, 0.75, 0.85), rgb(0.85, 0.85, 0.88)]
        for (i, col) in cols.enumerated() {
            let x = d.minX + 14 + CGFloat(i) * 60 + (i >= 7 ? 22 : 0)
            let r = CGRect(x: x, y: d.minY + 8, width: 48, height: 48)
            c.addPath(CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil)); c.setFillColor(col); c.fillPath()
            c.setFillColor(rgb(1, 1, 1, 0.85)); c.fillEllipse(in: r.insetBy(dx: 15, dy: 15))
        }
        c.setFillColor(rgb(1, 1, 1, 0.5)); c.fill(CGRect(x: d.minX + 14 + 7 * 60 + 2, y: d.minY + 12, width: 1, height: 40))
    }

    static func drawMenuBar(_ c: CGContext) {
        c.setFillColor(rgb(0.05, 0.07, 0.18, 0.55)); c.fill(CGRect(x: 0, y: size.height - menuH, width: size.width, height: menuH))
        let y = size.height - menuH + 4
        text("Finder", CGPoint(x: 18, y: y), size: 13, color: .white, bold: true)
        var x: CGFloat = 80
        for m in ["파일", "편집", "보기", "이동", "윈도우", "도움말"] { text(m, CGPoint(x: x, y: y), size: 13, color: .white); x += 48 }
        text("❄", CGPoint(x: size.width - 250, y: y - 1), size: 14, color: .white)
        text("12월 24일 (목) 오후 8:00", CGPoint(x: size.width - 200, y: y), size: 13, color: .white)
    }
}
