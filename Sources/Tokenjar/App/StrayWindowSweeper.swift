import AppKit

/// Keeps render runs off the user's screen. Every window a render captures is parked far off every display, but while a
/// render spins the run loop SwiftUI can still open its empty Settings scene window on screen. Once started, any shown
/// window that touches a display is hidden within one timer tick.
enum StrayWindowSweeper {
    private static var timer: Timer?

    static func start() {
        sweep()
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func isStray(frame: NSRect, isVisible: Bool, screens: [NSRect]) -> Bool {
        isVisible && screens.contains { $0.intersects(frame) }
    }

    static func report(hiding frame: NSRect) -> String {
        "stray window hidden: \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))\n"
    }

    private static func sweep() {
        let screens = NSScreen.screens.map(\.frame)
        for window in NSApp.windows where isStray(frame: window.frame, isVisible: window.isVisible, screens: screens) {
            FileHandle.standardError.write(Data(report(hiding: window.frame).utf8))
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }
}
