import Observation
import SwiftUI

/// Colors of the website (web/*.html :root vars).
enum Theme {
    static let bg = Color(hex: 0x0C0C0F)
    static let panel = Color(hex: 0x16161B)
    static let panel2 = Color(hex: 0x1D1D24)
    static let line = Color(hex: 0x2A2A33)
    static let fg = Color(hex: 0xECECF1)
    static let mute = Color(hex: 0x8D8D9A)
    static let acc = Color(hex: 0xFE2C55)
    static let acc2 = Color(hex: 0x25F4EE)
    static let ok = Color(hex: 0x2EA043)
    static let warn = Color(hex: 0xD29922)
    static let purple = Color(hex: 0x6E40C9)
    static let amber = Color(hex: 0x9E6A03)
    static let blue = Color(hex: 0x1F6FEB)
    static let red = Color(hex: 0xDA3633)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    init(css: String) {
        self.init(hex: UInt32(css.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFE600)
    }
}

struct Logo: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Cut")
            Text("ForTiktok").foregroundStyle(LinearGradient(colors: [Theme.acc2, Theme.acc], startPoint: .leading, endPoint: .trailing))
        }
        .fontWeight(.heavy)
    }
}

struct PrimaryButton: ButtonStyle {
    var color: Color = Theme.acc
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .padding(.vertical, 13).padding(.horizontal, 16)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 12))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.vertical, 11).padding(.horizontal, 14)
            .background(Theme.panel2.opacity(configuration.isPressed ? 0.6 : 1), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .foregroundStyle(Theme.fg)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .black.opacity(0.75)
    var body: some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(color, in: .capsule).foregroundStyle(.white)
    }
}

/// 16:9 thumbnail with status / duration / parts pills (cards of all list pages).
struct ClipThumb: View {
    let clip: ClipItem
    var status: (String, Color)?
    var corner: String?

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: clip.thumbURL) { $0.resizable().scaledToFill() } placeholder: { Theme.panel2 }
            }
            .clipped()
            .overlay(alignment: .topLeading) { if let status { Pill(text: status.0, color: status.1).padding(8) } }
            .overlay(alignment: .topTrailing) {
                if (clip.parts ?? 1) > 1 { Pill(text: "🔗 \(clip.parts!) Clips", color: Theme.purple).padding(8) }
            }
            .overlay(alignment: .bottomTrailing) { Pill(text: "\(Int((clip.duration ?? 0).rounded()))s").padding(8) }
            .overlay(alignment: .bottomLeading) { if let corner { Pill(text: corner, color: Theme.acc).padding(8) } }
    }
}

/// Configurations from the Mac (Einstellungen). The active one decides which streamers For You, Discovery and the
/// background downloads use; `version` changes when another one becomes active, pages reload on it.
@Observable
final class ConfigStore {
    var list: [ConfigItem] = []
    var active = ""
    var all: [String] = []
    var version = 0

    var activeItem: ConfigItem? { list.first { $0.id == active } }

    func load(_ api: API?) async {
        guard let api, let j = try? await api.configs() else { return }
        apply(j)
    }

    func apply(_ j: ConfigsResponse) {
        list = j.configs
        all = j.streamers
        if active != j.active {
            if !active.isEmpty { version += 1 }
            active = j.active
        }
    }

    /// page answered with another active configuration (changed on the website): take it over
    func check(_ info: ConfigInfo?, _ api: API?) {
        guard let info, !active.isEmpty, info.id != active else { return }
        Task { await load(api) }
    }

    func activate(_ id: String, _ api: API?) async throws {
        guard let api else { return }
        apply(try await api.activateConfig(id))
    }
}

/// Toolbar: active configuration, switch to another one.
struct ConfigMenu: View {
    @Environment(Connection.self) private var connection
    @Environment(ConfigStore.self) private var configs
    @State private var error: String?

    var body: some View {
        Menu {
            Picker("Konfiguration", selection: Binding(get: { configs.active }, set: { id in
                Task { do { try await configs.activate(id, connection.api) } catch { self.error = error.localizedDescription } }
            })) {
                ForEach(configs.list) { c in
                    Text("\(c.name) (\(c.streamers.map { "\($0.count)" } ?? "alle"))").tag(c.id)
                }
            }
        } label: {
            Label(configs.activeItem?.name ?? "Konfiguration", systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .task { if configs.list.isEmpty { await configs.load(connection.api) } }
        .errorAlert($error)
    }
}

/// Toolbar menu with the connection (host, disconnect).
struct ConnectionMenu: View {
    @Environment(Connection.self) private var connection
    @State private var confirm = false

    var body: some View {
        Menu {
            Section(connection.server?.host() ?? "") {
                Button("Verbindung trennen", systemImage: "wifi.slash", role: .destructive) { confirm = true }
            }
        } label: {
            Image(systemName: connection.offline ? "wifi.exclamationmark" : "wifi")
                .foregroundStyle(connection.offline ? .orange : Theme.ok)
        }
        .confirmationDialog("Vom Mac trennen?", isPresented: $confirm) {
            Button("Trennen", role: .destructive) { connection.unpair() }
        } message: { Text("Zum erneuten Verbinden den QR-Code auf localhost:8080/pair scannen.") }
    }
}

/// Live countdown to the listener's next Twitch scan.
struct SyncCountdown: View {
    let nextSync: Double?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let n = nextSync, n > 0 {
                let s = Int(n - ctx.date.timeIntervalSince1970)
                Text(s > 0 ? "nächster Scan in \(s / 60):\(String(format: "%02d", s % 60))" : "Scan läuft…")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.mute)
            }
        }
    }
}

extension View {
    /// Shows `error` as an alert; clears it on OK.
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert("Fehler", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
            Button("OK") { error.wrappedValue = nil }
        } message: { Text(error.wrappedValue ?? "") }
    }

    /// Reloads every `seconds` while the view is visible (the website polls the same way).
    func polling(every seconds: Double, _ action: @escaping () async -> Void) -> some View {
        task {
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }
}
