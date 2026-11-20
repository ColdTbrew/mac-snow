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
    static var dockRect = CGRect(x: 455, y: 6, width: 530, height: 64)

    static func run(outDir: String) {
        // fixed settings for the run only (argument domain: never written to disk)
        UserDefaults.standard.setVolatileDomain(["snowOn": true, "intensity": 1, "snowmenOn": true, "autoPlow": false, "flakesOnTop": false, "windOn": true, "windStrength": 1, "meltOn": true, "meltSpeed": 1, "batteryMode": 2, "shakeOn": true, "shakeStrength": ShakeStrength.normal.rawValue],
                                                forName: UserDefaults.argumentDomain)
        S = 1.15
        dockRect = CGRect(x: 455, y: 6, width: 530, height: 64)
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
        engine.dockSource = { _ in
            let inset = max(18, min(28, dockRect.height * 0.28))
            return (dockRect.minX + inset, dockRect.maxX - inset, dockRect.maxY)
        }
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
        if let dock = engine.surfaces[Engine.dockKey(0)], let pile = engine.piles[dock.key],
           let gp = engine.pilePath(dock, pile) {
            let box = gp.boundingBoxOfPath
            precondition(dock.minX >= dockRect.minX + 18 && dock.maxX <= dockRect.maxX - 18)
            precondition(box.minX >= dock.minX - 0.5 && box.maxX <= dock.maxX + 0.5 && box.minY >= dock.top - 2.0)
        }
        if let win = engine.surfaces[1], let pile = engine.piles[1],
           let gp = engine.pilePath(win, pile) {
            precondition(gp.boundingBoxOfPath.minY < win.top - 6)
        }
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
        var poofShot = false
        step(30 * 2, record: true) { _ in
            if !poofShot, !engine.spills.isEmpty { poofShot = true; step(3, record: true); still("still-7-poof") }
        }
        // 6) resize narrower: Finder's exposed right edge spills onto the Dock below.
        let fi = fake.index(1)
        let originalWidth = fake.list[fi].frame.width
        engine.piles[1]?.fill()
        // Leave room in the receiving pile so the landed clumps visibly add snow.
        if let dock = engine.surfaces[Engine.dockKey(0)], let pile = engine.piles[dock.key] {
            _ = pile.take(from: 500 - dock.minX, to: 690 - dock.minX, fraction: 0.65)
        }
        engine.mouseIsDown = true          // a mouse resize (non-mouse size changes keep the snow)
        step(30, record: true) { i in
            fake.list[fi].frame.size.width = originalWidth - 250 * CGFloat(i + 1) / 30
            engine.refreshGeometry()
            if i == 18 { still("still-5-spill") }
        }
        engine.mouseIsDown = false
        step(30, record: true)       // clumps reach the Dock
        // 7) Dock width change: remove two icons, keeping the Dock centered.
        let oldDock = dockRect
        step(18, record: true) { i in
            let inset = 60 * CGFloat(i + 1) / 18
            dockRect = oldDock.insetBy(dx: inset, dy: 0)
            engine.refreshGeometry()
        }
        step(12, record: true)
        // 8) snowplow pushes the Dock snow into a mound
        engine.piles[Engine.dockKey(0)]?.fill()
        engine.startPlow()
        var shot = false
        step(30 * 7, record: true) { _ in
            if !shot, let p = engine.plows.first, p.x > dockRect.midX + 40 { still("still-4-plow"); shot = true }
        }
        // 9) pick up a loose ball and stack it on the larger one (real mouse handlers).
        if let s = engine.surfaces[2] {
            let base = Prop(kind: .ball, scale: 7 * S)
            let small = Prop(kind: .ball, scale: 5 * S)
            let x = s.minX + s.width * 0.35
            engine.addProp(base, on: s.key, atX: x, fromY: s.top + 30)
            engine.addProp(small, on: s.key, atX: x + 120, fromY: s.top + 30)
            step(20, record: true)
            let start = CGPoint(x: small.pos.x, y: small.pos.y + small.scale)
            let end = CGPoint(x: base.pos.x, y: base.pos.y + base.scale)
            engine.mouseDown(at: start)
            step(30, record: true) { i in
                let k = CGFloat(i + 1) / 30
                engine.mouseDragged(to: CGPoint(x: start.x + (end.x - start.x) * k,
                                                y: start.y + (end.y - start.y) * k + 65 * sin(.pi * k)))
                if i == 14 { still("still-6-stack") }
            }
            engine.mouseUp(at: end)
            step(15, record: true)
            precondition(!engine.props.contains(where: { $0 === base || $0 === small }) &&
                             engine.props.contains(where: { $0.kind == .snowman && $0.host == s.key }))
            still("still-6-stacked")
        }
        // 10) quick sweeps push falling snow and lift dust off Music's pile.
        if let surf = engine.surfaces[2] {
            engine.piles[2]?.fill(); engine.pileDirty = true
            step(30, record: true) { i in
                if i % 3 == 0 {
                    let x = 40 + CGFloat(i) * 45
                    engine.windGust(at: CGPoint(x: x, y: 490), velocity: CGPoint(x: 2600, y: 0))
                }
            }
            step(9, record: true) { i in
                if i % 3 == 0 {
                    engine.windGust(at: CGPoint(x: surf.minX + 100 + CGFloat(i) * 15, y: surf.top + 8),
                                    velocity: CGPoint(x: 3000, y: 0))
                }
            }
            still("still-8-wind")
            still("wind-dust-zoom", scale: 3, crop: CGRect(x: surf.minX + 40, y: surf.top - 20, width: 320, height: 90))
            print("wind gusts=\(engine.windGusts) pushed=\(engine.windPushed) dust=\(engine.windDust)")
            // 11) ten simulated minutes lower the pile and feed the hanging icicles.
            var settings = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            settings["meltSpeed"] = 0
            UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
            engine.piles[2]?.fill()
            engine.piles[2]?.created = .distantPast
            let before = engine.piles[2]?.mean ?? 0
            var sawDrip = false
            step(30, record: true) { _ in
                engine.meltStep(seconds: 20)
                if engine.waterDrops.contains(where: { $0.kind == .drop }) { sawDrip = true }
            }
            precondition(sawDrip, "melting should produce dripping water drops")
            still("still-9-icicles")
            still("icicles-zoom", scale: 3, crop: CGRect(x: surf.minX + 10, y: surf.top - 30, width: 380, height: 70))
            let ic = engine.piles[2]?.icicles.map(\.length).filter { $0 > 0 } ?? []
            print("melt mean \(before) -> \(engine.piles[2]?.mean ?? 0), icicles n=\(ic.count) max=\(ic.max() ?? 0)")
            if let pile = engine.piles[2] {
                let targets = pile.icicles.indices.filter {
                    pile.icicles[$0].length >= 4 * S &&
                    pile.icicles[$0].x < surf.width - 12 * S &&
                    engine.isVisible(surf.key, surf.minX + pile.icicles[$0].x)
                }
                precondition(targets.count >= 2, "expected at least 2 visible icicles to test click and swipe")
                // Clicking an icicle snaps it and spawns an .iceShard without spawning a snowman.
                let idx1 = targets[0], site1 = pile.icicles[idx1]
                let half1 = min(2.2 * S, site1.length * 0.18) * site1.girth
                let clickPt = CGPoint(x: surf.minX + site1.x + half1 * site1.lean * 0.5, y: surf.top - site1.length * 0.5)
                let shardsBeforeClick = engine.waterDrops.filter { $0.kind == .iceShard }.count
                let propsBeforeClick = engine.props.count
                engine.mouseDown(at: clickPt)
                engine.mouseUp(at: clickPt)
                precondition(pile.icicles[idx1].length == 0, "clicking an icicle should snap it (length == 0)")
                precondition(engine.waterDrops.filter { $0.kind == .iceShard }.count == shardsBeforeClick + 1, "clicking an icicle should spawn an .iceShard")
                precondition(engine.props.count == propsBeforeClick, "clicking an icicle should not spawn a snowman")
                // Swiping quickly across a visible icicle snaps it.
                let idx2 = targets[1], site2 = pile.icicles[idx2]
                let gx2 = surf.minX + site2.x, y2 = surf.top - site2.length * 0.5
                let shardsBeforeSwipe = engine.waterDrops.filter { $0.kind == .iceShard }.count
                engine.mouseWind(at: CGPoint(x: gx2 - 25 * S, y: y2))
                step(1)
                engine.mouseWind(at: CGPoint(x: gx2 + 25 * S, y: y2))
                precondition(pile.icicles[idx2].length == 0, "swiping across an icicle should snap it (length == 0)")
                precondition(engine.waterDrops.filter { $0.kind == .iceShard }.count >= shardsBeforeSwipe + 1, "swiping an icicle should spawn an .iceShard")
                step(15, record: true)
                print("icicle interact: click snapped idx=\(idx1), swipe snapped idx=\(idx2), waterDrops=\(engine.waterDrops.count)")
            }
        }
        // 12) grab Music by its title bar and shake it: the snow and its snowman fly off.
        let mi = fake.index(2)
        if let surf = engine.surfaces[2] {
            engine.piles[2]?.fill(); engine.pileDirty = true
            engine.spawnSnowman(onSurface: surf.key, atX: surf.minX + surf.width * 0.6, fromY: surf.top + 30 * S)
            step(30, record: true)
            let before = engine.piles[2]?.mean ?? 0
            let origin = fake.list[mi].frame.origin
            let grab = CGPoint(x: surf.minX + 200, y: surf.top - 12)
            engine.mouseDown(at: grab)
            var shook = false
            step(30 * 2, record: true) { i in
                let tt = CGFloat(i + 1) / 30
                let dx = 70 * sin(2 * .pi * 2.6 * tt) * min(1, tt * 3)
                fake.list[mi].frame.origin = CGPoint(x: origin.x + dx, y: origin.y)
                engine.mouseDragged(to: CGPoint(x: grab.x + dx, y: grab.y))
                if !shook, (engine.piles[2]?.mean ?? 0) < before * 0.6 { shook = true; still("still-10-shake") }
            }
            fake.list[mi].frame.origin = origin
            engine.mouseUp(at: grab)
            step(30 * 2, record: true)
            print("shake mean \(before) -> \(engine.piles[2]?.mean ?? 0), props on Music: \(engine.props.filter { $0.host == 2 }.count)")
        }
        // Clicking a visible snowman removes it and starts a puff at its position.
        if let surf = engine.surfaces[2] {
            engine.spawnSnowman(onSurface: surf.key, atX: surf.minX + surf.width * 0.8, fromY: surf.top + 30 * S)
            if let snowman = engine.props.last {
                step(30)
                let click = CGPoint(x: snowman.pos.x, y: snowman.pos.y + snowman.height * 0.35)
                let before = engine.spills.count
                engine.mouseDown(at: click)
                engine.mouseUp(at: click)
                precondition(!engine.props.contains { $0 === snowman } && engine.spills.count == before + 26)
                print("snowman click: removed, 26 puff particles")
            }
            // Render all 4 snowman hat styles side by side to verify accessory variants.
            let styles: [SnowmanStyle] = [
                SnowmanStyle(hat: .santa, scarf: .red),
                SnowmanStyle(hat: .beanie, scarf: .pine),
                SnowmanStyle(hat: .bucket, scarf: .cobalt),
                SnowmanStyle(hat: .tophat, scarf: .gold),
            ]
            for (idx, style) in styles.enumerated() {
                let m = Prop(kind: .snowman, scale: S, withBalls: idx == 0, style: style)
                m.grounded = true
                engine.addProp(m, on: surf.key, atX: surf.minX + 60 + CGFloat(idx) * 70, fromY: surf.top)
            }
            step(10)
            still("snowmen-styles-zoom", scale: 2, crop: CGRect(x: surf.minX + 20, y: surf.top - 10, width: 320, height: 90))
            print("snowman styles: \(styles.count) hat variants rendered")

            // 13) throw a snowball fast at a snowman: parabolic arc, hit removes snowman + puff.
            step(25)
            let target = Prop(kind: .snowman, scale: S, withBalls: false)
            target.grounded = true
            engine.addProp(target, on: surf.key, atX: surf.minX + 500, fromY: surf.top)
            let ammo = Prop(kind: .ball, scale: 6 * S)
            ammo.grounded = true
            engine.addProp(ammo, on: surf.key, atX: surf.minX + 340, fromY: surf.top)
            step(5)
            let throwStart = CGPoint(x: ammo.pos.x, y: ammo.pos.y + ammo.scale)
            let throwRelease = CGPoint(x: throwStart.x + 90, y: throwStart.y + 35)
            engine.mouseDown(at: throwStart)
            step(5) { i in
                let k = CGFloat(i + 1) / 5
                engine.mouseDragged(to: CGPoint(x: throwStart.x + (throwRelease.x - throwStart.x) * k,
                                                y: throwStart.y + (throwRelease.y - throwStart.y) * k))
            }
            engine.mouseUp(at: throwRelease)
            engine.forceFast = false
            precondition(ammo.thrown && !ammo.grounded && engine.desiredInterval() == 1.0 / 30)
            engine.forceFast = true
            var hitVerified = false
            for i in 0..<25 {
                let spillsBefore = engine.spills.count
                step(1)
                if i == 1 { still("still-11-throw") }
                if !hitVerified && !engine.props.contains(where: { $0 === target }) {
                    precondition(!engine.props.contains(where: { $0 === ammo }))
                    precondition(engine.spills.count >= spillsBefore + 38)
                    hitVerified = true
                    still("still-11-throw-hit")
                }
            }
            precondition(hitVerified)
            print("snowball throw: hit snowman, removed with puff particles")
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
        var cols = [rgb(0.30, 0.60, 0.98), rgb(0.98, 0.35, 0.40), rgb(1.0, 0.80, 0.25), rgb(0.35, 0.80, 0.45),
                    rgb(0.60, 0.45, 0.95), rgb(0.98, 0.55, 0.25), rgb(0.25, 0.75, 0.85), rgb(0.85, 0.85, 0.88)]
        if d.width < 470 { cols.removeSubrange(5...6) }
        let last = cols.count - 1
        for (i, col) in cols.enumerated() {
            let x = d.minX + 14 + CGFloat(i) * 60 + (i == last ? 22 : 0)
            let r = CGRect(x: x, y: d.minY + 8, width: 48, height: 48)
            c.addPath(CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil)); c.setFillColor(col); c.fillPath()
            c.setFillColor(rgb(1, 1, 1, 0.85)); c.fillEllipse(in: r.insetBy(dx: 15, dy: 15))
        }
        c.setFillColor(rgb(1, 1, 1, 0.5)); c.fill(CGRect(x: d.minX + 14 + CGFloat(last) * 60 + 2, y: d.minY + 12, width: 1, height: 40))
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
