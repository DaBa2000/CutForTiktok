import SwiftUI

/// Pick streamers, then newest n per channel or top n per channel of the last t minutes. Mirrors web/index.html.
struct SelectorView: View {
    @Environment(Connection.self) private var connection
    @Environment(ClipOrder.self) private var order
    @State private var clips: [ClipItem] = []
    @State private var streamers: [String] = []
    @State private var rendering: Set<String> = []
    @State private var prefetching: String?
    @State private var nextSync: Double?
    @State private var seen: Set<String>?
    @State private var fresh: Set<String> = []
    @State private var hidden: Set<String> = []  // stored on the Mac, same as the website
    @AppStorage("selectorMode") private var mode = "new"
    @AppStorage("selectorN") private var n = 5
    @AppStorage("selectorT") private var t = 60
    @AppStorage("selectorOrder") private var channelOrder = "recent"  // recent | used | top
    @State private var pins: [String] = []
    @State private var used: [String: Int] = [:]
    @State private var channel: String?  // channel view: only this channel's clips, all of them
    @State private var syncing = false
    @State private var path: [String] = []
    @State private var error: String?

    private struct Group: Identifiable { let streamer: String; let list: [ClipItem]; let total: Int; var id: String { streamer } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if let channel { channelHeader(channel) } else { filters }
                let gs = groups()
                LazyVStack(alignment: .leading, spacing: 26, pinnedViews: []) {
                    ForEach(gs) { g in section(g) }
                }
                .padding(.horizontal)
                if gs.isEmpty {
                    Text(mode == "top" ? "Keine Clips in den letzten \(t) Minuten."
                         : "Keine Clips. Der Listener lädt beim Start alle Clips seit dem eingestellten Datum, das kann kurz dauern.")
                        .foregroundStyle(Theme.mute).multilineTextAlignment(.center).padding(40)
                }
            }
            .background(Theme.bg)
            .navigationTitle(channel.map { "@\($0)" } ?? "Post Selector")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await sync() } } label: {
                        if syncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in EditorHost(startId: id, path: $path) }
            .polling(every: 15) { if path.isEmpty { await load() } }  // listener adds clips in background
            .refreshable { await load() }
            .errorAlert($error)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StreamerFilter(streamers: streamers, hidden: Binding(get: { hidden }, set: { new in
                    hidden = new
                    Task { await connection.api?.saveHidden("selector", new) }
                }), counts: Dictionary(grouping: clips, by: \.streamer).mapValues(\.count))
                    .buttonStyle(SecondaryButton())
                Picker("", selection: $mode) { Text("Neueste").tag("new"); Text("Top").tag("top") }
                    .pickerStyle(.segmented)
            }
            Picker("Kanäle", selection: $channelOrder) {
                Text("Neueste zuerst").tag("recent"); Text("Meist genutzt").tag("used"); Text("Top-Clips").tag("top")
            }
            .pickerStyle(.segmented)
            HStack {
                Stepper("\(n) pro Kanal", value: $n, in: 1...100).font(.subheadline)
            }
            if mode == "top" {
                HStack(spacing: 6) {
                    Text("aus den letzten").font(.caption).foregroundStyle(Theme.mute)
                    ForEach([(15, "15m"), (60, "1h"), (180, "3h"), (360, "6h"), (1440, "24h")], id: \.0) { v, l in
                        Button(l) { t = v }
                            .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.panel2, in: .capsule)
                            .overlay(Capsule().stroke(t == v ? Theme.acc2 : Theme.line))
                            .foregroundStyle(t == v ? Theme.acc2 : Theme.mute)
                    }
                }
            }
            HStack {
                Text(info).font(.caption).foregroundStyle(Theme.mute)
                Spacer()
                SyncCountdown(nextSync: nextSync)
            }
        }
        .padding()
    }

    private func avatar(_ s: String) -> some View {
        Text(String(s.prefix(1)).uppercased()).font(.subheadline.weight(.heavy)).foregroundStyle(.black)
            .frame(width: 30, height: 30)
            .background(LinearGradient(colors: [Theme.acc2, Theme.acc], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
    }

    private func pinButton(_ s: String) -> some View {
        Button { Task { await togglePin(s) } } label: {
            Image(systemName: pins.contains(s) ? "pin.fill" : "pin").foregroundStyle(pins.contains(s) ? Theme.acc : Theme.mute)
        }
        .buttonStyle(.plain)
    }

    private func channelHeader(_ s: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { channel = nil } label: { Label("Alle Kanäle", systemImage: "chevron.left") }.font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                avatar(s)
                Text("@\(s)").font(.title3.bold())
                pinButton(s)
                Spacer()
                Text("\(used[s] ?? 0)× genutzt").font(.caption).foregroundStyle(Theme.mute)
            }
            Picker("", selection: $mode) { Text("Neueste").tag("new"); Text("Top").tag("top") }.pickerStyle(.segmented)
        }
        .padding()
    }

    private func section(_ g: Group) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if channel == nil {
                HStack(spacing: 10) {
                    Button { channel = g.streamer } label: {
                        HStack(spacing: 10) {
                            avatar(g.streamer)
                            Text("@\(g.streamer)").font(.headline)
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Theme.mute)
                        }
                    }
                    .buttonStyle(.plain)
                    pinButton(g.streamer)
                    Text((mode == "top" ? "Top \(g.list.count) von \(g.total)" : "\(g.list.count) neueste von \(g.total)")
                         + (used[g.streamer].map { " · \($0)× genutzt" } ?? ""))
                        .font(.caption).foregroundStyle(Theme.mute).lineLimit(1)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(g.list.enumerated()), id: \.element.id) { i, c in card(c, rank: i + 1).frame(width: 260) }
                    }
                }
            } else {  // channel view: all clips as a grid
                Text("\(g.total) Clips").font(.caption).foregroundStyle(Theme.mute)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(Array(g.list.enumerated()), id: \.element.id) { i, c in card(c, rank: i + 1) }
                }
            }
        }
    }

    private func card(_ c: ClipItem, rank: Int) -> some View {
        let ready = c.status == "new" && c.ready
        let st: (String, Color) = ready ? ("bereit ⚡", Theme.purple)
            : c.status == "pending_review" ? ("bearbeitet", Theme.amber) : c.status == "failed" ? ("Fehler", Theme.red) : ("neu", .black.opacity(0.75))
        return VStack(alignment: .leading, spacing: 0) {
            Button { open(c) } label: { ClipThumb(clip: c, status: st, corner: mode == "top" ? "#\(rank)" : nil) }
            VStack(alignment: .leading, spacing: 6) {
                Text(c.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                Text("\(c.views ?? 0) Views · \(ago(c.createdDate))").font(.caption).foregroundStyle(Theme.mute)
                if let e = c.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                HStack(spacing: 6) {
                    Button { open(c) } label: { Text("Bearbeiten").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButton())
                    Button { Task { await ignore(c) } } label: { Text("Ignorieren") }.buttonStyle(SecondaryButton())
                }
                .font(.subheadline)
            }
            .padding(10)
        }
        .background(Theme.panel, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(fresh.contains(c.id) ? Color(hex: 0xE5C100) : Theme.line))
    }

    private var info: String {
        let gs = groups()
        var s = "\(gs.reduce(0) { $0 + $1.list.count }) Clips aus \(gs.count) Kanälen"
        if !fresh.isEmpty { s += " · \(fresh.count) neu" }
        if !rendering.isEmpty { s += " · \(rendering.count) exportiert gerade" }
        if let p = prefetching { s += " · bereite vor: " + (clips.first { $0.id == p }?.displayTitle ?? "…") }
        return s
    }

    /// newest n per channel, or top n per channel by views among clips of the last t minutes
    private func groups() -> [Group] {
        let since = Date().addingTimeInterval(-Double(t) * 60)
        var by: [String: [ClipItem]] = [:]
        for c in clips where (channel.map { c.streamer == $0 } ?? !hidden.contains(c.streamer)) && !rendering.contains(c.id) {
            if channel == nil, mode == "top", (c.createdDate ?? .distantPast) < since { continue }
            by[c.streamer, default: []].append(c)
        }
        let top = mode == "top"
        let sortKey: (ClipItem, ClipItem) -> Bool = top ? { ($0.views ?? 0) > ($1.views ?? 0) }
            : { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
        let maxViews = { (g: Group) in g.list.map { $0.views ?? 0 }.max() ?? 0 }
        return by.map { s, list in
            let sorted = list.sorted(by: sortKey)
            return Group(streamer: s, list: channel == nil ? Array(sorted.prefix(n)) : sorted, total: list.count)
        }
        .sorted { a, b in
            let pa = pins.contains(a.streamer), pb = pins.contains(b.streamer)
            if pa != pb { return pa }  // pinned channels first
            switch channelOrder {
            case "used":
                let ua = used[a.streamer] ?? 0, ub = used[b.streamer] ?? 0
                return ua != ub ? ua > ub : maxViews(a) > maxViews(b)
            case "top": return maxViews(a) > maxViews(b)
            default: return sortKey(a.list[0], b.list[0])
            }
        }
    }

    /// round robin over channels: "next clip" in the editor follows the top of every channel first
    private func roundRobin() -> [String] {
        let gs = groups()
        var out: [String] = []
        let rounds = gs.map(\.list.count).max() ?? 0
        for i in 0..<rounds { for g in gs where i < g.list.count { out.append(g.list[i].id) } }
        return out
    }

    private func open(_ c: ClipItem) {
        order.ids = roundRobin()
        path.append(c.id)
    }

    private func load() async {
        guard let api = connection.api, let j: ClipsResponse = try? await api.get("/api/clips") else { return }
        if let seen { for c in j.clips where !seen.contains(c.id) { fresh.insert(c.id) } }
        seen = Set(j.clips.map(\.id))
        clips = j.clips
        streamers = j.streamers ?? []
        rendering = Set(j.rendering ?? [])
        prefetching = j.prefetch?.current
        nextSync = j.next_sync
        pins = j.pins ?? []
        hidden = Set(j.hidden ?? [])
        used = j.used ?? [:]
    }

    private func togglePin(_ s: String) async {
        if let i = pins.firstIndex(of: s) { pins.remove(at: i) } else { pins.append(s) }
        try? await connection.api?.post("/api/pins", ["pins": pins])
    }

    private func ignore(_ c: ClipItem) async {
        guard let api = connection.api else { return }
        do {
            try await api.setStatus(c.id, "ignored")
            clips.removeAll { $0.id == c.id }
            fresh.remove(c.id)
        } catch { self.error = error.localizedDescription }
    }

    private func sync() async {
        guard let api = connection.api else { return }
        syncing = true
        do { try await api.post("/api/sync") } catch { self.error = error.localizedDescription }
        await load()
        syncing = false
    }
}
