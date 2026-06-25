import Foundation
import Network

/// A DeskLink server found on the LAN via Bonjour.
struct DiscoveredServer: Identifiable, Hashable {
    let id: String          // endpoint description
    let name: String        // human-friendly name from TXT or service name
    let endpoint: NWEndpoint
}

/// Browses for `_desklink._tcp` services using Network.framework's NWBrowser.
/// Requires the "Local Network" permission + NSBonjourServices in Info.plist.
@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var servers: [DiscoveredServer] = []

    private var browser: NWBrowser?
    private var restarts = 0

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_desklink._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.servers = results.compactMap { Self.map($0) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        // The Local Network permission prompt resolves *after* the first browse
        // starts; on a fresh install the browser can fail/stall before the user
        // grants access. Restart it when it fails so discovery recovers on its
        // own instead of only appearing after some other action forces a retry.
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                // `.cancelled` is always intentional (stop/restart) — ignore it to
                // avoid a restart loop; only recover from `.failed`.
                if case .failed = state { self.restart() }
            }
        }
        browser.start(queue: .main)
    }

    private func restart() {
        guard restarts < 5 else { return }
        restarts += 1
        browser?.cancel()
        browser = nil
        // Brief backoff, then browse again (e.g. once permission is granted).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.start()
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        servers = []
        restarts = 0
    }

    private static func map(_ result: NWBrowser.Result) -> DiscoveredServer? {
        var name = "DeskLink"
        if case let .service(svc, _, _, _) = result.endpoint {
            name = svc
        }
        if case let .bonjour(txt) = result.metadata, let n = txt["name"] {
            name = n
        }
        return DiscoveredServer(id: "\(result.endpoint)", name: name, endpoint: result.endpoint)
    }
}
