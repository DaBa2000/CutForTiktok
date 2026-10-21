import Foundation
import Observation

/// Mac server (CutForTiktok `review`) this phone is paired with. Pairing link from the QR code on
/// http://localhost:8080/pair:  clipper://pair?u=http%3A%2F%2F192.168.x.y%3A8080&k=<token>
@Observable
final class Connection {
    private(set) var server: URL?
    private(set) var token: String?
    /// last request failed because the Mac was not reachable (shown as a banner)
    var offline = false

    var isPaired: Bool { server != nil && token != nil }
    var api: API? { server.flatMap { s in token.map { API(base: s, token: $0, connection: self) } } }

    init() {
        let d = UserDefaults.standard
        server = d.string(forKey: "server").flatMap(URL.init(string:))
        token = d.string(forKey: "token")
    }

    /// Accepts the pairing link (or a plain http URL containing ?k=).
    static func parse(_ link: String) -> (URL, String)? {
        guard let c = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let k = q["k"], !k.isEmpty else { return nil }
        if c.scheme == "clipper", let u = q["u"], let url = URL(string: u) { return (url, k) }
        if c.scheme == "http" || c.scheme == "https", let host = c.host {
            return (URL(string: "\(c.scheme!)://\(host)\(c.port.map { ":\($0)" } ?? "")")!, k)
        }
        return nil
    }

    /// Checks the Mac answers with this token before storing it.
    func pair(server: URL, token: String) async throws {
        let api = API(base: server, token: token, connection: nil)
        let info: [String: AnyCodable] = try await api.get("/api/info")
        guard info["app"]?.string == "cutfortiktok" else { throw APIError.message("Kein CutForTiktok-Server") }
        await MainActor.run {
            self.server = server
            self.token = token
            self.offline = false
            UserDefaults.standard.set(server.absoluteString, forKey: "server")
            UserDefaults.standard.set(token, forKey: "token")
        }
    }

    func unpair() {
        server = nil
        token = nil
        UserDefaults.standard.removeObject(forKey: "server")
        UserDefaults.standard.removeObject(forKey: "token")
    }
}

/// Website's "clipOrder" (localStorage): the list page last shown decides which clip "Exportieren & weiter" opens next.
@Observable
final class ClipOrder {
    var ids: [String] = []

    /// handled clip leaves the order; the next one is whatever now sits at its position
    func next(after id: String) -> String? {
        let i = ids.firstIndex(of: id)
        if let i { ids.remove(at: i) }
        let j = i ?? 0
        return j < ids.count ? ids[j] : nil
    }
}
