import Foundation

/// Checks whether HTTP services answer. Runs only when the panel opens, at most once a minute per port,
/// so it does not fill dev server logs with requests.
actor HealthProbe {
    private var lastProbe: [String: Date] = [:]
    private(set) var unresponsive: Set<String> = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    /// Probes the given `pid:port` targets. Returns the set of keys that timed out.
    func probe(_ targets: [(key: String, port: UInt16)]) async -> Set<String> {
        let now = Date()
        let due = targets.filter { now.timeIntervalSince(lastProbe[$0.key] ?? .distantPast) > 60 }
        for t in due { lastProbe[t.key] = now }

        await withTaskGroup(of: (String, Bool).self) { group in
            for t in due {
                group.addTask { [session] in
                    var request = URLRequest(url: URL(string: "http://localhost:\(t.port)/favicon.ico")!)
                    request.setValue("portbar health check", forHTTPHeaderField: "User-Agent")
                    do {
                        _ = try await session.data(for: request)
                        return (t.key, false)
                    } catch let error as URLError where error.code == .timedOut {
                        return (t.key, true)
                    } catch {
                        return (t.key, false)   // refused or reset: not a hang
                    }
                }
            }
            for await (key, timedOut) in group {
                if timedOut { unresponsive.insert(key) } else { unresponsive.remove(key) }
            }
        }

        let live = Set(targets.map(\.key))
        unresponsive = unresponsive.intersection(live)
        lastProbe = lastProbe.filter { live.contains($0.key) }
        return unresponsive
    }
}
