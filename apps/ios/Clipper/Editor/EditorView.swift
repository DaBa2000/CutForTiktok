import SwiftUI

/// Touch version of web/editor.html: stage (9:16 preview or source with the facecam + game frames), transport and
/// timeline (trim, cut-out ranges, perspective switches, keyframes), then tabs Bild / Schnitt / Perspektiven /
/// Keyframes / Text / Untertitel, and Ignorieren / Exportieren & weiter at the bottom. Changes are autosaved.
struct EditorView: View {
    let clipId: String
    /// called with this clip's id after "Exportieren & weiter" / "Ignorieren" → host opens the next clip
    let onDone: (String) -> Void

    @Environment(Connection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var m: EditorModel?
    @State private var stage = Stage.preview
    @State private var tab = Tab.picture
    @State private var web: IdentifiedURL?

    enum Stage: String, CaseIterable { case preview = "Vorschau", source = "Quelle & Rahmen" }
    enum Tab: String, CaseIterable { case picture = "Bild", cut = "Schnitt", persp = "Perspektiven", kf = "Keyframes", text = "Text", subs = "Untertitel" }

    var body: some View {
        Group {
            if let m {
                if m.preparing { preparing } else if let e = m.loadError { failed(e) } else if m.clip != nil { editor(m) } else { ProgressView() }
            } else { ProgressView() }
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("@\(m?.clip?.streamer ?? "")").font(.subheadline.bold())
                    Text(m?.clip?.title ?? "").font(.caption2).foregroundStyle(Theme.mute).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Im Web-Editor öffnen", systemImage: "safari") {
                        Task {
                            await m?.save()  // web editor loads the saved state
                            if let api = connection.api { web = IdentifiedURL(url: api.mediaURL("/edit/\(clipId)")) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task {
            guard m == nil, let api = connection.api else { return }
            let model = EditorModel(id: clipId, api: api)
            m = model
            await model.load()
        }
        .onDisappear {
            m?.player.pause()
            m?.other.pause()
            Task { await m?.save() }  // leaving within the autosave delay
        }
        .sheet(item: $web, onDismiss: { Task { await m?.reloadFromServer() } }) { WebEditorSheet(url: $0.url) }
    }

    private var preparing: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(Theme.acc2)
            Text("Clip wird vorbereitet:\nDownload, Facecam-Erkennung, Transkription…").multilineTextAlignment(.center)
            Text("Läuft auf dem Mac – kann ein bis zwei Minuten dauern.").font(.caption).foregroundStyle(Theme.mute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ e: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.red)
            Text(e).multilineTextAlignment(.center)
            Button("Zurück") { dismiss() }.buttonStyle(SecondaryButton())
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: editor

    private func editor(_ m: EditorModel) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("", selection: $stage) { ForEach(Stage.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.segmented)
                    Group {
                        if stage == .preview { PreviewStage(m: m).frame(maxHeight: 440) } else { SourceStage(m: m) }
                    }
                    .frame(maxWidth: .infinity)
                    HStack {
                        Text("Bearbeitet: ").foregroundStyle(Theme.mute) + Text(m.label(m.target())).foregroundStyle(Theme.acc2).bold()
                        Spacer()
                    }
                    .font(.caption)
                    TransportBar(m: m)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Tab.allCases, id: \.self) { t in
                                Button(t.rawValue) { tab = t }
                                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(tab == t ? Theme.fg : Theme.panel, in: .capsule)
                                    .foregroundStyle(tab == t ? .black : Theme.mute)
                            }
                        }
                    }
                    switch tab {
                    case .picture: PictureTab(m: m, showSource: { stage = .source })
                    case .cut: CutTab(m: m)
                    case .persp: PerspTab(m: m)
                    case .kf: KeyframeTab(m: m)
                    case .text: TextTab(m: m)
                    case .subs: SubsTab(m: m)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar(m)
        }
    }

    private func bottomBar(_ m: EditorModel) -> some View {
        VStack(spacing: 6) {
            if !m.message.isEmpty {
                Text(m.message).font(.caption).foregroundStyle(m.messageIsError ? .red : Theme.mute).lineLimit(2)
            }
            HStack(spacing: 10) {
                Button {
                    Task { if await m.ignore() { onDone(clipId) } }
                } label: { Text("Ignorieren").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButton())
                    .frame(maxWidth: 130)
                Button {
                    Task {
                        m.say("Wird im Hintergrund gerendert & exportiert…")
                        if await m.export() { UINotificationFeedbackGenerator().notificationOccurred(.success); onDone(clipId) }
                    }
                } label: {
                    HStack { if m.busy { ProgressView().tint(.white) }; Text("Exportieren & weiter ➜") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton(color: Theme.ok))
            }
            .disabled(m.busy)
        }
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)
        .background(.bar)
    }
}

// MARK: - transport + timeline

private struct TransportBar: View {
    @Bindable var m: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { m.togglePlay() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 30) }
                Button { Task { await m.seek(max(0, m.time - 0.1)) } } label: { Image(systemName: "gobackward") }
                Button { Task { await m.seek(min(m.duration, m.time + 0.1)) } } label: { Image(systemName: "goforward") }
                Text(fmt(m.time)).font(.caption.monospacedDigit()).foregroundStyle(Theme.mute)
                Spacer()
                Text("Länge \(fmt(m.finalLength))s").font(.caption.monospacedDigit()).foregroundStyle(Theme.mute)
            }
            TimelineBar(m: m)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { m.trimStart = min((m.time * 10).rounded() / 10, m.trimEnd - 1); m.fitCutsToTrim() } label: { Label("Start", systemImage: "arrow.right.to.line") }
                    Button { m.cutOut() } label: { Label("Ausschneiden", systemImage: "scissors") }
                    Button { m.addKeyframe() } label: { Label("Keyframe", systemImage: "diamond") }
                    if m.selectedCut != nil || m.selectedKeyframe != nil {
                        Button(role: .destructive) { m.deleteSelection() } label: { Label("Löschen", systemImage: "trash") }
                    }
                    Button { m.trimEnd = max((m.time * 10).rounded() / 10, m.trimStart + 1); m.fitCutsToTrim() } label: { Label("Ende", systemImage: "arrow.left.to.line") }
                }
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Full clip timeline: trimmed part (red handles), cut-out ranges (hatched red), perspective switches (cyan),
/// keyframes (yellow), in/out marks, playhead. Tap/drag seeks; drag the handles; tap a cut or keyframe to select it.
private struct TimelineBar: View {
    @Bindable var m: EditorModel
    @State private var grab: Grab?
    enum Grab: Equatable { case start, end, seek, cutStart(Int), cutEnd(Int), keyframe(UUID) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(m.duration, 0.1)
            let x = { (t: Double) in CGFloat(t / d) * w }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.panel2).frame(height: 54)
                // perspective bands
                ForEach(Array(m.switches.enumerated()), id: \.offset) { i, s in
                    if s.clip != nil {
                        let end = i + 1 < m.switches.count ? m.switches[i + 1].t : m.trimEnd
                        Text("@\(s.streamer ?? "")").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.acc2).lineLimit(1)
                            .padding(.leading, 3)
                            .frame(width: max(2, x(end) - x(s.t)), height: 12, alignment: .leading)
                            .background(Theme.acc2.opacity(0.22)).clipped()
                            .offset(x: x(s.t), y: 3)
                    }
                }
                // cut-out ranges
                ForEach(Array(m.cuts.enumerated()), id: \.offset) { i, c in
                    RoundedRectangle(cornerRadius: 3).fill(Theme.red.opacity(0.65))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(m.selectedCut == i ? .white : Theme.red, lineWidth: m.selectedCut == i ? 2 : 1))
                        .frame(width: max(3, x(c.end) - x(c.start)), height: 18)
                        .offset(x: x(c.start), y: 18)
                }
                // in / out marks
                if let a = m.markIn { Rectangle().fill(.white.opacity(0.8)).frame(width: 2, height: 54).offset(x: x(a)) }
                if let b = m.markOut { Rectangle().fill(.white.opacity(0.8)).frame(width: 2, height: 54).offset(x: x(b)) }
                // keyframes
                ForEach(m.keyframes) { k in
                    if k.ease > 0 { Rectangle().fill(Theme.kf).frame(width: x(k.ease), height: 2).offset(x: x(k.t), y: 45) }
                    Rectangle().fill(m.selectedKeyframe == k.id ? .white : Theme.kf).frame(width: 9, height: 9)
                        .rotationEffect(.degrees(45)).offset(x: x(k.t) - 4.5, y: 40)
                }
                // outside the trim
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, x(m.trimStart)), height: 54)
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, w - x(m.trimEnd)), height: 54).offset(x: x(m.trimEnd))
                handle("[").offset(x: x(m.trimStart))
                handle("]").offset(x: x(m.trimEnd) - 12)
                Rectangle().fill(.white).frame(width: 2, height: 54).offset(x: x(m.time) - 1)
            }
            .frame(height: 54)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let t = clamp(Double(g.location.x / w) * d, 0, d)
                    if grab == nil { grab = pick(g.startLocation, x: x, w: w) }
                    switch grab {
                    case .start: m.trimStart = (min(t, m.trimEnd - 1) * 10).rounded() / 10; m.fitCutsToTrim(); Task { await m.seek(m.trimStart) }
                    case .end: m.trimEnd = (max(t, m.trimStart + 1) * 10).rounded() / 10; m.fitCutsToTrim(); Task { await m.seek(m.trimEnd) }
                    case .cutStart(let i) where m.cuts.indices.contains(i):
                        m.cuts[i].start = (clamp(t, m.trimStart, m.cuts[i].end - 0.1) * 100).rounded() / 100; Task { await m.seek(m.cuts[i].start) }
                    case .cutEnd(let i) where m.cuts.indices.contains(i):
                        m.cuts[i].end = (clamp(t, m.cuts[i].start + 0.1, m.trimEnd) * 100).rounded() / 100; Task { await m.seek(m.cuts[i].end) }
                    case .keyframe(let id):
                        if let i = m.keyframes.firstIndex(where: { $0.id == id }), g.translation.width.magnitude > 4 {
                            m.keyframes[i].t = (t * 100).rounded() / 100
                        }
                        Task { await m.seek((m.keyframes.first { $0.id == id }?.t ?? t) + 0.01) }
                    default: Task { await m.seek(t) }
                    }
                }
                .onEnded { _ in
                    if case .keyframe(_)? = grab { m.keyframes.sort { $0.t < $1.t } }
                    grab = nil
                })
        }
        .frame(height: 54)
    }

    /// what a touch at p grabs: trim handles, edges of the selected cut, a keyframe, a cut (select), else seek
    private func pick(_ p: CGPoint, x: (Double) -> CGFloat, w: CGFloat) -> Grab {
        let ds = abs(p.x - x(m.trimStart)), de = abs(p.x - x(m.trimEnd))
        if min(ds, de) < 16 { return ds < de ? .start : .end }
        if let i = m.selectedCut, m.cuts.indices.contains(i) {
            if abs(p.x - x(m.cuts[i].start)) < 14 { return .cutStart(i) }
            if abs(p.x - x(m.cuts[i].end)) < 14 { return .cutEnd(i) }
        }
        if p.y > 34, let k = m.keyframes.min(by: { abs(x($0.t) - p.x) < abs(x($1.t) - p.x) }), abs(x(k.t) - p.x) < 14 {
            m.selectedKeyframe = k.id; m.selectedCut = nil
            return .keyframe(k.id)
        }
        if p.y > 14, p.y < 40, let i = m.cuts.firstIndex(where: { x($0.start) - 6 <= p.x && p.x <= x($0.end) + 6 }) {
            m.selectedCut = i; m.selectedKeyframe = nil
            return .seek
        }
        m.selectedCut = nil; m.selectedKeyframe = nil
        return .seek
    }

    private func handle(_ s: String) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Theme.acc).frame(width: 12, height: 54)
            .overlay(Text(s).font(.system(size: 10, weight: .heavy)).foregroundStyle(.white))
    }
}

// MARK: - tabs

private struct PictureTab: View {
    @Bindable var m: EditorModel
    let showSource: () -> Void

    var body: some View {
        let tg = m.target()
        VStack(alignment: .leading, spacing: 14) {
            if m.joined {
                Label("Verbundener Clip: jeder Teil hat sein eigenes Layout – im Web-Editor bearbeiten (⋯ oben rechts).", systemImage: "link")
                    .font(.caption).foregroundStyle(Theme.acc2)
            }
            Toggle("Facecam", isOn: Binding(get: { m.frames(tg).cam != nil }, set: { m.setHasCam($0) }))
            HStack {
                Button("Facecam erkennen") { Task { await m.redetect() } }.disabled(m.busy || !m.isMain(tg))
                Button("Spiel ganze Höhe") { m.gameFullHeight() }
                Spacer()
                Button("Rahmen") { showSource() }
            }
            .font(.subheadline).buttonStyle(.bordered)
            zoomSlider("Facecam-Zoom", cam: true).disabled(m.frames(tg).cam == nil)
            zoomSlider("Spiel-Zoom", cam: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Facecam-Höhe \(Int(m.camH)) px").font(.caption).foregroundStyle(Theme.mute)
                    Spacer()
                    Button("Zurücksetzen") { m.setSplit(m.R.cam_height) }.font(.caption)
                }
                Slider(value: Binding(get: { m.camH }, set: { m.setSplit($0) }), in: 240...1400)
            }.disabled(m.cam == nil)
            Text("Was im Rahmen liegt, zeigt das Video. Über das Bild hinaus = schwarz (z. B. Spiel kleiner mit Balken). In der Vorschau: ziehen = verschieben, zwei Finger = Zoom, Trennlinie = Facecam-Höhe. Wird für @\(m.clip?.streamer ?? "") gemerkt.")
                .font(.caption).foregroundStyle(Theme.mute)
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
    }

    /// width of the frame, log scale: right = zoom in (smaller frame)
    private func zoomSlider(_ title: String, cam: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.mute)
            Slider(value: Binding(get: {
                let f = m.frames(m.target())
                return -log((cam ? f.cam : f.game)?[2] ?? 1) / log(3)
            }, set: { v in
                let f = m.frames(m.target())
                guard let cur = cam ? f.cam : f.game else { return }
                m.zoomFrame(cam: cam, from: cur, k: pow(3, -v) / cur[2])
            }), in: -1...3)
        }
    }
}

private struct CutTab: View {
    @Bindable var m: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Anfang und Ende markieren (oder nur ✂: 1 s ab hier), dann ausschneiden. Im Zeitstrahl einen Bereich antippen = auswählen, seine Kanten ziehen.")
                .font(.caption).foregroundStyle(Theme.mute)
            HStack {
                Button { m.markIn = (m.time * 100).rounded() / 100 } label: { Label(m.markIn.map { "Anfang \(fmt($0))" } ?? "Anfang", systemImage: "arrow.right.to.line") }
                Button { m.markOut = (m.time * 100).rounded() / 100 } label: { Label(m.markOut.map { "Ende \(fmt($0))" } ?? "Ende", systemImage: "arrow.left.to.line") }
                Spacer()
                Button { m.cutOut() } label: { Label("Ausschneiden", systemImage: "scissors") }.buttonStyle(.borderedProminent).tint(Theme.red)
            }
            .font(.subheadline).buttonStyle(.bordered)
            ForEach(Array(m.cuts.enumerated()), id: \.offset) { i, c in
                HStack {
                    Button { m.selectedCut = i; Task { await m.seek(max(m.trimStart, c.start - 1)) } } label: {
                        Text("\(fmt(c.start)) – \(fmt(c.end)) s").font(.subheadline.monospacedDigit())
                    }
                    Text("\(fmt(c.end - c.start)) s raus").font(.caption).foregroundStyle(Theme.mute)
                    Spacer()
                    Button(role: .destructive) { m.cuts.remove(at: i); m.selectedCut = nil } label: { Image(systemName: "trash") }
                }
                .padding(8).background(m.selectedCut == i ? Theme.red.opacity(0.2) : Theme.panel2, in: .rect(cornerRadius: 8))
            }
            if m.cuts.isEmpty { Text("Nichts ausgeschnitten.").font(.caption).foregroundStyle(Theme.mute) }
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
    }
}

private struct PerspTab: View {
    @Bindable var m: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Andere Streams zur gleichen Zeit. 👁 = Vorschau (wird geladen und gespeichert), ⇄ = ab der aktuellen Zeit wechseln. In einem Wechsel bearbeitest du Facecam und Spiel dieser Perspektive.")
                .font(.caption).foregroundStyle(Theme.mute)
            if m.persp.isEmpty { Text("Keine Clips anderer Streams zur gleichen Zeit gefunden.").font(.caption).foregroundStyle(Theme.mute) }
            ForEach(m.persp) { p in
                let here = m.time >= p.from && m.time < p.to
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(p.streamer)").bold()
                        Text("deckt \(fmt(p.from))–\(fmt(p.to)) s" + (m.loadingPersp.contains(p.id) ? " · lädt…" : m.pv[p.id] != nil ? " · ✓" : ""))
                            .font(.caption).foregroundStyle(Theme.mute)
                    }
                    Spacer()
                    Button { Task { await m.togglePeek(p) } } label: { Image(systemName: m.peek == p.id ? "eye.fill" : "eye") }
                        .buttonStyle(.bordered).tint(m.peek == p.id ? Theme.acc2 : nil)
                    Button { Task { await m.addSwitch(p) } } label: { Text("⇄ ab hier") }
                        .buttonStyle(.bordered).disabled(!here)
                }
                .padding(8).background(m.peek == p.id ? Theme.acc2.opacity(0.15) : Theme.panel2, in: .rect(cornerRadius: 8))
            }
            Text("Wechsel im Video").font(.caption.bold()).foregroundStyle(Theme.mute).padding(.top, 6)
            ForEach(Array(m.switches.enumerated()), id: \.offset) { i, s in
                HStack {
                    Button { Task { await m.seek(s.t + 0.01) } } label: { Text(fmt(s.t)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.acc2) }
                    Text("→ " + (s.clip != nil ? "@\(s.streamer ?? "")" : "@\(m.clip?.streamer ?? "") (zurück)")).bold()
                    Spacer()
                    Button(role: .destructive) { m.switches.remove(at: i) } label: { Image(systemName: "xmark") }
                }
            }
            Button { m.backToMain() } label: { Label("ab hier wieder @\(m.clip?.streamer ?? "")", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.bordered).font(.subheadline)
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
    }
}

private struct KeyframeTab: View {
    @Bindable var m: EditorModel
    static let eases: [(Double, String)] = [(0, "Sprung"), (0.3, "0,3 s"), (0.5, "0,5 s"), (1, "1 s"), (2, "2 s"), (3, "3 s")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyframes ändern Facecam und Spiel während des Clips: ab dem Keyframe gilt sein Layout, als Sprung oder fließender Übergang. Zwischen zwei Keyframes bearbeitest du den vorherigen.")
                .font(.caption).foregroundStyle(Theme.mute)
            Button { m.addKeyframe() } label: { Label("Keyframe hier", systemImage: "diamond") }.buttonStyle(.bordered).disabled(m.joined)
            ForEach($m.keyframes) { $k in
                HStack {
                    Button { m.selectedKeyframe = k.id; Task { await m.seek(k.t + 0.01) } } label: {
                        Text("◆ \(fmt(k.t)) s").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.kf)
                    }
                    Spacer()
                    Picker("Übergang", selection: $k.ease) { ForEach(Self.eases, id: \.0) { Text($0.1).tag($0.0) } }
                    Button(role: .destructive) { m.keyframes.removeAll { $0.id == k.id } } label: { Image(systemName: "trash") }
                }
                .padding(8).background(m.selectedKeyframe == k.id ? Theme.kf.opacity(0.15) : Theme.panel2, in: .rect(cornerRadius: 8))
            }
            if m.keyframes.isEmpty { Text("Noch keine Keyframes.").font(.caption).foregroundStyle(Theme.mute) }
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
    }
}

private struct TextTab: View {
    @Bindable var m: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Titel-Einblendung (erste Sekunden)").font(.caption).foregroundStyle(Theme.mute)
            TextField("leer = kein Titel", text: $m.overlayTitle, axis: .vertical)
                .onChange(of: m.overlayTitle) { m.titleChanged() }
                .padding(10).background(Theme.panel2, in: .rect(cornerRadius: 9))
            Text("Beschreibung (TikTok)").font(.caption).foregroundStyle(Theme.mute).padding(.top, 6)
            TextEditor(text: $m.caption)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(6).background(Theme.panel2, in: .rect(cornerRadius: 9))
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
    }
}

private struct SubsTab: View {
    @Bindable var m: EditorModel
    @State private var texts: [UUID: String] = [:]
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zeit antippen springt dorthin · Text ändern verteilt das Timing neu · ⋯ für Start/Ende")
                .font(.caption).foregroundStyle(Theme.mute)
            let cur = m.currentSubIndex
            ForEach(Array(m.subs.enumerated()), id: \.element.id) { i, c in
                HStack(spacing: 8) {
                    Button { Task { await m.seek(c.start) } } label: {
                        Text("\(fmt(c.start))\n\(fmt(c.end))").font(.caption2.monospacedDigit()).multilineTextAlignment(.trailing)
                            .foregroundStyle(i == cur ? Theme.acc2 : Theme.mute).frame(width: 40)
                    }
                    TextField("", text: Binding(get: { texts[c.id] ?? c.text }, set: { texts[c.id] = $0 }))
                        .focused($focused, equals: c.id)
                        .submitLabel(.done)
                        .onSubmit { commit(c.id) }
                        .padding(8).background(Theme.panel2, in: .rect(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(i == cur ? Color(hex: 0xE5C100) : .clear))
                    Menu {
                        Button("Start = aktuelle Zeit", systemImage: "arrow.right.to.line") { m.updateSub(c.id, start: (m.time * 100).rounded() / 100) }
                        Button("Ende = aktuelle Zeit", systemImage: "arrow.left.to.line") { m.updateSub(c.id, end: (m.time * 100).rounded() / 100) }
                        Button("0,1s früher", systemImage: "backward") { m.updateSub(c.id, start: c.start - 0.1, end: c.end - 0.1) }
                        Button("0,1s später", systemImage: "forward") { m.updateSub(c.id, start: c.start + 0.1, end: c.end + 0.1) }
                        Button("Löschen", systemImage: "trash", role: .destructive) { m.subs.removeAll { $0.id == c.id } }
                    } label: { Image(systemName: "ellipsis").frame(width: 28, height: 32) }
                }
            }
            Button { let id = m.addSub(); focused = id } label: { Label("Zeile bei aktueller Zeit", systemImage: "plus") }
                .buttonStyle(.bordered).padding(.top, 4)
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
        .onChange(of: focused) { old, new in
            if let old { commit(old) }
            if let new, let c = m.subs.first(where: { $0.id == new }) { Task { await m.seek(c.start) } }
        }
    }

    private func commit(_ id: UUID) {
        guard let t = texts.removeValue(forKey: id) else { return }
        m.updateSub(id, text: t)
    }
}
