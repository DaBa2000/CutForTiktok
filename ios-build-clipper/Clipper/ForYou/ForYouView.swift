import AVKit
import SwiftUI

/// Ranked untouched clips one at a time: Behalten (→ Edit) / Ignorieren. Mirrors web/foryou.html.
struct ForYouView: View {
    @Environment(Connection.self) private var connection
    @State private var feed: [ClipItem] = []
    @State private var streamers: [String] = []
    @State private var nextSync: Double?
    @State private var cur: ClipItem?
    @State private var decided: Set<String> = []
    @State private var undoStack: [ClipItem] = []
    @State private var kept = 0
    @State private var ignored = 0
    @State private var hidden = storedSet("foryouHidden")
    @AppStorage("foryouAge") private var age = 0  // only clips of the last n minutes (0 = all)
    @State private var player = AVPlayer()
    @State private var playing: String?  // clip id loaded in the player (main clip or a perspective)
    @State private var persp: [Perspective] = []
    @State private var view: Perspective?  // perspective shown (nil = the clip itself)
    @State private var loadingPersp: String?
    @State private var drag: CGFloat = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let c = cur { stage(c) } else { empty }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Theme.bg)
            .navigationTitle("For You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionMenu() }
                ToolbarItem(placement: .principal) { SyncCountdown(nextSync: nextSync) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await undoLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(undoStack.isEmpty)
                    AgeFilter(age: $age)
                    StreamerFilter(streamers: streamers, hidden: $hidden)
                }
            }
            .onChange(of: age) { cur = nil; Task { await load() } }
            .onChange(of: hidden) { storeSet(hidden, "foryouHidden"); cur = nil; Task { await load() } }
            .polling(every: 4) { await load() }  // downloads finishing, new clips
            .onDisappear { player.pause() }
            .errorAlert($error)
        }
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
                    Text("@\(c.streamer) · \(c.views ?? 0) Views · vor \(ago(c.createdDate)) · \(Int((c.duration ?? 0).rounded()))s")
                    if (c.parts ?? 1) > 1 { Pill(text: "🔗 \(c.parts!)", color: Theme.purple) }
                }
                .font(.subheadline).foregroundStyle(Theme.mute)
            }

            if let w = c.why {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("Views", "\(Int(w.views * 100))")
                        chip("für den Kanal", "\(Int(w.channel * 100))")
                        chip("frisch", "\(Int(w.fresh * 100))")
                        chip("Kanal", "\(w.kept)✓ / \(w.ignored)✕ → ×\(String(format: "%.2f", w.affinity))")
                    }
                }
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
            Text("Wischen: ← ignorieren · → behalten").font(.caption).foregroundStyle(Theme.mute).frame(maxWidth: .infinity)
            Text("Diese Sitzung: \(kept) behalten · \(ignored) ignoriert · \(feed.count) im Feed")
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
                }
        )
    }

    private func chip(_ k: String, _ v: String) -> some View {
        (Text(k + " ").foregroundStyle(Theme.mute) + Text(v).bold())
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.panel, in: .rect(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
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

    private func load() async {
        guard let api = connection.api else { return }
        let q = hidden.sorted().joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let j: ClipsResponse = try? await api.get("/api/foryou?hidden=\(q)" + (age > 0 ? "&age=\(age)" : "")) else { return }
        feed = j.clips.filter { !decided.contains($0.id) }
        streamers = j.streamers ?? []
        nextSync = j.next_sync
        // keep the clip on screen until decided; just refresh its data (e.g. download finished)
        if let c = cur, let same = feed.first(where: { $0.id == c.id }) {
            cur = same
            if same.ready && playing == nil { show(same) }
        } else {
            show(feed.first)
        }
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
        if status == "kept" { kept += 1 } else { ignored += 1 }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        show(feed.first { !decided.contains($0.id) })
        do { try await api.post("/api/clip/\(c.id)/status", ["status": status]) } catch { self.error = error.localizedDescription }
        await load()  // re-rank: the decision changes the channel's weight
    }

    private func undoLast() async {
        guard let c = undoStack.popLast(), let api = connection.api else { return }
        try? await api.post("/api/clip/\(c.id)/status", ["status": "new"])
        decided.remove(c.id)
        cur = nil
        await load()
        if let back = feed.first(where: { $0.id == c.id }) { show(back) }
    }

    private func fmtS(_ s: Double) -> String { "\(Int(s) / 60):\(String(format: "%02d", Int(s.rounded()) % 60))" }
}

/// Time filter like the website's chips: 15 Min … 7 Tage.
struct AgeFilter: View {
    @Binding var age: Int
    static let options = [(0, "Alle"), (15, "15 Min"), (60, "1 h"), (180, "3 h"), (360, "6 h"), (720, "12 h"),
                          (1440, "24 h"), (2880, "2 Tage"), (4320, "3 Tage"), (10080, "7 Tage")]

    var body: some View {
        Menu {
            Picker("Zeitraum", selection: $age) {
                ForEach(Self.options, id: \.0) { Text($0.1).tag($0.0) }
            }
        } label: {
            Label(age == 0 ? "Zeit" : Self.options.first { $0.0 == age }?.1 ?? "", systemImage: "clock")
                .labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                .foregroundStyle(age == 0 ? Theme.fg : Theme.acc2)
        }
    }
}
