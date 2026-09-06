import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true
    @Published private(set) var isCellular = false
    @Published private(set) var isConstrained = false
    @Published private(set) var isSlow = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cm.mobly.netmon", qos: .utility)
    private var slowTimer: Task<Void, Never>?
    private var recentLatencies: [TimeInterval] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                self.isCellular = path.usesInterfaceType(.cellular)
                self.isConstrained = path.isConstrained

                if self.isConnected && !wasConnected {
                    self.isSlow = false
                    self.recentLatencies.removeAll()
                    NotificationCenter.default.post(name: Self.didReconnect, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }

    static let didReconnect = Notification.Name("NetworkMonitorDidReconnect")

    func recordLatency(_ duration: TimeInterval) {
        recentLatencies.append(duration)
        if recentLatencies.count > 5 { recentLatencies.removeFirst() }
        let avg = recentLatencies.reduce(0, +) / Double(recentLatencies.count)
        isSlow = avg > 4.0
    }
}
