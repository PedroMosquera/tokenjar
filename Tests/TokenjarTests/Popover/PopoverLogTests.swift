import AppKit
import Testing
@testable import Tokenjar

@MainActor
struct PopoverLogTests {
    private final class Count {
        var value = 0
    }

    /// A show that AppKit reports without a close before it must not leave the earlier show's observers logging too.
    @Test func newFrameObserversReplaceTheOldOnes() {
        let delegate = AppDelegate()
        let name = Notification.Name("PopoverLogTests.frame")
        let window = NSObject()
        let count = Count()
        let observe = {
            // A nil queue runs the block on the posting thread, and every post below comes from the main actor.
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { _ in
                MainActor.assumeIsolated { count.value += 1 }
            }
        }

        delegate.popoverFrameObservers = [observe()]
        delegate.popoverFrameObservers = [observe()]
        NotificationCenter.default.post(name: name, object: window)
        #expect(count.value == 1)

        delegate.popoverFrameObservers = []
        NotificationCenter.default.post(name: name, object: window)
        #expect(count.value == 1)
    }
}
