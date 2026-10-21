import SwiftUI

/// Touch version of web/editor.html: stage (9:16 preview or source with facecam box), transport + trim,
/// then tabs Bild / Text / Untertitel, and Ignorieren / Exportieren & weiter at the bottom.
/// Changes are autosaved. Perspective switches and cut-out ranges are edited in the web editor (⋯ → Web-Editor).
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

    enum Stage: String, CaseIterable { case preview = "Vorschau", source = "Facecam & Spiel" }
    enum Tab: String, CaseIterable { case picture = "Bild", text = "Text", subs = "Untertitel" }

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
                Button {
                    Task {
                        await m?.save()  // web editor loads the saved state
                        if let api = connection.api { web = IdentifiedURL(url: api.mediaURL("/edit/\(clipId)")) }
                    }
                } label: { Label("Web-Editor", systemImage: "safari") }
                .help("Perspektiven-Wechsel und ausgeschnittene Bereiche")
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
                        if stage == .preview {
                            PreviewStage(m: m).frame(maxHeight: 440)
                        } else {
                            SourceStage(m: m)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    TransportBar(m: m)
                    Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.segmented)
                    switch tab {
                    case .picture: PictureTab(m: m, showSource: { stage = .source })
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

// MARK: - transport + trim

private struct TransportBar: View {
    @Bindable var m: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { m.togglePlay() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 34) }
                TrimScrubber(m: m)
                Text(fmt(m.time)).font(.caption.monospacedDigit()).foregroundStyle(Theme.mute).frame(width: 40)
            }
            HStack(spacing: 8) {
                Button { m.trimStart = min((m.time * 10).rounded() / 10, m.trimEnd - 1) } label: { Label("Start", systemImage: "arrow.right.to.line") }
                Text("\(fmt(m.trimStart))–\(fmt(m.trimEnd)) · \(fmt(m.trimEnd - m.trimStart))s")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.mute).frame(maxWidth: .infinity)
                Button { m.trimEnd = max((m.time * 10).rounded() / 10, m.trimStart + 1) } label: { Label("Ende", systemImage: "arrow.left.to.line") }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
    }
}

/// Full clip timeline; the trimmed part is highlighted, its edges can be dragged, tap/drag elsewhere seeks.
private struct TrimScrubber: View {
    @Bindable var m: EditorModel
    @State private var grab: Grab?
    enum Grab { case start, end, seek }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(m.duration, 0.1)
            let x = { (t: Double) in CGFloat(t / d) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panel2).frame(height: 8)
                Rectangle().fill(Theme.acc.opacity(0.45)).frame(width: max(0, x(m.trimEnd) - x(m.trimStart)), height: 8).offset(x: x(m.trimStart))
                handle.offset(x: x(m.trimStart) - 5)
                handle.offset(x: x(m.trimEnd) - 5)
                Rectangle().fill(.white).frame(width: 2, height: 22).offset(x: x(m.time) - 1)
            }
            .frame(height: 30)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let t = clamp(Double(g.location.x / w) * d, 0, d)
                    if grab == nil {
                        let ds = abs(g.startLocation.x - x(m.trimStart)), de = abs(g.startLocation.x - x(m.trimEnd))
                        grab = min(ds, de) < 18 ? (ds < de ? .start : .end) : .seek
                    }
                    switch grab {
                    case .start: m.trimStart = (min(t, m.trimEnd - 1) * 10).rounded() / 10; Task { await m.seek(m.trimStart) }
                    case .end: m.trimEnd = (max(t, m.trimStart + 1) * 10).rounded() / 10; Task { await m.seek(m.trimEnd) }
                    default: Task { await m.seek(t) }
                    }
                }
                .onEnded { _ in grab = nil })
        }
        .frame(height: 30)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Theme.acc).frame(width: 10, height: 26)
    }
}

// MARK: - tabs

private struct PictureTab: View {
    @Bindable var m: EditorModel
    let showSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Facecam vorhanden", isOn: Binding(get: { m.cam != nil }, set: { m.setHasCam($0) }))
            HStack {
                Button("Facecam neu erkennen") { Task { await m.redetect() } }.disabled(m.busy)
                Spacer()
                Button("Box verschieben") { showSource() }
            }
            .font(.subheadline).buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 4) {
                Text("Spiel-Ausschnitt (horizontal)").font(.caption).foregroundStyle(Theme.mute)
                Slider(value: $m.gameX, in: 0...1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Mehr Sicht (schwarze Balken oben/unten)").font(.caption).foregroundStyle(Theme.mute)
                Slider(value: $m.zoom, in: 0...1)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Facecam-Höhe \(Int(m.camH)) px").font(.caption).foregroundStyle(Theme.mute)
                    Spacer()
                    Button("Zurücksetzen") { m.setSplit(m.R.cam_height) }.font(.caption)
                }
                Slider(value: Binding(get: { m.camH }, set: { m.setSplit($0) }), in: 240...1400)
            }.disabled(m.cam == nil)
            Text("Facecam-Position, Höhe und Ausschnitt werden automatisch für @\(m.clip?.streamer ?? "") gemerkt.")
                .font(.caption).foregroundStyle(Theme.mute)
            if !m.switches.isEmpty || !m.cuts.isEmpty {
                Label("\(m.switches.count) Perspektiven-Wechsel · \(m.cuts.count) ausgeschnittene Bereiche – bearbeiten im Web-Editor (oben rechts)",
                      systemImage: "rectangle.2.swap")
                    .font(.caption).foregroundStyle(Theme.acc2)
            }
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
