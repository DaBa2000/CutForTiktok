import Foundation

enum APIError: LocalizedError {
    case message(String)
    case unauthorized
    case offline

    var errorDescription: String? {
        switch self {
        case .message(let m): m
        case .unauthorized: "Nicht verbunden – QR-Code auf dem Mac neu scannen"
        case .offline: "Mac nicht erreichbar – läuft `cutfortiktok review` und ist das iPhone im selben WLAN?"
        }
    }
}

/// Same endpoints the website uses (src/cutfortiktok/server.py). Every request carries the pairing token.
struct API {
    let base: URL
    let token: String
    weak var connection: Connection?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 900  // "prepare" downloads + transcribes before answering
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func url(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }

    /// For AVPlayer / web view: token as query parameter (they can't set headers).
    func mediaURL(_ path: String) -> URL {
        var c = URLComponents(url: url(path), resolvingAgainstBaseURL: true)!
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "k", value: token)]
        return c.url!
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(URLRequest(url: url(path)))
    }

    @discardableResult
    func post<T: Decodable>(_ path: String, _ body: some Encodable = [String: String]()) async throws -> T {
        var r = URLRequest(url: url(path))
        r.httpMethod = "POST"
        r.httpBody = try JSONEncoder().encode(body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(r)
    }

    func post(_ path: String, _ body: some Encodable = [String: String]()) async throws {
        let _: [String: AnyCodable] = try await post(path, body)
    }

    /// The view being looked at and its next clips: the Mac downloads them in background (prefetch.py).
    /// view: foryou | profile | discovery. Sent again only when the list changed or after 30 s.
    func focus(_ view: String, _ ids: [String]) async {
        struct Body: Encodable { let view: String; let ids: [String] }
        let ids = Array(ids.prefix(12))
        let key = view + ":" + ids.joined(separator: ",")
        guard await FocusMemo.shared.shouldSend(key) else { return }
        try? await post("/api/focus", Body(view: view, ids: ids))
    }

    /// configurations: op save {id?, name, streamers (nil = all), pins} | activate {id} | delete {id}
    func configs() async throws -> ConfigsResponse { try await get("/api/configs") }

    @discardableResult
    func activateConfig(_ id: String) async throws -> ConfigsResponse {
        try await post("/api/configs", ["op": "activate", "id": id])
    }

    /// ignored / kept / new / uploaded: the server applies it everywhere (lists, scheduler, files)
    func setStatus(_ clipId: String, _ status: String) async throws {
        try await post("/api/clip/\(clipId)/status", ["status": status])
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        var req = req
        req.setValue(token, forHTTPHeaderField: "X-Clipper-Token")
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch let e as URLError where e.code != .cancelled {
            await setOffline(true)
            throw APIError.offline
        }
        await setOffline(false)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode([String: AnyCodable].self, from: data))?["error"]?.string
            throw APIError.message(msg ?? "Fehler \(code)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.message("Antwort nicht lesbar: \(error)")
        }
    }

    @MainActor private func setOffline(_ v: Bool) {
        if connection?.offline != v { connection?.offline = v }
    }
}

actor FocusMemo {
    static let shared = FocusMemo()
    private var key = ""
    private var at = Date.distantPast
    func shouldSend(_ k: String) -> Bool {
        if k == key, Date().timeIntervalSince(at) < 30 { return false }
        key = k; at = Date()
        return true
    }
}

/// Loose JSON value for small ad-hoc responses ({"ok": true}, {"error": "..."}).
struct AnyCodable: Codable {
    let value: Any?

    var string: String? { value as? String }

    init(_ v: Any?) { value = v }

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { value = nil }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let n = try? c.decode(Double.self) { value = n }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues(\.value) }
        else { value = nil }
    }

    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as String: try c.encode(v)
        default: try c.encodeNil()
        }
    }
}
