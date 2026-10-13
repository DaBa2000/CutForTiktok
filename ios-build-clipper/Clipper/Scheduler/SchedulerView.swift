import SwiftUI

/// Exported clips → plan day + time (German time); the TikTok helper extension on the Mac posts them. Mirrors web/scheduler.html.
struct SchedulerView: View {
    @Environment(Connection.self) private var connection
    @State private var queue: [QueueItem] = []
    @State private var plans: [String: Schedule] = [:]
    @State private var planning: PlanTarget?
    @State private var autoStart = nextFree()
    @State private var autoEvery = 60
    @State private var playing: IdentifiedURL?
    @State private var editing: String?
    @State private var editMode = EditMode.inactive  // "Reihenfolge": drag planned clips into other time slots
    @State private var path: [String] = []
    @State private var error: String?

    private struct PlanTarget: Identifiable { let id: String; let title: String; let at: Date }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    if planned.isEmpty {
                        Text("Noch nichts geplant. Unten einen Clip planen oder automatisch verteilen.").foregroundStyle(Theme.mute)
                    }
                    ForEach(Array(planned.enumerated()), id: \.element.id) { i, p in
                        VStack(alignment: .leading, spacing: 6) {
                            if i == 0 || dayLabel(planned[i - 1].date) != dayLabel(p.date) {
                                Text(dayLabel(p.date)).font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(Theme.mute)
                            }
                            plannedRow(p)
                        }
                        .listRowBackground(Theme.panel)
                        .moveDisabled(p.state == "running")
                    }
                    .onMove { from, to in Task { await reorder(from: from, to: to) } }
                } header: {
                    header("⏰ Geplant", planned.count)
                } footer: {
                    Text("Die Browser-Extension auf dem Mac postet zur geplanten Zeit (deutsche Zeit). Dafür müssen Mac (wach), Safari und CutForTiktok laufen.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Automatisch verteilen").font(.subheadline.bold())
                        DatePicker("ab", selection: $autoStart, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, berlin)
                        Stepper("alle \(autoEvery) Min", value: $autoEvery, in: 5...720, step: 5)
                        Button { Task { await distribute() } } label: { Text("Verteilen").frame(maxWidth: .infinity) }
                            .buttonStyle(PrimaryButton()).disabled(open.isEmpty)
                    }
                    .padding(.vertical, 4)
                    ForEach(open) { c in openRow(c) }
                    if open.isEmpty {
                        Text("Keine exportierten Clips offen. Im Edit-Bereich Clips bearbeiten und exportieren.").foregroundStyle(Theme.mute)
                    }
                } header: { header("📦 Exportiert, noch nicht geplant", open.count) }
            }
            .environment(\.editMode, $editMode)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Scheduler")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Text(nextInfo).font(.caption).foregroundStyle(Theme.mute)
                        if planned.count > 1 {
                            Button(editMode == .active ? "Fertig" : "Reihenfolge") {
                                withAnimation { editMode = editMode == .active ? .inactive : .active }
                            }
                            .bold()
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in EditorHost(startId: id, path: $path) }
            .polling(every: 15) { if path.isEmpty && planning == nil { await load() } }  // extension updates the status
            .refreshable { await load() }
            .sheet(item: $planning) { t in PlanSheet(title: t.title, initial: t.at) { at in Task { await plan(t.id, at) } } }
            .fullScreenCover(item: $playing) { VideoSheet(url: $0.url) }
            .errorAlert($error)
        }
    }

    private func header(_ t: String, _ n: Int) -> some View {
        Text(n > 0 ? "\(t) (\(n))" : t).font(.subheadline.weight(.bold)).foregroundStyle(Theme.fg).textCase(nil)
    }

    private func plannedRow(_ p: Schedule) -> some View {
        let c = queue.first { $0.id == p.id }
        let close = planned.contains { $0.id != p.id && abs($0.at - p.at) < 10 * 60000 }
        return HStack(spacing: 10) {
            Text(timeString(p.date)).font(.headline.monospacedDigit()).frame(width: 50, alignment: .trailing)
            Circle().fill(p.state == "running" ? Theme.ok : p.state == "failed" ? .red : Theme.acc2).frame(width: 9, height: 9)
            AsyncImage(url: c?.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                .frame(width: 72, height: 40).clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text("@\(p.streamer ?? "")").foregroundStyle(Theme.mute)
                    Pill(text: p.state == "running" ? "wird gepostet…" : p.state == "failed" ? "fehlgeschlagen" : "geplant",
                         color: p.state == "running" ? Theme.ok : p.state == "failed" ? Theme.red : Color(hex: 0x25A8A4))
                }
                .font(.caption)
                if close { Text("weniger als 10 Min Abstand").font(.caption).foregroundStyle(Theme.warn) }
                if let e = p.error { Text(e).font(.caption).foregroundStyle(.red) }
                if c == nil { Text("nicht mehr in der Export-Liste").font(.caption).foregroundStyle(.red) }
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard p.state != "running", c != nil else { return }
            planning = PlanTarget(id: p.id, title: p.title ?? "", at: p.at > Date().timeIntervalSince1970 * 1000 ? p.date : nextFree())
        }
        .swipeActions {
            Button("Entfernen", role: .destructive) { Task { await plan(p.id, nil) } }
        }
    }

    private func openRow(_ c: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button { if let api = connection.api { playing = IdentifiedURL(url: api.mediaURL("/export/\(c.id)")) } } label: {
                    AsyncImage(url: c.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                        .frame(width: 120, height: 68).clipShape(.rect(cornerRadius: 8))
                        .overlay { Image(systemName: "play.fill").font(.title2).foregroundStyle(.white).shadow(radius: 6) }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("@\(c.streamer)").font(.caption).foregroundStyle(Theme.mute)
                    Text(c.caption ?? "").font(.caption).foregroundStyle(Theme.mute).lineLimit(2)
                }
            }
            HStack(spacing: 6) {
                Button { planning = PlanTarget(id: c.id, title: c.title ?? "", at: nextFree()) } label: {
                    Label("Planen", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton())
                Button { path.append(c.id) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(SecondaryButton())
                Button { Task { await posted(c) } } label: { Text("✓ gepostet") }.buttonStyle(SecondaryButton())
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.panel)
    }

    // MARK: data

    private var planned: [Schedule] { plans.values.sorted { $0.at < $1.at } }
    private var open: [QueueItem] { queue.filter { plans[$0.id] == nil } }
    private var nextInfo: String {
        guard let n = planned.first(where: { $0.state == "planned" && $0.date > Date() }) else { return "Nichts geplant" }
        return "Nächster: \(dayLabel(n.date).components(separatedBy: ",")[0]) \(timeString(n.date))"
    }

    private func load() async {
        guard let api = connection.api else { return }
        async let q: [QueueItem]? = try? api.get("/api/queue")
        async let s: [String: Schedule]?? = try? api.get("/api/schedules")
        if let q = await q { queue = q }
        if let s = await s { plans = s ?? [:] }
    }

    private func plan(_ id: String, _ at: Date?) async {
        guard let api = connection.api else { return }
        let body: [String: Double?] = ["at": at.map { ($0.timeIntervalSince1970 * 1000).rounded() }]
        do { try await api.post("/api/schedule/\(id)", body) } catch { self.error = error.localizedDescription }
        await load()
    }

    /// The time slots stay, the clips change places: moved clip takes the slot at its new position.
    private func reorder(from: IndexSet, to: Int) async {
        var list = planned
        let slots = list.map(\.at)
        list.move(fromOffsets: from, toOffset: to)
        for (p, at) in zip(list, slots) where p.at != at {
            plans[p.id]?.at = at  // instant feedback, server confirms on reload
        }
        guard let api = connection.api else { return }
        for (p, at) in zip(list, slots) where p.at != at {
            do { try await api.post("/api/schedule/\(p.id)", ["at": at]) } catch { self.error = error.localizedDescription }
        }
        await load()
    }

    private func posted(_ c: QueueItem) async {
        guard let api = connection.api else { return }
        try? await api.post("/api/clip/\(c.id)/status", ["status": "uploaded"])
        await load()
    }

    private func distribute() async {
        guard autoStart > Date() else { error = "Startzeit ist schon vorbei"; return }
        let every = Double(autoEvery) * 60
        var at = autoStart.timeIntervalSince1970
        var taken = plans.values.map { $0.at / 1000 }
        for c in open {
            while taken.contains(where: { abs($0 - at) < every / 2 }) { at += every }  // skip already used slots
            await plan(c.id, Date(timeIntervalSince1970: at))
            taken.append(at)
            at += every
        }
    }
}

/// Day + time picker in German time.
private struct PlanSheet: View {
    let title: String
    let onPlan: (Date) -> Void
    @State private var at: Date
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: Date, onPlan: @escaping (Date) -> Void) {
        self.title = title
        self.onPlan = onPlan
        _at = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(title).font(.headline) }
                Section {
                    DatePicker("Tag", selection: $at, in: Date()..., displayedComponents: .date)
                    DatePicker("Uhrzeit", selection: $at, displayedComponents: .hourAndMinute)
                } footer: { Text("Deutsche Zeit (Europe/Berlin)") }
            }
            .environment(\.timeZone, berlin)
            .environment(\.locale, Locale(identifier: "de_DE"))
            .navigationTitle("Planen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Planen") { onPlan(at); dismiss() }.disabled(at <= Date())
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: German time

let berlin = TimeZone(identifier: "Europe/Berlin")!

/// suggestion: next full hour >= 30 min ahead
func nextFree() -> Date {
    Date(timeIntervalSince1970: ((Date().timeIntervalSince1970 + 1800) / 3600).rounded(.up) * 3600)
}

func timeString(_ d: Date) -> String {
    let f = DateFormatter(); f.timeZone = berlin; f.dateFormat = "HH:mm"; return f.string(from: d)
}

func dayLabel(_ d: Date) -> String {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = berlin
    let f = DateFormatter(); f.timeZone = berlin; f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "dd.MM."
    let date = f.string(from: d)
    if cal.isDateInToday(d) { return "Heute, \(date)" }
    if cal.isDateInTomorrow(d) { return "Morgen, \(date)" }
    f.dateFormat = "EEEE"
    return "\(f.string(from: d)), \(date)"
}
