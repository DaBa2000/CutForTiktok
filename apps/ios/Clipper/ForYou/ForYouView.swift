import AVKit
import SwiftUI

/// For You tab: all streamers of the active configuration.
struct ForYouView: View {
    var body: some View {
        NavigationStack { ForYouFeed() }
    }
}

/// Untouched clips one at a time: Behalten (→ Edit) / Ignorieren, swipe up/down to browse. Ranked ("Für dich"),
/// newest or top first. With `streamer`: that streamer's profile "For You style" (pushed from Discovery).
/// Mirrors web/foryou.html. The next clips get downloaded on the Mac (skip = position in the feed).
struct ForYouFeed: View {
    var streamer: String? = nil
    var initialSort: String? = nil
    var initialAge: Int? = nil
    var startId: String? = nil

    @Environment(Connection.self) private var connection
    @Environment(ConfigStore.self) private var configs
    @State private var feed: [ClipItem] = []
    @State private var idx = 0
    @State private var nextSync: Double?
    @State private var cur: ClipItem?
    @State private var decided: Set<String> = []
    @State private var undoStack: [ClipItem] = []
    @State private var excluding: String?  // "Streamer ausblenden" confirmation
    @AppStorage("foryouAge") private var savedAge = 0  // only clips of the last n minutes (0 = all)
    @AppStorage("foryouSort") private var savedSort = "rank"
    @State private var age = 0
    @State private var sort = "rank"
    @State private var started = false
    @State private var pendingStart: String?
    @State private var player = AVPlayer()
    @State private var playing: String?  // clip id loaded in the player (main clip or a perspective)
    @State private var persp: [Perspective] = []
    @State private var view: Perspective?  // perspective shown (nil = the clip itself)
    @State private var loadingPersp: String?
    @State private var drag: CGFloat = 0
    @State private var error: String?

    private var sorts: [(String, String)] {
        streamer == nil ? [("rank", "Für dich"), ("new", "Neueste"), ("top", "Top")] : [("new", "Neueste"), ("top", "Top")]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Picker("", selection: $sort) { ForEach(sorts, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.segmented)
                AgeChips(age: $age)
            }
            .padding(.horizontal).padding(.top, 6)
            if let c = cur { stage(c) } else { empty }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.bg)
        .navigationTitle(streamer.map { "@\($0)" } ?? "For You")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if streamer == nil { ToolbarItem(placement: .topBarLeading) { ConfigMenu() } }
            ToolbarItem(placement: .principal) { SyncCountdown(nextSync: nextSync) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await undoLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(undoStack.isEmpty)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            sort = initialSort ?? (streamer == nil ? savedSort : "new")
            age = initialAge ?? (streamer == nil ? savedAge : 0)
            pendingStart = startId
        }
        .onChange(of: sort) { if streamer == nil { savedSort = sort }; restart() }
        .onChange(of: age) { if streamer == nil { savedAge = age }; restart() }
        .onChange(of: configs.version) { restart() }
        .polling(every: 4) { await load() }  // downloads finishing, new clips
        .onDisappear { player.pause() }
        .errorAlert($error)
        .confirmationDialog("@\(excluding ?? "") ausblenden?", isPresented: Binding(get: { excluding != nil }, set: { if !$0 { excluding = nil } }),
                            titleVisibility: .visible) {
            Button("Ausblenden", role: .destructive) { if let s = excluding { Task { await exclude(s) } } }
        } message: { Text("Aus der aktiven Konfiguration nehmen (in den Einstellungen wieder einschaltbar).") }
    }

    private func restart() {
        guard started else { return }
        cur = nil
        idx = 0
        Task { await load() }
    }

    // MARK: views

    private func stage(_ c: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Color.black
                if c.ready {
                    VideoPlayer(player: player)
                } else {
                    AsyncImage(url: c.thumbURL) { $0.resizable().scaledToFit() } placeholder: { Color.black }
                    VStack(spacing: 10) { ProgressView().tint(Theme.acc2); Text("wird geladen…").bold() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.55))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(c.displayTitle).font(.title3.weight(.heavy))
                HStack(spacing: 6) {
                    Text("@\(c.streamer)")
                    if streamer == nil {
                        Button { excluding = c.streamer } label: { Image(systemName: "nosign") }
                            .buttonStyle(.borderless).tint(Theme.mute)
                            .accessibilityLabel("@\(c.streamer) ausblenden")
                    }
                    Text("· \(c.views ?? 0) Views · vor \(ago(c.createdDate)) · \(Int((c.duration ?? 0).rounded()))s")
                    if (c.parts ?? 1) > 1 { Pill(text: "🔗 \(c.parts!)", color: Theme.purple) }
                }
                .font(.subheadline).foregroundStyle(Theme.mute)
            }

            if let e = c.error { Text(e).font(.footnote).foregroundStyle(.red) }
            if !persp.isEmpty { perspectives(c) }

            HStack(spacing: 12) {
                Button { Task { await decide("ignored") } } label: { Label("Ignorieren", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButton())
                Button { Task { await decide("kept") } } label: { Label("Behalten", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButton())
            }
            .font(.title3)
            HStack(spacing: 12) {
                Button { step(-1) } label: { Label("Vorheriger", systemImage: "chevron.up").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButton()).disabled(idx == 0)
                Button { step(1) } label: { Label("Nächster", systemImage: "chevron.down").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButton()).disabled(idx >= feed.count - 1)
            }
            .font(.subheadline)
            Text("Wischen: ← ignorieren · → behalten · ↑↓ blättern · Clip \(idx + 1) von \(feed.count)")
                .font(.caption).foregroundStyle(Theme.mute).frame(maxWidth: .infinity)
        }
        .padding()
        .offset(x: drag)
        .rotationEffect(.degrees(Double(drag / 40)))
        .overlay {
            if abs(drag) > 30 {
                Image(systemName: drag > 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 90)).foregroundStyle(drag > 0 ? Theme.acc : Theme.mute)
                    .opacity(Double(min(1, abs(drag) / 120)))
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 25)
                .onChanged { g in if abs(g.translation.width) > abs(g.translation.height) { drag = g.translation.width } }
                .onEnded { g in
                    let d = drag
                    withAnimation(.spring(duration: 0.25)) { drag = 0 }
                    if d > 110 { Task { await decide("kept") } } else if d < -110 { Task { await decide("ignored") } }
                    else if abs(g.translation.height) > 120 && abs(g.translation.height) > abs(g.translation.width) * 2 {
                        step(g.translation.height < 0 ? 1 : -1)  // swipe up = next clip, like TikTok
                    }
                }
        )
    }

    private func perspectives(_ c: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("👀 Gleichzeitig").font(.caption).foregroundStyle(Theme.mute)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    perspButton("@\(c.streamer)", "Original", on: view == nil) { switchTo(nil) }
                    ForEach(persp) { p in
                        perspButton("@\(p.streamer)", loadingPersp == p.id ? "lädt…" : "\(fmtS(p.from))–\(fmtS(p.to))\(p.ready ? "" : " ⤓")",
                                    on: view?.id == p.id) { switchTo(p) }
                    }
                }
            }
        }
    }

    private func perspButton(_ t: String, _ sub: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            (Text(t).bold() + Text(" " + sub).font(.caption).foregroundStyle(on ? Color(hex: 0x004444) : Theme.mute))
                .font(.subheadline).padding(.horizontal, 11).padding(.vertical, 6)
                .background(on ? Theme.acc2 : Theme.panel, in: .capsule)
                .foregroundStyle(on ? .black : Theme.fg)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("🎉").font(.system(size: 50))
            Text(age > 0 ? "Keine offenen Clips in diesem Zeitraum." : "Alles gesichtet.").bold()
            Text("Neue Clips kommen mit dem nächsten Scan.").foregroundStyle(Theme.mute)
        }
        .frame(maxWidth: .infinity).padding(.top, 120)
    }

    // MARK: logic

    private func exclude(_ streamer: String) async {
        struct Body: Encodable { let streamer: String }
        do { try await connection.api?.post("/api/filters/exclude", Body(streamer: streamer)) } catch { self.error = error.localizedDescription }
        await configs.load(connection.api)
        cur = nil
        await load()
    }

    private func load() async {
        guard let api = connection.api, started else { return }
        var q = [URLQueryItem(name: "sort", value: sort), URLQueryItem(name: "skip", value: "\(idx)")]
        if age > 0 { q.append(URLQueryItem(name: "age", value: "\(age)")) }
        if let streamer { q.append(URLQueryItem(name: "streamer", value: streamer)) }
        var comps = URLComponents(); comps.path = "/api/foryou"; comps.queryItems = q
        guard let j: ClipsResponse = try? await api.get(comps.string ?? "/api/foryou") else { return }
        configs.check(j.config, api)
        feed = j.clips.filter { !decided.contains($0.id) }
        nextSync = j.next_sync
        if let s = pendingStart, let k = feed.firstIndex(where: { $0.id == s }) { idx = k; pendingStart = nil; cur = nil }
        // keep the clip on screen until decided / skipped; just refresh its data (e.g. download finished)
        if let c = cur, let k = feed.firstIndex(where: { $0.id == c.id }) {
            idx = k
            cur = feed[k]
            if feed[k].ready && playing == nil { show(feed[k]) }
        } else {
            idx = min(idx, max(0, feed.count - 1))
            show(feed.indices.contains(idx) ? feed[idx] : nil)
        }
    }

    /// browse without deciding (swipe up / down)
    private func step(_ d: Int) {
        let n = idx + d
        guard feed.indices.contains(n) else { return }
        idx = n
        show(feed[n])
        Task { await load() }  // the Mac downloads the clips after this one
    }

    private func show(_ c: ClipItem?) {
        cur = c
        view = nil
        persp = []
        playing = nil
        player.replaceCurrentItem(with: nil)
        guard let c, let api = connection.api else { return }
        if c.ready {
            player.replaceCurrentItem(with: AVPlayerItem(url: api.mediaURL("/raw/\(c.id)")))
            player.play()
            playing = c.id
        }
        Task {
            let list: [Perspective] = (try? await api.get("/api/clip/\(c.id)/perspectives")) ?? []
            if cur?.id == c.id { persp = list }
        }
    }

    private func switchTo(_ p: Perspective?) {
        guard let c = cur, let api = connection.api, p?.id != view?.id, playing != nil else { return }
        let mainT = player.currentTime().seconds - (view?.off ?? 0)  // position in the clip's own timeline
        Task {
            if let p, !p.ready {
                loadingPersp = p.id
                do { try await api.post("/api/clip/\(p.id)/fetch") } catch { self.error = error.localizedDescription; loadingPersp = nil; return }
                loadingPersp = nil
                if let i = persp.firstIndex(where: { $0.id == p.id }) { persp[i].ready = true }
            }
            let wasPlaying = player.rate > 0
            view = p
            let item = AVPlayerItem(url: api.mediaURL("/raw/\(p?.id ?? c.id)"))
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: max(0, mainT + (p?.off ?? 0)), preferredTimescale: 600))
            if wasPlaying { player.play() }
        }
    }

    private func decide(_ status: String) async {
        guard let c = cur, let api = connection.api else { return }
        decided.insert(c.id)
        undoStack.append(c)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        feed.removeAll { decided.contains($0.id) }
        idx = min(idx, max(0, feed.count - 1))
        show(feed.indices.contains(idx) ? feed[idx] : nil)
        do { try await api.setStatus(c.id, status) } catch { self.error = error.localizedDescription }
        await load()
    }

    private func undoLast() async {
        guard let c = undoStack.popLast(), let api = connection.api else { return }
        try? await api.setStatus(c.id, "new")
        decided.remove(c.id)
        pendingStart = c.id
        cur = nil
        await load()
    }

    private func fmtS(_ s: Double) -> String { "\(Int(s) / 60):\(String(format: "%02d", Int(s.rounded()) % 60))" }
}
