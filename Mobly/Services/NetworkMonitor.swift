import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true
    @Published private(set) var isCellular = false
    @Published private(set) var isConstrained = false

    // API response times include server processing and cannot establish
    // whether the user’s internet connection is slow. Track reachability only.
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cm.mobly.netmon", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                self.isCellular = path.usesInterfaceType(.cellular)
                self.isConstrained = path.isConstrained

                if self.isConnected && !wasConnected {
                    NotificationCenter.default.post(name: Self.didReconnect, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }

    static let didReconnect = Notification.Name("NetworkMonitorDidReconnect")

}
