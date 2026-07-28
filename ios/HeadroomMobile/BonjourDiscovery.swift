import Foundation
import Network

struct DiscoveredMac: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let endpoint: String
}

@MainActor
final class BonjourDiscovery: ObservableObject {
    @Published private(set) var services: [DiscoveredMac] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        isSearching = true
        errorMessage = nil

        let browser = NWBrowser(
            for: .bonjour(type: "_headroom._tcp", domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                case .failed(let error):
                    self.isSearching = false
                    self.errorMessage = error.localizedDescription
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.mac(from:))
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                self?.services = found
            }
        }
        self.browser = browser
        browser.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    func restart() {
        stop()
        services = []
        start()
    }

    private nonisolated static func mac(
        from result: NWBrowser.Result
    ) -> DiscoveredMac? {
        guard case let .service(name, type, domain, _) = result.endpoint,
              type == "_headroom._tcp" else { return nil }
        let host = "\(name).\(domain)"
            .replacingOccurrences(of: "..", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let normalized = MobileConnection.normalize(
            "http://\(host):8737/usage"
        ) else { return nil }
        return DiscoveredMac(
            id: "\(name)|\(domain)",
            name: name,
            endpoint: normalized
        )
    }
}
