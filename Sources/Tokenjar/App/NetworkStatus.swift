import Foundation
import Network

enum NetworkPath: Equatable {
    case usable, unusable
}

/// macOS's view of whether any network path is usable. Reading it sends nothing and asks for no permission.
protocol NetworkStatus: AnyObject {
    /// Reports the current path soon after the call, then every change, on the main actor.
    func start(onChange: @escaping @MainActor (NetworkPath) -> Void)
    func stop()
}

/// Reads only the path's status: interface names, addresses, Wi-Fi names and the expensive or constrained flags are
/// never read, stored or logged.
final class PathMonitorNetworkStatus: NetworkStatus {
    /// Created in `start`, so a model built for a render or a test never starts one.
    private var monitor: NWPathMonitor?

    func start(onChange: @escaping @MainActor (NetworkPath) -> Void) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let usability = Self.usability(of: path.status)
            MainActor.assumeIsolated { onChange(usability) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// `requiresConnection` counts as usable: a connection attempt may bring the path up, so a check is let try.
    nonisolated static func usability(of status: NWPath.Status) -> NetworkPath {
        switch status {
        case .unsatisfied: .unusable
        case .satisfied, .requiresConnection: .usable
        @unknown default: .usable
        }
    }
}
