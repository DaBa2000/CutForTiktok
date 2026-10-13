import SwiftUI

/// Kept (For You) + edited, not yet exported. Mirrors web/editlist.html.
struct EditListView: View {
    @Environment(Connection.self) private var connection
    @Environment(ClipOrder.self) private var order
    @State private var clips: [ClipItem] = []
    @State private var rendering: Set<String> = []
    @State private var current: String?
    @State private var titles: [String: String] = [:]  // edited overlay titles not yet saved
    @State private var savedId: String?
    @State private var path: [String] = []
    @State private var error: String?
    @FocusState private var focused: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(clips) { c in card(c) }
                }
                .padding()
                if clips.isEmpty {
                    VStack(spacing: 6) {
                        Text("Noch nichts zum Bearbeiten.")
                        Text("Im For-You-Feed Clips behalten.").foregroundStyle(Theme.mute)
                    }
                    .padding(.top, 100)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Edit")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionMenu() }
                ToolbarItem(placement: .topBarTrailing) { Text(info).font(.caption).foregroundStyle(Theme.mute) }
            }
            .navigationDestination(for: String.self) { id in EditorHost(startId: id, path: $path) }
            .polling(every: 4) { if path.isEmpty { await load() } }
            .errorAlert($error)
        }
    }

    private var info: String {
        let ready = clips.filter(\.ready).count
        return "\(clips.count) Clips · \(ready) bereit"
    }

    private func state(_ c: ClipItem) -> (String, Color) {
        if rendering.contains(c.id) { return ("exportiert gerade…", Theme.ok) }
        if c.error != nil && !c.ready { return ("Fehler", Theme.red) }
        if !c.ready { return (c.id == current ? "wird vorbereitet…" : "in Warteschlange", Theme.blue) }
        return c.status == "pending_review" ? ("bearbeitet", Theme.amber) : ("bereit ⚡", Theme.purple)
    }

    private func card(_ c: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open(c) } label: { ClipThumb(clip: c, status: state(c)) }.disabled(!c.ready)
            VStack(alignment: .leading, spacing: 8) {
                Text("@\(c.streamer) · \(c.views ?? 0) Views · Original: \(c.displayTitle)")
                    .font(.caption).foregroundStyle(Theme.mute).lineLimit(1)
                HStack {
                    TextField("Titel für das Video", text: titleBinding(c))
                        .font(.body.weight(.semibold))
                        .focused($focused, equals: c.id)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveTitle(c) } }
                        .padding(9).background(Theme.panel2, in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused == c.id ? Theme.acc2 : Theme.line))
                    if savedId == c.id { Image(systemName: "checkmark").foregroundStyle(Theme.ok) }
                }
                if let e = c.error { Text(e).font(.caption).foregroundStyle(.red) }
                HStack(spacing: 6) {
                    Button { open(c) } label: { Text("Bearbeiten").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButton(color: c.ready ? Theme.acc : Theme.panel2)).disabled(!c.ready)
                    Button { Task { await setStatus(c, "new") } } label: { Text("↶ Feed") }.buttonStyle(SecondaryButton())
                    Button { Task { await setStatus(c, "ignored") } } label: { Text("Ignorieren") }.buttonStyle(SecondaryButton())
                }
                .font(.subheadline)
            }
            .padding(12)
        }
        .background(Theme.panel, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        .onChange(of: focused) { old, _ in
            if old == c.id { Task { await saveTitle(c) } }  // left the field
        }
    }

    private func titleBinding(_ c: ClipItem) -> Binding<String> {
        Binding(get: { titles[c.id] ?? c.overlay_title ?? c.title ?? "" }, set: { titles[c.id] = $0 })
    }

    private func open(_ c: ClipItem) {
        order.ids = clips.map(\.id)  // editor "Exportieren & weiter" follows this list
        path.append(c.id)
    }

    private func load() async {
        guard let api = connection.api, let j: ClipsResponse = try? await api.get("/api/editlist") else { return }
        clips = j.clips
        rendering = Set(j.rendering ?? [])
        current = j.prefetch?.current
    }

    private func saveTitle(_ c: ClipItem) async {
        guard let new = titles[c.id], new != (c.overlay_title ?? c.title ?? ""), let api = connection.api else { return }
        do {
            try await api.post("/api/clip/\(c.id)/title", ["overlay_title": new])
            if let i = clips.firstIndex(where: { $0.id == c.id }) { clips[i].overlay_title = new }
            titles[c.id] = nil
            savedId = c.id
            try? await Task.sleep(for: .seconds(1.5))
            if savedId == c.id { savedId = nil }
        } catch { self.error = error.localizedDescription }
    }

    private func setStatus(_ c: ClipItem, _ st: String) async {
        guard let api = connection.api else { return }
        do { try await api.post("/api/clip/\(c.id)/status", ["status": st]) } catch { self.error = error.localizedDescription }
        await load()
    }
}

/// Shows the editor; "Exportieren & weiter" / "Ignorieren" swap in the next clip of the list's order.
struct EditorHost: View {
    let startId: String
    @Binding var path: [String]
    @State private var id: String?
    @Environment(ClipOrder.self) private var order

    var body: some View {
        Group {
            if let id {
                EditorView(clipId: id) { done in
                    if let next = order.next(after: done) { self.id = next } else { path.removeAll() }
                }
                .id(id)
            }
        }
        .onAppear { if id == nil { id = startId } }
    }
}
