// MacSnow — menu bar snow that lands and piles up on window tops and the Dock.
import AppKit
import QuartzCore
import ApplicationServices
import IOKit.ps
import ServiceManagement
import Sparkle

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

enum ShakeStrength: Int, CaseIterable {
    case gentle = 0, normal, strong
    var title: String { ["약하게 (Gentle)", "보통 (Normal)", "세게 (Strong)"][rawValue] }

    func shedFraction(strokeStrength: CGFloat, repeated: Bool) -> CGFloat {
        let base: CGFloat = [0.16, 0.26, 0.38][rawValue]
        let limit: CGFloat = [0.65, 0.85, 0.95][rawValue]
        return min(limit, base * strokeStrength * (repeated ? 1.5 : 1))
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    init() { d.register(defaults: ["snowOn": true, "intensity": 1, "snowmenOn": true, "autoPlow": true, "flakesOnTop": false, "windOn": true, "windStrength": 1, "meltOn": true, "meltSpeed": 1, "campfireOn": false, "batteryMode": 0, "shakeOn": true, "shakeStrength": ShakeStrength.normal.rawValue]) }
    var windOn: Bool { get { d.bool(forKey: "windOn") } set { d.set(newValue, forKey: "windOn") } }
    var windStrength: Int { get { max(0, min(2, d.integer(forKey: "windStrength"))) } set { d.set(newValue, forKey: "windStrength") } }
    /// shaking a window by its title bar knocks its snow (and snowmen) off
    var shakeOn: Bool { get { d.bool(forKey: "shakeOn") } set { d.set(newValue, forKey: "shakeOn") } }
    var shakeStrength: ShakeStrength {
        get { ShakeStrength(rawValue: d.integer(forKey: "shakeStrength")) ?? .normal }
        set { d.set(newValue.rawValue, forKey: "shakeStrength") }
    }
    var meltOn: Bool { get { d.bool(forKey: "meltOn") } set { d.set(newValue, forKey: "meltOn") } }
    var meltSpeed: Int { get { max(0, min(2, d.integer(forKey: "meltSpeed"))) } set { d.set(newValue, forKey: "meltSpeed") } }
    var campfireOn: Bool { get { d.bool(forKey: "campfireOn") } set { d.set(newValue, forKey: "campfireOn") } }
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
    /// Mission Control (or Launchpad) is showing, as of the last fetch: window frames are scaled thumbnails
    var exposeActive: Bool { get }
}
extension WindowProvider {
    /// The window still exists (maybe on another Space, minimized or hidden), i.e. it wasn't closed.
    func exists(_ id: CGWindowID) -> Bool { frame(of: id) != nil }
    var exposeActive: Bool { false }
}

struct SystemWindows: WindowProvider {
    func fetch() -> [Win] { WindowList.fetch() }
    var exposeActive: Bool { WindowList.exposeActive }
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
    var exposeActive: Bool { WindowList.exposeActive }
}

enum WindowList {
    /// Mission Control puts a full-screen shield window (WindowManager, layer 19 on macOS 14+; the Dock
    /// on older systems) over the desktop. Owner names and layers need no screen-recording permission.
    static var exposeActive = false
    static let exposeLayers = 18...19
    static func fetch() -> [Win] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [Win] = []
        let screenArea = NSScreen.screens.map { $0.frame.width * $0.frame.height }.max() ?? 1
        var expose = false
        defer { exposeActive = expose }
        for info in raw {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let owner = info[kCGWindowOwnerName as String] as? String
            if owner == "WindowManager" || owner == "Dock" {
                if exposeLayers.contains(layer) { expose = true }
                continue                      // Mission Control / Stage Manager chrome, never a surface
            }
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
            let sideInset = max(18, min(28, ax.height * 0.28))
            guard f.contains(CGPoint(x: ax.midX, y: ax.midY)),
                  ax.width > sideInset * 2 + 40 else { return nil }
            return (ax.minX + sideInset, ax.maxX - sideInset, ax.maxY - topInset)
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
        // Each icon slot is slightly wider than tilesize; inset both ends so fallback snow
        // stays strictly narrower than the Dock's rounded pill even without AX permission.
        var width = CGFloat(icons) * tile * 1.03 + CGFloat(seps) * tile * 0.28 + tile * 0.15
        let sideInset = max(18, tile * 0.38)
        width = max(60, min(width, f.width - 8) - sideInset * 2)
        return (f.midX - width / 2, f.midX + width / 2, v.minY)     // AX: list maxY - topInset == visibleFrame.minY
    }
}

// MARK: - Snow pile height map

struct Icicle {
    let x: CGFloat
    let cap: CGFloat
    let girth: CGFloat
    let lean: CGFloat
    var length: CGFloat = 0
}

final class Pile {
    static let step: CGFloat = 3
    static let maxH: CGFloat = 13 * S
    static let kernel: [CGFloat] = (-5...5).map { exp(-CGFloat($0 * $0) / 8) }
    var dirty = true
    var heights: [CGFloat] = []
    var caps: [CGFloat] = []
    var lastSeen = Date()
    var created = Date()
    var icicles: [Icicle] = []
    var icicleLayoutWidth: CGFloat?
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

    @discardableResult func relax() -> Bool {
        guard heights.count > 2 else { return false }
        var h = heights
        var changed = false
        for i in 1..<(h.count - 1) {
            h[i] += ((heights[i - 1] + heights[i + 1]) / 2 - heights[i]) * 0.15
            if abs(h[i] - heights[i]) > 0.01 { changed = true }
        }
        heights = h
        if changed { dirty = true }
        return changed
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

struct SnowmanStyle: Codable, Equatable {
    enum Hat: Int, CaseIterable, Codable {
        case santa = 0, beanie, bucket, tophat
    }
    enum ScarfColor: Int, CaseIterable, Codable {
        case red = 0, pine, cobalt, gold, plum, coral
        var color: NSColor {
            switch self {
            case .red:    return santaRed
            case .pine:   return NSColor(calibratedRed: 0.14, green: 0.56, blue: 0.34, alpha: 1)
            case .cobalt: return NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.85, alpha: 1)
            case .gold:   return NSColor(calibratedRed: 0.92, green: 0.68, blue: 0.14, alpha: 1)
            case .plum:   return NSColor(calibratedRed: 0.58, green: 0.24, blue: 0.68, alpha: 1)
            case .coral:  return NSColor(calibratedRed: 0.94, green: 0.38, blue: 0.28, alpha: 1)
            }
        }
        var stripe: NSColor {
            switch self {
            case .red:    return NSColor(calibratedRed: 1, green: 0.88, blue: 0.88, alpha: 0.9)
            case .pine:   return NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.82, alpha: 0.9)
            case .cobalt: return NSColor(calibratedRed: 0.82, green: 0.93, blue: 1, alpha: 0.9)
            case .gold:   return NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.1, alpha: 0.85)
            case .plum:   return NSColor(calibratedRed: 0.96, green: 0.84, blue: 1, alpha: 0.9)
            case .coral:  return NSColor(calibratedRed: 1, green: 0.93, blue: 0.8, alpha: 0.9)
            }
        }
    }
    let hat: Hat
    let scarf: ScarfColor

    static func random() -> SnowmanStyle {
        SnowmanStyle(hat: Hat.allCases.randomElement() ?? .santa,
                     scarf: ScarfColor.allCases.randomElement() ?? .red)
    }
}

/// Snowman with randomized winter hat and scarf, drawn at unit scale (base radius 9). Anchor = bottom centre.
func makeSnowmanLayer(style: SnowmanStyle = .random()) -> CALayer {
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
    root.addSublayer(shape(scarf, fill: style.scarf.color))
    let stripes = CGMutablePath()
    stripes.addRect(CGRect(x: 22.2, y: 21.0, width: 2.6, height: 1.0))
    stripes.addRect(CGRect(x: 22.2, y: 23.2, width: 2.6, height: 1.0))
    root.addSublayer(shape(stripes, fill: style.scarf.stripe))
    root.addSublayer(shape(circle(CGPoint(x: 18, y: 35), 0.8), fill: .black))
    root.addSublayer(shape(circle(CGPoint(x: 22, y: 35), 0.8), fill: .black))
    let nose = CGMutablePath()
    nose.move(to: CGPoint(x: 20, y: 33.7)); nose.addLine(to: CGPoint(x: 25, y: 32.6)); nose.addLine(to: CGPoint(x: 20, y: 32.4)); nose.closeSubpath()
    root.addSublayer(shape(nose, fill: NSColor(calibratedRed: 1, green: 0.5, blue: 0.1, alpha: 1)))
    switch style.hat {
    case .santa:
        let hat = CGMutablePath()
        hat.move(to: CGPoint(x: 15, y: 38)); hat.addQuadCurve(to: CGPoint(x: 27, y: 46), control: CGPoint(x: 19, y: 48))
        hat.addQuadCurve(to: CGPoint(x: 25, y: 38), control: CGPoint(x: 24, y: 42)); hat.closeSubpath()
        root.addSublayer(shape(hat, fill: santaRed))
        let brim = CGMutablePath(); brim.addRoundedRect(in: CGRect(x: 14, y: 36.6, width: 12, height: 3), cornerWidth: 1.5, cornerHeight: 1.5)
        root.addSublayer(shape(brim, fill: .white, stroke: snowEdge, lw: 0.5))
        root.addSublayer(shape(circle(CGPoint(x: 27.2, y: 45.6), 1.9), fill: .white, stroke: snowEdge, lw: 0.5))
    case .beanie:
        let dome = CGMutablePath()
        dome.move(to: CGPoint(x: 14.4, y: 37.8))
        dome.addQuadCurve(to: CGPoint(x: 20, y: 45.4), control: CGPoint(x: 14.8, y: 44.8))
        dome.addQuadCurve(to: CGPoint(x: 25.6, y: 37.8), control: CGPoint(x: 25.2, y: 44.8))
        dome.closeSubpath()
        root.addSublayer(shape(dome, fill: style.scarf.color))
        let band = CGMutablePath()
        band.addRoundedRect(in: CGRect(x: 13.8, y: 36.5, width: 12.4, height: 3.1), cornerWidth: 1.4, cornerHeight: 1.4)
        root.addSublayer(shape(band, fill: style.scarf.stripe, stroke: style.scarf.color.withAlphaComponent(0.45), lw: 0.5))
        root.addSublayer(shape(circle(CGPoint(x: 20, y: 46.2), 2.2), fill: .white, stroke: snowEdge, lw: 0.5))
    case .bucket:
        let tin = NSColor(calibratedRed: 0.50, green: 0.64, blue: 0.78, alpha: 1)
        let tinDark = NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.56, alpha: 1)
        let bucket = CGMutablePath()
        bucket.move(to: CGPoint(x: 14.2, y: 37.4))
        bucket.addLine(to: CGPoint(x: 16.4, y: 46.4))
        bucket.addLine(to: CGPoint(x: 24.4, y: 45.3))
        bucket.addLine(to: CGPoint(x: 25.6, y: 36.9))
        bucket.closeSubpath()
        root.addSublayer(shape(bucket, fill: tin, stroke: tinDark, lw: 0.6))
        let rim = CGMutablePath()
        rim.move(to: CGPoint(x: 13.4, y: 37.6)); rim.addLine(to: CGPoint(x: 26.2, y: 36.8))
        root.addSublayer(shape(rim, fill: .clear, stroke: tinDark, lw: 1.5))
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: 15.0, y: 39.2))
        handle.addQuadCurve(to: CGPoint(x: 25.2, y: 38.6), control: CGPoint(x: 20.5, y: 34.4))
        root.addSublayer(shape(handle, fill: .clear, stroke: NSColor(calibratedWhite: 0.35, alpha: 0.9), lw: 0.7))
    case .tophat:
        let felt = NSColor(calibratedWhite: 0.16, alpha: 1)
        let feltEdge = NSColor(calibratedWhite: 0.34, alpha: 1)
        let crown = CGMutablePath()
        crown.move(to: CGPoint(x: 15.4, y: 38.6))
        crown.addLine(to: CGPoint(x: 14.6, y: 47.4))
        crown.addLine(to: CGPoint(x: 25.4, y: 47.4))
        crown.addLine(to: CGPoint(x: 24.6, y: 38.6))
        crown.closeSubpath()
        root.addSublayer(shape(crown, fill: felt, stroke: feltEdge, lw: 0.5))
        let ribbon = CGMutablePath()
        ribbon.addRect(CGRect(x: 15.2, y: 39.0, width: 9.6, height: 2.1))
        root.addSublayer(shape(ribbon, fill: style.scarf.color))
        let brim = CGMutablePath()
        brim.addRoundedRect(in: CGRect(x: 12.2, y: 37.0, width: 15.6, height: 2.2), cornerWidth: 1.1, cornerHeight: 1.1)
        root.addSublayer(shape(brim, fill: felt, stroke: feltEdge, lw: 0.4))
    }
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

enum CampfireAssets {
    /// Soft warm radial amber/orange glow halo behind the campfire.
    static let glowImage: CGImage? = {
        let size = 128
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [
            CGColor(srgbRed: 1.0, green: 0.78, blue: 0.24, alpha: 0.48),
            CGColor(srgbRed: 1.0, green: 0.46, blue: 0.08, alpha: 0.26),
            CGColor(srgbRed: 0.96, green: 0.25, blue: 0.03, alpha: 0.09),
            CGColor(srgbRed: 0.95, green: 0.20, blue: 0.00, alpha: 0.0),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.34, 0.70, 1.0]
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locs) {
            let c = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
            ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        }
        return ctx.makeImage()
    }()

    /// Glistening translucent sky-blue teardrop for melted snow flowing down.
    static let dropImage: CGImage? = {
        let w = 32, h = 48
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 16, y: 45))
        path.addCurve(to: CGPoint(x: 27, y: 16), control1: CGPoint(x: 19, y: 35), control2: CGPoint(x: 27, y: 26))
        path.addCurve(to: CGPoint(x: 16, y: 4), control1: CGPoint(x: 27, y: 8.5), control2: CGPoint(x: 22.2, y: 4))
        path.addCurve(to: CGPoint(x: 5, y: 16), control1: CGPoint(x: 9.8, y: 4), control2: CGPoint(x: 5, y: 8.5))
        path.addCurve(to: CGPoint(x: 16, y: 45), control1: CGPoint(x: 5, y: 26), control2: CGPoint(x: 13, y: 35))
        path.closeSubpath()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = [
            CGColor(srgbRed: 0.72, green: 0.94, blue: 1.0, alpha: 0.76),
            CGColor(srgbRed: 0.34, green: 0.76, blue: 0.99, alpha: 0.85),
            CGColor(srgbRed: 0.16, green: 0.56, blue: 0.96, alpha: 0.92),
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.52, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 16, y: 45), end: CGPoint(x: 16, y: 4), options: [])
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        ctx.fillEllipse(in: CGRect(x: 9.2, y: 14.5, width: 4.8, height: 8.5))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.52))
        ctx.fillEllipse(in: CGRect(x: 11.2, y: 9.2, width: 2.6, height: 2.8))
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 0.82, green: 0.96, blue: 1.0, alpha: 0.82))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        return ctx.makeImage()
    }()

    /// Bright sky-blue round water splash droplet.
    static let splashImage: CGImage? = {
        let size = 24
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 3, y: 3, width: 18, height: 18)
        ctx.saveGState()
        ctx.addEllipse(in: r)
        ctx.clip()
        let colors = [
            CGColor(srgbRed: 0.86, green: 0.97, blue: 1.0, alpha: 0.95),
            CGColor(srgbRed: 0.34, green: 0.78, blue: 1.0, alpha: 0.88),
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 9, y: 15), startRadius: 1,
                                   endCenter: CGPoint(x: 12, y: 12), endRadius: 10, options: [])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(srgbRed: 0.88, green: 0.98, blue: 1.0, alpha: 0.82))
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: r)
        return ctx.makeImage()
    }()

    /// Soft radial translucent white steam puff.
    static let steamImage: CGImage? = {
        let size = 48
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55),
            CGColor(srgbRed: 0.94, green: 0.97, blue: 1, alpha: 0.24),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1]) {
            let c = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
            ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        }
        return ctx.makeImage()
    }()
}

/// Click-through animated campfire attached to the cursor: warm glow halo, crossed logs,
/// glowing ember coals, and 3 layered flickering flames that lean opposite cursor velocity.
final class CampfireVisual {
    let root = CALayer()
    let glow = CALayer()
    let logs = CALayer()
    let coals = CAShapeLayer()
    let coalGlow = CAShapeLayer()
    let outerFlame = CAShapeLayer()
    let midFlame = CAShapeLayer()
    let innerFlame = CAShapeLayer()
    weak var parent: CALayer?

    init() {
        root.zPosition = 1000
        let s = S

        glow.bounds = CGRect(x: 0, y: 0, width: 82 * s, height: 82 * s)
        glow.position = CGPoint(x: 0, y: 4 * s)
        glow.contents = CampfireAssets.glowImage
        glow.contentsGravity = .resize
        root.addSublayer(glow)

        let barkDark = NSColor(calibratedRed: 0.30, green: 0.16, blue: 0.08, alpha: 1)
        let barkLight = NSColor(calibratedRed: 0.44, green: 0.24, blue: 0.11, alpha: 1)
        let barkEdge = NSColor(calibratedRed: 0.18, green: 0.09, blue: 0.04, alpha: 1)
        let woodCut = NSColor(calibratedRed: 0.68, green: 0.48, blue: 0.28, alpha: 1)

        func makeLog(angle: CGFloat, fill: NSColor, cutRight: Bool) -> CALayer {
            let l = CALayer()
            let len = 25 * s, thick = 4.8 * s
            let body = CGMutablePath()
            body.addRoundedRect(in: CGRect(x: -len / 2, y: -thick / 2, width: len, height: thick),
                                cornerWidth: thick * 0.42, cornerHeight: thick * 0.42)
            l.addSublayer(shape(body, fill: fill, stroke: barkEdge, lw: 0.8 * s))
            let grain = CGMutablePath()
            grain.move(to: CGPoint(x: -len * 0.32, y: thick * 0.14))
            grain.addLine(to: CGPoint(x: len * 0.20, y: thick * 0.14))
            grain.move(to: CGPoint(x: -len * 0.14, y: -thick * 0.16))
            grain.addLine(to: CGPoint(x: len * 0.30, y: -thick * 0.16))
            l.addSublayer(shape(grain, fill: .clear, stroke: barkEdge.withAlphaComponent(0.45), lw: 0.6 * s))
            let cx = cutRight ? (len / 2 - thick * 0.32) : (-len / 2 + thick * 0.32)
            let endRect = CGRect(x: cx - thick * 0.28, y: -thick * 0.36, width: thick * 0.56, height: thick * 0.72)
            l.addSublayer(shape(CGPath(ellipseIn: endRect, transform: nil), fill: woodCut, stroke: barkEdge, lw: 0.5 * s))
            l.position = CGPoint(x: 0, y: -6.5 * s)
            l.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            return l
        }
        logs.addSublayer(makeLog(angle: 0.36, fill: barkDark, cutRight: false))
        logs.addSublayer(makeLog(angle: -0.36, fill: barkLight, cutRight: true))
        logs.shadowColor = NSColor.black.cgColor
        logs.shadowOpacity = 0.35
        logs.shadowRadius = 2 * s
        logs.shadowOffset = CGSize(width: 0, height: -1 * s)
        root.addSublayer(logs)

        let coalPath = CGMutablePath()
        for (x, y, rx, ry) in [(-4.8, -7.8, 2.3, 1.4), (0.0, -8.5, 2.8, 1.6), (4.6, -7.7, 2.2, 1.4),
                               (-2.0, -5.8, 2.1, 1.3), (2.5, -6.0, 2.0, 1.3)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            coalPath.addEllipse(in: CGRect(x: (x - rx) * s, y: (y - ry) * s, width: 2 * rx * s, height: 2 * ry * s))
        }
        coals.path = coalPath
        coals.fillColor = NSColor(calibratedRed: 0.92, green: 0.28, blue: 0.04, alpha: 0.95).cgColor
        coals.contentsScale = 2
        root.addSublayer(coals)

        let hotPath = CGMutablePath()
        for (x, y, rx, ry) in [(-3.6, -7.4, 1.3, 0.8), (0.2, -8.0, 1.8, 1.0), (3.4, -7.4, 1.2, 0.8),
                               (0.0, -5.8, 1.6, 0.9)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            hotPath.addEllipse(in: CGRect(x: (x - rx) * s, y: (y - ry) * s, width: 2 * rx * s, height: 2 * ry * s))
        }
        coalGlow.path = hotPath
        coalGlow.fillColor = NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.16, alpha: 0.96).cgColor
        coalGlow.contentsScale = 2
        root.addSublayer(coalGlow)

        outerFlame.fillColor = NSColor(calibratedRed: 0.96, green: 0.28, blue: 0.05, alpha: 0.94).cgColor
        outerFlame.shadowColor = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.04, alpha: 1).cgColor
        outerFlame.shadowOpacity = 0.65
        outerFlame.shadowRadius = 5 * s
        outerFlame.shadowOffset = .zero
        outerFlame.contentsScale = 2

        midFlame.fillColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.08, alpha: 0.96).cgColor
        midFlame.contentsScale = 2

        innerFlame.fillColor = NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.62, alpha: 0.98).cgColor
        innerFlame.contentsScale = 2

        root.addSublayer(outerFlame)
        root.addSublayer(midFlame)
        root.addSublayer(innerFlame)
        update(phase: 0, velocity: .zero)
    }

    private func flamePath(baseX: CGFloat = 0, baseY: CGFloat, halfW: CGFloat, height: CGFloat, tipX: CGFloat, bellyShift: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let tip = CGPoint(x: baseX + tipX, y: baseY + height)
        let bottom = CGPoint(x: baseX, y: baseY - halfW * 0.24)
        p.move(to: bottom)
        p.addCurve(
            to: CGPoint(x: baseX + halfW * 0.84 + bellyShift * 0.45, y: baseY + height * 0.34),
            control1: CGPoint(x: baseX + halfW * 0.72, y: baseY - halfW * 0.18),
            control2: CGPoint(x: baseX + halfW * 1.08 + bellyShift * 0.25, y: baseY + height * 0.14)
        )
        p.addCurve(
            to: tip,
            control1: CGPoint(x: baseX + halfW * 0.56 + tipX * 0.48, y: baseY + height * 0.62),
            control2: CGPoint(x: baseX + tipX + halfW * 0.16, y: baseY + height * 0.84)
        )
        p.addCurve(
            to: CGPoint(x: baseX - halfW * 0.84 + bellyShift * 0.45, y: baseY + height * 0.34),
            control1: CGPoint(x: baseX + tipX - halfW * 0.16, y: baseY + height * 0.84),
            control2: CGPoint(x: baseX - halfW * 0.56 + tipX * 0.48, y: baseY + height * 0.62)
        )
        p.addCurve(
            to: bottom,
            control1: CGPoint(x: baseX - halfW * 1.08 + bellyShift * 0.25, y: baseY + height * 0.14),
            control2: CGPoint(x: baseX - halfW * 0.72, y: baseY - halfW * 0.18)
        )
        p.closeSubpath()
        return p
    }

    func update(phase: CGFloat, velocity: CGPoint) {
        let s = S
        let leanX = max(-14 * s, min(14 * s, -velocity.x * 0.018))
        let stretchY = max(-3.5 * s, min(5.5 * s, -velocity.y * 0.005))

        let sway1 = sin(phase * 8.6) * 2.1 * s + sin(phase * 14.3 + 1.2) * 0.9 * s
        let sway2 = sin(phase * 10.8 + 0.8) * 1.5 * s + cos(phase * 16.5) * 0.6 * s
        let sway3 = sin(phase * 13.4 + 2.1) * 0.8 * s
        let pulse1 = 1 + 0.09 * sin(phase * 11.2) + 0.05 * cos(phase * 17.6)
        let pulse2 = 1 + 0.11 * sin(phase * 13.7 + 0.9)
        let pulse3 = 1 + 0.13 * cos(phase * 16.1 + 1.7)

        let outer = CGMutablePath()
        outer.addPath(flamePath(baseY: -4.8 * s, halfW: 9.2 * s, height: (24.5 * s + stretchY) * pulse1,
                                tipX: leanX + sway1, bellyShift: leanX * 0.25 + sway1 * 0.3))
        let leftLickH = (11.5 + 2.2 * sin(phase * 12.1 + 0.4)) * s
        outer.addPath(flamePath(baseX: -4.5 * s, baseY: -4.6 * s, halfW: 3.3 * s, height: leftLickH,
                                tipX: -2.0 * s + leanX * 0.65 + sway2 * 0.7, bellyShift: -0.8 * s + leanX * 0.15))
        let rightLickH = (10.5 + 2.0 * cos(phase * 13.3 + 1.5)) * s
        outer.addPath(flamePath(baseX: 4.5 * s, baseY: -4.6 * s, halfW: 3.1 * s, height: rightLickH,
                                tipX: 1.8 * s + leanX * 0.65 - sway2 * 0.6, bellyShift: 0.8 * s + leanX * 0.15))
        outerFlame.path = outer

        midFlame.path = flamePath(baseY: -4.4 * s, halfW: 6.4 * s, height: (17.5 * s + stretchY * 0.65) * pulse2,
                                  tipX: leanX * 0.72 + sway2, bellyShift: leanX * 0.18 + sway2 * 0.25)
        innerFlame.path = flamePath(baseY: -4.0 * s, halfW: 3.5 * s, height: (10.5 * s + stretchY * 0.35) * pulse3,
                                    tipX: leanX * 0.42 + sway3, bellyShift: leanX * 0.10 + sway3 * 0.2)

        let glowPulse = 0.94 + 0.08 * sin(phase * 5.3) + 0.04 * cos(phase * 9.7)
        glow.opacity = Float(0.80 + 0.18 * sin(phase * 4.7) * cos(phase * 2.3))
        glow.setAffineTransform(CGAffineTransform(scaleX: glowPulse, y: glowPulse))
        coalGlow.opacity = Float(0.70 + 0.28 * (0.5 + 0.5 * sin(phase * 6.4)))
    }

    func remove() {
        root.removeFromSuperlayer()
        parent = nil
    }
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
    /// Everything we draw sits in these clips, which stop at the menu bar's bottom edge: the menu bar
    /// is translucent, so snow on a window just under it (or a falling flake) would show through it.
    let clip = CALayer(), backClip = CALayer()

    /// Offscreen overlay for the showcase renderer: same layers, no window.
    init(virtualFrame: CGRect) {
        frame = virtualFrame; screen = nil; window = nil; backWindow = nil
        root = CALayer(); backRoot = CALayer()
        for r in [root, backRoot] { r.frame = CGRect(origin: .zero, size: virtualFrame.size) }
        setUpClips(height: virtualFrame.height)
        setFlakesOnTop(Settings.shared.flakesOnTop)
    }

    static func makeWindow(_ screen: NSScreen, level: Int, behavior: NSWindow.CollectionBehavior) -> (NSWindow, CALayer) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                  // click-through: every click reaches what's below
        w.level = NSWindow.Level(rawValue: level)
        w.collectionBehavior = behavior
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
        // .transient: the window server hides it during Mission Control, in step with the animation
        // (windows there are scaled thumbnails, so snow on their old frames would float in mid-air)
        (window, root) = Overlay.makeWindow(screen, level: Int(CGWindowLevelForKey(.dockWindow)) + 1,
                                            behavior: [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle])
        // above the wallpaper and desktop icons, below every normal window
        // falling flakes over the wallpaper stay, Mission Control included
        (backWindow, backRoot) = Overlay.makeWindow(screen, level: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1,
                                                    behavior: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle])
        // visibleFrame also leaves out the Dock, but only its top edge (the menu bar) matters here
        setUpClips(height: min(screen.frame.height, screen.visibleFrame.maxY - screen.frame.minY))
        setFlakesOnTop(Settings.shared.flakesOnTop)
        window?.orderFrontRegardless()
    }

    private func setUpClips(height: CGFloat) {
        let full = root.bounds
        for (c, r) in [(clip, root), (backClip, backRoot)] {
            c.frame = CGRect(x: 0, y: 0, width: full.width, height: max(0, height))   // layers are y-up: clip the top
            c.masksToBounds = true
            r.addSublayer(c)
        }
        for l in [piles, actors] as [CALayer] { l.frame = full; clip.addSublayer(l) }
        flakeRoot.frame = full
    }

    /// Falling flakes in front of everything (old behaviour) or behind app windows (default).
    func setFlakesOnTop(_ top: Bool) {
        let parent = top ? clip : backClip
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

/// Water drips, splashes, and snapped icicle shards in the front overlay.
struct WaterDrop {
    enum Kind { case drop, splash, iceShard }
    let kind: Kind
    let layer: CALayer
    var pos: CGPoint
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    var angle: CGFloat = 0
    var spin: CGFloat = 0
    let source: UInt64
    var ttl: CGFloat = .infinity
    var maxTtl: CGFloat = 0.3
}

/// A snowman or a snowball sitting on a surface.
final class Prop {
    enum Kind { case snowman, ball }
    let kind: Kind
    let style: SnowmanStyle?
    let layer: CALayer
    let deco: CALayer?
    var scale: CGFloat
    var host: UInt64?
    var localX: CGFloat = 0
    var pos = CGPoint.zero     // global, bottom centre
    var vy: CGFloat = 0
    var vx: CGFloat = 0        // while falling off (shaken / host gone) or thrown
    var grounded = false
    var thrown = false
    let decoSide: CGFloat = Bool.random() ? 1 : -1
    weak var parent: CALayer?

    init(kind: Kind, scale: CGFloat, withBalls: Bool = false, style: SnowmanStyle? = nil) {
        self.kind = kind; self.scale = scale
        if kind == .snowman {
            let chosen = style ?? SnowmanStyle.random()
            self.style = chosen
            layer = makeSnowmanLayer(style: chosen)
        } else {
            self.style = nil
            layer = makeBallLayer()
        }
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
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    var active = false
    var cancelled = false
    init(prop: Prop, host: UInt64, at p: CGPoint, time: CFTimeInterval) {
        self.prop = prop; self.host = host; localX = prop.localX; pickup = prop.pos
        down = p; offset = CGSize(width: prop.pos.x - p.x, height: prop.pos.y - p.y)
        lastPoint = p; lastTime = time
    }
    func position(at p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.width, y: p.y + offset.height) }
}

/// Melted snow flowing down as glistening sky-blue water droplets / trickling streams.
struct MeltDrop {
    let layer: CALayer
    var pos: CGPoint
    var vx: CGFloat
    var vy: CGFloat
    var width: CGFloat
    var cling: CGFloat          // > 0: clinging trickle slowly sliding down edge before falling
    let source: UInt64
    let fromDock: Bool
    let isSplash: Bool
    var ttl: CGFloat            // finite for splash droplets, .infinity for falling drops
    let maxTTL: CGFloat
}

/// Glowing ember spark rising from the campfire cursor.
struct CampfireSpark {
    let layer: CALayer
    var pos: CGPoint
    var vx: CGFloat
    var vy: CGFloat
    var age: CGFloat
    let life: CGFloat
    let phase: CGFloat
}

/// Faint translucent white steam puff rising from actively melting snow.
struct CampfireSteam {
    let layer: CALayer
    var pos: CGPoint
    var vx: CGFloat
    var vy: CGFloat
    var age: CGFloat
    let life: CGFloat
    let baseSize: CGFloat
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
    var waterDrops: [WaterDrop] = []
    var props: [Prop] = []
    var plows: [Plow] = []
    var roll: Roll?
    var carry: Carry?
    var campfireVisual: CampfireVisual?
    var campfirePoint: CGPoint?
    var campfireLastPoint: CGPoint?
    var campfireVel: CGPoint = .zero
    var campfirePhase: CGFloat = 0
    var campfireMelting = false
    var meltDrops: [MeltDrop] = []
    var meltDropPool: [CALayer] = []
    var campfireSparks: [CampfireSpark] = []
    var sparkPool: [CALayer] = []
    var campfireSteams: [CampfireSteam] = []
    var steamPool: [CALayer] = []
    var meltWaterDebt: CGFloat = 0
    var sparkDebt: CGFloat = 0
    var lastSteam: CFTimeInterval = -.infinity
    var timer: Timer?
    var interval: Double = 0
    var paused = false
    var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    var onAC = true
    var powerSource: CFRunLoopSource?
    var lastMelt = CACurrentMediaTime()
    var mouseMoveMonitor: Any?
    var mouseMoveMask: NSEvent.EventTypeMask = []
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
    var lastGeometryChange: CFTimeInterval = -.infinity
    var lastGeometryPoll: CFTimeInterval = -.infinity
    lazy var lastRelax = clock()
    lazy var lastPrune = clock()
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

    /// Shake detection for a title-bar drag: fast strokes that suddenly turn around. Per axis we keep the
    /// fastest speed of the current stroke (decaying, so a slow drift doesn't count); a reversal after a
    /// fast stroke is a jolt, and the stroke's velocity is what the snow keeps going with (inertia).
    struct Shake {
        var p: CGPoint, t: CFTimeInterval
        var v = CGPoint.zero              // smoothed window velocity, pt/s
        var peak = CGPoint.zero           // fastest signed speed of the current stroke, per axis
        var jolts: [CFTimeInterval] = []
        var shed = 0                      // jolts that shook snow off during this drag
    }
    var shake: Shake?
    var shakeJolts = 0, shakeSheds = 0, dragCount = 0       // debug counters (dump)
    static let shakeSpeed: CGFloat = 650     // pt/s a stroke must reach before turning around
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
    struct SavedProp: Codable { var snowman: Bool; var scale: Double; var host: UInt64; var localX: Double; var balls: Bool; var style: SnowmanStyle? = nil }
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
            return SavedProp(snowman: m.kind == .snowman, scale: Double(m.scale), host: h, localX: Double(m.localX), balls: m.deco != nil, style: m.style)
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
            let m = Prop(kind: sp.snowman ? .snowman : .ball, scale: CGFloat(sp.scale), withBalls: sp.balls, style: sp.style)
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
        startExposeWatch()
        updateRate()
        if Engine.shouldSleep() { setPaused(true) }
    }

    // MARK: Mission Control
    // The front overlay is .transient, so the window server itself hides the snow on windows during
    // Mission Control. Its occlusion change is our (event-driven) cue to re-read the window list, where
    // Mission Control's shield window tells us to freeze the geometry: windows are shrunk thumbnails then.
    var occlusionObserver: Any?
    var exposeChecks: [DispatchWorkItem] = []
    var exposeAt: CFTimeInterval = 0
    var occlusionEvents = 0, geometryReads = 0

    func startExposeWatch() {
        guard virtualNow == nil, occlusionObserver == nil else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                   object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, self.overlays.contains(where: { $0.window === w }) else { return }
            self.occlusionEvents += 1
            // the shield can appear a moment after the occlusion change: look now and twice more
            self.exposeChecks.forEach { $0.cancel() }
            self.exposeChecks = [0, 0.15, 0.4].map { delay in
                let item = DispatchWorkItem { [weak self] in
                    guard let self, !self.paused else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.refreshGeometry()
                    CATransaction.commit()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return item
            }
        }
    }

    /// Tick only as fast as needed: 60 Hz while the mouse is down (drag / rolling),
    /// 30 Hz while something animates on the CPU side, 4 Hz for snowfall,
    /// 2–4 Hz when only resting snow has to follow windows, 1 Hz otherwise, and nothing while paused.
    func desiredInterval() -> Double? {
        if paused { return nil }
        if mouseIsDown || forceFast { return lowPower ? 1.0 / 30 : 1.0 / 60 }
        if roll != nil || !plows.isEmpty || !spills.isEmpty || !waterDrops.isEmpty || props.contains(where: { !$0.grounded }) { return 1.0 / 30 }
        if (Settings.shared.campfireOn && !expose) || !meltDrops.isEmpty || !campfireSparks.isEmpty || !campfireSteams.isEmpty {
            return lowPower ? 1.0 / 20 : 1.0 / 30
        }
        if Settings.shared.snowOn || !flakes.isEmpty { return 1.0 / 4 }
        if !props.isEmpty || piles.values.contains(where: { $0.mean > 0.05 }) { return clock() - lastGeometryChange < 2 ? 1.0 / 4 : 1.0 / 2 }
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
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                if n != NSWorkspace.didActivateApplicationNotification { DockGeometry.invalidate() }   // Dock width changes
                guard let self else { return }
                self.lastGeometryChange = self.clock()
                self.refreshGeometry()
            }
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
        campfireVel = .zero; campfireLastPoint = nil
        pauseWatch?.invalidate(); pauseWatch = nil
        if p {
            // every 2 s while paused: resume if we are actually unlocked and awake
            pauseWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                if !Engine.shouldSleep() { self?.setPaused(false) }
            }
            pauseWatch?.tolerance = 1
        }
        if p { dropAllFlakes() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        campfireVisual?.root.isHidden = !Settings.shared.campfireOn || paused || expose
        for o in overlays { o.root.speed = p ? 0 : 1 }   // freezes plow beacon etc. on the GPU side too
        CATransaction.commit()
        updateRate()
    }

    func dropAllFlakes() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for f in flakes { f.layer.removeAllAnimations(); f.layer.removeFromSuperlayer(); flakePool.append(f.layer) }
        for f in spills { f.layer.removeFromSuperlayer(); f.layer.opacity = 1; flakePool.append(f.layer) }
        for d in meltDrops { d.layer.removeFromSuperlayer(); d.layer.opacity = 1; meltDropPool.append(d.layer) }
        for sp in campfireSparks { sp.layer.removeFromSuperlayer(); sp.layer.opacity = 1; sparkPool.append(sp.layer) }
        for st in campfireSteams { st.layer.removeFromSuperlayer(); st.layer.opacity = 1; steamPool.append(st.layer) }
        spills.removeAll()
        for d in waterDrops { d.layer.removeFromSuperlayer() }
        waterDrops.removeAll()
        meltDrops.removeAll()
        campfireSparks.removeAll()
        campfireSteams.removeAll()
        meltWaterDebt = 0; sparkDebt = 0
        CATransaction.commit()
        flakes.removeAll()
    }

    func rebuildOverlays() {
        for o in overlays { o.window?.orderOut(nil); o.backWindow?.orderOut(nil) }
        dropAllFlakes()
        campfireVisual?.remove()
        campfireVisual = nil
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        if expose { for o in overlays { o.clip.opacity = 0 } }
        pileViews.removeAll()
        for p in props { p.remove(); p.parent = nil }
        for p in plows { p.layer.removeFromSuperlayer(); p.mound.removeFromSuperlayer() }
        plows.removeAll()
        pileDirty = true
    }

    func applySettings() {
        updateMouseMoveMonitor()
        lastMelt = clock()
        for v in pileViews.values { v.icicles.isHidden = !Settings.shared.meltOn }
        if !Settings.shared.snowmenOn { removeAllProps() }
        if Settings.shared.campfireOn {
            rollCancel()
            if virtualNow == nil { campfirePoint = NSEvent.mouseLocation }
        } else {
            campfireVel = .zero; campfireLastPoint = nil; campfireMelting = false
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        campfireVisual?.root.isHidden = !Settings.shared.campfireOn || paused || expose
        for o in overlays { o.setFlakesOnTop(Settings.shared.flakesOnTop) }
        CATransaction.commit()
        updateRate()
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
        lastGeometryPoll = clock()
        var list = windowSource.fetch()
        geometryReads += 1
        setExpose(windowSource.exposeActive)
        // Mission Control: windows are shrunk thumbnails; keep the real geometry (and the snow) as it was
        if expose { return }
        // while a title-bar drag is followed by prediction, the list's (older) frame mustn't pull it back
        if let d = drag, d.confirmed, let i = list.firstIndex(where: { $0.id == d.id }),
           let cur = wins.first(where: { $0.id == d.id }) {
            list[i] = Win(id: d.id, frame: cur.frame, z: list[i].z, surface: list[i].surface)
        }
        applyWins(list)
    }

    /// Mission Control is up: fade all the snow on windows / the Dock out, and back in when it closes.
    var expose = false
    func setExpose(_ on: Bool) {
        guard on != expose else { return }
        expose = on; exposeAt = CACurrentMediaTime()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        campfireVisual?.root.isHidden = !Settings.shared.campfireOn || paused || expose
        for o in overlays { fadeClip(o) }
        CATransaction.commit()
        updateRate()
    }
    func fadeClip(_ o: Overlay) {
        let to: Float = expose ? 0 : 1
        guard o.clip.opacity != to else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = o.clip.presentation()?.opacity ?? o.clip.opacity
        a.toValue = to; a.duration = expose ? 0.06 : 0.3
        o.clip.opacity = to
        o.clip.add(a, forKey: "fade")
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
        if !list.elementsEqual(wins, by: { $0.id == $1.id && $0.frame == $1.frame && $0.z == $1.z && $0.surface == $1.surface }) {
            lastGeometryChange = clock()
        }
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
            lastGeometryChange = clock()
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
        // ~8 Hz; otherwise the full list ~4 Hz after geometry changes, ~2 Hz when settled
        if let d = drag, d.confirmed {
            if tickCount % 4 == 0 { reconcileDrag() }          // ~15 Hz check against the window list
            if tickCount % 8 == 0 { refreshGeometry() }
        } else if mouseIsDown || forceFast {
            if tickCount % 8 == 0 { refreshGeometry() } else { refreshDragged() }
        } else if now - lastGeometryPoll >= (now - lastGeometryChange < 2 ? 0.25 : 0.5) { refreshGeometry() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if virtualNow == nil, !paused, now - lastMelt >= 2 {
            let elapsed = now - lastMelt; lastMelt = now
            meltStep(seconds: elapsed)
        }
        updateFlakes(dt: dt, now: now)
        updateSpills(dt: dt)
        updateWaterDrops(dt: dt)
        updateCampfire(dt: dt, now: now)
        // every ~10 ticks while fast (drag / animations, as before), at most every 1.25 s when slow
        if now - lastRelax >= min(1.25, 10 * Double(dt)) {
            lastRelax = now
            for p in piles.values where p.mean > 0.05 { if p.relax() { pileDirty = true } }
        }
        if virtualNow == nil, now - lastSave > 30 { saveState() }
        if now - lastPrune >= min(15, 120 * Double(dt)) {
            lastPrune = now
            let cutoff = Date().addingTimeInterval(-3), keepFor = Date().addingTimeInterval(-6 * 3600)
            piles = piles.filter {
                surfaces[$0.key] != nil || $0.value.lastSeen > cutoff || ($0.value.lastSeen > keepFor && hostAlive($0.key))
            }
        }
        updatePlows(dt: dt, now: now)
        updateProps(dt: dt)
        updateRoll()
        // pile paths: immediately when windows move, ~20 Hz while campfire melts, otherwise ~2.5 Hz
        let pileInterval: CFTimeInterval = campfireMelting ? 0.05 : 0.4
        if geometryChanged || (pileDirty && now - lastPileDraw > pileInterval) {   // moves: cheap re-position
            redrawPiles(); pileDirty = false; geometryChanged = false; lastPileDraw = now
        }
        CATransaction.commit()
        updateRate()
    }

    func updateMouseMoveMonitor() {
        var want: NSEvent.EventTypeMask = []
        if Settings.shared.windOn || Settings.shared.meltOn || Settings.shared.campfireOn { want.insert(.mouseMoved) }
        if Settings.shared.campfireOn { want.insert(.rightMouseDragged) }
        if want == mouseMoveMask { return }
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
        mouseMoveMask = want
        if !Settings.shared.windOn && !Settings.shared.meltOn { windPoint = nil }
        guard !want.isEmpty else { return }
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: want) { [weak self] ev in
            let p = NSEvent.mouseLocation
            if ev.type == .mouseMoved { self?.mouseWind(at: p) }
            if Settings.shared.campfireOn { self?.updateCampfirePointer(at: p) }
        }
    }

    func mouseWind(at p: CGPoint) {
        let windOn = Settings.shared.windOn, meltOn = Settings.shared.meltOn
        guard (windOn || meltOn), !paused else { return }
        let hasIcicles = meltOn && piles.values.contains { $0.icicles.contains { $0.length >= 2 * S } }
        if !windOn && !hasIcicles { windPoint = nil; return }
        let now = clock(), previous = windPoint, elapsed = now - windTime
        windPoint = p; windTime = now
        guard let q = previous, elapsed > 0, elapsed < 0.2,
              !(mouseIsDown && (roll != nil || carry != nil || drag != nil)) else { return }
        let velocity = CGPoint(x: (p.x - q.x) / CGFloat(elapsed), y: (p.y - q.y) / CGFloat(elapsed))
        let speed = hypot(velocity.x, velocity.y)
        if hasIcicles, speed > 350 {
            swipeIcicles(from: q, to: p, velocity: velocity)
        }
        guard windOn, !gustPending, now - lastGust >= 1.0 / 15 else { return }
        let strength: CGFloat = [0.7, 1, 1.4][Settings.shared.windStrength]
        guard speed > 1200 / strength else { return }
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
            f.layer.removeAnimation(forKey: "fall"); f.layer.removeAnimation(forKey: "sway")
            f.layer.position = CGPoint(x: x - o.frame.minX, y: virtualNow == nil ? endY - o.frame.minY : current.y)
            if virtualNow == nil {
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.fromValue = current.y; fall.toValue = endY - o.frame.minY; fall.duration = duration
                f.layer.add(fall, forKey: "fall")
                let push = CABasicAnimation(keyPath: "position.x")
                push.fromValue = current.x; push.toValue = x - o.frame.minX; push.duration = 0.18
                push.timingFunction = CAMediaTimingFunction(name: .easeOut)
                f.layer.add(push, forKey: "wind")
                addSway(f.layer, duration: duration)
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

    func layoutIcicles(on surf: Surface, pile: Pile) {
        let width = surf.width / S
        guard pile.icicleLayoutWidth != width else { return }
        pile.icicleLayoutWidth = width
        var seed = surf.key
        func sample(_ range: ClosedRange<CGFloat>) -> CGFloat {
            // SplitMix64 keeps the layout stable as the window moves or reveals more sites on resize.
            seed &+= 0x9e3779b97f4a7c15
            var value = seed
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            let fraction = CGFloat(value >> 40) / 16_777_216
            return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        }

        var sites: [Icicle] = []
        var x = sample(16...45)
        let limit = width - 12
        while x < limit {
            let count = Int(sample(1...5))
            let longest = Int(sample(0...CGFloat(count)))
            for index in 0..<count {
                guard x < limit else { break }
                let cap = index == longest ? sample(11...27) : sample(3...13)
                sites.append(Icicle(x: x * S, cap: cap * S, girth: sample(0.8...1.35),
                                    lean: sample(-0.65...0.65)))
                if index + 1 < count { x += sample(5...16) }
            }
            x += sample(27...96)
        }
        for index in 0..<min(sites.count, pile.icicles.count) {
            sites[index].length = pile.icicles[index].length
        }
        pile.icicles = sites
        pile.icicleDirty = true
    }

    /// Explicit calls also drive the debug and virtual-desktop melt scenes.
    func meltStep(seconds: CFTimeInterval) {
        guard Settings.shared.meltOn, !paused, seconds > 0 else { return }
        let amount = [CGFloat(0.4), 1.2, 3.0][Settings.shared.meltSpeed] * S * CGFloat(seconds) / 60
        let dripChance = min(0.35, CGFloat(seconds) * 0.015 * [CGFloat(0.6), 1.0, 1.8][Settings.shared.meltSpeed])
        var dripTips: [(pos: CGPoint, source: UInt64)] = []
        for (key, pile) in piles where Date().timeIntervalSince(pile.created) >= 180 {
            guard pile.heights.contains(where: { $0 > 0 }) || pile.icicles.contains(where: { $0.length > 0 }) else { continue }
            let before = pile.heights
            for i in pile.heights.indices { pile.heights[i] = max(0, pile.heights[i] - amount) }
            pile.dirty = true; pileDirty = true
            guard key < Engine.dockKey(0), let surf = surfaces[key] else { continue }
            layoutIcicles(on: surf, pile: pile)
            let empty = !before.contains { $0 > 0.05 }
            for i in pile.icicles.indices {
                let site = pile.icicles[i], bin = min(before.count - 1, pile.index(site.x))
                guard bin >= 0 else { continue }
                let old = site.length
                var activeMelt = false
                if empty {
                    pile.icicles[i].length = max(0, old - amount * 2)
                    activeMelt = old > 0
                } else if before[bin] > 0, isVisible(key, surf.minX + site.x) {
                    let growth = (before[bin] - pile.heights[bin]) * site.cap / (4 * S)
                    pile.icicles[i].length = min(site.cap, old + growth)
                    activeMelt = true
                }
                if old != pile.icicles[i].length { pile.icicleDirty = true }
                let length = pile.icicles[i].length
                if activeMelt, length >= 5 * S, site.x < surf.width - 12 * S,
                   isVisible(key, surf.minX + site.x), dripTips.count < 8,
                   CGFloat.random(in: 0..<1) < dripChance {
                    let half = min(2.2 * S, length * 0.18) * site.girth
                    let tip = CGPoint(x: surf.minX + site.x + half * site.lean, y: surf.top - length)
                    if !wins.contains(where: { $0.z < surf.z && $0.frame.contains(tip) }) {
                        dripTips.append((pos: tip, source: key))
                    }
                }
            }
        }
        if !dripTips.isEmpty, !overlays.isEmpty {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for tip in dripTips { spawnWaterDrop(at: tip.pos, source: tip.source) }
            CATransaction.commit()
            updateRate()
        }
    }

    func iciclePath(_ surf: Surface, _ pile: Pile) -> CGPath {
        let path = CGMutablePath()
        guard surf.z >= 0 else { return path }
        for site in pile.icicles where site.length > 0 {
            let x = site.x, length = site.length
            guard x < surf.width - 12 * S, isVisible(surf.key, surf.minX + x) else { continue }
            let half = min(2.2 * S, length * 0.18) * site.girth
            let tip = CGPoint(x: x + half * site.lean, y: -length)
            path.move(to: CGPoint(x: x - half, y: 0))
            path.addQuadCurve(to: tip, control: CGPoint(x: tip.x - half * 0.4, y: -length * 0.65))
            path.addQuadCurve(to: CGPoint(x: x + half, y: 0),
                              control: CGPoint(x: tip.x + half * 0.5, y: -length * 0.55))
            path.closeSubpath()
        }
        return path
    }

    func icicleHit(at p: CGPoint, pad: CGFloat = 4 * S) -> (key: UInt64, index: Int)? {
        guard Settings.shared.meltOn, !paused else { return nil }
        for surf in surfaces.values.filter({ $0.z >= 0 }).sorted(by: { $0.z < $1.z }) {
            guard let pile = piles[surf.key], !pile.icicles.isEmpty else { continue }
            guard p.x >= surf.minX - pad, p.x <= surf.maxX + pad,
                  p.y >= surf.top - 32 * S - pad, p.y <= surf.top + min(pad, 2.5 * S) else { continue }
            guard !wins.contains(where: { $0.z < surf.z && $0.frame.contains(p) }) else { continue }
            var best: (index: Int, dist: CGFloat)?
            for i in pile.icicles.indices {
                let site = pile.icicles[i]
                guard site.length >= 2 * S, site.x < surf.width - 12 * S else { continue }
                let gx = surf.minX + site.x
                guard isVisible(surf.key, gx) else { continue }
                let half = min(2.2 * S, site.length * 0.18) * site.girth
                let tipX = gx + half * site.lean
                let minX = min(gx - half, tipX) - pad
                let maxX = max(gx + half, tipX) + pad
                let minY = surf.top - site.length - pad
                let maxY = surf.top + min(pad, 2.5 * S)
                guard p.x >= minX, p.x <= maxX, p.y >= minY, p.y <= maxY else { continue }
                let dist = hypot(p.x - (gx + tipX) * 0.5, p.y - (surf.top - site.length * 0.5))
                if best == nil || dist < best!.dist { best = (i, dist) }
            }
            if let best { return (surf.key, best.index) }
        }
        return nil
    }

    func snapIcicle(on key: UInt64, index: Int, vx: CGFloat = 0, vy: CGFloat = 0) {
        guard let surf = surfaces[key], let pile = piles[key], pile.icicles.indices.contains(index) else { return }
        let site = pile.icicles[index]
        guard site.length >= 2 * S else { return }
        let length = site.length
        pile.icicles[index].length = 0
        pile.icicleDirty = true; pileDirty = true
        lastPileDraw = -.infinity
        guard !overlays.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spawnIceShard(on: surf, site: site, length: length, vx: vx, vy: vy)
        let breakPt = CGPoint(x: surf.minX + site.x, y: surf.top - min(2 * S, length * 0.15))
        spawnWaterSplash(at: breakPt, count: Int.random(in: 2...3), icy: true, source: key, baseVx: vx * 0.35)
        CATransaction.commit()
        updateRate()
    }

    private func segmentIntersectsRect(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> CGPoint? {
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        for (p, q) in [(-dx, a.x - r.minX), (dx, r.maxX - a.x), (-dy, a.y - r.minY), (dy, r.maxY - a.y)] {
            if abs(p) < 1e-6 {
                if q < 0 { return nil }
            } else {
                let ratio = q / p
                if p < 0 { t0 = max(t0, ratio) } else { t1 = min(t1, ratio) }
                if t0 > t1 { return nil }
            }
        }
        let t = (t0 + t1) * 0.5
        return CGPoint(x: a.x + dx * t, y: a.y + dy * t)
    }

    func swipeIcicles(from q: CGPoint, to p: CGPoint, velocity: CGPoint) {
        guard Settings.shared.meltOn, !paused, !overlays.isEmpty else { return }
        let pad = 4 * S
        let segMinX = min(q.x, p.x) - pad, segMaxX = max(q.x, p.x) + pad
        let segMinY = min(q.y, p.y) - pad, segMaxY = max(q.y, p.y) + pad
        let vx = max(-420 * S, min(420 * S, velocity.x * 0.28))
        let vy = max(-100 * S, min(140 * S, velocity.y * 0.1 + 30 * S))
        for (key, surf) in surfaces where surf.z >= 0 {
            guard segMaxX >= surf.minX, segMinX <= surf.maxX,
                  segMaxY >= surf.top - 32 * S, segMinY <= surf.top + 2.5 * S else { continue }
            guard let pile = piles[key], !pile.icicles.isEmpty else { continue }
            for i in pile.icicles.indices {
                let site = pile.icicles[i]
                guard site.length >= 2 * S, site.x < surf.width - 12 * S else { continue }
                let gx = surf.minX + site.x
                guard isVisible(key, gx) else { continue }
                let half = min(2.2 * S, site.length * 0.18) * site.girth
                let tipX = gx + half * site.lean
                let rect = CGRect(x: min(gx - half, tipX) - pad, y: surf.top - site.length - pad,
                                  width: abs(half * site.lean) + 2 * half + 2 * pad,
                                  height: site.length + pad + min(pad, 2.5 * S))
                guard let hit = segmentIntersectsRect(q, p, rect) else { continue }
                guard !wins.contains(where: { $0.z < surf.z && $0.frame.contains(hit) }) else { continue }
                snapIcicle(on: key, index: i, vx: vx, vy: vy)
            }
        }
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
                // depth: small flakes read as far away, so they fall slower and fainter (parallax)
                let depth = CGFloat.random(in: 0...1)
                let r = (1.3 + 1.4 * depth) * S
                let v = (48 + 30 * depth + .random(in: -5...5)) * (0.85 + 0.15 * S)
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
                layer.opacity = Float(0.62 + 0.38 * depth)
                layer.position = CGPoint(x: x - f.minX, y: endY - f.minY)
                o.flakeRoot.addSublayer(layer)
                CATransaction.commit()
                if virtualNow == nil {
                    let a = CABasicAnimation(keyPath: "position.y")
                    a.fromValue = startY - f.minY
                    a.toValue = endY - f.minY
                    a.duration = dur
                    layer.add(a, forKey: "fall")
                    addSway(layer, duration: dur)
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

    /// Flutter: a slow side-to-side drift added on top of the straight fall (GPU, additive). It is zero
    /// at both ends, so the flake still lands exactly where its landing spot was chosen.
    func addSway(_ layer: CALayer, duration: Double) {
        guard virtualNow == nil, duration > 0.4 else { return }
        let amp = CGFloat.random(in: 2.5...8) * S
        let w = 2 * CGFloat.pi / CGFloat.random(in: 2.2...4.6), ph = CGFloat.random(in: 0...(2 * .pi))
        let D = CGFloat(duration), n = min(48, max(6, Int(duration * 2.5)))   // cubic: ≥5 keys per sway period
        let endOff = sin(w * D + ph) - sin(ph)
        let sway = CAKeyframeAnimation(keyPath: "position.x")
        sway.values = (0...n).map { i -> CGFloat in
            let t = D * CGFloat(i) / CGFloat(n)
            return amp * (sin(w * t + ph) - sin(ph) - endOff * t / D)
        }
        sway.calculationMode = .cubic
        sway.isAdditive = true
        sway.duration = duration
        layer.add(sway, forKey: "sway")
    }

    func flakeLayer() -> CALayer {
        if let l = flakePool.popLast() { l.opacity = 1; return l }
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
        snowPuff(for: m, baseY: s.top, source: s.key)
    }

    private func snowPuff(for m: Prop, baseY: CGFloat, source: UInt64) {
        guard !overlays.isEmpty else { return }
        let count = m.kind == .snowman ? 26 : 12
        let w = m.halfWidth, h = m.height * 0.7
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for _ in 0..<count {
            let pos = CGPoint(x: m.pos.x + .random(in: -w...w), y: baseY + .random(in: 0...h))
            let o = overlays[overlayIndex(for: pos)]
            let layer = flakeLayer()
            let r = CGFloat.random(in: 1.2...2.6) * S
            layer.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            layer.cornerRadius = r; layer.position = o.local(pos)
            o.actors.addSublayer(layer)
            let dir: CGFloat = pos.x < m.pos.x ? -1 : 1
            spills.append(Spill(layer: layer, pos: pos, vy: .random(in: 60...260) * S, vx: dir * .random(in: 30...170) * S,
                                area: 0, source: source, fromDock: true, ttl: .random(in: 0.4...0.6)))
        }
        CATransaction.commit()
        updateRate()
    }

    /// `toss`: the velocity the snow had when it came loose (a shaken window); nil = it just crumbles off.
    func spillSnow(_ samples: [(x: CGFloat, y: CGFloat, area: CGFloat)], from surf: Surface, toss: CGPoint? = nil) {
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
            var vx = CGFloat.random(in: -25...25) * S, vy = CGFloat.random(in: -20...40) * S
            if let t = toss {
                vx = max(-520 * S, min(520 * S, t.x * .random(in: 0.2...0.55))) + .random(in: -35...35) * S
                vy = max(-200 * S, min(420 * S, t.y * .random(in: 0.2...0.45))) + .random(in: 50...170) * S
            }
            spills.append(Spill(layer: layer, pos: pos, vy: vy, vx: vx,
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

    func spawnWaterDrop(at pos: CGPoint, source: UInt64) {
        guard waterDrops.count < 140, !overlays.isEmpty else { return }
        let r = CGFloat.random(in: 1.35...1.85) * S
        let h = r * 2.7
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r, y: h))
        path.addQuadCurve(to: CGPoint(x: 2 * r, y: r), control: CGPoint(x: 1.95 * r, y: h * 0.52))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 2 * r, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0.05 * r, y: h * 0.52))
        path.closeSubpath()
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: h)
        layer.path = path
        layer.fillColor = CGColor(srgbRed: 150 / 255, green: 215 / 255, blue: 1, alpha: 0.85)
        layer.strokeColor = CGColor(srgbRed: 215 / 255, green: 240 / 255, blue: 1, alpha: 0.7)
        layer.lineWidth = 0.4
        layer.contentsScale = 2
        let o = overlays[overlayIndex(for: pos)]
        layer.position = o.local(pos)
        o.actors.addSublayer(layer)
        waterDrops.append(WaterDrop(kind: .drop, layer: layer, pos: pos,
                                    vx: .random(in: -4...4) * S, vy: -10 * S, source: source))
    }

    func spawnIceShard(on surf: Surface, site: Icicle, length: CGFloat, vx: CGFloat = 0, vy: CGFloat = 0) {
        guard waterDrops.count < 140, !overlays.isEmpty else { return }
        let half = min(2.2 * S, length * 0.18) * site.girth
        let pad = abs(half * site.lean) + 1
        let cx = half + pad
        let path = CGMutablePath()
        let tip = CGPoint(x: cx + half * site.lean, y: 0)
        path.move(to: CGPoint(x: cx - half, y: length))
        path.addQuadCurve(to: tip, control: CGPoint(x: tip.x - half * 0.4, y: length * 0.35))
        path.addQuadCurve(to: CGPoint(x: cx + half, y: length),
                          control: CGPoint(x: tip.x + half * 0.5, y: length * 0.45))
        path.closeSubpath()
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: cx * 2, height: length)
        layer.path = path
        layer.fillColor = NSColor(calibratedRed: 230 / 255, green: 244 / 255, blue: 1, alpha: 0.88).cgColor
        layer.strokeColor = NSColor(calibratedRed: 191 / 255, green: 227 / 255, blue: 1, alpha: 0.92).cgColor
        layer.lineWidth = 0.5
        layer.contentsScale = 2
        let pos = CGPoint(x: surf.minX + site.x + half * site.lean * 0.5, y: surf.top - length * 0.5)
        let o = overlays[overlayIndex(for: pos)]
        layer.position = o.local(pos)
        o.actors.addSublayer(layer)
        let dir: CGFloat = vx != 0 ? (vx > 0 ? -1 : 1) : (Bool.random() ? 1 : -1)
        let spin = dir * CGFloat.random(in: 5...11)
        waterDrops.append(WaterDrop(kind: .iceShard, layer: layer, pos: pos, vx: vx, vy: vy,
                                    spin: spin, source: surf.key))
    }

    func spawnWaterSplash(at pos: CGPoint, count: Int, icy: Bool, source: UInt64, baseVx: CGFloat = 0) {
        guard !overlays.isEmpty else { return }
        for _ in 0..<count {
            guard waterDrops.count < 140 else { break }
            let layer = CALayer()
            let r = (icy ? CGFloat.random(in: 0.85...1.6) : CGFloat.random(in: 0.75...1.3)) * S
            layer.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            layer.cornerRadius = r
            if icy {
                layer.backgroundColor = CGColor(srgbRed: 235 / 255, green: 247 / 255, blue: 1, alpha: 0.96)
                layer.borderColor = CGColor(srgbRed: 175 / 255, green: 225 / 255, blue: 1, alpha: 0.85)
                layer.borderWidth = 0.4
            } else {
                layer.backgroundColor = CGColor(srgbRed: 170 / 255, green: 225 / 255, blue: 1, alpha: 0.92)
            }
            let o = overlays[overlayIndex(for: pos)]
            layer.position = o.local(pos)
            o.actors.addSublayer(layer)
            let ttl = CGFloat.random(in: 0.22...0.38)
            let vx = baseVx + (icy ? CGFloat.random(in: -135...135) : CGFloat.random(in: -75...75)) * S
            let vy = (icy ? CGFloat.random(in: 65...175) : CGFloat.random(in: 55...135)) * S
            waterDrops.append(WaterDrop(kind: .splash, layer: layer, pos: pos, vx: vx, vy: vy,
                                        source: source, ttl: ttl, maxTtl: ttl))
        }
    }

    func updateWaterDrops(dt: CGFloat) {
        guard !waterDrops.isEmpty else { return }
        let bottom = (overlays.map { $0.frame.minY }.min() ?? 0) - 20 * S
        var kept: [WaterDrop] = []
        var pendingSplashes: [(pos: CGPoint, count: Int, icy: Bool, source: UInt64, baseVx: CGFloat)] = []
        for var d in waterDrops {
            let oldY = d.pos.y
            let g: CGFloat = d.kind == .iceShard ? 1100 * S : (d.kind == .drop ? 900 * S : 780 * S)
            d.vy -= g * dt
            d.pos.y += d.vy * dt
            d.pos.x += d.vx * dt
            if d.kind == .iceShard {
                d.angle += d.spin * dt
                d.layer.setAffineTransform(CGAffineTransform(rotationAngle: d.angle))
            }
            var landed = false
            if d.kind != .splash, d.pos.y < oldY,
               let s = landingSurface(at: d.pos.x, below: oldY, above: d.pos.y, excluding: d.source) {
                landed = true
                let hitPos = CGPoint(x: d.pos.x, y: s.top + 1 * S)
                if d.kind == .drop {
                    pendingSplashes.append((pos: hitPos, count: Int.random(in: 3...4), icy: false, source: s.key, baseVx: d.vx * 0.2))
                } else {
                    pendingSplashes.append((pos: hitPos, count: Int.random(in: 4...6), icy: true, source: s.key, baseVx: d.vx * 0.25))
                }
            }
            if d.kind == .splash {
                d.ttl -= dt
                d.vx *= 1 - min(1, 2.5 * dt)
                d.layer.opacity = Float(max(0, min(1, d.ttl / max(0.01, d.maxTtl))))
            }
            if landed || d.pos.y < bottom || (d.kind == .splash && d.ttl <= 0) {
                d.layer.removeFromSuperlayer()
            } else {
                let o = overlays[overlayIndex(for: d.pos)]
                if d.layer.superlayer !== o.actors { o.actors.addSublayer(d.layer) }
                d.layer.position = o.local(d.pos)
                kept.append(d)
            }
        }
        waterDrops = kept
        for sp in pendingSplashes {
            spawnWaterSplash(at: sp.pos, count: sp.count, icy: sp.icy, source: sp.source, baseVx: sp.baseVx)
        }
    }

    // MARK: piles

    static let windowCorner: CGFloat = 12

    /// Snow on one surface as a closed path (global coords): tapers to nothing over the last
    /// stretch and wraps over the rounded corner (on the Dock it tapers flat along the top).
    func pilePath(_ surf: Surface, _ pile: Pile) -> CGPath? {
        let width = surf.width
        guard width > 30 else { return nil }
        let isDock = surf.z < 0
        let R: CGFloat = isDock ? 0 : Engine.windowCorner
        let T = isDock ? max(14, 16 * S) : max(R + 4, 16 * S)   // taper length
        func drop(_ d: CGFloat) -> CGFloat { R <= 0 || d >= R ? 0 : R - (R * R - (R - d) * (R - d)).squareRoot() }
        func smooth(_ t: CGFloat) -> CGFloat { let u = max(0, min(1, t)); return u * u * (3 - 2 * u) }
        var tops: [CGPoint] = [], bots: [CGPoint] = []
        var x: CGFloat = 0
        while true {
            let cx = min(x, width)
            let d = min(cx, width - cx)
            let taper = smooth(d / T) * (isDock ? 1 : 0.35 + 0.65 * smooth(d / (R * 0.8)))
            let h = pile.height(at: cx) * taper
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
            let empty = (pile.mean <= 0.05 && !pile.icicles.contains { $0.length > 0 }) || (segments[k] ?? []).isEmpty
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
        let throwGravity: CGFloat = 1100 * S
        let lowest = (overlays.map { $0.frame.minY }.min() ?? 0) - 120
        let minX = (overlays.map { $0.frame.minX }.min() ?? 0) - 120
        let maxX = (overlays.map { $0.frame.maxX }.max() ?? 0) + 120
        var dead = Set<ObjectIdentifier>()

        for m in props where !(m.host == nil && m.thrown) {
            let mid = ObjectIdentifier(m)
            if let c = carry, c.active, c.prop === m { place(m); continue }
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
                continue
            } else {
                // the window it sat on is gone: fall straight down; poof on the Dock, else off screen
                m.host = nil; m.grounded = false
                let oldY = m.pos.y
                m.vy -= gravity * dt
                m.pos.y += m.vy * dt
                m.pos.x += m.vx * dt
                m.vx *= 1 - min(1, 0.6 * dt)
                if let d = orderedSurfaces.first(where: { $0.z < 0 && m.pos.x >= $0.minX && m.pos.x <= $0.maxX }) {
                    let g = d.top + (piles[d.key]?.height(at: m.pos.x - d.minX) ?? 0) * 0.5
                    if oldY >= g && m.pos.y <= g { m.pos.y = g; poof(m, on: d); dead.insert(mid); continue }
                }
                if m.pos.y < lowest { m.remove(); dead.insert(mid); continue }
            }
            place(m)
        }

        func hitRect(_ p: CGPoint, radius: CGFloat, _ t: Prop) -> Bool {
            let x = min(max(p.x, t.pos.x - t.halfWidth), t.pos.x + t.halfWidth)
            let y = min(max(p.y, t.pos.y), t.pos.y + t.height)
            return hypot(p.x - x, p.y - y) < radius
        }

        var hitSnowman = false
        for m in props where m.host == nil && m.thrown {
            let mid = ObjectIdentifier(m)
            if dead.contains(mid) { continue }
            if dt <= 0 { place(m); continue }
            let oldPos = m.pos
            m.vy -= throwGravity * dt
            m.vx *= 1 - min(1, 0.35 * dt)
            m.pos.x += m.vx * dt
            m.pos.y += m.vy * dt

            let oldCenter = CGPoint(x: oldPos.x, y: oldPos.y + m.scale)
            let newCenter = CGPoint(x: m.pos.x, y: m.pos.y + m.scale)
            let travel = hypot(newCenter.x - oldCenter.x, newCenter.y - oldCenter.y)
            let steps = max(1, Int(ceil(travel / max(4, m.scale))))
            var collided = false

            for stepIndex in 1...steps where !collided {
                let u = CGFloat(stepIndex) / CGFloat(steps)
                let probe = CGPoint(x: oldCenter.x + (newCenter.x - oldCenter.x) * u,
                                    y: oldCenter.y + (newCenter.y - oldCenter.y) * u)
                if let t = props.reversed().first(where: { t in
                    t.kind == .snowman && !t.layer.isHidden && !dead.contains(ObjectIdentifier(t)) &&
                        hitRect(probe, radius: m.scale + 2 * S, t)
                }) {
                    dead.insert(mid)
                    dead.insert(ObjectIdentifier(t))
                    m.pos = CGPoint(x: probe.x, y: probe.y - m.scale)
                    m.remove(); t.remove()
                    if let tk = t.host, let pile = piles[tk] {
                        let lx = surfaces[tk].map { t.pos.x - $0.minX } ?? t.localX
                        pile.deposit(at: lx, area: 0.25 * (13 * t.scale) * (50 * t.scale))
                        pileDirty = true
                    }
                    snowPuff(for: t, baseY: t.pos.y, source: t.host ?? 0)
                    snowPuff(for: m, baseY: m.pos.y, source: t.host ?? 0)
                    hitSnowman = true
                    collided = true
                } else if let t = props.reversed().first(where: { t in
                    t.kind == .ball && t !== m && !t.layer.isHidden && !dead.contains(ObjectIdentifier(t)) &&
                        hypot(probe.x - t.pos.x, probe.y - (t.pos.y + t.scale)) < m.scale + t.scale + 2 * S
                }) {
                    dead.insert(mid)
                    m.pos = CGPoint(x: probe.x, y: probe.y - m.scale)
                    m.remove()
                    snowPuff(for: m, baseY: m.pos.y, source: t.host ?? 0)
                    jump(t)
                    collided = true
                }
            }
            if collided { continue }

            if m.vy <= 0, let s = landingSurface(at: m.pos.x, below: oldPos.y, above: m.pos.y) {
                dead.insert(mid)
                m.pos.y = s.top
                poof(m, on: s)
                continue
            }
            if m.pos.y < lowest || (!overlays.isEmpty && (m.pos.x < minX || m.pos.x > maxX)) {
                dead.insert(mid)
                m.remove()
                continue
            }
            place(m)
        }

        if !dead.isEmpty { props.removeAll { dead.contains(ObjectIdentifier($0)) } }
        if hitSnowman { saveState() }
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
        m.host = c.host; m.localX = c.localX; m.pos = c.pickup; m.grounded = true; m.thrown = false; m.vx = 0; m.vy = 0
        m.layer.removeAnimation(forKey: "spin")
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
            c.prop.host = nil; c.prop.grounded = false; c.prop.thrown = false; c.prop.vx = 0; c.prop.vy = 0
            c.prop.layer.removeAnimation(forKey: "squash")
        }
        if elapsed > 0.12 {
            c.vx = 0; c.vy = 0
        } else if elapsed > 0.002 {
            let rvx = dx / CGFloat(elapsed), rvy = dy / CGFloat(elapsed)
            let alpha = min(CGFloat(1), CGFloat(elapsed) / 0.045)
            c.vx += (rvx - c.vx) * alpha
            c.vy += (rvy - c.vy) * alpha
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
        if clock() - c.lastTime > 0.12 { c.vx = 0; c.vy = 0 }
        let speed = hypot(c.vx, c.vy)
        if speed > 260 * S {
            m.host = nil
            m.grounded = false
            m.thrown = true
            m.vx = max(-1100 * S, min(1100 * S, c.vx * 0.85))
            m.vy = max(-600 * S, min(950 * S, c.vy * 0.85))
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.byValue = (m.vx >= 0 ? -1 : 1) * CGFloat.random(in: 4...8)
            spin.duration = 0.9
            spin.isAdditive = true
            spin.repeatCount = .infinity
            m.layer.add(spin, forKey: "spin")
            place(m)
            return
        }
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
        m.grounded = false; m.thrown = false; m.vx = 0; m.vy = 0
        place(m)
    }

    // MARK: snowball rolling

    /// mouse down: arm a roll if the press is on a visible pile band of a still window.
    func rollBegin(at p: CGPoint) {
        roll = nil
        guard Settings.shared.snowmenOn, !Settings.shared.campfireOn else { return }
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
        // (the window may have moved since the roll started: keep the ball's spot on the window)
        if r.shown, r.r > 5 * S, let surf = surfaces[r.key] {
            addProp(Prop(kind: .ball, scale: r.r), on: r.key, atX: surf.minX + r.localX, fromY: surf.top + r.r)
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

    // MARK: campfire

    func updateCampfirePointer(at p: CGPoint) {
        guard Settings.shared.campfireOn, p.x.isFinite, p.y.isFinite else { return }
        campfirePoint = p
        guard !paused, !expose, !overlays.isEmpty, let vis = campfireVisual else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let o = overlays[overlayIndex(for: p)]
        if vis.parent !== o.actors {
            vis.root.removeFromSuperlayer()
            o.actors.addSublayer(vis.root)
            vis.parent = o.actors
        }
        vis.root.isHidden = false
        vis.root.position = o.local(p)
        CATransaction.commit()
    }

    func updateCampfire(dt: CGFloat, now: CFTimeInterval) {
        updateCampfireSparks(dt: dt)
        updateMeltDrops(dt: dt)
        updateCampfireSteams(dt: dt)

        campfireMelting = false
        let active = Settings.shared.campfireOn && !paused && !expose && !overlays.isEmpty
        if !active {
            campfireVisual?.root.isHidden = true
            campfireVel = .zero
            campfireLastPoint = nil
            return
        }
        if virtualNow == nil {
            campfirePoint = NSEvent.mouseLocation
        }
        guard let p = campfirePoint, p.x.isFinite, p.y.isFinite else {
            campfireVisual?.root.isHidden = true
            return
        }

        if let prev = campfireLastPoint, dt > 0.001 {
            let raw = CGPoint(x: (p.x - prev.x) / dt, y: (p.y - prev.y) / dt)
            let alpha = min(1, dt * 14)
            campfireVel = CGPoint(x: campfireVel.x + (raw.x - campfireVel.x) * alpha,
                                  y: campfireVel.y + (raw.y - campfireVel.y) * alpha)
        } else {
            campfireVel = .zero
        }
        campfireLastPoint = p

        let vis = campfireVisual ?? CampfireVisual()
        campfireVisual = vis
        let o = overlays[overlayIndex(for: p)]
        if vis.parent !== o.actors {
            vis.root.removeFromSuperlayer()
            o.actors.addSublayer(vis.root)
            vis.parent = o.actors
        }
        vis.root.isHidden = false
        vis.root.position = o.local(p)
        campfirePhase += dt
        vis.update(phase: campfirePhase, velocity: campfireVel)

        // Rising ember sparks (capped at 25)
        sparkDebt += (lowPower ? 7 : 12) * dt
        while sparkDebt >= 1 {
            sparkDebt -= 1
            if campfireSparks.count >= 25 { sparkDebt = 0; break }
            spawnCampfireSpark(near: p, velocity: campfireVel)
        }

        // Heat melting within radius ~68 * S
        let radius = 68 * S
        let dropThreshold = 6.0 * S * S

        // 1) Snow piles & icicles
        for (key, surf) in surfaces {
            guard p.x >= surf.minX - radius, p.x <= surf.maxX + radius else { continue }
            guard let pile = piles[key], !pile.heights.isEmpty else { continue }

            if p.y >= surf.top - radius, p.y <= surf.top + Pile.maxH + radius {
                let firstBin = max(0, Int((p.x - radius - surf.minX) / Pile.step))
                let lastBin = min(pile.heights.count - 1, Int((p.x + radius - surf.minX) / Pile.step))
                if firstBin <= lastBin {
                    var surfMelted: CGFloat = 0
                    var spots: [CGFloat] = []
                    for i in firstBin...lastBin {
                        let h = pile.heights[i]
                        guard h > 0.01 else { continue }
                        let gx = surf.minX + min(surf.width, CGFloat(i) * Pile.step)
                        guard isVisible(key, gx) else { continue }
                        let dist = hypot(gx - p.x, (surf.top + h * 0.5) - p.y)
                        guard dist < radius else { continue }
                        let intensity = pow(1 - dist / radius, 1.4)
                        let melted = min(h, 11.5 * S * intensity * dt)
                        let nextH = h - melted
                        pile.heights[i] = nextH < 0.02 ? 0 : nextH
                        surfMelted += melted * Pile.step
                        spots.append(gx)
                    }
                    if surfMelted > 0 {
                        pile.dirty = true; pileDirty = true; campfireMelting = true
                        meltWaterDebt += surfMelted
                        while meltWaterDebt >= dropThreshold {
                            meltWaterDebt -= dropThreshold
                            let dropX = (spots.randomElement() ?? p.x) + .random(in: -2...2) * S
                            spawnMeltDrop(at: CGPoint(x: dropX, y: surf.top - 1 * S),
                                          source: key, fromDock: surf.z < 0,
                                          cling: .random(in: 0.14...0.30))
                        }
                        if now - lastSteam >= 0.14, let sx = spots.randomElement() {
                            lastSteam = now
                            spawnCampfireSteam(at: CGPoint(x: sx, y: surf.top + 3 * S))
                        }
                    }
                }
            }

            // 2) Visible icicles
            if Settings.shared.meltOn, surf.z >= 0,
               p.y >= surf.top - 40 * S - radius, p.y <= surf.top + radius,
               pile.icicles.contains(where: { $0.length > 0 }) {
                for i in pile.icicles.indices {
                    let site = pile.icicles[i]
                    guard site.length > 0, site.x < surf.width - 12 * S else { continue }
                    let gx = surf.minX + site.x
                    guard isVisible(key, gx) else { continue }
                    let tipY = surf.top - site.length
                    let midY = surf.top - site.length * 0.5
                    let dist = min(hypot(gx - p.x, tipY - p.y), hypot(gx - p.x, midY - p.y))
                    guard dist < radius else { continue }
                    let intensity = pow(1 - dist / radius, 1.4)
                    let shrink = min(site.length, 24 * S * intensity * dt)
                    let nextLen = site.length - shrink
                    pile.icicles[i].length = nextLen < 0.8 ? 0 : nextLen
                    pile.icicleDirty = true; pileDirty = true; campfireMelting = true
                    meltWaterDebt += shrink * 2.2 * S
                    while meltWaterDebt >= dropThreshold {
                        meltWaterDebt -= dropThreshold
                        spawnMeltDrop(at: CGPoint(x: gx, y: surf.top - pile.icicles[i].length),
                                      source: key, fromDock: false,
                                      cling: .random(in: 0.04...0.10))
                    }
                }
            }
        }

        // 3) Snowmen & snowballs
        if !props.isEmpty {
            var propMelted = false
            props.removeAll { m in
                if m.layer.isHidden { return false }
                if let c = carry, c.active, c.prop === m { return false }
                let cx = min(max(p.x, m.pos.x - m.halfWidth), m.pos.x + m.halfWidth)
                let cy = min(max(p.y, m.pos.y), m.pos.y + m.height)
                let dist = hypot(p.x - cx, p.y - cy)
                guard dist < radius else { return false }
                let intensity = pow(1 - dist / radius, 1.4)
                campfireMelting = true
                let shrink = (m.kind == .snowman ? 0.38 * S : 3.6 * S) * intensity * dt
                m.scale -= shrink
                let minScale = m.kind == .snowman ? 0.38 * S : 2.5 * S
                let source = m.host ?? 0
                let fromDock = source >= Engine.dockKey(0)
                if m.scale < minScale {
                    let basePos = m.pos
                    let halfW = m.halfWidth
                    let splashCount = m.kind == .snowman ? 10 : 6
                    let trickleCount = m.kind == .snowman ? 6 : 4
                    m.remove()
                    spawnWaterSplash(at: CGPoint(x: basePos.x, y: basePos.y + 2 * S), count: splashCount)
                    for _ in 0..<trickleCount {
                        spawnMeltDrop(at: CGPoint(x: basePos.x + .random(in: -halfW...halfW) * 0.8, y: basePos.y),
                                      source: source, fromDock: fromDock,
                                      cling: .random(in: 0.08...0.22))
                    }
                    propMelted = true
                    return true
                }
                let k = m.kind == .snowman ? m.scale : m.scale / 20
                m.layer.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
                if let d = m.deco {
                    let dk = min(S, m.scale)
                    d.setAffineTransform(CGAffineTransform(scaleX: dk, y: dk))
                }
                place(m)
                meltWaterDebt += (m.kind == .snowman ? shrink * 28 * S : shrink * 3.2 * S)
                while meltWaterDebt >= dropThreshold {
                    meltWaterDebt -= dropThreshold
                    spawnMeltDrop(at: CGPoint(x: m.pos.x + .random(in: -m.halfWidth...m.halfWidth) * 0.6, y: m.pos.y),
                                  source: source, fromDock: fromDock,
                                  cling: .random(in: 0.12...0.26))
                }
                if now - lastSteam >= 0.16 {
                    lastSteam = now
                    spawnCampfireSteam(at: CGPoint(x: m.pos.x, y: m.pos.y + m.height * 0.65))
                }
                return false
            }
            if propMelted { saveState() }
        }
    }

    private func meltDropLayer(splash: Bool) -> CALayer {
        let l = meltDropPool.popLast() ?? {
            let layer = CALayer()
            layer.zPosition = 50
            layer.contentsGravity = .resize
            return layer
        }()
        l.contents = splash ? CampfireAssets.splashImage : CampfireAssets.dropImage
        l.opacity = 1
        l.setAffineTransform(.identity)
        return l
    }

    private func recycleMeltDrop(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        layer.opacity = 1
        meltDropPool.append(layer)
    }

    func spawnMeltDrop(at pos: CGPoint, source: UInt64, fromDock: Bool, cling: CGFloat) {
        guard !overlays.isEmpty, meltDrops.count < 140 else { return }
        let layer = meltDropLayer(splash: false)
        let w = CGFloat.random(in: 3.4...5.2) * S
        let h = w * 1.45
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let o = overlays[overlayIndex(for: pos)]
        o.actors.addSublayer(layer)
        layer.position = o.local(pos)
        meltDrops.append(MeltDrop(
            layer: layer, pos: pos,
            vx: .random(in: -10...10) * S,
            vy: .random(in: -18 ... -6) * S,
            width: w, cling: cling,
            source: source, fromDock: fromDock,
            isSplash: false, ttl: .infinity, maxTTL: 1
        ))
    }

    func spawnWaterSplash(at pos: CGPoint, count: Int) {
        guard !overlays.isEmpty else { return }
        for _ in 0..<count {
            guard meltDrops.count < 140 else { break }
            let layer = meltDropLayer(splash: true)
            let d = CGFloat.random(in: 2.4...4.0) * S
            layer.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            let o = overlays[overlayIndex(for: pos)]
            o.actors.addSublayer(layer)
            layer.position = o.local(pos)
            let ttl = CGFloat.random(in: 0.22...0.42)
            meltDrops.append(MeltDrop(
                layer: layer, pos: pos,
                vx: .random(in: -88...88) * S,
                vy: .random(in: 55...135) * S,
                width: d, cling: 0,
                source: 0, fromDock: true,
                isSplash: true, ttl: ttl, maxTTL: ttl
            ))
        }
    }

    func updateMeltDrops(dt: CGFloat) {
        guard !meltDrops.isEmpty else { return }
        let bottom = (overlays.map { $0.frame.minY }.min() ?? 0) - 24 * S
        var kept: [MeltDrop] = []
        kept.reserveCapacity(meltDrops.count)
        var splashes: [CGPoint] = []
        for var d in meltDrops {
            let oldY = d.pos.y
            if d.isSplash {
                d.vy -= 520 * S * dt
                d.vx *= 1 - min(1, 2.5 * dt)
                d.pos.x += d.vx * dt
                d.pos.y += d.vy * dt
                d.ttl -= dt
                d.layer.opacity = Float(max(0, min(1, d.ttl / max(0.05, d.maxTTL * 0.65))))
                if d.ttl <= 0 || d.pos.y < bottom {
                    recycleMeltDrop(d.layer)
                    continue
                }
            } else {
                if d.cling > 0 {
                    d.cling -= dt
                    d.vy = max(-55 * S, d.vy - 95 * S * dt)
                    d.vx *= 1 - min(1, 5 * dt)
                } else {
                    d.vy = max(-540 * S, d.vy - 640 * S * dt)
                    d.vx *= 1 - min(1, 1.2 * dt)
                }
                d.pos.x += d.vx * dt
                d.pos.y += d.vy * dt
                let stretch = min(4.2, 1.35 + abs(d.vy) / (115 * S))
                d.layer.bounds = CGRect(x: 0, y: 0, width: d.width, height: d.width * stretch)

                if !d.fromDock, d.pos.y < oldY,
                   let target = landingSurface(at: d.pos.x, below: oldY, above: d.pos.y, excluding: d.source) {
                    let hitY = target.top + (piles[target.key]?.height(at: d.pos.x - target.minX) ?? 0) * 0.45 + 1
                    splashes.append(CGPoint(x: d.pos.x, y: hitY))
                    recycleMeltDrop(d.layer)
                    continue
                }
                if d.pos.y < bottom {
                    recycleMeltDrop(d.layer)
                    continue
                }
            }
            let o = overlays[overlayIndex(for: d.pos)]
            if d.layer.superlayer !== o.actors { o.actors.addSublayer(d.layer) }
            d.layer.position = o.local(d.pos)
            kept.append(d)
        }
        meltDrops = kept
        for pt in splashes {
            spawnWaterSplash(at: pt, count: Int.random(in: 3...4))
        }
    }

    func spawnCampfireSpark(near p: CGPoint, velocity: CGPoint) {
        guard !overlays.isEmpty, campfireSparks.count < 25 else { return }
        let layer = sparkPool.popLast() ?? {
            let l = CALayer()
            l.zPosition = 1001
            l.shadowColor = NSColor(calibratedRed: 1, green: 0.55, blue: 0.08, alpha: 1).cgColor
            l.shadowOpacity = 0.8
            l.shadowRadius = 2.5
            l.shadowOffset = .zero
            return l
        }()
        let r = CGFloat.random(in: 0.9...1.9) * S
        let hot = Bool.random()
        layer.backgroundColor = (hot
            ? NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.28, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.46, blue: 0.08, alpha: 1)).cgColor
        layer.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        layer.cornerRadius = r
        layer.opacity = 1
        layer.setAffineTransform(.identity)

        let pos = CGPoint(x: p.x + .random(in: -7...7) * S, y: p.y + .random(in: -2...12) * S)
        let o = overlays[overlayIndex(for: pos)]
        o.actors.addSublayer(layer)
        layer.position = o.local(pos)
        let trailX = max(-90 * S, min(90 * S, -velocity.x * 0.12))
        campfireSparks.append(CampfireSpark(
            layer: layer, pos: pos,
            vx: trailX + .random(in: -18...18) * S,
            vy: .random(in: 28...68) * S,
            age: 0, life: .random(in: 0.45...0.95),
            phase: .random(in: 0...(2 * .pi))
        ))
    }

    func updateCampfireSparks(dt: CGFloat) {
        guard !campfireSparks.isEmpty else { return }
        var kept: [CampfireSpark] = []
        kept.reserveCapacity(campfireSparks.count)
        for var sp in campfireSparks {
            sp.age += dt
            if sp.age >= sp.life {
                sp.layer.removeFromSuperlayer()
                sp.layer.opacity = 1
                sparkPool.append(sp.layer)
                continue
            }
            let u = sp.age / sp.life
            sp.vx *= 1 - min(1, 1.8 * dt)
            sp.pos.x += (sp.vx + sin(sp.phase + sp.age * 9) * 14 * S) * dt
            sp.pos.y += sp.vy * dt
            sp.layer.opacity = Float(max(0, (1 - u) * (1 - u * 0.3)))
            let sc = max(0.35, 1 - u * 0.55)
            sp.layer.setAffineTransform(CGAffineTransform(scaleX: sc, y: sc))
            let o = overlays[overlayIndex(for: sp.pos)]
            if sp.layer.superlayer !== o.actors { o.actors.addSublayer(sp.layer) }
            sp.layer.position = o.local(sp.pos)
            kept.append(sp)
        }
        campfireSparks = kept
    }

    func spawnCampfireSteam(at pos: CGPoint) {
        guard !overlays.isEmpty, campfireSteams.count < 18 else { return }
        let layer = steamPool.popLast() ?? {
            let l = CALayer()
            l.zPosition = 900
            l.contents = CampfireAssets.steamImage
            l.contentsGravity = .resize
            return l
        }()
        let size = CGFloat.random(in: 12...19) * S
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.opacity = 0.01
        layer.setAffineTransform(CGAffineTransform(scaleX: 0.75, y: 0.75))
        let o = overlays[overlayIndex(for: pos)]
        o.actors.addSublayer(layer)
        layer.position = o.local(pos)
        campfireSteams.append(CampfireSteam(
            layer: layer, pos: pos,
            vx: .random(in: -10...10) * S,
            vy: .random(in: 22...40) * S,
            age: 0, life: .random(in: 0.75...1.25),
            baseSize: size
        ))
    }

    func updateCampfireSteams(dt: CGFloat) {
        guard !campfireSteams.isEmpty else { return }
        var kept: [CampfireSteam] = []
        kept.reserveCapacity(campfireSteams.count)
        for var st in campfireSteams {
            st.age += dt
            if st.age >= st.life {
                st.layer.removeFromSuperlayer()
                st.layer.opacity = 1
                steamPool.append(st.layer)
                continue
            }
            let u = st.age / st.life
            st.pos.x += (st.vx + sin(st.age * 4.5 + st.baseSize) * 6 * S) * dt
            st.pos.y += st.vy * dt
            let fadeIn = min(1, u / 0.2)
            let fadeOut = max(0, 1 - max(0, u - 0.2) / 0.8)
            st.layer.opacity = Float(0.28 * fadeIn * fadeOut)
            let sc = 0.75 + u * 1.15
            st.layer.setAffineTransform(CGAffineTransform(scaleX: sc, y: sc))
            let o = overlays[overlayIndex(for: st.pos)]
            if st.layer.superlayer !== o.actors { o.actors.addSublayer(st.layer) }
            st.layer.position = o.local(st.pos)
            kept.append(st)
        }
        campfireSteams = kept
    }

    // MARK: mouse (global monitors; the overlay itself stays click-through)

    var downPoint: CGPoint?
    var downTime: CFTimeInterval = 0
    var downWin: Win?
    weak var downSnowman: Prop?
    var downIcicle: (key: UInt64, index: Int)?

    func topWindow(at p: CGPoint, in list: [Win]) -> Win? { list.first { $0.frame.contains(p) }.flatMap { $0.surface ? $0 : nil } }

    func installMouseMonitors() {
        updateMouseMoveMonitor()
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in self?.mouseDown(at: NSEvent.mouseLocation) }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            let p = NSEvent.mouseLocation
            self?.mouseDragged(to: p)
            self?.mouseWind(at: p)
            if Settings.shared.campfireOn { self?.updateCampfirePointer(at: p) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in self?.mouseUp(at: NSEvent.mouseLocation) }
    }

    func mouseDown(at p: CGPoint) {
        carryCancel(); carry = nil
        downSnowman = nil
        downIcicle = nil
        mouseIsDown = true
        refreshGeometry()
        if expose { downPoint = nil; downWin = nil; drag = nil; rollCancel(); return }   // Mission Control clicks
        downPoint = p
        downTime = clock()
        downWin = topWindow(at: p, in: wins)
        drag = nil
        shake = nil
        // title bar / toolbar strip: a possible window drag
        if predictDrag, let w = downWin, p.y >= w.frame.maxY - 60 {
            drag = Drag(id: w.id, frame0: w.frame, p0: p, p: p)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let m = prop(at: p, ballsOnly: true), let key = m.host, surfaces[key] != nil {
            rollCancel()
            carry = Carry(prop: m, host: key, at: p, time: clock())
        } else if let m = prop(at: p), m.kind == .snowman {
            rollCancel()
            downSnowman = m
        } else if Settings.shared.meltOn, let ic = icicleHit(at: p, pad: 4 * S) {
            rollCancel()
            downIcicle = ic
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
            dragCount += 1
            if roll != nil { rollCancel() }
            carryCancel()
        }
        drag = d
        moveDragged(to: d.predicted(p))
        trackShake(d)
    }

    /// Feed the dragged window's motion; on a jolt, shake part of its snow off.
    func trackShake(_ d: Drag) {
        guard Settings.shared.shakeOn else { return }
        // the mouse, not the predicted frame: its menu-bar clamp can jump tens of pt in one event
        let now = clock(), q = d.p
        guard var s = shake else { shake = Shake(p: q, t: now); return }
        let dt = now - s.t
        guard dt > 0.004 else { return }                    // let a few pt build up between samples
        defer { shake = s }
        if dt > 0.15 { s.p = q; s.t = now; s.v = .zero; s.peak = .zero; return }   // paused: a new stroke
        let raw = CGPoint(x: (q.x - s.p.x) / CGFloat(dt), y: (q.y - s.p.y) / CGFloat(dt))
        s.v = CGPoint(x: s.v.x * 0.45 + raw.x * 0.55, y: s.v.y * 0.45 + raw.y * 0.55)
        s.p = q; s.t = now
        let decay = CGFloat(exp(-dt / 0.3))
        func turned(_ v: CGFloat, _ peak: inout CGFloat) -> CGFloat? {
            if v * peak < 0 && abs(v) > 250 {             // a real swing back, not a small correction
                let hit = abs(peak) >= Engine.shakeSpeed ? peak : nil
                peak = v; return hit
            }
            peak *= decay
            if abs(v) > abs(peak) { peak = v }
            return nil
        }
        let hx = turned(s.v.x, &s.peak.x), hy = turned(s.v.y, &s.peak.y)
        guard hx != nil || hy != nil else { return }
        let fling = CGPoint(x: hx ?? 0, y: hy ?? 0)
        s.jolts = s.jolts.filter { now - $0 < 0.9 } + [now]
        shakeJolts += 1
        // one back-and-forth while positioning a window (even a fast fling + correction) isn't a shake
        guard s.jolts.count >= 2 else { return }
        s.shed += 1; shakeSheds += 1
        shedFromShake(UInt64(d.id), fling: fling, repeated: s.jolts.count >= 3, knockProps: s.shed >= 2)
    }

    private func shedFromShake(_ key: UInt64, fling: CGPoint, repeated: Bool, knockProps: Bool) {
        let speed = max(abs(fling.x), abs(fling.y))
        let strokeStrength = min(2.5, speed / Engine.shakeSpeed)
        let fraction = Settings.shared.shakeStrength.shedFraction(strokeStrength: strokeStrength, repeated: repeated)
        shakeOff(key, fraction: fraction, fling: fling, knockProps: knockProps)
    }

    /// Knock `fraction` of a surface's snow off as tumbling clumps that keep the window's momentum
    /// (they land on windows / the Dock below like resize spills), plus a puff of powder.
    func shakeOff(_ key: UInt64, fraction: CGFloat, fling: CGPoint, knockProps: Bool) {
        guard let surf = surfaces[key], let pile = piles[key], !overlays.isEmpty else { return }
        let f = pile.mean < 0.6 * S ? 1 : fraction           // the last thin layer goes all at once
        var samples: [(x: CGFloat, y: CGFloat, area: CGFloat)] = []
        for i in pile.heights.indices where pile.heights[i] > 0.01 {
            let h = pile.heights[i], t = h * f
            pile.heights[i] = h - t
            let x = surf.minX + min(surf.width, CGFloat(i) * Pile.step)
            samples.append((x: x, y: surf.top + h - t / 2, area: t * Pile.step))
        }
        var snappedShards: [(site: Icicle, length: CGFloat)] = []
        if pile.icicles.contains(where: { $0.length > 0 }) {        // icicles snap off with it
            let keep = 1 - min(1, f * 1.5)
            for index in pile.icicles.indices {
                let oldSite = pile.icicles[index]
                let length = oldSite.length * keep
                pile.icicles[index].length = length < 1 ? 0 : length
                if oldSite.length >= 2 * S, pile.icicles[index].length == 0,
                   oldSite.x < surf.width - 12 * S, isVisible(key, surf.minX + oldSite.x) {
                    snappedShards.append((site: oldSite, length: oldSite.length))
                }
            }
            pile.icicleDirty = true
        }
        pile.dirty = true; pileDirty = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !snappedShards.isEmpty {
            let picks = snappedShards.count > 6 ? Array(snappedShards.shuffled().prefix(6)) : snappedShards
            for item in picks {
                let vx = max(-420 * S, min(420 * S, fling.x * .random(in: 0.18...0.45))) + .random(in: -30...30) * S
                let vy = max(-180 * S, min(260 * S, fling.y * .random(in: 0.15...0.35))) + .random(in: -20...60) * S
                spawnIceShard(on: surf, site: item.site, length: item.length, vx: vx, vy: vy)
            }
        }
        if !samples.isEmpty {
            spillSnow(samples, from: surf, toss: fling)
            // fine powder: a short-lived puff over the snow line
            let total = samples.reduce(CGFloat(0)) { $0 + $1.area }
            for _ in 0..<min(16, max(4, Int(total / (40 * S * S)))) {
                let pos = CGPoint(x: .random(in: surf.minX...surf.maxX), y: surf.top + .random(in: 0...6) * S)
                let o = overlays[overlayIndex(for: pos)], layer = flakeLayer()
                let r = CGFloat.random(in: 0.7...1.5) * S
                layer.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
                layer.cornerRadius = r; layer.position = o.local(pos)
                o.actors.addSublayer(layer)
                spills.append(Spill(layer: layer, pos: pos, vy: .random(in: 40...140) * S,
                                    vx: max(-320 * S, min(320 * S, fling.x * .random(in: 0.15...0.35))) + .random(in: -40...40) * S,
                                    area: 0, source: key, fromDock: true, ttl: .random(in: 0.35...0.7)))
            }
        }
        if knockProps {
            for m in props where m.host == key && m !== carry?.prop {
                m.host = nil; m.grounded = false
                m.vy = .random(in: 120...240) * S + max(0, fling.y) * 0.25
                m.vx = max(-260 * S, min(260 * S, fling.x * 0.3))
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.byValue = (m.vx >= 0 ? -1 : 1) * CGFloat.random(in: 2...4.5)
                spin.duration = 1.2; spin.isAdditive = true; spin.fillMode = .forwards; spin.isRemovedOnCompletion = false
                m.layer.add(spin, forKey: "tumble")
            }
        }
        CATransaction.commit()
        updateRate()
    }

    func mouseUp(at p: CGPoint) {
        mouseIsDown = false
        defer { downSnowman = nil; downIcicle = nil; updateRate() }
        let draggedWindow = drag?.confirmed == true
        if draggedWindow {
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
        if let m = downSnowman {
            guard !draggedWindow, prop(at: p) === m else { return }
            props.removeAll { $0 === m }
            m.remove()
            snowPuff(for: m, baseY: m.pos.y, source: m.host ?? 0)
            saveState()
            return
        }
        if let ic = downIcicle {
            guard !draggedWindow else { return }
            snapIcicle(on: ic.key, index: ic.index)
            return
        }
        if let m = prop(at: p) {
            if m.kind == .ball { jump(m) }
            return
        }
        guard Settings.shared.snowmenOn, !Settings.shared.campfireOn, let w0 = downWin else { return }
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
    /// debug: shake the front window's snow off (as if it were shaken left-right hard)
    func demoShake() {
        guard let w = demoTargets().first else { return }
        shedFromShake(UInt64(w.id), fling: CGPoint(x: 1400, y: 0), repeated: true, knockProps: true)
    }

    /// debug: write surfaces / piles / windows to $TMPDIR/macsnow-debug.txt
    func dump() {
        var out = "interval=\(interval) flakes=\(flakes.count) props=\(props.count) paused=\(paused)\n"
        let settings = Settings.shared
        out += "settings intensity=\(settings.intensity.rawValue) wind=\(settings.windOn)/\(settings.windStrength) melt=\(settings.meltOn)/\(settings.meltSpeed) campfire=\(settings.campfireOn) battery=\(settings.batteryMode.rawValue) lowPower=\(lowPower) onAC=\(onAC) lpm=\(ProcessInfo.processInfo.isLowPowerModeEnabled) login=\(SMAppService.mainApp.status.rawValue)\n"
        out += "wind gusts=\(windGusts) pushed=\(windPushed) dust=\(windDust) campfireDrops=\(meltDrops.count) campfireSparks=\(campfireSparks.count)\n"
        out += "occlusion=\(occlusionEvents) geometryReads=\(geometryReads) lastGeometryChange age=\(clock() - lastGeometryChange) ticks=\(tickCount) expose=\(expose) at=\(exposeAt) clipOpacity=\(overlays.first?.clip.opacity ?? -1)\n"
        out += "shake on=\(settings.shakeOn) strength=\(settings.shakeStrength.rawValue) jolts=\(shakeJolts) sheds=\(shakeSheds) drags=\(dragCount)\n"
        for (k, p) in piles where k < Engine.dockKey(0) {
            let lengths = p.icicles.map(\.length).filter { $0 > 0 }
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

// MARK: - Auto-update (Sparkle 2)

@MainActor
final class Updater {
    static let releasesURL = URL(string: "https://github.com/ColdTbrew/mac-snow/releases/latest")!
    let isConfigured: Bool
    private let controller: SPUStandardUpdaterController

    init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isConfigured = !key.isEmpty
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        isConfigured ? controller.updater.canCheckForUpdates : true
    }

    var automaticallyChecksForUpdates: Bool {
        get { isConfigured ? controller.updater.automaticallyChecksForUpdates : false }
        set {
            guard isConfigured else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "자동 업데이트가 설정되지 않았어요 (Updates not configured)"
            alert.informativeText = "이 빌드에는 Sparkle 공개 키(SUPublicEDKey)가 들어 있지 않아 자동 업데이트를 확인할 수 없어요. GitHub Releases에서 새 버전을 직접 받을 수 있어요."
            alert.addButton(withTitle: "GitHub Releases 열기")
            alert.addButton(withTitle: "닫기")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesURL)
            }
            return
        }
        controller.checkForUpdates(nil)
    }
}

// MARK: - App / menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    var item: NSStatusItem!
    let menu = NSMenu()
    var updater: Updater?

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
        updater = Updater()
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
        func add(_ title: String, _ sel: Selector, on: Bool? = nil, key: String = "", enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? sel : nil, keyEquivalent: key)
            i.target = enabled ? self : nil
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
        add("창 흔들어 눈 털기 (Shake off snow)", #selector(toggleShake), on: s.shakeOn)
        choices("눈 털기 강도 (Shake strength)", ShakeStrength.allCases.map { $0.title }, s.shakeStrength.rawValue, #selector(setShakeStrength(_:)))
        add("녹기·고드름 (Melting & icicles)", #selector(toggleMelt), on: s.meltOn)
        choices("녹는 속도 (Melt speed)", ["느리게 (Slow)", "보통 (Normal)", "빠르게 (Fast)"], s.meltSpeed, #selector(setMeltSpeed(_:)))
        add("모닥불 모드 (Campfire mode)", #selector(toggleCampfire), on: s.campfireOn)
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
        add("업데이트 확인… (Check for Updates…)", #selector(checkForUpdates), enabled: updater?.canCheckForUpdates ?? false)
        add("자동 업데이트 확인 (Check for updates automatically)", #selector(toggleAutoUpdates), on: updater?.automaticallyChecksForUpdates ?? false, enabled: updater?.isConfigured ?? false)
        menu.addItem(.separator())
        add("종료 (Quit)", #selector(quit), key: "q")
    }

    @objc func toggleWind() { Settings.shared.windOn.toggle(); engine.updateMouseMoveMonitor() }
    @objc func setWindStrength(_ i: NSMenuItem) { Settings.shared.windStrength = i.tag }
    @objc func toggleShake() { Settings.shared.shakeOn.toggle() }
    @objc func setShakeStrength(_ i: NSMenuItem) { Settings.shared.shakeStrength = ShakeStrength(rawValue: i.tag) ?? .normal }
    @objc func toggleMelt() { Settings.shared.meltOn.toggle(); engine.applySettings() }
    @objc func setMeltSpeed(_ i: NSMenuItem) { Settings.shared.meltSpeed = i.tag; engine.lastMelt = engine.clock() }
    @objc func toggleCampfire() { Settings.shared.campfireOn.toggle(); engine.applySettings() }
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
    @MainActor @objc func checkForUpdates() { updater?.checkForUpdates() }
    @MainActor @objc func toggleAutoUpdates() { updater?.automaticallyChecksForUpdates.toggle() }
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
// Debug control channel (see notify.sh): plow, spawn, balls, jump, shake, campfire, clear, fill, roll
for (name, action) in [("plow", { delegate.engine.startPlow() }),
                       ("melt.fast", {
                           delegate.engine.piles.values.forEach { $0.created = .distantPast }
                           delegate.engine.meltStep(seconds: 600)
                       }),
                       ("campfire", {
                           Settings.shared.campfireOn.toggle()
                           delegate.engine.applySettings()
                       }),
                       ("spawn", { delegate.engine.spawnDemoSnowmen() }),
                       ("balls", { delegate.engine.spawnDemoBalls() }),
                       ("jump", { delegate.engine.jumpAll() }),
                       ("shake", { delegate.engine.demoShake() }),
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
