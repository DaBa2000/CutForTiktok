import SwiftUI

/// Configurations (same as the website's /settings): name, which streamers are shown (all or a selection) and
/// pinned channels. The active one applies everywhere: For You, Discovery, background downloads.
struct SettingsView: View {
    @Environment(Connection.self) private var connection
    @Environment(ConfigStore.self) private var configs
    @State private var editing: ConfigItem?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(configs.list) { c in
                        HStack {
                            Button {
                                Task { do { try await configs.activate(c.id, connection.api) } catch { self.error = error.localizedDescription } }
                            } label: {
                                HStack {
                                    Image(systemName: c.id == configs.active ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(c.id == configs.active ? Theme.ok : Theme.mute)
                                    VStack(alignment: .leading) {
                                        Text(c.name).bold()
                                        Text(c.streamers.map { "\($0.count) Streamer" } ?? "Alle Streamer")
                                            + Text((c.pins ?? []).isEmpty ? "" : " · \(c.pins!.count) 📌")
                                    }
                                    .foregroundStyle(Theme.fg)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button("Bearbeiten") { editing = c }.font(.subheadline).buttonStyle(.bordered)
                        }
                    }
                    Button { editing = ConfigItem(id: "", name: "", streamers: [], pins: []) } label: {
                        Label("Neue Konfiguration", systemImage: "plus")
                    }
                } header: { Text("Konfigurationen") } footer: {
                    Text("Die aktive Konfiguration gilt überall: For You, Discovery, Streamer-Profile und die Downloads im Hintergrund – in der App und auf der Website.")
                }
                Section("Verbindung") {
                    LabeledContent("Mac", value: connection.server?.host() ?? "–")
                    Button("Verbindung trennen", role: .destructive) { connection.unpair() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Einstellungen")
            .refreshable { await configs.load(connection.api) }
            .task { await configs.load(connection.api) }
            .sheet(item: $editing) { c in ConfigEditor(config: c) }
            .errorAlert($error)
        }
    }
}

/// Create / change one configuration.
struct ConfigEditor: View {
    @Environment(Connection.self) private var connection
    @Environment(ConfigStore.self) private var configs
    @Environment(\.dismiss) private var dismiss
    @State var config: ConfigItem
    @State private var all = true
    @State private var picked: Set<String> = []
    @State private var pins: Set<String> = []
    @State private var query = ""
    @State private var error: String?
    @State private var confirmDelete = false

    var isNew: Bool { config.id.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                Section { TextField("Name, z. B. „Craft Attack Top 10“", text: $config.name) }
                Section {
                    Picker("Streamer", selection: $all) {
                        Text("Alle").tag(true); Text("Auswahl").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: all) { if !all && picked.isEmpty { picked = Set(configs.all) } }
                } footer: {
                    Text(all ? "Alle Streamer aus accounts.txt, auch neu hinzugefügte." : "\(picked.count) von \(configs.all.count) ausgewählt · 📌 = angeheftet (Discovery oben, Clips werden im Hintergrund geladen)")
                }
                Section {
                    if !all {
                        HStack {
                            Button("Alle") { picked.formUnion(shown) }
                            Spacer()
                            Button("Keine") { picked.subtract(shown) }
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(shown, id: \.self) { s in
                        HStack {
                            Button {
                                if picked.contains(s) { picked.remove(s) } else { picked.insert(s) }
                            } label: {
                                Label("@\(s)", systemImage: all || picked.contains(s) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(all || picked.contains(s) ? Theme.fg : Theme.mute)
                            }
                            .buttonStyle(.plain)
                            .disabled(all)
                            Spacer()
                            Button {
                                if pins.contains(s) { pins.remove(s) } else { pins.insert(s) }
                            } label: {
                                Image(systemName: pins.contains(s) ? "pin.fill" : "pin").foregroundStyle(pins.contains(s) ? Theme.acc : Theme.mute)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !isNew && configs.list.count > 1 {
                    Section { Button("Konfiguration löschen", role: .destructive) { confirmDelete = true } }
                }
            }
            .searchable(text: $query, prompt: "Streamer suchen")
            .navigationTitle(isNew ? "Neue Konfiguration" : "Bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button("Speichern") { Task { await save(activate: false) } }
                        Button("Speichern & aktivieren") { Task { await save(activate: true) } }
                    } label: { Text("Speichern").bold() } primaryAction: { Task { await save(activate: isNew) } }
                }
            }
            .onAppear {
                all = config.streamers == nil
                picked = Set(config.streamers ?? [])
                pins = Set(config.pins ?? [])
            }
            .confirmationDialog("„\(config.name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { Task { await delete() } }
            }
            .errorAlert($error)
        }
    }

    private var shown: [String] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? configs.all : configs.all.filter { $0.contains(q) }
    }

    private func save(activate: Bool) async {
        struct Body: Encodable {
            let op = "save"; let id: String?; let name: String; let streamers: [String]?; let pins: [String]; let activate: Bool
            enum CodingKeys: String, CodingKey { case op, id, name, streamers, pins, activate }
            func encode(to e: Encoder) throws {
                var c = e.container(keyedBy: CodingKeys.self)
                try c.encode(op, forKey: .op); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
                try c.encode(streamers, forKey: .streamers)  // explicit null = all streamers
                try c.encode(pins, forKey: .pins); try c.encode(activate, forKey: .activate)
            }
        }
        guard let api = connection.api else { return }
        if config.name.trimmingCharacters(in: .whitespaces).isEmpty { error = "Bitte einen Namen eingeben"; return }
        if !all && picked.isEmpty { error = "Mindestens einen Streamer auswählen"; return }
        do {
            let j: ConfigsResponse = try await api.post("/api/configs", Body(id: isNew ? nil : config.id, name: config.name,
                                                                         streamers: all ? nil : picked.sorted(), pins: pins.sorted(), activate: activate))
            configs.apply(j)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        guard let api = connection.api else { return }
        do {
            let j: ConfigsResponse = try await api.post("/api/configs", ["op": "delete", "id": config.id])
            configs.apply(j)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
