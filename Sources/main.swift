// MacSnow — menu bar snow that lands and piles up on window tops and the Dock.
import AppKit
import QuartzCore
import ApplicationServices
import IOKit.ps
import ServiceManagement

/// Size scale so things read like the reel on large displays (1.0 on a ~900pt-tall screen).
var S: CGFloat = {
    let h = NSScreen.screens.first?.frame.height ?? 900
    return max(1, min(1.8, h / 900))
}()

// MARK: - Settings

enum Intensity: Int, CaseIterable {
    case light = 0, normal, heavy, blizzard
    var title: String { ["가랑눈 (Flurries)", "보통 (Normal)", "많이 (Heavy)", "폭설 (Blizzard)"][rawValue] }
    /// flakes per second per 100pt of screen width
    var flakeRate: CGFloat { [0.5, 1.4, 2.8, 5.0][rawValue] }
}

enum BatteryMode: Int, CaseIterable {
    case auto = 0, always, off
    var title: String { ["자동 (Auto)", "항상 (Always)", "끄기 (Off)"][rawValue] }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    init() { d.register(defaults: ["snowOn": true, "intensity": 1, "snowmenOn": true, "autoPlow": true, "flakesOnTop": false, "windOn": true, "windStrength": 1, "meltOn": true, "meltSpeed": 1, "batteryMode": 0]) }
    var windOn: Bool { get { d.bool(forKey: "windOn") } set { d.set(newValue, forKey: "windOn") } }
    var windStrength: Int { get { max(0, min(2, d.integer(forKey: "windStrength"))) } set { d.set(newValue, forKey: "windStrength") } }
    var meltOn: Bool { get { d.bool(forKey: "meltOn") } set { d.set(newValue, forKey: "meltOn") } }
    var meltSpeed: Int { get { max(0, min(2, d.integer(forKey: "meltSpeed"))) } set { d.set(newValue, forKey: "meltSpeed") } }
    var batteryMode: BatteryMode {
        get { BatteryMode(rawValue: d.integer(forKey: "batteryMode")) ?? .auto }
        set { d.set(newValue.rawValue, forKey: "batteryMode") }
    }
    var snowOn: Bool { get { d.bool(forKey: "snowOn") } set { d.set(newValue, forKey: "snowOn") } }
    var snowmenOn: Bool { get { d.bool(forKey: "snowmenOn") } set { d.set(newValue, forKey: "snowmenOn") } }
    var autoPlow: Bool { get { d.bool(forKey: "autoPlow") } set { d.set(newValue, forKey: "autoPlow") } }
    /// false (default): falling flakes are drawn behind app windows, on the desktop only
    var flakesOnTop: Bool { get { d.bool(forKey: "flakesOnTop") } set { d.set(newValue, forKey: "flakesOnTop") } }
    var intensity: Intensity {
        get { Intensity(rawValue: d.integer(forKey: "intensity")) ?? .normal }
        set { d.set(newValue.rawValue, forKey: "intensity") }
    }
}

// MARK: - Window list

struct Win {
    let id: CGWindowID
    let frame: CGRect      // AppKit global coordinates (y up)
    let z: Int             // 0 = frontmost
    let surface: Bool      // normal window (layer 0): snow lands on it; floating ones only hide snow
}

/// Where window rectangles come from: the real window server, or a scripted fake (showcase).
protocol WindowProvider {
    func fetch() -> [Win]                 // front-to-back
    func frame(of id: CGWindowID) -> CGRect?
    func exists(_ id: CGWindowID) -> Bool
}
extension WindowProvider {
    /// The window still exists (maybe on another Space, minimized or hidden), i.e. it wasn't closed.
    func exists(_ id: CGWindowID) -> Bool { frame(of: id) != nil }
}

struct SystemWindows: WindowProvider {
    func fetch() -> [Win] { WindowList.fetch() }
    /// Minimized windows and windows on other Spaces only show up in the full list (not in a
    /// single-window query), so look there. Called rarely (missing windows, ≤ every 2 s each).
    func exists(_ id: CGWindowID) -> Bool {
        let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return all.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }
    func frame(of id: CGWindowID) -> CGRect? {
        guard let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let b = raw.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let h = b["Height"] ?? 0
        return CGRect(x: b["X"] ?? 0, y: primaryH - (b["Y"] ?? 0) - h, width: b["Width"] ?? 0, height: h)
    }
}

/// Debug (lag test): the real list, except windows whose frame a simulated drag reported.
/// Lets the drag-lag test run even when the window server's list is unreliable (e.g. screen locked).
final class SimOverride: WindowProvider {
    var frames: [CGWindowID: CGRect] = [:]
    func fetch() -> [Win] {
        WindowList.fetch().map { w in frames[w.id].map { Win(id: w.id, frame: $0, z: w.z, surface: w.surface) } ?? w }
    }
    func frame(of id: CGWindowID) -> CGRect? { frames[id] ?? SystemWindows().frame(of: id) }
    func exists(_ id: CGWindowID) -> Bool { frames[id] != nil || SystemWindows().exists(id) }
}

enum WindowList {
    static func fetch() -> [Win] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [Win] = []
        let screenArea = NSScreen.screens.map { $0.frame.width * $0.frame.height }.max() ?? 1
        for info in raw {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer >= 0, layer < 20,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let a = info[kCGWindowAlpha as String] as? CGFloat, a < 0.1 { continue }
            let w = b["Width"] ?? 0, h = b["Height"] ?? 0
            guard w >= 80, h >= 50 else { continue }
            let x = b["X"] ?? 0, y = b["Y"] ?? 0
            if layer > 0 && w * h > screenArea * 0.8 { continue }   // full-screen helper overlays
            out.append(Win(id: id, frame: CGRect(x: x, y: primaryH - y - h, width: w, height: h), z: out.count, surface: layer == 0))
        }
        return out
    }
}

// MARK: - Dock geometry (Accessibility frame, with a preferences-based fallback)

enum DockGeometry {
    /// AX includes a little padding above the visible background.
    /// Measured y=1346, h=84 on a 1440pt screen -> AppKit maxY=94, snow top=90.
    static let topInset: CGFloat = 4
    private static var cache: [ObjectIdentifier: ((CGFloat, CGFloat, CGFloat)?, CFTimeInterval)] = [:]
    private static var axFrame: CGRect?
    static var debugAXFrame: CGRect? { axFrame }
    private static var lastAXCheck: CFTimeInterval = -.infinity
    static func invalidate() { cache.removeAll(); lastAXCheck = -.infinity }
    /// (minX, maxX, topY) in global coords for a screen whose Dock sits at the bottom.
    static func span(for screen: NSScreen) -> (CGFloat, CGFloat, CGFloat)? {
        let now = CACurrentMediaTime()
        if now - lastAXCheck >= 2 {
            lastAXCheck = now
            let measured = AXIsProcessTrusted() ? accessibilityFrame() : nil
            if measured != axFrame { axFrame = measured; cache.removeAll() }
        }
        let key = ObjectIdentifier(screen)
        if let c = cache[key], now - c.1 < 30 { return c.0 }
        let v = compute(screen)
        cache[key] = (v, now)
        return v
    }

    private static func accessibilityFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        var best: CGRect?, bestIsList = false
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for child in children {
            var role: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size) == .success,
                  let p = position, let s = size,
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { continue }
            var point = CGPoint.zero, extent = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
                  AXValueGetValue(s as! AXValue, .cgSize, &extent),
                  point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
                  extent.width > 0, extent.height > 0 else { continue }
            let frame = CGRect(x: point.x, y: primaryH - point.y - extent.height, width: extent.width, height: extent.height)
            let isList = (role as? String) == (kAXListRole as String)
            if best == nil || (isList && !bestIsList) || (isList == bestIsList && frame.width * frame.height > best!.width * best!.height) {
                best = frame; bestIsList = isList
            }
        }
        return best
    }

    private static func compute(_ screen: NSScreen) -> (CGFloat, CGFloat, CGFloat)? {
        let f = screen.frame, v = screen.visibleFrame
        let dock = UserDefaults(suiteName: "com.apple.dock")
        guard !(dock?.bool(forKey: "autohide") ?? false),
              (dock?.string(forKey: "orientation") ?? "bottom") == "bottom" else { return nil }
        if let ax = axFrame {
            guard f.contains(CGPoint(x: ax.midX, y: ax.midY)) else { return nil }
            return (ax.minX, ax.maxX, ax.maxY - topInset)
        }
        guard v.minY - f.minY > 20 else { return nil }          // hidden or on the side
        let ts = CGFloat(dock?.double(forKey: "tilesize") ?? 0)
        let tile = ts > 0 ? ts : 48
        let apps = (dock?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        var ids = Set<String>()
        for a in apps {
            guard let td = a["tile-data"] as? [String: Any] else { continue }
            if let b = td["bundle-identifier"] as? String { ids.insert(b.lowercased()) }
            // Some persistent tiles only have a file URL, with no bundle identifier.
            if let data = td["file-data"] as? [String: Any], let path = data["_CFURLString"] as? String,
               let url = URL(string: path), let b = Bundle(url: url)?.bundleIdentifier { ids.insert(b.lowercased()) }
        }
        var extra = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let b = app.bundleIdentifier?.lowercased() ?? app.bundleURL?.absoluteString ?? String(app.processIdentifier)
            if b != "com.apple.finder", !ids.contains(b) { extra.insert(b) }
        }
        let others = ((dock?.array(forKey: "persistent-others")) ?? []).count
        let showRecents = dock?.object(forKey: "show-recents") as? Bool ?? true
        let icons = 1 + apps.count + extra.count + others + 1 + (showRecents ? 3 : 0)
        let seps = 1 + (showRecents ? 1 : 0)
        // each icon slot is a bit wider than tilesize (calibrated on one Mac against the AX frame:
        // 32 icons, tile 64 -> 2290 pt)
        var width = CGFloat(icons) * tile * 1.1 + CGFloat(seps) * tile * 0.3 + tile * 0.35
        width = min(width, f.width - 8)
        return (f.midX - width / 2, f.midX + width / 2, v.minY)     // AX: list maxY - topInset == visibleFrame.minY
    }
}

// MARK: - Snow pile height map

final class Pile {
    static let step: CGFloat = 3
    static let maxH: CGFloat = 13 * S
    static let kernel: [CGFloat] = (-5...5).map { exp(-CGFloat($0 * $0) / 8) }
    var dirty = true
    var heights: [CGFloat] = []
    var caps: [CGFloat] = []
    var lastSeen = Date()
    var created = Date()
    var icicles: [CGFloat] = []
    var icicleDirty = true
    private let ph1 = CGFloat.random(in: 0...6.28), ph2 = CGFloat.random(in: 0...6.28)
    /// soft rounded lumps rather than a flat slab
    private func cap(_ i: Int) -> CGFloat {
        let x = CGFloat(i)
        return Pile.maxH * (0.8 + 0.1 * sin(x * 0.17 + ph1) + 0.07 * sin(x * 0.47 + ph2) + CGFloat.random(in: -0.02...0.03))
    }

    /// Re-bin by global x, splitting partial samples so even sub-step resizes conserve area.
    /// A plain window move keeps local snow; Dock moves and window width changes keep global x.
    func resize(from old: Surface?, to surf: Surface) -> [(x: CGFloat, y: CGFloat, area: CGFloat)] {
        let n = max(2, Int(surf.width / Pile.step) + 1)
        guard let old else {
            // a window coming back (other Space, un-minimized) at another width: stretch, don't truncate
            if heights.count >= 2 && heights.count != n { rescale(to: surf.width); return [] }
            // new surface, or one coming back after a brief absence from the window list: keep what's there
            if heights.count > n { heights.removeLast(heights.count - n); caps.removeLast(caps.count - n) }
            while heights.count < n { heights.append(0); caps.append(cap(heights.count - 1)) }
            dirty = true
            return []
        }
        guard abs(old.width - surf.width) > 0.001 || (surf.z < 0 && abs(old.minX - surf.minX) > 0.001) else { return [] }
        var next = Array(repeating: CGFloat(0), count: n)
        var limits = (0..<n).map { cap($0) }
        var removed: [(x: CGFloat, y: CGFloat, area: CGFloat)] = []
        for i in heights.indices {
            let a = old.minX + CGFloat(i) * Pile.step
            let b = min(old.maxX, a + Pile.step)
            guard b > a else { continue }
            func spill(_ lo: CGFloat, _ hi: CGFloat) {
                if hi > lo && heights[i] > 0 {
                    removed.append((x: (lo + hi) / 2, y: old.top + heights[i] / 2, area: heights[i] * (hi - lo)))
                }
            }
            spill(a, min(b, surf.minX))
            spill(max(a, surf.maxX), b)
            let lo = max(a, surf.minX), hi = min(b, surf.maxX)
            guard hi > lo else { continue }
            let first = max(0, Int((lo - surf.minX) / Pile.step))
            let last = min(n - 1, Int((hi - surf.minX) / Pile.step))
            for j in first...last {
                let left = surf.minX + CGFloat(j) * Pile.step
                let right = min(surf.maxX, left + Pile.step)
                let overlap = min(hi, right) - max(lo, left)
                if overlap > 0 && right > left {
                    next[j] += heights[i] * overlap / (right - left)
                    limits[j] = max(limits[j], caps[i])
                }
            }
        }
        heights = next; caps = limits; dirty = true
        return removed
    }
    /// add `area` pt² of snow around local x
    func deposit(at x: CGFloat, area: CGFloat) {
        let c = Int(x / Pile.step)
        let amount = area / (4.99 * Pile.step)
        for k in -5...5 {
            let i = c + k
            guard i >= 0, i < heights.count else { continue }
            heights[i] = min(caps[i], heights[i] + amount * Pile.kernel[k + 5])
        }
        dirty = true
    }
    func fill() { for i in heights.indices { heights[i] = caps[i] * CGFloat.random(in: 0.92...1) }; dirty = true }
    /// Stretch/squeeze the profile to a new width without losing snow (scaled or programmatic resizes).
    func rescale(to width: CGFloat) {
        let n = max(2, Int(width / Pile.step) + 1), m = heights.count
        guard m > 1, n != m else { return }
        func lerp(_ a: [CGFloat], _ i: Int) -> CGFloat {
            let x = CGFloat(i) * CGFloat(m - 1) / CGFloat(n - 1), j = min(m - 2, Int(x)), t = x - CGFloat(j)
            return a[j] * (1 - t) + a[j + 1] * t
        }
        heights = (0..<n).map { lerp(heights, $0) }
        caps = (0..<n).map { lerp(caps, $0) }
        dirty = true
    }

    func relax() {
        guard heights.count > 2 else { return }
        var h = heights
        for i in 1..<(h.count - 1) { h[i] += ((heights[i - 1] + heights[i + 1]) / 2 - heights[i]) * 0.15 }
        heights = h
        dirty = true
    }
    func height(at x: CGFloat) -> CGFloat {
        let i = Int(x / Pile.step)
        guard i >= 0, i < heights.count else { return 0 }
        return heights[i]
    }
    func index(_ x: CGFloat) -> Int { Int(x / Pile.step) }
    /// remove a fraction of the snow between two local x's; returns removed area (pt²)
    func take(from x0: CGFloat, to x1: CGFloat, fraction: CGFloat) -> CGFloat {
        let a = max(0, index(min(x0, x1))), b = min(heights.count - 1, index(max(x0, x1)))
        guard a <= b else { return 0 }
        var got: CGFloat = 0
        for i in a...b { let t = heights[i] * fraction; heights[i] -= t; got += t * Pile.step }
        dirty = true
        return got
    }
    var mean: CGFloat { heights.isEmpty ? 0 : heights.reduce(0, +) / CGFloat(heights.count) }
}

struct Surface: Equatable {
    let key: UInt64
    let minX: CGFloat, maxX: CGFloat, top: CGFloat
    let z: Int           // window z, or -1 for the Dock (above all windows)
    var width: CGFloat { maxX - minX }
}

// MARK: - Drawing helpers

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }

func shape(_ p: CGPath, fill: NSColor, stroke: NSColor? = nil, lw: CGFloat = 0) -> CAShapeLayer {
    let l = CAShapeLayer()
    l.path = p; l.fillColor = fill.cgColor
    l.strokeColor = stroke?.cgColor; l.lineWidth = lw
    l.lineCap = .round
    l.contentsScale = 2
    return l
}

let snowEdge = NSColor(calibratedRed: 0.74, green: 0.81, blue: 0.92, alpha: 1)
let santaRed = NSColor(calibratedRed: 0.86, green: 0.1, blue: 0.12, alpha: 1)

/// Snowman with Santa hat and scarf, drawn at unit scale (base radius 9). Anchor = bottom centre.
func makeSnowmanLayer() -> CALayer {
    let root = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: 40, height: 52)
    root.anchorPoint = CGPoint(x: 0.5, y: 0)
    let stick = NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.14, alpha: 1)
    let arms = CGMutablePath()
    arms.move(to: CGPoint(x: 13, y: 22)); arms.addLine(to: CGPoint(x: 4, y: 28))
    arms.move(to: CGPoint(x: 6.5, y: 26.5)); arms.addLine(to: CGPoint(x: 4, y: 25))
    arms.move(to: CGPoint(x: 27, y: 22)); arms.addLine(to: CGPoint(x: 36, y: 28))
    arms.move(to: CGPoint(x: 33.5, y: 26.5)); arms.addLine(to: CGPoint(x: 36, y: 25))
    root.addSublayer(shape(arms, fill: .clear, stroke: stick, lw: 1.4))
    root.addSublayer(shape(circle(CGPoint(x: 20, y: 9), 9), fill: .white, stroke: snowEdge, lw: 0.8))
    root.addSublayer(shape(circle(CGPoint(x: 20, y: 22.5), 7), fill: .white, stroke: snowEdge, lw: 0.8))
    root.addSublayer(shape(circle(CGPoint(x: 20, y: 33.5), 5.6), fill: .white, stroke: snowEdge, lw: 0.8))
    for y in [20.0, 24.0] { root.addSublayer(shape(circle(CGPoint(x: 20, y: y), 0.9), fill: .black)) }
    let scarf = CGMutablePath()
    scarf.addRoundedRect(in: CGRect(x: 14, y: 27, width: 12, height: 3), cornerWidth: 1.4, cornerHeight: 1.4)
    scarf.addRoundedRect(in: CGRect(x: 22, y: 19.5, width: 3, height: 9), cornerWidth: 1.2, cornerHeight: 1.2)
    root.addSublayer(shape(scarf, fill: santaRed))
    root.addSublayer(shape(circle(CGPoint(x: 18, y: 35), 0.8), fill: .black))
    root.addSublayer(shape(circle(CGPoint(x: 22, y: 35), 0.8), fill: .black))
    let nose = CGMutablePath()
    nose.move(to: CGPoint(x: 20, y: 33.7)); nose.addLine(to: CGPoint(x: 25, y: 32.6)); nose.addLine(to: CGPoint(x: 20, y: 32.4)); nose.closeSubpath()
    root.addSublayer(shape(nose, fill: NSColor(calibratedRed: 1, green: 0.5, blue: 0.1, alpha: 1)))
    let hat = CGMutablePath()
    hat.move(to: CGPoint(x: 15, y: 38)); hat.addQuadCurve(to: CGPoint(x: 27, y: 46), control: CGPoint(x: 19, y: 48))
    hat.addQuadCurve(to: CGPoint(x: 25, y: 38), control: CGPoint(x: 24, y: 42)); hat.closeSubpath()
    root.addSublayer(shape(hat, fill: santaRed))
    let brim = CGMutablePath(); brim.addRoundedRect(in: CGRect(x: 14, y: 36.6, width: 12, height: 3), cornerWidth: 1.5, cornerHeight: 1.5)
    root.addSublayer(shape(brim, fill: .white, stroke: snowEdge, lw: 0.5))
    root.addSublayer(shape(circle(CGPoint(x: 27.2, y: 45.6), 1.9), fill: .white, stroke: snowEdge, lw: 0.5))
    root.shadowColor = NSColor(calibratedRed: 0.2, green: 0.25, blue: 0.4, alpha: 1).cgColor
    root.shadowOpacity = 0.35; root.shadowRadius = 1.5; root.shadowOffset = CGSize(width: 0, height: -1)
    return root
}

func makeSnowballsLayer() -> CALayer {
    let root = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: 26, height: 12)
    root.anchorPoint = CGPoint(x: 0, y: 0)
    root.addSublayer(shape(circle(CGPoint(x: 6, y: 5), 5), fill: .white, stroke: snowEdge, lw: 0.7))
    root.addSublayer(shape(circle(CGPoint(x: 18, y: 6), 6), fill: .white, stroke: snowEdge, lw: 0.7))
    return root
}

/// One snowball drawn at radius 20 (scale it), anchor = centre; speckles make rolling visible.
func makeBallLayer() -> CALayer {
    let root = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
    root.addSublayer(shape(circle(CGPoint(x: 20, y: 20), 19.5), fill: .white, stroke: snowEdge, lw: 1.2))
    let dots = CGMutablePath()
    for (x, y, r) in [(12.0, 26.0, 1.6), (27.0, 13.0, 1.4), (24.0, 28.0, 1.1), (14.0, 12.0, 1.0), (30.0, 22.0, 0.9)] {
        dots.addPath(circle(CGPoint(x: x, y: y), r))
    }
    root.addSublayer(shape(dots, fill: NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.9, alpha: 1)))
    let arc = CGMutablePath(); arc.addArc(center: CGPoint(x: 20, y: 20), radius: 13, startAngle: 2.2, endAngle: 3.4, clockwise: false)
    root.addSublayer(shape(arc, fill: .clear, stroke: NSColor(calibratedRed: 0.8, green: 0.86, blue: 0.94, alpha: 1), lw: 1.2))
    root.shadowColor = NSColor(calibratedRed: 0.2, green: 0.25, blue: 0.4, alpha: 1).cgColor
    root.shadowOpacity = 0.3; root.shadowRadius = 1.5; root.shadowOffset = CGSize(width: 0, height: -1)
    return root
}

/// Pixel-art snowplow facing right. Anchor = bottom centre. Returns (layer, blade height).
func makePlowLayer(px: CGFloat) -> (CALayer, CGFloat) {
    let art = [
        "................................",
        "................................",
        "................................",
        "...........YYYYYYYYY............",
        "..........YYBBBBBBBYY...........",
        "......G...YYBLLBBBBYY...........",
        "......K...YYBLBBBBBYY...........",
        "......K...YYBBBBBBBYY.......SSS.",
        "......K...YYBBBBBBBYY.......SSS.",
        "......K...YYYYYYYYYYY......GSS..",
        "....YYYYYYYYYYYYYYYYYYYYY..GSS..",
        "...YYYYYYYYYYYYYYYYYYYYYYY.GSS..",
        "...YYYYYYYYYYYYYYYYYYYYYYGGGSS..",
        "...DDDDDDDDDDDDDDDDDDDDDDGGGSS..",
        "...YYYYYYYYYYYYYYYYYYYYYYY.GSS..",
        "...YDDDDDDDDDDDDDDDDDDDDDY.GSS..",
        "...KKKKKKKKKKKKKKKKKKKKKKK.GSS..",
        "..KKWWWKKWWWKKWWWKKWWWKKKKKGSS..",
        "..KKWGWKKWGWKKWGWKKWGWKKKKKGSS..",
        "..KKWGWKKWGWKKWGWKKWGWKKKKKGSS..",
        "..KKWWWKKWWWKKWWWKKWWWKKKKK.SSS.",
        "...KKKKKKKKKKKKKKKKKKKKKKK..SSS.",
    ]
    let colors: [Character: NSColor] = [
        "Y": NSColor(calibratedRed: 1, green: 0.82, blue: 0.12, alpha: 1),
        "D": NSColor(calibratedRed: 0.88, green: 0.6, blue: 0.05, alpha: 1),
        "B": NSColor(calibratedRed: 0.5, green: 0.78, blue: 0.95, alpha: 1),
        "L": NSColor(calibratedRed: 0.86, green: 0.95, blue: 1, alpha: 1),
        "G": NSColor(calibratedWhite: 0.55, alpha: 1),
        "K": NSColor(calibratedWhite: 0.22, alpha: 1),
        "W": NSColor(calibratedWhite: 0.68, alpha: 1),
        "S": NSColor(calibratedWhite: 0.76, alpha: 1),
    ]
    let cols = art[0].count, rows = art.count
    let img = NSImage(size: NSSize(width: cols, height: rows), flipped: true) { _ in
        for (r, row) in art.enumerated() {
            for (c, ch) in row.enumerated() {
                guard let col = colors[ch] else { continue }
                col.setFill()
                NSRect(x: c, y: r, width: 1, height: 1).fill()
            }
        }
        return true
    }
    let w = CGFloat(cols) * px, h = CGFloat(rows) * px
    let root = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
    root.anchorPoint = CGPoint(x: 0.5, y: 0)
    root.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    root.magnificationFilter = .nearest
    root.contentsGravity = .resize
    // flashing orange beacon on the cab roof (rows 1-2, cols 14-16)
    let light = CALayer()
    light.frame = CGRect(x: 14 * px, y: h - 3 * px, width: 3 * px, height: 2 * px)
    light.backgroundColor = NSColor(calibratedRed: 1, green: 0.45, blue: 0.0, alpha: 1).cgColor
    light.cornerRadius = px * 0.6
    light.shadowColor = light.backgroundColor; light.shadowOpacity = 0.9; light.shadowRadius = 4; light.shadowOffset = .zero
    let blink = CABasicAnimation(keyPath: "opacity")
    blink.fromValue = 1; blink.toValue = 0.15; blink.duration = 0.35
    blink.autoreverses = true; blink.repeatCount = .infinity
    light.add(blink, forKey: "blink")
    root.addSublayer(light)
    return (root, 15 * px)
}

// MARK: - Overlay per screen

final class Overlay {
    let frame: CGRect          // global coordinates of the screen this overlay covers
    let screen: NSScreen?
    let window: NSWindow?          // in front: piles, snowmen, plow (sit on window tops / the Dock)
    let backWindow: NSWindow?      // desktop level: falling flakes, behind every app window
    let root: CALayer
    let backRoot: CALayer
    let piles = CALayer()
    let actors = CALayer()
    let flakeRoot = CALayer()

    /// Offscreen overlay for the showcase renderer: same layers, no window.
    init(virtualFrame: CGRect) {
        frame = virtualFrame; screen = nil; window = nil; backWindow = nil
        root = CALayer(); backRoot = CALayer()
        for r in [root, backRoot] { r.frame = CGRect(origin: .zero, size: virtualFrame.size) }
        for l in [piles, actors] as [CALayer] { l.frame = root.bounds; root.addSublayer(l) }
        flakeRoot.frame = root.bounds
        setFlakesOnTop(Settings.shared.flakesOnTop)
    }

    static func makeWindow(_ screen: NSScreen, level: Int) -> (NSWindow, CALayer) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                  // click-through: every click reaches what's below
        w.level = NSWindow.Level(rawValue: level)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        w.contentView = view
        w.setFrame(screen.frame, display: false)
        return (w, view.layer!)
    }

    init(screen: NSScreen) {
        self.screen = screen
        frame = screen.frame
        // above Dock, below menu bar & menus
        (window, root) = Overlay.makeWindow(screen, level: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // above the wallpaper and desktop icons, below every normal window
        (backWindow, backRoot) = Overlay.makeWindow(screen, level: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for l in [piles, actors] as [CALayer] { l.frame = root.bounds; root.addSublayer(l) }
        flakeRoot.frame = root.bounds
        setFlakesOnTop(Settings.shared.flakesOnTop)
        window?.orderFrontRegardless()
    }

    /// Falling flakes in front of everything (old behaviour) or behind app windows (default).
    func setFlakesOnTop(_ top: Bool) {
        let parent = top ? root : backRoot
        if flakeRoot.superlayer !== parent { flakeRoot.removeFromSuperlayer(); parent.insertSublayer(flakeRoot, at: top ? 2 : 0) }
        if top { backWindow?.orderOut(nil) } else { backWindow?.orderFrontRegardless() }
    }

    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }
}

/// Layers for one surface's snow: a blue-grey underside + white top, clipped by a mask.
final class PileView {
    let container = CALayer()
    let under = CAShapeLayer()
    let top = CAShapeLayer()
    let mask = CAShapeLayer()
    let icicles = CAShapeLayer()
    var width: CGFloat = -1
    var occSig: [CGRect] = []
    var needsPath = true
    init() {
        under.fillColor = NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.9, alpha: 1).cgColor
        under.shadowColor = NSColor(calibratedRed: 0.15, green: 0.22, blue: 0.4, alpha: 1).cgColor
        under.shadowOpacity = 0.45
        under.shadowRadius = 2
        under.shadowOffset = CGSize(width: 0, height: -1.5)
        top.fillColor = NSColor.white.cgColor
        icicles.fillColor = NSColor(calibratedRed: 230 / 255, green: 244 / 255, blue: 1, alpha: 0.9).cgColor
        icicles.strokeColor = NSColor(calibratedRed: 191 / 255, green: 227 / 255, blue: 1, alpha: 0.9).cgColor
        icicles.lineWidth = 0.5
        container.addSublayer(icicles)
        container.addSublayer(under)
        container.addSublayer(top)
    }
}

// MARK: - Actors

/// A falling flake: Core Animation moves it (no per-frame CPU work); we only settle it on arrival.
struct Flake {
    let overlay: Overlay
    let layer: CALayer
    let startAt: CFTimeInterval
    let fromY: CGFloat, toY: CGFloat       // overlay-local
    let arriveAt: CFTimeInterval
    let key: UInt64?          // surface it lands on (nil = falls off the bottom)
    let localX: CGFloat
    let area: CGFloat
}

/// Resize spill: screen-space snow clumps in the front overlay, with gravity and live landings.
struct Spill {
    let layer: CALayer
    var pos: CGPoint
    var vy: CGFloat = 0
    var vx: CGFloat = 0
    let area: CGFloat
    let source: UInt64
    let fromDock: Bool
    var ttl: CGFloat = .infinity       // finite: a fading poof particle
}

/// A snowman or a snowball sitting on a surface.
final class Prop {
    enum Kind { case snowman, ball }
    let kind: Kind
    let layer: CALayer
    let deco: CALayer?
    var scale: CGFloat
    var host: UInt64?
    var localX: CGFloat = 0
    var pos = CGPoint.zero     // global, bottom centre
    var vy: CGFloat = 0
    var grounded = false
    let decoSide: CGFloat = Bool.random() ? 1 : -1
    weak var parent: CALayer?

    init(kind: Kind, scale: CGFloat, withBalls: Bool = false) {
        self.kind = kind; self.scale = scale
        layer = kind == .snowman ? makeSnowmanLayer() : makeBallLayer()
        deco = withBalls ? makeSnowballsLayer() : nil
        let k = kind == .snowman ? scale : scale / 20
        layer.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
        deco?.setAffineTransform(CGAffineTransform(scaleX: S, y: S))
    }
    var height: CGFloat { kind == .snowman ? 50 * scale : 2 * scale }
    var halfWidth: CGFloat { kind == .snowman ? 13 * scale : scale }
    func remove() { layer.removeFromSuperlayer(); deco?.removeFromSuperlayer() }
}

final class Plow {
    let layer: CALayer
    let bladeH: CGFloat
    let mound = CAShapeLayer()
    var screenIndex: Int
    var x: CGFloat
    var lastFront: CGFloat
    var volume: CGFloat = 0
    init(screenIndex: Int, x: CGFloat) {
        (layer, bladeH) = makePlowLayer(px: 1.8 * S)
        self.screenIndex = screenIndex; self.x = x
        lastFront = x + layer.bounds.width / 2
        mound.fillColor = NSColor.white.cgColor
        mound.shadowColor = NSColor(calibratedRed: 0.3, green: 0.4, blue: 0.62, alpha: 1).cgColor
        mound.shadowOpacity = 0.6; mound.shadowRadius = 1.8; mound.shadowOffset = CGSize(width: 0, height: -1)
    }
    var front: CGFloat { x + layer.bounds.width / 2 - 2 * S }
}

/// A snowball being rolled by a mouse drag along a pile.
final class Roll {
    let key: UInt64
    let startMinX: CGFloat, startTop: CGFloat
    var localX: CGFloat
    var r: CGFloat = 3 * S
    var angle: CGFloat = 0
    var shown = false
    let layer = makeBallLayer()
    init(key: UInt64, surface s: Surface, localX: CGFloat) {
        self.key = key; startMinX = s.minX; startTop = s.top; self.localX = localX
    }
}

/// A loose ball picked up by hand; retain the pickup attachment until the gesture ends.
final class Carry {
    let prop: Prop
    let host: UInt64
    let localX: CGFloat
    let pickup: CGPoint
    let down: CGPoint
    let offset: CGSize
    var lastPoint: CGPoint
    var lastTime: CFTimeInterval
    var active = false
    var cancelled = false
    init(prop: Prop, host: UInt64, at p: CGPoint, time: CFTimeInterval) {
        self.prop = prop; self.host = host; localX = prop.localX; pickup = prop.pos
        down = p; offset = CGSize(width: prop.pos.x - p.x, height: prop.pos.y - p.y)
        lastPoint = p; lastTime = time
    }
    func position(at p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.width, y: p.y + offset.height) }
}

// MARK: - Engine

/// Selector target for CADisplayLink (Engine isn't an NSObject).
final class LinkTarget: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}

final class Engine {
    var overlays: [Overlay] = []
    var piles: [UInt64: Pile] = [:]
    var surfaces: [UInt64: Surface] = [:]
    var segments: [UInt64: [(CGFloat, CGFloat)]] = [:]
    var orderedSurfaces: [Surface] = []
    var pileViews: [UInt64: PileView] = [:]
    var wins: [Win] = []
    var flakes: [Flake] = []
    var spills: [Spill] = []
    var props: [Prop] = []
    var plows: [Plow] = []
    var roll: Roll?
    var carry: Carry?
    var timer: Timer?
    var interval: Double = 0
    var paused = false
    var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    var onAC = true
    var powerSource: CFRunLoopSource?
    var lastMelt = CACurrentMediaTime()
    var windMonitor: Any?
    var windPoint: CGPoint?
    var windTime: CFTimeInterval = 0
    var lastGust: CFTimeInterval = -.infinity
    var lastDust: CFTimeInterval = -.infinity
    var gustPending = false
    var windGusts = 0, windDust = 0, windPushed = 0
    var flakePool: [CALayer] = []
    var lastPileDraw: CFTimeInterval = 0
    var windowSource: WindowProvider = SystemWindows()
    /// Dock top edge for an overlay: AX / Dock prefs, or scripted in the showcase.
    var dockSource: (Overlay) -> (CGFloat, CGFloat, CGFloat)? = { o in o.screen.flatMap { DockGeometry.span(for: $0) } }
    /// Showcase drives a virtual clock and moves flakes itself (render(in:) can't see CA animations).
    var virtualNow: CFTimeInterval?
    func clock() -> CFTimeInterval { virtualNow ?? CACurrentMediaTime() }
    var last = CACurrentMediaTime()
    var lastPlow = CACurrentMediaTime()
    var spawnDebt: CGFloat = 0
    var pileDirty = true
    var geometryChanged = true
    var tickCount = 0
    var demoBoost: CGFloat = 1
    var mouseIsDown = false
    var forceFast = false        // debug: behave as if the mouse were held (to measure drag cost)
    var displayLink: AnyObject?  // CADisplayLink (macOS 14+) while the mouse is down

    /// A window being dragged by its title bar. Its snow follows the mouse directly
    /// (frame at mouse-down + mouse delta) instead of waiting for the window list to catch up.
    struct Drag {
        let id: CGWindowID
        let frame0: CGRect
        let p0: CGPoint
        var p: CGPoint
        var confirmed = false            // the window list showed the window really moving
        var bias = CGSize.zero           // persistent offset learned from the window list (e.g. menu bar clamp)
        var pendingDiff: CGSize?
        var pendingAt: CGPoint?          // mouse position when pendingDiff was seen
        func predicted(_ q: CGPoint) -> CGRect {
            var f = frame0.offsetBy(dx: q.x - p0.x + bias.width, dy: q.y - p0.y + bias.height)
            // windows can't go above the menu bar
            if let sc = NSScreen.screens.first(where: { $0.frame.contains(q) }), f.maxY > sc.visibleFrame.maxY {
                f.origin.y = sc.visibleFrame.maxY - f.height
            }
            return f
        }
    }
    var drag: Drag?
    var predictDrag = !ProcessInfo.processInfo.arguments.contains("--legacydrag")   // debug: old behaviour
    /// debug (--laglog <file>): when the dragged window's frame changes in `wins`, log time + origin
    var lagLog: FileHandle? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--laglog"), i + 1 < a.count else { return nil }
        FileManager.default.createFile(atPath: a[i + 1], contents: nil)
        return FileHandle(forWritingAtPath: a[i + 1])
    }()
    var lagLast: CGPoint?
    func lagWrite(_ line: String) { lagLog?.write((line + "\n").data(using: .utf8)!) }

    static let snowmanThreshold: CGFloat = 9 * S     // ball radius that turns into a snowman
    static let maxBall: CGFloat = 16 * S

    // MARK: saved state (snow survives quitting / relaunching / updating the app)

    struct SavedPile: Codable { var key: UInt64; var width: Double; var heights: [Float] }
    struct SavedProp: Codable { var snowman: Bool; var scale: Double; var host: UInt64; var localX: Double; var balls: Bool }
    struct SavedState: Codable { var time: Date; var piles: [SavedPile]; var props: [SavedProp] }
    var lastSave: CFTimeInterval = CACurrentMediaTime()
    static let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacSnow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    func saveState() {
        guard virtualNow == nil else { return }
        lastSave = CACurrentMediaTime()
        var ps: [SavedPile] = []
        for (k, p) in piles where p.mean > 0.05 {
            let w = surfaces[k]?.width ?? CGFloat(p.heights.count - 1) * Pile.step
            ps.append(SavedPile(key: k, width: Double(w), heights: p.heights.map { Float(($0 * 10).rounded() / 10) }))
        }
        let pr = props.compactMap { m -> SavedProp? in
            if let c = carry, c.prop === m { return nil }
            guard let h = m.host, m.grounded else { return nil }
            return SavedProp(snowman: m.kind == .snowman, scale: Double(m.scale), host: h, localX: Double(m.localX), balls: m.deco != nil)
        }
        if let d = try? JSONEncoder().encode(SavedState(time: Date(), piles: ps, props: pr)) {
            try? d.write(to: Engine.stateURL, options: .atomic)
        }
    }

    /// Put back the snow saved by the previous run on windows that are still there (same width).
    func restoreState() {
        guard virtualNow == nil, let d = try? Data(contentsOf: Engine.stateURL),
              let st = try? JSONDecoder().decode(SavedState.self, from: d), Date().timeIntervalSince(st.time) < 30 * 60 else { return }
        for sp in st.piles {
            let dock = sp.key >= Engine.dockKey(0)
            if let surf = surfaces[sp.key] {
                guard abs(surf.width - CGFloat(sp.width)) < (dock ? 40 : 1) else { continue }
            } else if dock || !hostAlive(sp.key) { continue }
            let p = piles[sp.key] ?? Pile()
            _ = p.resize(from: nil, to: surfaces[sp.key] ?? Surface(key: sp.key, minX: 0, maxX: CGFloat(sp.width), top: 0, z: 0))
            for i in 0..<min(p.heights.count, sp.heights.count) { p.heights[i] = CGFloat(sp.heights[i]) }
            p.dirty = true; p.lastSeen = Date(); p.created = .distantPast
            piles[sp.key] = p
        }
        for sp in st.props {
            guard let surf = surfaces[sp.host] else { continue }
            let m = Prop(kind: sp.snowman ? .snowman : .ball, scale: CGFloat(sp.scale), withBalls: sp.balls)
            m.grounded = true
            addProp(m, on: sp.host, atX: surf.minX + CGFloat(sp.localX), fromY: surf.top)
        }
        pileDirty = true; geometryChanged = true
    }

    func start() {
        rebuildOverlays()
        refreshGeometry()
        restoreState()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DockGeometry.invalidate()
            self?.rebuildOverlays()
        }
        installMouseMonitors()
        installPowerObservers()
        updateRate()
        if Engine.shouldSleep() { setPaused(true) }
    }

    /// Tick only as fast as needed: 60 Hz while the mouse is down (drag / rolling),
    /// 30 Hz while something animates on the CPU side, 10 Hz (5 in Low Power) for snowfall,
    /// 4 Hz when only resting snow has to follow windows, 1 Hz otherwise, and nothing while paused.
    func desiredInterval() -> Double? {
        if paused { return nil }
        if mouseIsDown || forceFast { return lowPower ? 1.0 / 30 : 1.0 / 60 }
        if roll != nil || !plows.isEmpty || !spills.isEmpty || props.contains(where: { !$0.grounded }) { return 1.0 / 30 }
        if Settings.shared.snowOn || !flakes.isEmpty { return lowPower ? 1.0 / 4 : 1.0 / 8 }
        if !props.isEmpty || piles.values.contains(where: { $0.mean > 0.05 }) { return 1.0 / 4 }
        return 1.0
    }

    func updateRate() {
        if virtualNow != nil { return }        // showcase steps the engine itself
        let want = desiredInterval()
        if want == nil { timer?.invalidate(); timer = nil; stopLink(); interval = 0; return }
        // mouse down: tick in step with the display (no timer phase drift / tolerance slop)
        if predictDrag, want! <= 1.0 / 60 + 1e-6, #available(macOS 14, *), let sc = NSScreen.main ?? NSScreen.screens.first {
            if displayLink == nil {
                timer?.invalidate(); timer = nil
                let l = sc.displayLink(target: LinkTarget { [weak self] in self?.tick() }, selector: #selector(LinkTarget.fire))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                l.add(to: .main, forMode: .common)
                displayLink = l
                last = CACurrentMediaTime()
            }
            interval = want!
            return
        }
        stopLink()
        if timer != nil && want! == interval { return }
        interval = want!
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        last = CACurrentMediaTime()
    }

    func stopLink() {
        guard let l = displayLink else { return }
        if #available(macOS 14, *) { (l as? CADisplayLink)?.invalidate() }
        displayLink = nil
        if timer == nil { interval = 0 }    // force updateRate to start a timer
    }

    /// Stop all work while displays sleep, the screen is locked or the session is switched out.
    func installPowerObservers() {
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue().updatePower()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source = powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        updatePower()
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in DockGeometry.invalidate() }   // Dock width changes
        }
        for (n, pause) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                           (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.setPaused(pause) }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.dock.prefchanged"), object: nil, queue: .main) { _ in DockGeometry.invalidate() }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setPaused(true) }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setPaused(false) }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updatePower()
        }
    }

    func updatePower() {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            onAC = (type as String) == kIOPMACPowerKey
        }
        switch Settings.shared.batteryMode {
        case .always: lowPower = true
        case .off: lowPower = false
        case .auto: lowPower = !onAC || ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        updateRate()
    }

    let noPause = ProcessInfo.processInfo.arguments.contains("--nopause")   // debug: measure CPU while locked

    var pauseWatch: Timer?

    /// Locked or all displays asleep, read directly (backup in case a wake/unlock notification is missed).
    static func shouldSleep() -> Bool {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    func setPaused(_ p: Bool) {
        guard p != paused, !noPause else { return }
        paused = p
        lastMelt = clock(); windPoint = nil
        pauseWatch?.invalidate(); pauseWatch = nil
        if p {
            // every 2 s while paused: resume if we are actually unlocked and awake
            pauseWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                if !Engine.shouldSleep() { self?.setPaused(false) }
            }
            pauseWatch?.tolerance = 1
        }
        if p { dropAllFlakes() }
        for o in overlays { o.root.speed = p ? 0 : 1 }   // freezes plow beacon etc. on the GPU side too
        updateRate()
    }

    func dropAllFlakes() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for f in flakes { f.layer.removeAllAnimations(); f.layer.removeFromSuperlayer(); flakePool.append(f.layer) }
        for f in spills { f.layer.removeFromSuperlayer(); f.layer.opacity = 1; flakePool.append(f.layer) }
        spills.removeAll()
        CATransaction.commit()
        flakes.removeAll()
    }

    func rebuildOverlays() {
        for o in overlays { o.window?.orderOut(nil); o.backWindow?.orderOut(nil) }
        dropAllFlakes()
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        pileViews.removeAll()
        for p in props { p.remove(); p.parent = nil }
        for p in plows { p.layer.removeFromSuperlayer(); p.mound.removeFromSuperlayer() }
        plows.removeAll()
        pileDirty = true
    }

    func applySettings() {
        updateWindMonitor()
        lastMelt = clock()
        for v in pileViews.values { v.icicles.isHidden = !Settings.shared.meltOn }
        if !Settings.shared.snowmenOn { removeAllProps() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for o in overlays { o.setFlakesOnTop(Settings.shared.flakesOnTop) }
        CATransaction.commit()
    }

    func clearSnow() { piles.removeAll(); dropAllFlakes(); pileDirty = true; geometryChanged = true; removeAllProps() }
    func removeAllProps() {
        carry?.active = false; carry?.cancelled = true
        props.forEach { $0.remove() }; props.removeAll()
    }

    static func dockKey(_ i: Int) -> UInt64 { (1 << 40) + UInt64(i) }

    // MARK: geometry

    /// Full window list (~1 ms on a busy desktop). During a drag we only re-read the dragged
    /// window every frame (refreshDragged) and do the full list ~8 times a second.
    func refreshGeometry() {
        var list = windowSource.fetch()
        // while a title-bar drag is followed by prediction, the list's (older) frame mustn't pull it back
        if let d = drag, d.confirmed, let i = list.firstIndex(where: { $0.id == d.id }),
           let cur = wins.first(where: { $0.id == d.id }) {
            list[i] = Win(id: d.id, frame: cur.frame, z: list[i].z, surface: list[i].surface)
        }
        applyWins(list)
    }

    /// Put the dragged window at `f` and move its snow + snowmen right now (no implicit animation).
    func moveDragged(to f: CGRect) {
        guard let d = drag, let i = wins.firstIndex(where: { $0.id == d.id }), wins[i].frame != f else { return }
        var list = wins
        list[i] = Win(id: d.id, frame: f, z: list[i].z, surface: list[i].surface)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyWins(list)
        redrawPiles(paths: false)
        geometryChanged = false               // positions + masks are done; the tick needn't redo them
        updateProps(dt: 0)
        updateRoll()
        CATransaction.commit()
    }

    /// Compare the prediction with the window list. A difference > 2 pt that stays the same while the
    /// mouse holds still is a real offset (snapping, clamping): adopt it. While moving, the list may
    /// simply be behind, so never chase it then.
    func reconcileDrag() {
        guard var d = drag, d.confirmed, let f = windowSource.frame(of: d.id) else { return }
        let pr = d.predicted(d.p)
        let diff = CGSize(width: f.minX - pr.minX, height: f.minY - pr.minY)
        if lagLog != nil { lagWrite(String(format: "R %.6f %.2f %.2f", CACurrentMediaTime(), diff.width, diff.height)) }
        if f.size != d.frame0.size { drag = nil; refreshGeometry(); return }     // it's being resized, not moved
        if hypot(diff.width, diff.height) > 2 {
            if let pd = d.pendingDiff, d.pendingAt == d.p, hypot(diff.width - pd.width, diff.height - pd.height) < 1 {
                d.bias.width += diff.width; d.bias.height += diff.height; d.pendingDiff = nil
                drag = d
                moveDragged(to: d.predicted(d.p))
                return
            }
            d.pendingDiff = diff; d.pendingAt = d.p
        } else { d.pendingDiff = nil }
        drag = d
    }

    func refreshDragged() {
        guard let d = downWin, let f = windowSource.frame(of: d.id) else { refreshGeometry(); return }
        guard let i = wins.firstIndex(where: { $0.id == d.id }), wins[i].frame != f else { return }
        var list = wins
        list[i] = Win(id: d.id, frame: f, z: list[i].z, surface: list[i].surface)
        applyWins(list)
    }

    func applyWins(_ list: [Win]) {
        wins = list
        if lagLog != nil, let id = downWin?.id, let w = list.first(where: { $0.id == id }), w.frame.origin != lagLast {
            lagLast = w.frame.origin
            lagWrite(String(format: "A %.6f %.2f %.2f %@", CACurrentMediaTime(), w.frame.minX, w.frame.minY, drag?.confirmed == true ? "pred" : "list"))
        }
        var s: [UInt64: Surface] = [:]
        for w in wins where w.surface {
            s[UInt64(w.id)] = Surface(key: UInt64(w.id), minX: w.frame.minX, maxX: w.frame.maxX, top: w.frame.maxY, z: w.z)
        }
        for (i, o) in overlays.enumerated() {
            if let (a, b, t) = dockSource(o) {
                s[Engine.dockKey(i)] = Surface(key: Engine.dockKey(i), minX: a, maxX: b, top: t, z: -1)
            }
        }
        if s != surfaces {
            let previous = surfaces
            surfaces = s
            orderedSurfaces = s.values.sorted { $0.top > $1.top }
            geometryChanged = true
            segments = [:]
            for (k, surf) in s {
                segments[k] = visibleSegments(surf)
                let pile = piles[k] ?? Pile()
                piles[k] = pile
                var removed: [(x: CGFloat, y: CGFloat, area: CGFloat)] = []
                if let old = previous[k], surf.z >= 0, !mouseIsDown, abs(old.width - surf.width) > 0.001 {
                    // not a mouse resize (zoom, tiling, Mission Control / lock-screen scaling): keep all the snow
                    pile.rescale(to: surf.width)
                } else {
                    removed = pile.resize(from: previous[k], to: surf)
                }
                if pile.dirty { pileDirty = true }
                if let old = previous[k], !removed.isEmpty { spillSnow(removed, from: old) }
            }
        }
        for k in surfaces.keys { piles[k]?.lastSeen = Date() }
    }

    /// x-intervals (global) of a surface's top band that aren't hidden by windows in front of it.
    func visibleSegments(_ s: Surface) -> [(CGFloat, CGFloat)] {
        var segs: [(CGFloat, CGFloat)] = [(s.minX, s.maxX)]
        guard s.z >= 0 else { return segs }
        for w in wins where w.z < s.z {
            let f = w.frame
            guard f.minY < s.top + Pile.maxH, f.maxY > s.top - 2 else { continue }
            var next: [(CGFloat, CGFloat)] = []
            for (a, b) in segs {
                if f.maxX <= a || f.minX >= b { next.append((a, b)); continue }
                if f.minX > a { next.append((a, f.minX)) }
                if f.maxX < b { next.append((f.maxX, b)) }
            }
            segs = next
            if segs.isEmpty { break }
        }
        return segs.filter { $0.1 - $0.0 > 2 }
    }

    func isVisible(_ k: UInt64, _ gx: CGFloat) -> Bool {
        segments[k]?.contains { gx >= $0.0 && gx <= $0.1 } ?? false
    }

    // MARK: tick

    func tick() {
        tickCount += 1
        let now = clock()
        let dt = CGFloat(min(0.25, now - last))
        last = now

        // window bounds: mouse down -> the window under the cursor every frame (60 Hz) + full list
        // ~8 Hz; otherwise the full list ~4 Hz whatever the tick rate
        if let d = drag, d.confirmed {
            if tickCount % 4 == 0 { reconcileDrag() }          // ~15 Hz check against the window list
            if tickCount % 8 == 0 { refreshGeometry() }
        } else if mouseIsDown || forceFast {
            if tickCount % 8 == 0 { refreshGeometry() } else { refreshDragged() }
        } else if tickCount % max(1, Int(0.25 / max(interval, 0.001))) == 0 { refreshGeometry() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if virtualNow == nil, !paused, now - lastMelt >= 2 {
            let elapsed = now - lastMelt; lastMelt = now
            meltStep(seconds: elapsed)
        }
        updateFlakes(dt: dt, now: now)
        updateSpills(dt: dt)
        if tickCount % 10 == 0 { for p in piles.values where p.mean > 0.05 { p.relax() }; pileDirty = true }
        if virtualNow == nil, now - lastSave > 30 { saveState() }
        if tickCount % 120 == 0 {
            let cutoff = Date().addingTimeInterval(-3), keepFor = Date().addingTimeInterval(-6 * 3600)
            piles = piles.filter {
                surfaces[$0.key] != nil || $0.value.lastSeen > cutoff || ($0.value.lastSeen > keepFor && hostAlive($0.key))
            }
        }
        updatePlows(dt: dt, now: now)
        updateProps(dt: dt)
        updateRoll()
        // pile paths: immediately when windows move, otherwise at most ~4 Hz for slow growth
        if geometryChanged || (pileDirty && now - lastPileDraw > 0.4) {   // moves: cheap re-position
            redrawPiles(); pileDirty = false; geometryChanged = false; lastPileDraw = now
        }
        CATransaction.commit()
        updateRate()
    }

    func updateWindMonitor() {
        if let monitor = windMonitor, !Settings.shared.windOn {
            NSEvent.removeMonitor(monitor); windMonitor = nil; windPoint = nil
        } else if Settings.shared.windOn, windMonitor == nil {
            windMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.mouseWind(at: NSEvent.mouseLocation)
            }
        }
    }

    func mouseWind(at p: CGPoint) {
        guard Settings.shared.windOn, !paused else { return }
        let now = clock(), previous = windPoint, elapsed = now - windTime
        windPoint = p; windTime = now
        guard let q = previous, elapsed > 0, elapsed < 0.2,
              !(mouseIsDown && (roll != nil || carry != nil || drag != nil)),
              !gustPending, now - lastGust >= 1.0 / 15 else { return }
        let velocity = CGPoint(x: (p.x - q.x) / CGFloat(elapsed), y: (p.y - q.y) / CGFloat(elapsed))
        let strength: CGFloat = [0.7, 1, 1.4][Settings.shared.windStrength]
        guard hypot(velocity.x, velocity.y) > 1200 / strength else { return }
        gustPending = true
        // Keep the event handler constant-time; at most one bounded gust can be queued.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gustPending = false
            self.windGust(at: p, velocity: velocity)
        }
    }

    func windGust(at p: CGPoint, velocity: CGPoint) {
        guard Settings.shared.windOn, !paused, !overlays.isEmpty,
              p.x.isFinite, p.y.isFinite, velocity.x.isFinite, velocity.y.isFinite,
              !(mouseIsDown && (roll != nil || carry != nil || drag != nil)) else { return }
        let now = clock()
        let strength: CGFloat = [0.7, 1, 1.4][Settings.shared.windStrength]
        guard now - lastGust >= 1.0 / 15, hypot(velocity.x, velocity.y) > 1200 / strength else { return }
        lastGust = now; windGusts += 1
        let radius = 140 * S * strength
        let impulse = max(-60 * S * strength, min(60 * S * strength, velocity.x * 0.025 * strength))
        var pushed = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in flakes.indices {
            if pushed >= 120 { break }
            let f = flakes[i], o = f.overlay
            guard now < f.arriveAt - 0.12 else { continue }
            let current = virtualNow == nil ? (f.layer.presentation()?.position ?? f.layer.position) : f.layer.position
            let global = CGPoint(x: current.x + o.frame.minX, y: current.y + o.frame.minY)
            let distance = hypot(global.x - p.x, global.y - p.y)
            guard distance < radius else { continue }
            let x = global.x + impulse * (1 - distance / radius)
            let r = f.layer.bounds.width / 2
            let surface = landingSurface(at: x, below: global.y, above: o.frame.minY)
            let lx = surface.map { x - $0.minX } ?? 0
            let endY = surface.map { $0.top + (piles[$0.key]?.height(at: lx) ?? 0) + r * 0.3 } ?? (o.frame.minY - 2 * r)
            let speed = (f.fromY - f.toY) / CGFloat(max(0.001, f.arriveAt - 0.12 - f.startAt))
            let duration = Double(max(0, global.y - endY) / max(1, speed))
            f.layer.removeAnimation(forKey: "fall")
            f.layer.position = CGPoint(x: x - o.frame.minX, y: virtualNow == nil ? endY - o.frame.minY : current.y)
            if virtualNow == nil {
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.fromValue = current.y; fall.toValue = endY - o.frame.minY; fall.duration = duration
                f.layer.add(fall, forKey: "fall")
                let push = CABasicAnimation(keyPath: "position.x")
                push.fromValue = current.x; push.toValue = x - o.frame.minX; push.duration = 0.18
                push.timingFunction = CAMediaTimingFunction(name: .easeOut)
                f.layer.add(push, forKey: "wind")
            }
            flakes[i] = Flake(overlay: o, layer: f.layer, startAt: now, fromY: current.y, toY: endY - o.frame.minY,
                              arriveAt: now + duration + 0.12, key: surface?.key, localX: lx, area: f.area)
            pushed += 1; windPushed += 1
        }
        // Six particles per 0.1 s bounds continuous wiping to 60 particles/s.
        if now - lastDust >= 0.1, abs(velocity.x) > 300,
           let surf = orderedSurfaces.first(where: { s in
               guard let pile = piles[s.key], isVisible(s.key, p.x) else { return false }
               let h = pile.height(at: p.x - s.minX)
               return h > 0.05 && p.y >= s.top && p.y <= s.top + h + 12 * S * strength
           }), let pile = piles[surf.key] {
            lastDust = now
            let x = p.x - surf.minX
            let area = pile.take(from: x - 10 * S, to: x + 10 * S, fraction: 0.012)
            if area > 0 {
                pileDirty = true
                for _ in 0..<6 {
                    let pos = CGPoint(x: p.x + .random(in: -8...8) * S, y: surf.top + pile.height(at: x))
                    let o = overlays[overlayIndex(for: pos)], layer = flakeLayer()
                    let r = CGFloat.random(in: 0.8...1.6) * S
                    layer.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
                    layer.cornerRadius = r; layer.position = o.local(pos)
                    o.actors.addSublayer(layer)
                    spills.append(Spill(layer: layer, pos: pos, vy: .random(in: 65...120) * S,
                                        vx: max(-280 * S, min(280 * S, velocity.x * 0.08)),
                                        area: 0, source: surf.key, fromDock: true, ttl: .random(in: 0.45...0.65)))
                    windDust += 1
                }
            }
        }
        CATransaction.commit()
        updateRate()
    }

    func icicleSite(_ key: UInt64, _ index: Int) -> (x: CGFloat, cap: CGFloat) {
        let seed = (key &* 1664525 &+ UInt64(index) &* 1013904223) & 0xffff
        let fraction = CGFloat(seed) / 65535
        return ((25 + CGFloat(index) * 58 + fraction * 12) * S, (10 + fraction * 12) * S)
    }

    /// Explicit calls also drive the debug and virtual-desktop melt scenes.
    func meltStep(seconds: CFTimeInterval) {
        guard Settings.shared.meltOn, !paused, seconds > 0 else { return }
        let amount = [CGFloat(0.4), 1.2, 3.0][Settings.shared.meltSpeed] * S * CGFloat(seconds) / 60
        for (key, pile) in piles where Date().timeIntervalSince(pile.created) >= 180 {
            guard pile.heights.contains(where: { $0 > 0 }) || pile.icicles.contains(where: { $0 > 0 }) else { continue }
            let before = pile.heights
            for i in pile.heights.indices { pile.heights[i] = max(0, pile.heights[i] - amount) }
            pile.dirty = true; pileDirty = true
            guard key < Engine.dockKey(0), let surf = surfaces[key] else { continue }
            let count = max(0, Int((surf.width / S - 25) / 58))
            if pile.icicles.count != count {
                pile.icicles = Array(pile.icicles.prefix(count))
                while pile.icicles.count < count { pile.icicles.append(0) }
                pile.icicleDirty = true
            }
            let empty = !before.contains { $0 > 0.05 }
            for i in pile.icicles.indices {
                let site = icicleSite(key, i), bin = min(before.count - 1, max(0, pile.index(site.x)))
                guard bin >= 0 else { continue }
                let old = pile.icicles[i]
                if empty {
                    pile.icicles[i] = max(0, old - amount * 2)
                } else if before[bin] > 0, isVisible(key, surf.minX + site.x) {
                    pile.icicles[i] = min(site.cap, old + (before[bin] - pile.heights[bin]) * 4)
                }
                if old != pile.icicles[i] { pile.icicleDirty = true }
            }
        }
    }

    func iciclePath(_ surf: Surface, _ pile: Pile) -> CGPath {
        let path = CGMutablePath()
        guard surf.z >= 0 else { return path }
        for i in pile.icicles.indices where pile.icicles[i] > 0 {
            let x = icicleSite(surf.key, i).x, length = pile.icicles[i]
            guard x < surf.width - 12 * S, isVisible(surf.key, surf.minX + x) else { continue }
            let half = min(2.2 * S, length * 0.18)
            path.move(to: CGPoint(x: x - half, y: 0))
            path.addLine(to: CGPoint(x: x, y: -length))
            path.addLine(to: CGPoint(x: x + half, y: 0)); path.closeSubpath()
        }
        return path
    }

    // MARK: flakes

    func updateFlakes(dt: CGFloat, now: CFTimeInterval) {
        // settle the flakes that have arrived (their landing spot was chosen when they spawned)
        if !flakes.isEmpty {
            var kept: [Flake] = []
            kept.reserveCapacity(flakes.count)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for f in flakes {
                if now < f.arriveAt {
                    if virtualNow != nil {   // showcase: move it ourselves
                        let k = min(1, (now - f.startAt) / max(0.001, f.arriveAt - 0.12 - f.startAt))
                        f.layer.position.y = f.fromY + (f.toY - f.fromY) * CGFloat(k)
                    }
                    kept.append(f); continue
                }
                if let k = f.key, let pile = piles[k] {
                    pile.deposit(at: f.localX, area: f.area)
                    // --demo: extra flakes' worth of snow, spread nearby (keeps the profile smooth)
                    for _ in 0..<Int(demoBoost) - 1 { pile.deposit(at: f.localX + .random(in: -60...60), area: f.area) }
                    pileDirty = true
                }
                f.layer.removeAllAnimations(); f.layer.removeFromSuperlayer(); flakePool.append(f.layer)
            }
            CATransaction.commit()
            flakes = kept
        }
        guard Settings.shared.snowOn else { return }
        let intensity = Settings.shared.intensity
        let rate = (lowPower && intensity == .blizzard ? Intensity.heavy : intensity).flakeRate * (lowPower ? 0.5 : 1)
        // highest surfaces first: a flake crossing a window top sticks with some chance, otherwise
        // keeps falling in front of it to the windows / Dock further down (windows are layered).
        for o in overlays {
            let f = o.frame
            spawnDebt += rate * f.width / 100 * dt
            while spawnDebt >= 1 {
                spawnDebt -= 1
                if flakes.count >= 700 { spawnDebt = 0; break }
                let x = CGFloat.random(in: f.minX...f.maxX)
                let r = CGFloat.random(in: 1.3...2.7) * S
                let v = CGFloat.random(in: 52...80) * (0.85 + 0.15 * S)
                var endY = f.minY - 2 * r
                var key: UInt64?
                var lx: CGFloat = 0
                if let s = landingSurface(at: x, below: f.maxY, above: f.minY, snowChance: true) {
                    lx = x - s.minX
                    endY = s.top + (piles[s.key]?.height(at: lx) ?? 0) + r * 0.3
                    key = s.key
                }
                let startY = f.maxY + r + 2
                let dur = Double((startY - endY) / v)
                let layer = flakeLayer()
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
                layer.cornerRadius = r
                layer.position = CGPoint(x: x - f.minX, y: endY - f.minY)
                o.flakeRoot.addSublayer(layer)
                CATransaction.commit()
                if virtualNow == nil {
                    let a = CABasicAnimation(keyPath: "position.y")
                    a.fromValue = startY - f.minY
                    a.toValue = endY - f.minY
                    a.duration = dur
                    layer.add(a, forKey: "fall")
                } else { layer.position.y = startY - f.minY }
                flakes.append(Flake(overlay: o, layer: layer, startAt: now, fromY: startY - f.minY, toY: endY - f.minY,
                                    arriveAt: now + dur + 0.12, key: key, localX: lx,
                                    area: 0.6 * .pi * r * r))
            }
        }
    }

    /// Shared front-to-back landing rule; spills always stick to the first visible top below.
    func landingSurface(at x: CGFloat, below: CGFloat, above: CGFloat, excluding: UInt64? = nil, snowChance: Bool = false) -> Surface? {
        orderedSurfaces.first { s in
            s.key != excluding && x >= s.minX && x <= s.maxX && s.top < below && s.top >= above &&
                isVisible(s.key, x) && (!snowChance || s.z < 0 || CGFloat.random(in: 0..<1) < 0.45)
        }
    }

    func flakeLayer() -> CALayer {
        if let l = flakePool.popLast() { return l }
        let l = CALayer()
        l.backgroundColor = NSColor.white.cgColor
        l.borderColor = NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.75, alpha: 0.4).cgColor
        l.borderWidth = 0.5
        return l
    }

    /// A falling snowman/ball hits the Dock: burst into a short puff and leave a small bump of snow.
    func poof(_ m: Prop, on s: Surface) {
        m.remove()
        guard !overlays.isEmpty else { return }
        let area = m.kind == .snowman ? 0.3 * (13 * m.scale) * (50 * m.scale) : .pi * m.scale * m.scale
        piles[s.key]?.deposit(at: m.pos.x - s.minX, area: area)
        pileDirty = true
        let count = m.kind == .snowman ? 26 : 12
        let w = m.halfWidth, h = m.height * 0.7
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for _ in 0..<count {
            let pos = CGPoint(x: m.pos.x + .random(in: -w...w), y: s.top + .random(in: 0...h))
            let o = overlays[overlayIndex(for: pos)]
            let layer = flakeLayer()
            let r = CGFloat.random(in: 1.2...2.6) * S
            layer.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            layer.cornerRadius = r; layer.position = o.local(pos)
            o.actors.addSublayer(layer)
            let dir: CGFloat = pos.x < m.pos.x ? -1 : 1
            spills.append(Spill(layer: layer, pos: pos, vy: .random(in: 60...260) * S, vx: dir * .random(in: 30...170) * S,
                                area: 0, source: s.key, fromDock: true, ttl: .random(in: 0.4...0.6)))
        }
        CATransaction.commit()
        updateRate()
    }

    func spillSnow(_ samples: [(x: CGFloat, y: CGFloat, area: CGFloat)], from surf: Surface) {
        guard !overlays.isEmpty else { return }
        let total = samples.reduce(CGFloat(0)) { $0 + $1.area }
        guard total > 0 else { return }
        let count = min(40, max(1, Int(ceil(total / (30 * S * S)))))
        let area = total / CGFloat(count)
        // Equal-volume quantiles keep both edges represented, without one layer per pile sample.
        var index = 0, accumulated: CGFloat = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in 0..<count {
            let target = (CGFloat(i) + 0.5) * area
            while index < samples.count - 1 && accumulated + samples[index].area < target {
                accumulated += samples[index].area; index += 1
            }
            let sample = samples[index]
            // a little scatter so it reads as crumbling snow, not a dotted line
            let pos = CGPoint(x: sample.x + .random(in: -3...3) * S, y: sample.y + .random(in: -2...3) * S)
            let o = overlays[overlayIndex(for: pos)]
            let layer = flakeLayer()
            let r = min(4.5 * S, max(2 * S, (area / .pi).squareRoot())) * .random(in: 0.7...1.2)
            layer.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            layer.cornerRadius = r; layer.position = o.local(pos)
            o.actors.addSublayer(layer)
            spills.append(Spill(layer: layer, pos: pos, vy: .random(in: -20...40) * S, vx: .random(in: -25...25) * S,
                                area: area, source: surf.key, fromDock: surf.z < 0))
        }
        CATransaction.commit()
    }

    func updateSpills(dt: CGFloat) {
        guard !spills.isEmpty else { return }
        let bottom = (overlays.map { $0.frame.minY }.min() ?? 0) - 20 * S
        var kept: [Spill] = []
        for var f in spills {
            let oldY = f.pos.y
            f.vy -= 700 * S * dt
            f.pos.y += f.vy * dt
            f.pos.x += f.vx * dt
            var landed = false
            if !f.fromDock, let s = landingSurface(at: f.pos.x, below: oldY, above: f.pos.y, excluding: f.source) {
                piles[s.key]?.deposit(at: f.pos.x - s.minX, area: f.area)
                pileDirty = true; landed = true
            }
            if f.ttl.isFinite {
                f.ttl -= dt
                f.vx *= 1 - min(1, 3 * dt)                   // air drag: a puff, not shrapnel
                f.layer.opacity = Float(max(0, min(1, f.ttl / 0.25)))
            }
            if landed || f.pos.y < bottom || f.ttl <= 0 {
                f.layer.removeFromSuperlayer(); f.layer.opacity = 1; flakePool.append(f.layer)
            } else {
                let o = overlays[overlayIndex(for: f.pos)]
                if f.layer.superlayer !== o.actors { o.actors.addSublayer(f.layer) }
                f.layer.position = o.local(f.pos)
                kept.append(f)
            }
        }
        spills = kept
    }

    // MARK: piles

    static let windowCorner: CGFloat = 12
    static let dockCorner: CGFloat = 16

    /// Snow on one surface as a closed path (global coords): tapers to nothing over the last
    /// stretch and wraps over the rounded corner.
    func pilePath(_ surf: Surface, _ pile: Pile) -> CGPath? {
        let width = surf.width
        guard width > 30 else { return nil }
        let R = surf.z < 0 ? Engine.dockCorner : Engine.windowCorner
        let T = max(R + 4, 16 * S)                    // taper length
        func drop(_ d: CGFloat) -> CGFloat { d >= R ? 0 : R - (R * R - (R - d) * (R - d)).squareRoot() }
        func smooth(_ t: CGFloat) -> CGFloat { let u = max(0, min(1, t)); return u * u * (3 - 2 * u) }
        var tops: [CGPoint] = [], bots: [CGPoint] = []
        var x: CGFloat = 0
        while true {
            let cx = min(x, width)
            let d = min(cx, width - cx)
            let h = pile.height(at: cx) * smooth(d / T) * (0.35 + 0.65 * smooth(d / (R * 0.8)))
            let base = surf.top - drop(d)
            tops.append(CGPoint(x: surf.minX + cx, y: base + h))
            bots.append(CGPoint(x: surf.minX + cx, y: base - min(1.5, h)))
            if cx >= width { break }
            // finer steps on the corners so the curve stays round
            x += d < T ? 1.5 : Pile.step
        }
        let p = CGMutablePath()
        p.move(to: bots[0]); p.addLine(to: tops[0])
        for i in 1..<tops.count {
            let a = tops[i - 1], b = tops[i]
            p.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        p.addLine(to: tops[tops.count - 1])
        for b in bots.reversed() { p.addLine(to: b) }
        p.closeSubpath()
        return p
    }

    /// Clip region for a surface's snow: its band minus the rounded shapes of windows in front.
    /// Only recomputed when window geometry changes (boolean path ops are the expensive part).
    func clipPath(_ surf: Surface) -> CGPath? {
        guard surf.z > 0 else { return nil }
        let R = Engine.windowCorner
        let band = CGRect(x: surf.minX - 12, y: surf.top - max(R + 8, 24 * S), width: surf.width + 24, height: Pile.maxH + max(R + 8, 24 * S) + 16)
        var occ: CGPath?
        for w in wins where w.z < surf.z && w.frame.intersects(band) {
            let rr = CGPath(roundedRect: w.frame, cornerWidth: R, cornerHeight: R, transform: nil)
            occ = occ.map { $0.union(rr) } ?? rr
        }
        guard let o = occ else { return nil }
        return CGPath(rect: band, transform: nil).subtracting(o)
    }

    /// Windows in front whose shape cuts this surface's snow, relative to the surface origin.
    func occluderSignature(_ surf: Surface) -> [CGRect] {
        guard surf.z > 0 else { return [] }
        let band = CGRect(x: surf.minX - 12, y: surf.top - max(Engine.windowCorner + 8, 24 * S), width: surf.width + 24, height: Pile.maxH + max(Engine.windowCorner + 8, 24 * S) + 16)
        return wins.filter { $0.z < surf.z && $0.frame.intersects(band) }.map { $0.frame.offsetBy(dx: -surf.minX, dy: -surf.top) }
    }

    /// Snow layers live in surface-local coordinates, so moving a window only moves a layer.
    /// Paths are rebuilt only when that pile's heights or width change; masks only when the
    /// windows in front of it change relative to it.
    func redrawPiles(paths: Bool = true) {
        for (k, view) in pileViews where surfaces[k] == nil || piles[k] == nil {
            view.container.removeFromSuperlayer(); pileViews[k] = nil
        }
        for (k, surf) in surfaces {
            guard let pile = piles[k], pile.heights.count > 1 else { continue }
            let empty = (pile.mean <= 0.05 && !pile.icicles.contains { $0 > 0 }) || (segments[k] ?? []).isEmpty
            if empty { if let v = pileViews[k] { v.container.isHidden = true }; continue }
            let view = pileViews[k] ?? PileView()
            pileViews[k] = view
            let o = overlays[overlayIndex(for: CGPoint(x: surf.minX + surf.width / 2, y: surf.top))]
            if view.container.superlayer !== o.piles { o.piles.addSublayer(view.container) }
            view.container.isHidden = false
            view.container.zPosition = CGFloat(-surf.z)       // front windows' snow above back windows'
            view.container.position = o.local(CGPoint(x: surf.minX, y: surf.top))
            let toLocal = CGAffineTransform(translationX: -surf.minX, y: -surf.top)
            let widthChanged = view.width != surf.width
            if geometryChanged || widthChanged {
                let sig = occluderSignature(surf)
                if widthChanged || sig != view.occSig || view.width < 0 {
                    view.occSig = sig
                    if !sig.isEmpty, let c = clipPath(surf) {
                        let band = c.boundingBoxOfPath
                        view.mask.frame = band.applying(toLocal)
                        view.mask.path = c.copy(using: [CGAffineTransform(translationX: -band.minX, y: -band.minY)])
                        view.container.mask = view.mask
                    } else { view.container.mask = nil }
                }
            }
            view.icicles.isHidden = !Settings.shared.meltOn
            if pile.icicleDirty || geometryChanged || widthChanged || view.needsPath {
                view.icicles.path = iciclePath(surf, pile)
                pile.icicleDirty = false
            }
            if paths && (pile.dirty || view.needsPath) || widthChanged {
                pile.dirty = false; view.needsPath = false; view.width = surf.width
                guard let gp = pilePath(surf, pile) else { continue }
                view.top.path = gp.copy(using: [toLocal])
                let under = gp.copy(using: [toLocal.translatedBy(x: 0, y: -1.2 * S)])
                view.under.path = under
                view.under.shadowPath = under
            }
        }
    }

    // MARK: props (snowmen & snowballs)

    func addProp(_ m: Prop, on key: UInt64, atX gx: CGFloat, fromY: CGFloat) {
        guard let s = surfaces[key] else { return }
        if props.count >= 40, let i = props.firstIndex(where: { $0 !== carry?.prop }) { props.remove(at: i).remove() }
        m.host = key
        m.localX = min(max(gx, s.minX + m.halfWidth), s.maxX - m.halfWidth) - s.minX
        m.pos = CGPoint(x: s.minX + m.localX, y: max(fromY, s.top))
        props.append(m)
        place(m)
        updateRate()
    }

    func spawnSnowman(onSurface key: UInt64, atX gx: CGFloat, fromY: CGFloat) {
        guard Settings.shared.snowmenOn else { return }
        addProp(Prop(kind: .snowman, scale: S, withBalls: true), on: key, atX: gx, fromY: fromY)
    }

    func groundY(_ m: Prop, _ k: UInt64, _ s: Surface) -> CGFloat {
        s.top + (piles[k]?.height(at: m.localX) ?? 0) * (m.kind == .snowman ? 0.45 : 0.5) - 1
    }

    func updateProps(dt: CGFloat) {
        if let c = carry, !c.cancelled,
           drag?.confirmed == true || (!c.active && surfaces[c.host] == nil) { carryCancel() }
        guard !props.isEmpty else { return }
        let gravity: CGFloat = 1400 * S
        let lowest = (overlays.map { $0.frame.minY }.min() ?? 0) - 120
        props.removeAll { m in
            if let c = carry, c.active, c.prop === m { place(m); return false }
            if let k = m.host, let s = surfaces[k] {
                m.pos.x = s.minX + m.localX
                let ground = groundY(m, k, s)
                if m.grounded {
                    m.pos.y = ground
                } else {
                    m.vy -= gravity * dt
                    m.pos.y += m.vy * dt
                    if m.vy <= 0 && m.pos.y <= ground { m.pos.y = ground; m.vy = 0; m.grounded = true }
                }
            } else if let k = m.host, hostAlive(k) {
                // its window is only out of the list for now (other Space, minimized, hidden): wait for it
                m.layer.isHidden = true; m.deco?.isHidden = true
                return false
            } else {
                // the window it sat on is gone: fall straight down; poof on the Dock, else off screen
                m.host = nil; m.grounded = false
                let oldY = m.pos.y
                m.vy -= gravity * dt
                m.pos.y += m.vy * dt
                if let d = orderedSurfaces.first(where: { $0.z < 0 && m.pos.x >= $0.minX && m.pos.x <= $0.maxX }) {
                    let g = d.top + (piles[d.key]?.height(at: m.pos.x - d.minX) ?? 0) * 0.5
                    if oldY >= g && m.pos.y <= g { m.pos.y = g; poof(m, on: d); return true }
                }
                if m.pos.y < lowest { m.remove(); return true }
            }
            place(m)
            return false
        }
    }

    /// Surface owner still around? Dock keys always; windows: asked at most every 2 s per key.
    var aliveCache: [UInt64: (Bool, CFTimeInterval)] = [:]
    func hostAlive(_ k: UInt64) -> Bool {
        if k >= Engine.dockKey(0) { return true }
        let now = CACurrentMediaTime()
        if let c = aliveCache[k], now - c.1 < 2 { return c.0 }
        let v = windowSource.exists(CGWindowID(k))
        aliveCache[k] = (v, now)
        if aliveCache.count > 200 { aliveCache = aliveCache.filter { now - $0.value.1 < 2 } }
        return v
    }

    func overlayIndex(for p: CGPoint) -> Int {
        if let i = overlays.firstIndex(where: { $0.frame.insetBy(dx: 0, dy: -60).contains(p) }) { return i }
        return overlays.enumerated().min { abs($0.element.frame.midX - p.x) < abs($1.element.frame.midX - p.x) }?.offset ?? 0
    }

    func place(_ m: Prop) {
        guard !overlays.isEmpty else { return }
        let o = overlays[overlayIndex(for: m.pos)]
        if m.parent !== o.actors {
            if let d = m.deco { o.actors.addSublayer(d) }
            o.actors.addSublayer(m.layer); m.parent = o.actors
        }
        let lp = o.local(m.pos)
        m.layer.position = m.kind == .snowman ? lp : CGPoint(x: lp.x, y: lp.y + m.scale)
        if let d = m.deco {
            var by = lp.y
            if let k = m.host, let s = surfaces[k] { by = s.top - 1 - o.frame.minY + (piles[k]?.height(at: m.localX) ?? 0) * 0.4 }
            d.position = CGPoint(x: lp.x + (m.decoSide > 0 ? 14 * S : -40 * S), y: by)
        }
        var hidden = false
        if let k = m.host, let s = surfaces[k], s.z > 0 {
            let probe = CGPoint(x: m.pos.x, y: m.pos.y + min(16 * S, m.height / 2))
            hidden = wins.contains { $0.z < s.z && $0.frame.contains(probe) }
        }
        m.layer.isHidden = hidden
        m.deco?.isHidden = hidden || m.host == nil
    }

    func prop(at p: CGPoint, ballsOnly: Bool = false) -> Prop? {
        props.last {
            if ballsOnly && ($0.kind != .ball || !$0.grounded) { return false }
            let pad: CGFloat = ballsOnly ? 4 : 0
            return !$0.layer.isHidden && CGRect(x: $0.pos.x - $0.halfWidth - pad, y: $0.pos.y - 2 - pad,
                                                width: 2 * ($0.halfWidth + pad), height: $0.height + 4 + 2 * pad).contains(p)
        }
    }

    func jump(_ m: Prop) {
        guard m.host != nil, m.grounded else { return }
        m.grounded = false
        m.vy = 330 * S.squareRoot()
        let k = m.kind == .snowman ? m.scale : m.scale / 20
        let squash = CAKeyframeAnimation(keyPath: "transform.scale.y")
        squash.values = [k, k * 0.82, k * 1.08, k]; squash.keyTimes = [0, 0.15, 0.5, 1]; squash.duration = 0.5
        m.layer.add(squash, forKey: "squash")
    }

    // MARK: snowball carrying

    func carryCancel() {
        guard let c = carry, !c.cancelled else { return }
        c.cancelled = true; c.active = false
        let m = c.prop
        m.host = c.host; m.localX = c.localX; m.pos = c.pickup; m.grounded = true; m.vy = 0
        if let s = surfaces[c.host] { m.pos = CGPoint(x: s.minX + c.localX, y: groundY(m, c.host, s)) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place(m)
        CATransaction.commit()
    }

    func carryMove(to p: CGPoint) {
        guard let c = carry, !c.cancelled else { return }
        if drag?.confirmed == true || (!c.active && surfaces[c.host] == nil) { carryCancel(); return }
        let now = clock(), elapsed = now - c.lastTime
        let dx = p.x - c.lastPoint.x, dy = p.y - c.lastPoint.y
        c.lastPoint = p; c.lastTime = now
        if !c.active {
            guard hypot(p.x - c.down.x, p.y - c.down.y) > 4 else { return }
            c.active = true
            c.prop.host = nil; c.prop.grounded = false; c.prop.vy = 0
            c.prop.layer.removeAnimation(forKey: "squash")
        }
        var prediction = CGSize.zero
        if elapsed > 0 && elapsed < 0.15 {
            let factor = min(CGFloat(0.016 / elapsed), 24 / max(0.001, hypot(dx, dy)))
            prediction = CGSize(width: dx * factor, height: dy * factor)
        }
        let pos = c.position(at: p)
        c.prop.pos = CGPoint(x: pos.x + prediction.width, y: pos.y + prediction.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place(c.prop)
        CATransaction.commit()
    }

    func pop(_ m: Prop) {
        let k = m.scale
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [k * 0.3, k * 1.18, k * 0.94, k]; pop.keyTimes = [0, 0.45, 0.75, 1]; pop.duration = 0.4
        m.layer.add(pop, forKey: "pop")
    }

    func carryEnd(at p: CGPoint) {
        guard let c = carry, c.active, !c.cancelled else { return }
        let m = c.prop
        m.pos = c.position(at: p)       // release uses the actual grab point, without prediction
        let center = CGPoint(x: m.pos.x, y: m.pos.y + m.scale)
        let targets = props.reversed().filter { $0 !== m && !$0.layer.isHidden }
        if Settings.shared.snowmenOn, let target = targets.first(where: { t in
            t.kind == .ball && t.host.flatMap { surfaces[$0] } != nil &&
                hypot(center.x - t.pos.x, center.y - (t.pos.y + t.scale)) < m.scale + t.scale + 6
        }), let key = target.host {
            let snowman = Prop(kind: .snowman, scale: max(m.scale, target.scale) / 9)
            snowman.grounded = true
            m.remove(); target.remove()
            props.removeAll { $0 === m || $0 === target }
            addProp(snowman, on: key, atX: target.pos.x, fromY: target.pos.y)
            snowman.localX = target.localX; snowman.pos = target.pos
            place(snowman); pop(snowman)
            return
        }
        if let target = targets.first(where: { t in
            guard t.kind == .snowman else { return false }
            let x = min(max(center.x, t.pos.x - t.halfWidth), t.pos.x + t.halfWidth)
            let y = min(max(center.y, t.pos.y), t.pos.y + t.height)
            return hypot(center.x - x, center.y - y) < m.scale + 6
        }) {
            let side: CGFloat = center.x < target.pos.x ? -1 : 1
            m.pos.x = target.pos.x + side * (target.halfWidth + m.scale + 6)
        }
        let surface = landingSurface(at: m.pos.x, below: m.pos.y, above: -CGFloat.greatestFiniteMagnitude)
        m.host = surface?.key
        m.localX = surface.map { m.pos.x - $0.minX } ?? 0
        m.grounded = false; m.vy = 0
        place(m)
    }

    // MARK: snowball rolling

    /// mouse down: arm a roll if the press is on a visible pile band of a still window.
    func rollBegin(at p: CGPoint) {
        roll = nil
        guard Settings.shared.snowmenOn else { return }
        let cands = surfaces.values.filter { s in
            guard p.x >= s.minX + 4, p.x <= s.maxX - 4, isVisible(s.key, p.x) else { return false }
            let h = piles[s.key]?.height(at: p.x - s.minX) ?? 0
            return h > 2 && p.y >= s.top - 8 && p.y <= s.top + h + 10 * S
        }
        guard let s = cands.min(by: { ($0.z < 0 ? -1 : $0.z) < ($1.z < 0 ? -1 : $1.z) }) else { return }
        roll = Roll(key: s.key, surface: s, localX: p.x - s.minX)
    }

    func rollMove(to p: CGPoint) {
        guard let r = roll else { return }
        guard let s = surfaces[r.key], abs(s.minX - r.startMinX) < 0.5, abs(s.top - r.startTop) < 0.5 else {
            rollCancel(); return                                       // the window moved: that's a window drag
        }
        let nx = min(max(p.x - s.minX, r.r), s.width - r.r)
        let dx = nx - r.localX
        if !r.shown {
            guard abs(dx) >= 3 else { return }
            r.shown = true
            overlays[overlayIndex(for: p)].actors.addSublayer(r.layer)
        }
        if let pile = piles[r.key], dx != 0 {
            let got = pile.take(from: r.localX, to: nx, fraction: 0.55)
            r.r = min(Engine.maxBall, (r.r * r.r + got * 0.55 / .pi).squareRoot())
            pileDirty = true; geometryChanged = true
        }
        r.angle -= dx / r.r
        r.localX = nx
    }

    func updateRoll() {
        guard let r = roll, r.shown, let s = surfaces[r.key] else { return }
        let gx = s.minX + r.localX
        let gy = s.top + (piles[r.key]?.height(at: r.localX) ?? 0) * 0.5 - 1 + r.r
        let o = overlays[overlayIndex(for: CGPoint(x: gx, y: gy))]
        if r.layer.superlayer !== o.actors { o.actors.addSublayer(r.layer) }
        r.layer.position = o.local(CGPoint(x: gx, y: gy))
        r.layer.setAffineTransform(CGAffineTransform(rotationAngle: r.angle).scaledBy(x: r.r / 20, y: r.r / 20))
    }

    func rollCancel() {
        guard let r = roll else { return }
        roll = nil
        r.layer.removeFromSuperlayer()
        // leave a decent ball where it was rather than making it vanish
        if r.shown, r.r > 5 * S, surfaces[r.key] != nil {
            addProp(Prop(kind: .ball, scale: r.r), on: r.key, atX: r.startMinX + r.localX, fromY: r.startTop + r.r)
        }
    }

    /// mouse up: big ball -> snowman (with a pop), small ball -> snowball left on the edge.
    @discardableResult
    func rollEnd() -> Bool {
        guard let r = roll else { return false }
        roll = nil
        guard r.shown else { return false }
        r.layer.removeFromSuperlayer()
        guard let s = surfaces[r.key] else { return true }
        let gx = s.minX + r.localX
        if r.r >= Engine.snowmanThreshold {
            let m = Prop(kind: .snowman, scale: r.r / 9)
            m.grounded = true
            addProp(m, on: r.key, atX: gx, fromY: s.top)
            pop(m)
        } else {
            let b = Prop(kind: .ball, scale: r.r)
            b.grounded = true
            addProp(b, on: r.key, atX: gx, fromY: s.top)
        }
        return true
    }

    // MARK: plow

    func startPlow() {
        for (i, o) in overlays.enumerated() {
            guard plows.allSatisfy({ $0.screenIndex != i }), let s = surfaces[Engine.dockKey(i)] else { continue }
            let p = Plow(screenIndex: i, x: s.minX - 60 * S)
            o.actors.addSublayer(p.mound)
            o.actors.addSublayer(p.layer)
            plows.append(p)
        }
        lastPlow = clock()
        updateRate()
    }

    func updatePlows(dt: CGFloat, now: CFTimeInterval) {
        if Settings.shared.autoPlow, plows.isEmpty, now - lastPlow > 90 {
            let full = overlays.indices.contains { (piles[Engine.dockKey($0)]?.mean ?? 0) > Pile.maxH * 0.4 }
            if full { startPlow() } else { lastPlow = now - 60 }
        }
        guard !plows.isEmpty else { return }
        plows.removeAll { p in
            guard p.screenIndex < overlays.count, let s = surfaces[Engine.dockKey(p.screenIndex)] else {
                p.layer.removeFromSuperlayer(); p.mound.removeFromSuperlayer(); return true
            }
            p.x += 90 * S.squareRoot() * dt
            // scrape everything the blade passed over into the mound in front of it
            let f = p.front
            if f > p.lastFront, let pile = piles[s.key] {
                p.volume += pile.take(from: p.lastFront - s.minX, to: f - s.minX, fraction: 1)
                p.volume = min(p.volume, 1.6 * p.bladeH * p.bladeH)   // the rest spills off the front
                pileDirty = true
            }
            p.lastFront = f
            let o = overlays[p.screenIndex]
            let base = o.local(CGPoint(x: f, y: s.top - 2))
            p.layer.position = o.local(CGPoint(x: p.x, y: s.top - 1))
            // wedge: tallest at the blade, sloping down ahead (area ≈ 0.6·H·L)
            let path = CGMutablePath()
            if p.volume > 4 {
                var H = (p.volume / 1.32).squareRoot()
                H = min(H, p.bladeH * 1.05)
                let L = max(10, p.volume / (0.6 * H))
                path.move(to: CGPoint(x: base.x - 2, y: base.y))
                path.addLine(to: CGPoint(x: base.x - 2, y: base.y + H))
                path.addQuadCurve(to: CGPoint(x: base.x + H * 0.25, y: base.y + H * 0.98), control: CGPoint(x: base.x + H * 0.1, y: base.y + H * 1.05))
                path.addCurve(to: CGPoint(x: base.x + L, y: base.y), control1: CGPoint(x: base.x + L * 0.45, y: base.y + H * 0.95), control2: CGPoint(x: base.x + L * 0.7, y: base.y + H * 0.2))
                path.closeSubpath()
            }
            p.mound.path = path
            p.mound.shadowPath = path
            if p.x - p.layer.bounds.width / 2 > s.maxX + 20 && f > o.frame.maxX + p.volume / 10 {
                p.layer.removeFromSuperlayer(); p.mound.removeFromSuperlayer(); return true
            }
            if p.x > o.frame.maxX + 200 * S { p.layer.removeFromSuperlayer(); p.mound.removeFromSuperlayer(); return true }
            return false
        }
    }

    // MARK: mouse (global monitors; the overlay itself stays click-through)

    var downPoint: CGPoint?
    var downTime: CFTimeInterval = 0
    var downWin: Win?

    func topWindow(at p: CGPoint, in list: [Win]) -> Win? { list.first { $0.frame.contains(p) }.flatMap { $0.surface ? $0 : nil } }

    func installMouseMonitors() {
        updateWindMonitor()
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in self?.mouseDown(at: NSEvent.mouseLocation) }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in self?.mouseDragged(to: NSEvent.mouseLocation); self?.mouseWind(at: NSEvent.mouseLocation) }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in self?.mouseUp(at: NSEvent.mouseLocation) }
    }

    func mouseDown(at p: CGPoint) {
        carryCancel(); carry = nil
        mouseIsDown = true
        refreshGeometry()
        downPoint = p
        downTime = clock()
        downWin = topWindow(at: p, in: wins)
        drag = nil
        // title bar / toolbar strip: a possible window drag
        if predictDrag, let w = downWin, p.y >= w.frame.maxY - 60 {
            drag = Drag(id: w.id, frame0: w.frame, p0: p, p: p)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let m = prop(at: p, ballsOnly: true), let key = m.host, surfaces[key] != nil {
            rollCancel()
            carry = Carry(prop: m, host: key, at: p, time: clock())
        } else { rollBegin(at: p) }
        CATransaction.commit()
        updateRate()
    }

    func mouseDragged(to p: CGPoint) {
        if carry != nil { refreshGeometry() }
        // Run after the window check, including its early returns: the same press reaches
        // the window behind our click-through overlay and may confirm a title-bar drag.
        defer { carryMove(to: p) }
        if roll != nil {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            refreshGeometry()
            rollMove(to: p)
            CATransaction.commit()
        }
        guard var d = drag else { return }
        d.p = p
        if !d.confirmed {
            // first make sure the window really follows the mouse (some title areas don't drag,
            // the top edge resizes): one cheap single-window query per event until it moves
            guard let f = windowSource.frame(of: d.id) else { drag = nil; return }
            if f.size != d.frame0.size { drag = nil; return }
            if f.origin == d.frame0.origin {
                drag = carry == nil && hypot(p.x - d.p0.x, p.y - d.p0.y) > 12 ? nil : d
                return
            }
            d.confirmed = true
            if roll != nil { rollCancel() }
            carryCancel()
        }
        drag = d
        moveDragged(to: d.predicted(p))
    }

    func mouseUp(at p: CGPoint) {
        mouseIsDown = false
        defer { updateRate() }
        if drag?.confirmed == true {
            carryCancel()
            drag = nil
            // final word from the window list (it may have snapped / tiled)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            refreshGeometry(); redrawPiles(paths: false); updateProps(dt: 0)
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.mouseIsDown else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.refreshGeometry(); self.redrawPiles(paths: false); self.updateProps(dt: 0)
                CATransaction.commit()
            }
        }
        drag = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let c = carry {
            defer { carry = nil; downPoint = nil }
            refreshGeometry()
            if !c.active && surfaces[c.host] == nil { carryCancel() }
            guard !c.cancelled else { return }
            if c.active { carryEnd(at: p) }
            else if hypot(p.x - c.down.x, p.y - c.down.y) <= 4, clock() - downTime < 0.6 { jump(c.prop) }
            return
        }
        let rolled = rollEnd()
        guard !rolled, let d = downPoint else { downPoint = nil; return }
        downPoint = nil
        guard hypot(p.x - d.x, p.y - d.y) < 4, clock() - downTime < 0.6 else { return }
        if let m = prop(at: p) { jump(m); return }
        guard Settings.shared.snowmenOn, let w0 = downWin else { return }
        refreshGeometry()
        guard let w1 = topWindow(at: p, in: wins), w1.id == w0.id, w1.frame == w0.frame else { return }
        guard p.y >= w1.frame.maxY - 28 else { return }        // title-bar strip only
        spawnSnowman(onSurface: UInt64(w1.id), atX: p.x, fromY: w1.frame.maxY + 26 * S)
    }

    // MARK: debug / demo hooks

    func demoTargets() -> [Win] {
        refreshGeometry()
        let menuBottom = NSScreen.screens.map { $0.visibleFrame.maxY }.max() ?? .greatestFiniteMagnitude
        return wins.filter { $0.surface && $0.frame.width > 300 && $0.frame.maxY < menuBottom - 60 }
    }

    func spawnDemoSnowmen() {
        for w in demoTargets().prefix(2) {
            let xs: [CGFloat] = w.z == 0 ? [0.25, 0.42] : [0.6]
            for f in xs where isVisible(UInt64(w.id), w.frame.minX + w.frame.width * f) {
                spawnSnowman(onSurface: UInt64(w.id), atX: w.frame.minX + w.frame.width * f, fromY: w.frame.maxY + 40 * S)
            }
        }
    }
    func spawnDemoBalls() {
        guard let w = demoTargets().first, let s = surfaces[UInt64(w.id)] else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (offset, radius) in [(CGFloat(-60), 7 * S), (CGFloat(60), 5 * S)] {
            let x = (s.minX + s.maxX) / 2 + offset
            guard isVisible(s.key, x) else { continue }
            addProp(Prop(kind: .ball, scale: radius), on: s.key, atX: x, fromY: s.top + 40 * S)
        }
        CATransaction.commit()
    }
    func jumpAll() { props.forEach(jump) }

    /// debug: write surfaces / piles / windows to $TMPDIR/macsnow-debug.txt
    func dump() {
        var out = "interval=\(interval) flakes=\(flakes.count) props=\(props.count) paused=\(paused)\n"
        let settings = Settings.shared
        out += "settings intensity=\(settings.intensity.rawValue) wind=\(settings.windOn)/\(settings.windStrength) melt=\(settings.meltOn)/\(settings.meltSpeed) battery=\(settings.batteryMode.rawValue) lowPower=\(lowPower) onAC=\(onAC) lpm=\(ProcessInfo.processInfo.isLowPowerModeEnabled) login=\(SMAppService.mainApp.status.rawValue)\n"
        out += "wind gusts=\(windGusts) pushed=\(windPushed) dust=\(windDust)\n"
        for (k, p) in piles where k < Engine.dockKey(0) {
            let lengths = p.icicles.filter { $0 > 0 }
            if let longest = lengths.max() { out += "icicles key=\(k) n=\(lengths.count) maxLen=\(longest)\n" }
        }
        out += "axTrusted=\(AXIsProcessTrusted()) dockAX=\(DockGeometry.debugAXFrame.map { "\(Int($0.minX))..\(Int($0.maxX)) top=\(Int($0.maxY))" } ?? "nil")\n"
        for w in wins { out += "win id=\(w.id) z=\(w.z) surface=\(w.surface) frame=\(w.frame)\n" }
        for (k, p) in piles.sorted(by: { $0.key < $1.key }) where p.mean > 0.05 {
            out += "pile key=\(k) mean=\(String(format: "%.2f", p.mean)) n=\(p.heights.count) inList=\(surfaces[k] != nil)\n"
        }
        for m in props { out += "prop kind=\(m.kind == .ball ? "ball" : "snowman") host=\(m.host.map(String.init) ?? "nil") x=\(m.pos.x) y=\(m.pos.y) r=\(m.scale) grounded=\(m.grounded) hidden=\(m.layer.isHidden)\n" }
        for s in orderedSurfaces {
            let v = pileViews[s.key]
            out += "surf key=\(s.key) z=\(s.z) x=\(Int(s.minX))..\(Int(s.maxX)) top=\(Int(s.top)) mean=\(String(format: "%.2f", piles[s.key]?.mean ?? -1)) segs=\(segments[s.key]?.map { "\(Int($0.0))-\(Int($0.1))" } ?? []) view=\(v != nil) hidden=\(v?.container.isHidden ?? true) masked=\(v?.container.mask != nil)\n"
        }
        try? out.write(toFile: NSTemporaryDirectory() + "macsnow-debug.txt", atomically: true, encoding: .utf8)
    }
    func fillAll() { piles.values.forEach { $0.fill() }; pileDirty = true; geometryChanged = true }

    /// Scripted roll on the frontmost demo window: same code path as a real mouse drag.
    func demoRoll() {
        guard let w = demoTargets().first else { return }
        let s = surfaces[UInt64(w.id)]!
        piles[s.key]?.fill()
        let startX = s.minX + s.width * 0.55
        rollBegin(at: CGPoint(x: startX, y: s.top + 4))
        guard roll != nil else { NSLog("MacSnow demoRoll: no pile band"); return }
        var t: CGFloat = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            t += 1.0 / 60
            let x = startX + sin(t * 2.2) * s.width * 0.18 + t * 25 * S
            self.rollMove(to: CGPoint(x: x, y: s.top + 4))
            if t > 4.5 || self.roll == nil { tm.invalidate(); self.rollEnd() }
        }
    }
}

// MARK: - App / menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    var item: NSStatusItem!
    let menu = NSMenu()

    var termSource: DispatchSourceSignal?
    func applicationWillTerminate(_ n: Notification) { engine.saveState() }

    func applicationDidFinishLaunching(_ n: Notification) {
        // `kill` / `pkill` / logout: keep the snow for the next launch
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { [weak self] in self?.engine.saveState(); exit(0) }
        termSource?.resume()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            if let img = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "MacSnow") {
                img.isTemplate = true; b.image = img
            } else { b.title = "❄" }
        }
        menu.delegate = self
        item.menu = menu
        engine.start()
        askDockAccessOncePerBuild()
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            engine.demoBoost = 10
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { self.engine.demoBoost = 1 }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = Settings.shared
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector, on: Bool? = nil, key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        add("눈 내리기 (Snow)", #selector(toggleSnow), on: s.snowOn)
        let sub = NSMenu()
        for it in Intensity.allCases {
            let i = NSMenuItem(title: it.title, action: #selector(setIntensity(_:)), keyEquivalent: "")
            i.target = self; i.tag = it.rawValue; i.state = it == s.intensity ? .on : .off
            sub.addItem(i)
        }
        let parent = NSMenuItem(title: "세기 (Intensity)", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
        func choices(_ title: String, _ titles: [String], _ selected: Int, _ action: Selector) {
            let submenu = NSMenu()
            for (tag, title) in titles.enumerated() {
                let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
                i.target = self; i.tag = tag; i.state = tag == selected ? .on : .off
                submenu.addItem(i)
            }
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = submenu; menu.addItem(i)
        }
        add("마우스 바람 (Mouse wind)", #selector(toggleWind), on: s.windOn)
        choices("바람 세기 (Wind strength)", ["약하게 (Gentle)", "보통 (Normal)", "세게 (Strong)"], s.windStrength, #selector(setWindStrength(_:)))
        add("녹기·고드름 (Melting & icicles)", #selector(toggleMelt), on: s.meltOn)
        choices("녹는 속도 (Melt speed)", ["느리게 (Slow)", "보통 (Normal)", "빠르게 (Fast)"], s.meltSpeed, #selector(setMeltSpeed(_:)))
        choices("배터리 절약 (Battery saving)", BatteryMode.allCases.map { $0.title }, s.batteryMode.rawValue, #selector(setBatteryMode(_:)))
        add("로그인 시 자동 실행 (Launch at login)", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add("눈사람 (Snowmen) — 제목줄 클릭 / 눈 굴리기", #selector(toggleSnowmen), on: s.snowmenOn)
        add("제설차 자동 (Auto plow)", #selector(toggleAutoPlow), on: s.autoPlow)
        add("눈송이 창 위로 (Flakes over windows)", #selector(toggleFlakesOnTop), on: s.flakesOnTop)
        if !AXIsProcessTrusted() {
            add("Dock 크기 정확히 맞추기 (손쉬운 사용 권한)", #selector(requestDockAccess))
        }
        menu.addItem(.separator())
        add("지금 Dock 제설 (Plow the Dock now)", #selector(plowNow))
        add("앞 창에 눈사람 놓기 (Debug)", #selector(debugSpawn))
        add("눈 치우기 (Clear snow)", #selector(clearSnow))
        menu.addItem(.separator())
        add("종료 (Quit)", #selector(quit), key: "q")
    }

    @objc func toggleWind() { Settings.shared.windOn.toggle(); engine.updateWindMonitor() }
    @objc func setWindStrength(_ i: NSMenuItem) { Settings.shared.windStrength = i.tag }
    @objc func toggleMelt() { Settings.shared.meltOn.toggle(); engine.applySettings() }
    @objc func setMeltSpeed(_ i: NSMenuItem) { Settings.shared.meltSpeed = i.tag; engine.lastMelt = engine.clock() }
    @objc func setBatteryMode(_ i: NSMenuItem) { Settings.shared.batteryMode = BatteryMode(rawValue: i.tag) ?? .auto; engine.updatePower() }
    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 시 자동 실행 (Launch at login)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc func toggleSnow() { Settings.shared.snowOn.toggle(); engine.updateRate() }
    @objc func toggleSnowmen() { Settings.shared.snowmenOn.toggle(); engine.applySettings() }
    @objc func toggleAutoPlow() { Settings.shared.autoPlow.toggle() }
    @objc func toggleFlakesOnTop() { Settings.shared.flakesOnTop.toggle(); engine.applySettings() }
    @objc func setIntensity(_ i: NSMenuItem) { Settings.shared.intensity = Intensity(rawValue: i.tag) ?? .normal; engine.updateRate() }
    /// Not trusted yet: show the system Accessibility prompt once per build. A rebuilt (ad-hoc signed)
    /// binary loses the earlier grant, so the key is the executable's build time. The menu item stays.
    func askDockAccessOncePerBuild() {
        guard !AXIsProcessTrusted(), let exe = Bundle.main.executableURL,
              let built = (try? exe.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return }
        let stamp = String(Int(built.timeIntervalSince1970))
        guard UserDefaults.standard.string(forKey: "axPromptedBuild") != stamp else { return }
        UserDefaults.standard.set(stamp, forKey: "axPromptedBuild")
        requestDockAccess()
    }
    @objc func requestDockAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DockGeometry.invalidate()
    }
    @objc func plowNow() { engine.startPlow() }
    @objc func debugSpawn() { engine.spawnDemoSnowmen() }
    @objc func clearSnow() { engine.clearSnow() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
// `MacSnow --showcase <dir>`: render the scripted demo on a virtual desktop to PNG frames and exit.
if let i = CommandLine.arguments.firstIndex(of: "--showcase") {
    let dir = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "showcase-out"
    Showcase.run(outDir: dir)
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// Debug control channel (see notify.sh): plow, spawn, balls, jump, clear, fill, roll
for (name, action) in [("plow", { delegate.engine.startPlow() }),
                       ("melt.fast", {
                           delegate.engine.piles.values.forEach { $0.created = .distantPast }
                           delegate.engine.meltStep(seconds: 600)
                       }),
                       ("spawn", { delegate.engine.spawnDemoSnowmen() }),
                       ("balls", { delegate.engine.spawnDemoBalls() }),
                       ("jump", { delegate.engine.jumpAll() }),
                       ("clear", { delegate.engine.clearSnow() }),
                       ("fill", { delegate.engine.fillAll() }),
                       ("roll", { delegate.engine.demoRoll() }),
                       ("rebuild", { delegate.engine.rebuildOverlays() }),   // same as a screen-parameter change
                       ("dump", { delegate.engine.dump() }),
                       ("fast", {
                           delegate.engine.refreshGeometry()
                           delegate.engine.downWin = delegate.engine.wins.first { $0.surface }
                           delegate.engine.forceFast = true; delegate.engine.updateRate()
                           DispatchQueue.main.asyncAfter(deadline: .now() + 12) { delegate.engine.forceFast = false; delegate.engine.updateRate() }
                       })] as [(String, () -> Void)] {
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.coldtbrew.macsnow." + name), object: nil, queue: .main) { _ in
        CATransaction.begin(); CATransaction.setDisableActions(true); action(); CATransaction.commit()
    }
}
DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.coldtbrew.macsnow.wind.gust"), object: nil, queue: .main) { n in
    let c = ((n.object as? String) ?? "").split(separator: ",").compactMap { Double($0) }
    guard c.count == 4, c.allSatisfy({ $0.isFinite }) else { return }
    delegate.engine.windGust(at: CGPoint(x: c[0], y: c[1]), velocity: CGPoint(x: c[2], y: c[3]))
}
// Simulated mouse for drag-lag measurement (tools/testwin.swift lagtest):
// object = "x,y,windowID,fx,fy,fw,fh" (mouse point + the test window's real frame, AppKit global)
let sim = SimOverride()
for (name, act) in [("sim.down", { (p: CGPoint) in delegate.engine.mouseDown(at: p) }),
                    ("sim.drag", { (p: CGPoint) in delegate.engine.mouseDragged(to: p) }),
                    ("sim.up", { (p: CGPoint) in delegate.engine.mouseUp(at: p) })] as [(String, (CGPoint) -> Void)] {
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.coldtbrew.macsnow." + name), object: nil, queue: .main) { n in
        let c = ((n.object as? String) ?? "").split(separator: ",").compactMap { Double($0) }
        guard c.count == 7 else { return }
        if !(delegate.engine.windowSource is SimOverride) { delegate.engine.windowSource = sim }
        sim.frames[CGWindowID(c[2])] = CGRect(x: c[3], y: c[4], width: c[5], height: c[6])
        act(CGPoint(x: c[0], y: c[1]))
    }
}
app.run()
