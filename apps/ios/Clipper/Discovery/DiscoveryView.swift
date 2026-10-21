import Observation
import SwiftUI

/// Pages pushed from Discovery.
enum DiscoveryRoute: Hashable {
    case edit(String)
    case profile(String)
    case watch(streamer: String, sort: String, age: Int, start: String?)  // profile "For You style"
}

/// Per streamer of the active configuration: newest or top n clips of a time window; tap a streamer for its
/// profile. Mirrors web/index.html. Background downloads: the shown clips of pinned channels.
struct DiscoveryView: View {
    @Environment(Connection.self) private var connection
    @Environment(ClipOrder.self) private var order
    @Environment(ConfigStore.self) private var configs
    @State private var data = DiscoveryData()
    @AppStorage("selectorMode") private var mode = "new"
    @AppStorage("selectorN") private var n = 5
    @AppStorage("discoveryAge") private var age = 0
    @AppStorage("selectorOrder") private var channelOrder = "recent"  // recent | used | top
    @State private var syncing = false
    @State private var path: [DiscoveryRoute] = []
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                filters
                let gs = groups()
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(gs, id: \.streamer) { g in section(g) }
                }
                .padding(.horizontal)
                if gs.isEmpty {
                    Text(data.clips.isEmpty ? "Keine Clips. Der Listener lädt beim Start alle Clips der letzten Tage, das kann kurz dauern. Streamer wählen: Einstellungen."
                         : "Keine Clips in diesem Zeitraum.")
                        .foregroundStyle(Theme.mute).multilineTextAlignment(.center).padding(40)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Discovery")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConfigMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await sync() } } label: {
                        if syncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .navigationDestination(for: DiscoveryRoute.self) { r in
                switch r {
                case .edit(let id): EditorHost(startId: id) { path.removeAll() }
                case .profile(let s): ProfileView(streamer: s, data: data, path: $path)
                case let .watch(s, sort, age, start): ForYouFeed(streamer: s, initialSort: sort, initialAge: age, startId: start)
                }
            }
            .polling(every: 15) { await load() }  // listener adds clips in background
            .onChange(of: configs.version) { Task { await load() } }
            .onChange(of: path) { if path.isEmpty { focus() } }
            .refreshable { await load() }
            .errorAlert($error)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $mode) { Text("Neueste").tag("new"); Text("Top").tag("top") }
                .pickerStyle(.segmented)
            AgeChips(age: $age)
            HStack {
                Menu {
                    Picker("Kanäle", selection: $channelOrder) {
                        Text("Neueste zuerst").tag("recent"); Text("Meist genutzt").tag("used"); Text("Top-Clips").tag("top")
                    }
                } label: { Label("Kanäle", systemImage: "arrow.up.arrow.down").font(.subheadline.weight(.semibold)) }
                Spacer()
                Stepper("\(n) pro Kanal", value: $n, in: 1...100).font(.subheadline).fixedSize()
            }
            HStack {
                Text(info).font(.caption).foregroundStyle(Theme.mute)
                Spacer()
                SyncCountdown(nextSync: data.nextSync)
            }
        }
        .padding()
        .onChange(of: mode) { focus() }
        .onChange(of: age) { focus() }
        .onChange(of: n) { focus() }
    }

    private func section(_ g: ClipGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { path.append(.profile(g.streamer)) } label: {
                    HStack(spacing: 10) {
                        Avatar(streamer: g.streamer)
                        Text("@\(g.streamer)").font(.headline)
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Theme.mute)
                    }
                }
                .buttonStyle(.plain)
                PinButton(streamer: g.streamer, data: data)
                Text((mode == "top" ? "Top \(g.list.count)" : "\(g.list.count) neueste") + " von \(g.total)"
                     + (data.used[g.streamer].map { " · \($0)× genutzt" } ?? ""))
                    .font(.caption).foregroundStyle(Theme.mute).lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(g.list.enumerated()), id: \.element.id) { i, c in
                        DiscoveryCard(clip: c, rank: mode == "top" ? i + 1 : nil, fresh: data.fresh.contains(c.id),
                                      open: { open(c) },
                                      watch: { path.append(.watch(streamer: c.streamer, sort: mode, age: age, start: c.id)) },
                                      ignore: { Task { await ignore(c) } })
                            .frame(width: 260)
                    }
                }
            }
        }
    }

    private var info: String {
        let gs = groups()
        var s = "\(gs.reduce(0) { $0 + $1.list.count }) Clips aus \(gs.count) Kanälen"
        if !data.fresh.isEmpty { s += " · \(data.fresh.count) neu" }
        if !data.rendering.isEmpty { s += " · \(data.rendering.count) exportiert gerade" }
        if let p = data.prefetching { s += " · lädt: " + (data.clips.first { $0.id == p }?.displayTitle ?? "…") }
        return s
    }

    /// newest / top n per channel of the time window; pinned channels first
    private func groups() -> [ClipGroup] {
        var by: [String: [ClipItem]] = [:]
        for c in data.clips where !data.rendering.contains(c.id) && inAge(c, age) { by[c.streamer, default: []].append(c) }
        let maxViews = { (g: ClipGroup) in g.list.map { $0.views ?? 0 }.max() ?? 0 }
        return by.map { s, list in
            let sorted = list.sorted(by: clipOrder(mode))
            return ClipGroup(streamer: s, list: Array(sorted.prefix(n)), total: list.count)
        }
        .sorted { a, b in
            let pa = data.pins.contains(a.streamer), pb = data.pins.contains(b.streamer)
            if pa != pb { return pa }
            switch channelOrder {
            case "used":
                let ua = data.used[a.streamer] ?? 0, ub = data.used[b.streamer] ?? 0
                return ua != ub ? ua > ub : maxViews(a) > maxViews(b)
            case "top": return maxViews(a) > maxViews(b)
            default: return clipOrder(mode)(a.list[0], b.list[0])
            }
        }
    }

    /// round robin over channels: "next clip" in the editor follows the top of every channel first
    private func roundRobin() -> [ClipItem] {
        let gs = groups()
        var out: [ClipItem] = []
        for i in 0..<(gs.map(\.list.count).max() ?? 0) { for g in gs where i < g.list.count { out.append(g.list[i]) } }
        return out
    }

    /// background downloads: only the shown clips of pinned channels, in this order
    private func focus() {
        let ids = roundRobin().filter { data.pins.contains($0.streamer) }.map(\.id)
        Task { await connection.api?.focus("discovery", ids) }
    }

    private func open(_ c: ClipItem) {
        order.ids = roundRobin().map(\.id)
        path.append(.edit(c.id))
    }

    private func load() async {
        await data.load(connection.api, configs)
        if path.isEmpty { focus() }
    }

    private func ignore(_ c: ClipItem) async {
        do { try await data.ignore(c, connection.api) } catch { self.error = error.localizedDescription }
    }

    private func sync() async {
        guard let api = connection.api else { return }
        syncing = true
        do { try await api.post("/api/sync") } catch { self.error = error.localizedDescription }
        await load()
        syncing = false
    }
}

/// /api/clips, shared by Discovery and the streamer profiles.
@Observable
final class DiscoveryData {
    var clips: [ClipItem] = []
    var rendering: Set<String> = []
    var prefetching: String?
    var nextSync: Double?
    var seen: Set<String>?
    var fresh: Set<String> = []
    var pins: [String] = []
    var used: [String: Int] = [:]

    @MainActor func load(_ api: API?, _ configs: ConfigStore) async {
        guard let api, let j: ClipsResponse = try? await api.get("/api/clips") else { return }
        if let seen { for c in j.clips where !seen.contains(c.id) { fresh.insert(c.id) } }
        seen = Set(j.clips.map(\.id))
        clips = j.clips
        rendering = Set(j.rendering ?? [])
        prefetching = j.prefetch?.current
        nextSync = j.next_sync
        pins = j.pins ?? []
        used = j.used ?? [:]
        configs.check(j.config, api)
    }

    @MainActor func ignore(_ c: ClipItem, _ api: API?) async throws {
        guard let api else { return }
        try await api.setStatus(c.id, "ignored")
        clips.removeAll { $0.id == c.id }
        fresh.remove(c.id)
    }

    @MainActor func togglePin(_ s: String, _ api: API?) async {
        if let i = pins.firstIndex(of: s) { pins.remove(at: i) } else { pins.append(s) }
        try? await api?.post("/api/pins", ["pins": pins])
    }
}

struct ClipGroup { let streamer: String; let list: [ClipItem]; let total: Int }

func clipOrder(_ sort: String) -> (ClipItem, ClipItem) -> Bool {
    sort == "top" ? { ($0.views ?? 0) > ($1.views ?? 0) } : { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
}

func inAge(_ c: ClipItem, _ age: Int) -> Bool {
    age == 0 || (c.createdDate ?? .distantPast) >= Date().addingTimeInterval(-Double(age) * 60)
}

/// One streamer: all its clips in an order (newest / top) and time window, "For You style" viewing.
struct ProfileView: View {
    let streamer: String
    let data: DiscoveryData
    @Binding var path: [DiscoveryRoute]
    @Environment(Connection.self) private var connection
    @Environment(ClipOrder.self) private var order
    @AppStorage("profileSort") private var sort = "new"
    @AppStorage("profileAge") private var age = 0
    @State private var error: String?

    var body: some View {
        let all = data.clips.filter { $0.streamer == streamer }
        let list = all.filter { !data.rendering.contains($0.id) && inAge($0, age) }.sorted(by: clipOrder(sort))
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Avatar(streamer: streamer, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text("@\(streamer)").font(.title2.bold()); PinButton(streamer: streamer, data: data) }
                        Text("\(all.count) Clips · \(all.reduce(0) { $0 + ($1.views ?? 0) }) Views · \(data.used[streamer] ?? 0)× genutzt")
                            .font(.caption).foregroundStyle(Theme.mute)
                    }
                }
                Picker("", selection: $sort) { Text("Neueste").tag("new"); Text("Top").tag("top") }.pickerStyle(.segmented)
                AgeChips(age: $age)
                Button { path.append(.watch(streamer: streamer, sort: sort, age: age, start: nil)) } label: {
                    Label("Im For-You-Stil ansehen", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        DiscoveryCard(clip: c, rank: sort == "top" ? i + 1 : nil, fresh: data.fresh.contains(c.id),
                                      open: { order.ids = list.map(\.id); path.append(.edit(c.id)) },
                                      watch: { path.append(.watch(streamer: streamer, sort: sort, age: age, start: c.id)) },
                                      ignore: { Task { do { try await data.ignore(c, connection.api) } catch { self.error = error.localizedDescription } } })
                    }
                }
                if list.isEmpty { Text("Keine Clips in diesem Zeitraum.").foregroundStyle(Theme.mute).frame(maxWidth: .infinity).padding(30) }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("@\(streamer)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Link(destination: URL(string: "https://twitch.tv/\(streamer)")!) { Image(systemName: "arrow.up.right.square") }
            }
        }
        // the next clips in this order get downloaded in background
        .task(id: "\(sort)\(age)\(list.count)") { await connection.api?.focus("profile", list.map(\.id)) }
        .errorAlert($error)
    }
}

struct DiscoveryCard: View {
    let clip: ClipItem
    let rank: Int?
    let fresh: Bool
    let open: () -> Void
    let watch: () -> Void
    let ignore: () -> Void

    var body: some View {
        let c = clip
        let st: (String, Color) = c.status == "new" && c.ready ? ("bereit ⚡", Theme.purple)
            : c.status == "new" && c.downloaded ? ("geladen", Theme.blue)
            : c.status == "pending_review" ? ("bearbeitet", Theme.amber) : ("neu", .black.opacity(0.75))
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) { ClipThumb(clip: c, status: st, corner: rank.map { "#\($0)" }) }
            VStack(alignment: .leading, spacing: 6) {
                Text(c.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                Text("\(c.views ?? 0) Views · \(ago(c.createdDate))").font(.caption).foregroundStyle(Theme.mute)
                if let e = c.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                HStack(spacing: 6) {
                    Button(action: watch) { Image(systemName: "play.fill") }.buttonStyle(PrimaryButton(color: Color(hex: 0x1AA7A3)))
                    Button(action: open) { Text("Bearbeiten").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButton())
                    Button(action: ignore) { Image(systemName: "xmark") }.buttonStyle(SecondaryButton())
                }
                .font(.subheadline)
            }
            .padding(10)
        }
        .background(Theme.panel, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(fresh ? Color(hex: 0xE5C100) : Theme.line))
    }
}

struct Avatar: View {
    let streamer: String
    var size: CGFloat = 30
    var body: some View {
        Text(String(streamer.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .heavy)).foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Theme.acc2, Theme.acc], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
    }
}

struct PinButton: View {
    let streamer: String
    let data: DiscoveryData
    @Environment(Connection.self) private var connection
    var body: some View {
        Button { Task { await data.togglePin(streamer, connection.api) } } label: {
            Image(systemName: data.pins.contains(streamer) ? "pin.fill" : "pin").foregroundStyle(data.pins.contains(streamer) ? Theme.acc : Theme.mute)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Kanal anheften")
    }
}

/// Time window chips (minutes, 0 = all); clips older than a week are deleted on the Mac.
struct AgeChips: View {
    @Binding var age: Int
    static let options = [(0, "Alle"), (5, "5 Min"), (15, "15 Min"), (60, "1 h"), (180, "3 h"), (360, "6 h"), (720, "12 h"),
                          (1440, "24 h"), (4320, "3 Tage"), (10080, "1 Woche")]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.options, id: \.0) { v, l in
                    Button(l) { age = v }
                        .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.panel2, in: .capsule)
                        .overlay(Capsule().stroke(age == v ? Theme.acc2 : Theme.line))
                        .foregroundStyle(age == v ? Theme.acc2 : Theme.mute)
                }
            }
        }
    }
}
