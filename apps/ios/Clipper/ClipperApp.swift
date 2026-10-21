import AVFoundation
import SwiftUI

@main
struct ClipperApp: App {
    @State private var connection = Connection()
    @State private var order = ClipOrder()
    @State private var configs = ConfigStore()
    @State private var pairError: String?

    init() {
        // default session is muted by the silent switch; clips should always be audible (like YouTube/TikTok)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if connection.isPaired { RootView() } else { PairView() }
            }
            .environment(connection)
            .environment(order)
            .environment(configs)
            .preferredColorScheme(.dark)
            .tint(Theme.acc)
            // QR scanned with the iPhone camera app opens clipper://pair?...
            .onOpenURL { url in
                guard let (server, token) = Connection.parse(url.absoluteString) else { return }
                Task {
                    do { try await connection.pair(server: server, token: token) }
                    catch { pairError = error.localizedDescription }
                }
            }
            .alert("Verbinden fehlgeschlagen", isPresented: .constant(pairError != nil)) {
                Button("OK") { pairError = nil }
            } message: { Text(pairError ?? "") }
        }
    }
}

/// Same pages as the website's nav, same order, plus the settings (configurations).
struct RootView: View {
    @Environment(Connection.self) private var connection
    @AppStorage("tab") private var tab = "foryou"

    var body: some View {
        TabView(selection: $tab) {
            ForYouView().tabItem { Label("For You", systemImage: "play.rectangle.on.rectangle") }.tag("foryou")
            EditListView().tabItem { Label("Edit", systemImage: "scissors") }.tag("edit")
            SchedulerView().tabItem { Label("Scheduler", systemImage: "calendar.badge.clock") }.tag("scheduler")
            DiscoveryView().tabItem { Label("Discovery", systemImage: "square.grid.2x2") }.tag("selector")
            SettingsView().tabItem { Label("Einstellungen", systemImage: "gearshape") }.tag("settings")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if connection.offline {
                Label("Mac nicht erreichbar – gleiches WLAN? Server läuft?", systemImage: "wifi.exclamationmark")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.9))
                    .foregroundStyle(.black)
            }
        }
    }
}
