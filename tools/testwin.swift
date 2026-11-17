import AppKit
// Throwaway titled window used only for MacSnow tests (kill the process to "close" it).
// Moves itself when it receives com.coldtbrew.macsnow.testwin.move (simulates a drag of OUR window).
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 1250, y: 380, width: 760, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
w.title = "MacSnow test window"
w.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.coldtbrew.macsnow.testwin.move"), object: nil, queue: .main) { _ in
    let start = w.frame.origin
    var t = 0.0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { tm in
        t += 1.0 / 60
        let k = min(1, t / 1.5)
        w.setFrameOrigin(NSPoint(x: start.x - 700 * k, y: start.y + 150 * sin(k * .pi) - 120 * k))
        if k >= 1 { tm.invalidate() }
    }
}
// Lag test: drag OUR window along a path at 120 Hz and feed the same moves to MacSnow as a simulated
// mouse (com.coldtbrew.macsnow.sim.*). Logs "W <time> <x> <y>" to argv[1] (default ./lag-testwin.log).
let logPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "lag-testwin.log"
func post(_ n: String, _ p: CGPoint) {
    let f = w.frame
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.coldtbrew.macsnow." + n),
        object: String(format: "%.2f,%.2f,%d,%.2f,%.2f,%.2f,%.2f", p.x, p.y, w.windowNumber, f.minX, f.minY, f.width, f.height),
        userInfo: nil, deliverImmediately: true)
}
DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.coldtbrew.macsnow.testwin.lagtest"), object: nil, queue: .main) { _ in
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let log = FileHandle(forWritingAtPath: logPath)!
    let start = w.frame.origin
    let p0 = CGPoint(x: w.frame.minX + 200, y: w.frame.maxY - 12)       // in the title bar
    post("sim.down", p0)
    var t = 0.0
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { tm in
            t += 1.0 / 120
            let k = min(1, t / 2.0)
            let o = NSPoint(x: start.x - 700 * k + 60 * sin(k * 6 * .pi), y: start.y + 150 * sin(k * .pi) - 120 * k)
            w.setFrameOrigin(o)
            log.write(String(format: "W %.6f %.2f %.2f\n", CACurrentMediaTime(), w.frame.minX, w.frame.minY).data(using: .utf8)!)
            post("sim.drag", CGPoint(x: p0.x + o.x - start.x, y: p0.y + o.y - start.y))
            if k >= 1 {
                tm.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    post("sim.up", CGPoint(x: p0.x + o.x - start.x, y: p0.y + o.y - start.y))
                    log.closeFile()
                    w.setFrameOrigin(start)
                }
            }
        }
    }
}
// Reset tests: minimize the window for 8 s (it leaves the on-screen list but still exists, like
// windows on another Space), or scale it without the mouse.
DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.coldtbrew.macsnow.testwin.hide"), object: nil, queue: .main) { _ in
    w.miniaturize(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { w.deminiaturize(nil) }
}
DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.coldtbrew.macsnow.testwin.scale"), object: nil, queue: .main) { _ in
    let f = w.frame
    w.setFrame(NSRect(x: f.minX + f.width * 0.2, y: f.minY + f.height * 0.2, width: f.width * 0.6, height: f.height * 0.6), display: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { w.setFrame(f, display: true) }
}
// Title-bar drag that does NOT move the window: MacSnow's snow must stay put.
DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.coldtbrew.macsnow.testwin.staticdrag"), object: nil, queue: .main) { _ in
    let p0 = CGPoint(x: w.frame.minX + 200, y: w.frame.maxY - 12)
    post("sim.down", p0)
    for i in 1...30 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01 * Double(i)) { post("sim.drag", CGPoint(x: p0.x + 5 * CGFloat(i), y: p0.y)) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { post("sim.up", CGPoint(x: p0.x + 150, y: p0.y)) }
}
app.run()
