import AppKit
// Throwaway titled window used only for MacSnow tests (kill the process to "close" it).
// Moves itself when it receives com.coldtbrew.macsnow.testwin.move (simulates a drag of OUR window).
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 1250, y: 380, width: 760, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
app.run()
