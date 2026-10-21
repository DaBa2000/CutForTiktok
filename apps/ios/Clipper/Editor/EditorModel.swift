import AVFoundation
import Observation
import SwiftUI

/// State of one clip in the editor; geometry mirrors web/editor.html and layout.py on the Mac.
///
/// Layout: the facecam area (width x camH) on top, the game area below. Each area shows a *frame* of the source,
/// [x, y, w, h] normalized, with the area's aspect: what is inside the frame is what the video shows. A frame may
/// reach beyond the source (black there, e.g. a zoomed-out game with bars).
/// Keyframes change the frames during the clip; a perspective switch shows another stream with its own frames.
@Observable
final class EditorModel {
    let id: String
    let api: API
    var clip: ClipDetail?
    var preparing = false
    var loadError: String?
    var message = ""
    var messageIsError = false
    var dirty = false
    var busy = false

    // editable state (autosaved shortly after every change)
    var cam: [Double]? { didSet { markDirty() } }
    var lastCam: [Double]?
    var game: [Double] = [0, 0, 1, 1] { didSet { markDirty() } }
    var camH: Double = 640 { didSet { markDirty() } }
    var keyframes: [Keyframe] = [] { didSet { markDirty() } }
    var trimStart: Double = 0 { didSet { markDirty() } }
    var trimEnd: Double = 0 { didSet { markDirty() } }
    var cuts: [Cut] = [] { didSet { markDirty() } }
    var switches: [Switch] = [] { didSet { markDirty() } }
    var subs: [SubChunk] = [] { didSet { markDirty() } }
    var overlayTitle = "" { didSet { markDirty() } }
    var caption = "" { didSet { markDirty() } }
    /// joined clip ("Clips verbinden"): every part has its own layout, edited in the web editor
    var joined: Bool { clip?.segments != nil }
    private var loading = true  // suppress dirty while filling in
    private var saveTask: Task<Void, Never>?

    // in / out marks for cutting out a range, selection on the timeline
    var markIn: Double?
    var markOut: Double?
    var selectedCut: Int?
    var selectedKeyframe: UUID?

    // playback
    let player = AVPlayer()
    var time: Double = 0
    var duration: Double = 0
    var playing = false
    var videoSize = CGSize(width: 1920, height: 1080)
    private var observer: Any?

    // perspectives: other streams of the same moment, played in sync by a second player
    var persp: [Perspective] = []
    var pv: [String: PerspState] = [:]
    var loadingPersp: Set<String> = []
    var peek: String?  // perspective shown for review only (no switch)
    let other = AVPlayer()
    private var otherClip: String?

    struct PerspState { var off: Double; var size: CGSize; var layout: Frames; var refined: Bool; var duration: Double }

    var R: RenderDims { clip?.render ?? RenderDims(width: 1080, height: 1920, cam_height: 640, subs_y: 1300, font_size: 82, highlight: "#FFE600", title_secs: 3, title_size: 62) }

    init(id: String, api: API) {
        self.id = id
        self.api = api
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            self?.tick(t.seconds)
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        player.pause()
        other.pause()
    }

    // MARK: load / save

    @MainActor
    func load() async {
        do {
            var c: ClipDetail = try await api.get("/api/clip/\(id)")
            if c.subs == nil || c.raw_path == nil {  // not prepared yet (download + detect + transcribe) or videos dropped after export
                preparing = true
                try await api.post("/api/clip/\(id)/prepare")
                c = try await api.get("/api/clip/\(id)")
                preparing = false
            }
            let asset = AVURLAsset(url: api.mediaURL("/raw/\(id)"))
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, tf) = try await track.load(.naturalSize, .preferredTransform)
                let s = size.applying(tf)
                videoSize = CGSize(width: abs(s.width), height: abs(s.height))
            }
            duration = try await asset.load(.duration).seconds
            apply(c)
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            await seek(trimStart)
            await loadPersp()
        } catch {
            preparing = false
            loadError = error.localizedDescription
        }
    }

    private func apply(_ c: ClipDetail) {
        loading = true
        clip = c
        camH = c.cam_h ?? c.render.cam_height
        let size = videoSize
        cam = c.cam.map { cover($0, camAspect, size) }
        game = c.game.map { refit($0, gameAspect(cam != nil), size, keepWidth: false) }
            ?? legacyGame(c.game_x, c.zoom, size, gameAreaH(cam != nil))
        keyframes = (c.keyframes ?? []).sorted { $0.t < $1.t }.map { k in
            var k = k
            k.cam = k.cam.map { cover($0, camAspect, size) }
            k.game = k.game.map { refit($0, gameAspect(cam != nil), size, keepWidth: false) }
            return k
        }
        lastCam = cam ?? defaultCam(size)
        trimStart = c.trim_start ?? 0
        trimEnd = c.trim_end ?? duration
        subs = (c.subs ?? []).sorted { $0.start < $1.start }
        overlayTitle = c.overlay_title ?? c.title ?? ""
        caption = c.caption ?? ""
        switches = (c.switches?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([Switch].self, from: $0) } ?? []
        cuts = (c.cuts?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([Cut].self, from: $0) } ?? []
        lastTitle = overlayTitle.trimmingCharacters(in: .whitespaces).isEmpty ? nil : overlayTitle.trimmingCharacters(in: .whitespaces)
        dirty = false
        loading = false
    }

    /// every change is saved shortly after: edit state + the streamer's default layout (no render)
    private func markDirty() {
        guard !loading else { return }
        dirty = true
        say("Speichert…")
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { await save() }
        }
    }

    func say(_ t: String, error: Bool = false) { message = t; messageIsError = error }

    private var body: SaveBody {
        SaveBody(cam: cam, game: game, keyframes: keyframes.sorted { $0.t < $1.t }, trim_start: trimStart, trim_end: trimEnd,
                 subs: subs, caption: caption, overlay_title: overlayTitle, cam_h: Int(camH.rounded()), switches: switches, cuts: cuts)
    }

    @MainActor func save() async {
        saveTask?.cancel()
        guard dirty else { return }
        dirty = false
        do {
            try await api.post("/api/clip/\(id)", body)
            say("Gespeichert ✓")
        } catch {
            dirty = true
            say(error.localizedDescription, error: true)
        }
    }

    /// "Exportieren & weiter": saves, final render + export run in background on the Mac
    @MainActor func export() async -> Bool {
        saveTask?.cancel()
        busy = true; defer { busy = false }
        do {
            try await api.post("/api/clip/\(id)/export", body)
            dirty = false
            return true
        } catch { say(error.localizedDescription, error: true); return false }
    }

    @MainActor func ignore() async -> Bool {
        saveTask?.cancel()
        do {
            try await api.setStatus(id, "ignored")
            dirty = false
            return true
        } catch { say(error.localizedDescription, error: true); return false }
    }

    /// web editor saved meanwhile → take over its state
    @MainActor func reloadFromServer() async {
        if let c: ClipDetail = try? await api.get("/api/clip/\(id)") { apply(c) }
    }

    // MARK: playback

    private func tick(_ t: Double) {
        time = t
        playing = player.rate > 0
        if playing, let c = cuts.first(where: { t >= $0.start && t < $0.end }) {  // cut-out ranges are skipped
            Task { await seek(c.end) }
        }
        if playing, t >= trimEnd, trimEnd > 0 {  // loop inside the trimmed part
            player.pause()
            Task { await seek(trimStart) }
        }
        syncOther()
    }

    @MainActor func seek(_ t: Double) async {
        time = t
        await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        syncOther(force: true)
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() }
        else {
            if time >= trimEnd - 0.05 || time < trimStart - 0.05 { Task { await seek(trimStart); player.play() } }
            else { player.play() }
        }
    }

    /// the second player follows the main one while a perspective is shown
    private func syncOther(force: Bool = false) {
        guard let a = activePerspective(time) else {
            if other.rate > 0 { other.pause() }
            player.isMuted = false
            return
        }
        if otherClip != a.clip {
            otherClip = a.clip
            other.replaceCurrentItem(with: AVPlayerItem(url: api.mediaURL("/raw/\(a.clip)")))
        }
        let target = time + a.off
        if force || abs(other.currentTime().seconds - target) > 0.3 {
            other.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let previewing = peek == a.clip  // preview: hear the other stream instead of the clip
        other.isMuted = !previewing
        player.isMuted = previewing
        if playing && other.rate == 0 { other.play() }
        if !playing && other.rate > 0 { other.pause() }
    }

    // MARK: geometry (mirrors layout.py)

    var camAspect: Double { R.width / camH }
    func gameAreaH(_ hasCam: Bool) -> Double { R.height - (hasCam ? camH : 0) }
    func gameAspect(_ hasCam: Bool) -> Double { R.width / gameAreaH(hasCam) }
    var vAR: Double { videoSize.width / max(1, videoSize.height) }
    var subsY: Double { min(max(R.subs_y, camH + 170), R.height - 300) }  // mirrors effective_render()

    func r5(_ f: [Double]) -> [Double] { f.map { ($0 * 100000).rounded() / 100000 } }

    /// same center; keep the width (facecam) or the height (game: full height stays full height)
    func refit(_ f: [Double], _ aspect: Double, _ size: CGSize, keepWidth: Bool) -> [Double] {
        var (w, h) = (f[2], f[3])
        let cx = f[0] + w / 2, cy = f[1] + h / 2
        if keepWidth { h = w * size.width / (size.height * aspect) } else { w = h * size.height * aspect / size.width }
        return r5([cx - w / 2, cy - h / 2, w, h])
    }

    /// largest frame of the aspect inside f (older facecam boxes of any aspect)
    func cover(_ f: [Double], _ aspect: Double, _ size: CGSize) -> [Double] {
        let (x, y, w, h) = (f[0], f[1], f[2], f[3])
        if w * size.width / (h * size.height) > aspect {
            let nw = h * size.height * aspect / size.width
            return r5([x + (w - nw) / 2, y, nw, h])
        }
        let nh = w * size.width / (size.height * aspect)
        return r5([x, y + (h - nh) / 2, w, nh])
    }

    /// game_x + zoom of older clips -> game frame
    func legacyGame(_ gx: Double?, _ zoom: Double?, _ size: CGSize, _ gh: Double) -> [Double] {
        let vw = size.width, vh = size.height
        let fw = min(vw, vh * R.width / gh), w = fw + clamp(zoom ?? 0, 0, 1) * (vw - fw)
        let x = clamp((gx ?? 0.5) * vw - w / 2, 0, vw - w), h = w * gh / R.width / vh
        return r5([x / vw, (1 - h) / 2, w / vw, h])
    }

    func defaultCam(_ size: CGSize) -> [Double] { let w = 0.25; return r5([0.73, 0.02, w, w * size.width / (size.height * camAspect)]) }

    /// keyframes: from t on their frames, reached over `ease` seconds (mirrors layout.at)
    func frameAt(cam isCam: Bool, _ t: Double) -> [Double]? {
        var cur: [Double]? = isCam ? cam : game
        let ks = keyframes.filter { (isCam ? $0.cam : $0.game) != nil }.sorted { $0.t < $1.t }
        for (i, k) in ks.enumerated() {
            if t < k.t { break }
            let f = (isCam ? k.cam : k.game)!
            let e = min(k.ease, (i + 1 < ks.count ? ks[i + 1].t : 1e9) - k.t)
            if e > 0, t < k.t + e, let c = cur {
                let a = (t - k.t) / e
                return zip(c, f).map { $0 + ($1 - $0) * a }
            }
            cur = f
        }
        return cur
    }

    // MARK: what is shown / edited at a time
    // perspective (switch or preview) > keyframe > the clip's own layout

    enum Target: Equatable { case base, keyframe(UUID), perspective(Int), peek(String) }

    struct Active { let clip: String; let off: Double; let streamer: String }

    /// perspective shown at main time t (outside the other clip: the main clip)
    func activePerspective(_ t: Double) -> Active? {
        if let p = peek, let st = pv[p] {
            return t + st.off >= 0 && t < st.duration - st.off ? Active(clip: p, off: st.off, streamer: persp.first { $0.id == p }?.streamer ?? "") : nil
        }
        guard let s = switches.last(where: { $0.t <= t }), let c = s.clip, let st = pv[c] else { return nil }
        return t + s.off >= 0 && t < st.duration - s.off ? Active(clip: c, off: s.off, streamer: s.streamer ?? "") : nil
    }

    func target(_ t: Double? = nil) -> Target {
        let t = t ?? time
        if let a = activePerspective(t) {
            if peek == a.clip { return .peek(a.clip) }
            if let i = switches.lastIndex(where: { $0.t <= t }) { return .perspective(i) }
        }
        if let k = keyframes.filter({ $0.t <= t + 0.001 }).max(by: { $0.t < $1.t }) { return .keyframe(k.id) }
        return .base
    }

    func frames(_ tg: Target) -> Frames {
        switch tg {
        case .base: return Frames(cam: cam, game: game)
        case .keyframe(let id):
            guard let k = keyframes.first(where: { $0.id == id }) else { return Frames(cam: cam, game: game) }
            return Frames(cam: cam == nil ? nil : k.cam ?? frameAt(cam: true, k.t - 0.001), game: k.game ?? frameAt(cam: false, k.t - 0.001) ?? game)
        case .perspective(let i):
            let s = switches[i]
            if let g = s.game { return Frames(cam: s.cam, game: g) }
            return s.clip.flatMap { pv[$0]?.layout } ?? Frames(cam: cam, game: game)
        case .peek(let c): return pv[c]?.layout ?? Frames(cam: cam, game: game)
        }
    }

    func setFrames(_ tg: Target, _ f: Frames) {
        switch tg {
        case .base:
            if cam != f.cam { cam = f.cam }
            if game != f.game { game = f.game }
            if cam != nil { lastCam = cam }
        case .keyframe(let id):
            if let i = keyframes.firstIndex(where: { $0.id == id }) { keyframes[i].cam = f.cam; keyframes[i].game = f.game }
        case .perspective(let i):
            switches[i].cam = f.cam; switches[i].game = f.game
        case .peek(let c):
            pv[c]?.layout = f
        }
    }

    /// source size of the video a target shows
    func size(_ tg: Target) -> CGSize {
        switch tg {
        case .perspective(let i): return switches[i].clip.flatMap { pv[$0]?.size } ?? videoSize
        case .peek(let c): return pv[c]?.size ?? videoSize
        default: return videoSize
        }
    }

    func label(_ tg: Target) -> String {
        switch tg {
        case .base: return "Grundlayout"
        case .keyframe(let id): return "◆ Keyframe \(fmt(keyframes.first { $0.id == id }?.t ?? 0))s"
        case .perspective(let i): return "⇄ @\(switches[i].streamer ?? "")"
        case .peek(let c): return "👁 Vorschau @\(persp.first { $0.id == c }?.streamer ?? "")"
        }
    }

    /// player + frames drawn in the preview right now (keyframe transitions interpolated)
    var shown: (player: AVPlayer, frames: Frames, streamer: String) {
        let tg = target()
        switch tg {
        case .base, .keyframe:
            return (player, Frames(cam: cam == nil ? nil : frameAt(cam: true, time), game: frameAt(cam: false, time) ?? game), clip?.streamer ?? "")
        default:
            return (other, frames(tg), activePerspective(time)?.streamer ?? "")
        }
    }

    // MARK: editing frames of the current target

    func editFrame(cam isCam: Bool, _ f: [Double]) {
        let tg = target()
        var fr = frames(tg)
        if isCam { fr.cam = r5(f) } else { fr.game = r5(f) }
        setFrames(tg, fr)
    }

    func moveFrame(cam isCam: Bool, from s: [Double], dx: Double, dy: Double) {
        editFrame(cam: isCam, [clamp(s[0] + dx, 0.02 - s[2], 0.98), clamp(s[1] + dy, 0.02 - s[3], 0.98), s[2], s[3]])
    }

    /// corner drag: the opposite corner stays, the aspect stays (fx, fy: dragged corner 0 / 1)
    func scaleFrame(cam isCam: Bool, from s: [Double], corner: (fx: Double, fy: Double), dx: Double) {
        let ax = s[0] + (1 - corner.fx) * s[2], ay = s[1] + (1 - corner.fy) * s[3]
        let w = clamp(s[2] + (corner.fx == 1 ? dx : -dx), 0.03, 3), h = s[3] * w / s[2]
        editFrame(cam: isCam, [ax - (1 - corner.fx) * w, ay - (1 - corner.fy) * h, w, h])
    }

    /// k > 1: frame bigger = zoomed out (more visible, black beyond the source)
    func zoomFrame(cam isCam: Bool, from s: [Double], k: Double) {
        let w = clamp(s[2] * k, 0.03, 3), h = s[3] * w / s[2]
        editFrame(cam: isCam, [s[0] + s[2] / 2 - w / 2, s[1] + s[3] / 2 - h / 2, w, h])
    }

    /// the clip's own stream (layout or keyframe), not another perspective
    func isMain(_ tg: Target) -> Bool {
        switch tg { case .base, .keyframe: return true; default: return false }
    }

    /// facecam on/off: for the clip's own stream it holds for the whole clip, a perspective has its own
    func setHasCam(_ on: Bool) {
        let tg = target()
        guard isMain(tg) else {
            let sz = size(tg)
            var f = frames(tg)
            f.cam = on ? defaultCam(sz) : nil
            f.game = refit(f.game, gameAspect(on), sz, keepWidth: false)
            setFrames(tg, f)
            return
        }
        guard on != (cam != nil) else { return }
        if on { cam = lastCam ?? defaultCam(videoSize) } else { lastCam = cam; cam = nil }
        game = refit(game, gameAspect(on), videoSize, keepWidth: false)
        for i in keyframes.indices {
            if !on { keyframes[i].cam = nil }
            keyframes[i].game = keyframes[i].game.map { refit($0, gameAspect(on), videoSize, keepWidth: false) }
        }
    }

    func gameFullHeight() {
        let tg = target(), sz = size(tg)
        var f = frames(tg)
        f.game = legacyGame(0.5, 0, sz, gameAreaH(f.cam != nil))
        setFrames(tg, f)
    }

    /// facecam height: every frame keeps its center (facecam its width, game its height)
    func setSplit(_ px: Double) {
        let v = (clamp(px, 240, 1400) / 2).rounded() * 2
        guard v != camH else { return }
        camH = v
        if let c = cam { cam = refit(c, camAspect, videoSize, keepWidth: true) }
        game = refit(game, gameAspect(cam != nil), videoSize, keepWidth: false)
        if let c = lastCam { lastCam = refit(c, camAspect, videoSize, keepWidth: true) }
        for i in keyframes.indices {
            keyframes[i].cam = keyframes[i].cam.map { refit($0, camAspect, videoSize, keepWidth: true) }
            keyframes[i].game = keyframes[i].game.map { refit($0, gameAspect(cam != nil), videoSize, keepWidth: false) }
        }
        for i in switches.indices {
            guard let c = switches[i].clip, let g = switches[i].game, let sz = pv[c]?.size else { continue }
            switches[i].cam = switches[i].cam.map { refit($0, camAspect, sz, keepWidth: true) }
            switches[i].game = refit(g, gameAspect(switches[i].cam != nil), sz, keepWidth: false)
        }
        for (c, st) in pv {
            pv[c]?.layout = Frames(cam: st.layout.cam.map { refit($0, camAspect, st.size, keepWidth: true) },
                                   game: refit(st.layout.game, gameAspect(st.layout.cam != nil), st.size, keepWidth: false))
        }
    }

    @MainActor func redetect() async {
        guard isMain(target()) else { say("Erkennung nur für den eigenen Stream", error: true); return }
        busy = true; defer { busy = false }
        struct Detected: Decodable { var cam: [Double]? }
        do {
            let r: Detected = try await api.post("/api/clip/\(id)/redetect")
            guard let c = r.cam else { say("Keine Facecam gefunden", error: true); return }
            setHasCam(true)
            // facecam area sized so the whole detected cam fits
            setSplit(R.width / (c[2] * videoSize.width / (c[3] * videoSize.height)))
            editFrame(cam: true, cover(c, camAspect, videoSize))
            say("Facecam erkannt ✓")
        } catch { say(error.localizedDescription, error: true) }
    }

    // MARK: keyframes

    func addKeyframe() {
        let t = (time * 100).rounded() / 100
        if joined { say("Verbundene Clips: Layout pro Teil im Web-Editor", error: true); return }
        if activePerspective(t) != nil { say("Keyframes gelten für den eigenen Stream", error: true); return }
        guard !keyframes.contains(where: { abs($0.t - t) < 0.05 }) else { return }
        let k = Keyframe(t: t, cam: cam == nil ? nil : frameAt(cam: true, t).map(r5), game: frameAt(cam: false, t).map(r5), ease: 0)
        keyframes.append(k)
        keyframes.sort { $0.t < $1.t }
        selectedKeyframe = k.id
        selectedCut = nil
        say("Keyframe gesetzt – jetzt Facecam / Spiel verschieben")
    }

    // MARK: cutting out ranges

    func cutOut() {
        var a: Double, b: Double
        if let i = markIn, let o = markOut { a = min(i, o); b = max(i, o) }
        else if let i = markIn, time > i { a = i; b = time }
        else { a = time; b = time + 1 }
        a = clamp((a * 100).rounded() / 100, trimStart, trimEnd)
        b = clamp((b * 100).rounded() / 100, trimStart, trimEnd)
        guard b - a >= 0.1 else { say("Bereich zu kurz – Anfang / Ende markieren", error: true); return }
        guard !(a <= trimStart + 0.05 && b >= trimEnd - 0.05) else { say("Der ganze Clip kann nicht herausgeschnitten werden", error: true); return }
        var all = cuts + [Cut(start: a, end: b)]
        all.sort { $0.start < $1.start }
        var merged: [Cut] = []
        for c in all {
            if let last = merged.last, c.start <= last.end { merged[merged.count - 1].end = max(last.end, c.end) } else { merged.append(c) }
        }
        cuts = merged
        selectedCut = merged.firstIndex { $0.start <= a && $0.end >= b }
        selectedKeyframe = nil
        markIn = nil; markOut = nil
        say("Ausgeschnitten \(fmt(a))–\(fmt(b))s")
    }

    func fitCutsToTrim() {
        let fitted = cuts.map { Cut(start: max($0.start, trimStart), end: min($0.end, trimEnd)) }.filter { $0.end - $0.start >= 0.1 }
        if fitted != cuts { cuts = fitted; selectedCut = nil }
    }

    func deleteSelection() {
        if let i = selectedCut, cuts.indices.contains(i) { cuts.remove(at: i) }
        if let k = selectedKeyframe { keyframes.removeAll { $0.id == k } }
        selectedCut = nil; selectedKeyframe = nil
    }

    var finalLength: Double {
        trimEnd - trimStart - cuts.reduce(0) { $0 + max(0, min($1.end, trimEnd) - max($1.start, trimStart)) }
    }

    // MARK: perspectives

    @MainActor func loadPersp() async {
        persp = (try? await api.get("/api/clip/\(id)/perspectives")) ?? []
        // perspectives used by switches are loaded right away, others when tapped (the download is kept)
        for c in Set(switches.compactMap(\.clip)) {
            if let s = switches.first(where: { $0.clip == c }) { _ = try? await attach(c, off: s.off, at: s.t) }
        }
    }

    /// download + sync offset + layout of a perspective, once
    @MainActor func attach(_ clip: String, off: Double, at: Double) async throws -> PerspState {
        if let st = pv[clip] { return st }
        struct Aligned: Decodable { var off: Double; var refined: Bool; var size: [Double]?; var layout: Frames }
        struct Body: Encodable { let other: String; let off: Double; let at: Double; let cam_h: Int }
        loadingPersp.insert(clip); defer { loadingPersp.remove(clip) }
        let j: Aligned = try await api.post("/api/clip/\(id)/align", Body(other: clip, off: off, at: max(0, at), cam_h: Int(camH)))
        let size = j.size.map { CGSize(width: $0[0], height: $0[1]) } ?? videoSize
        var lay = j.layout
        lay.cam = lay.cam.map { cover($0, camAspect, size) }
        lay.game = refit(lay.game, gameAspect(lay.cam != nil), size, keepWidth: false)
        let st = PerspState(off: j.off, size: size, layout: lay, refined: j.refined,
                            duration: persp.first { $0.id == clip }?.duration ?? 1e9)
        pv[clip] = st
        return st
    }

    @MainActor func togglePeek(_ p: Perspective?) async {
        guard let p, peek != p.id else { peek = nil; player.isMuted = false; syncOther(force: true); return }
        do {
            let st = try await attach(p.id, off: p.off, at: clamp(time, p.from, max(p.from, p.to - 6)))
            peek = p.id
            if time < p.from || time >= p.to { await seek(p.from + 0.05) }  // into the part it covers
            syncOther(force: true)
            say("Vorschau @\(p.streamer) – " + (st.refined ? "per Ton synchronisiert" : "Abgleich nach Stream-Zeit (±2s)"))
        } catch { say(error.localizedDescription, error: true) }
    }

    @MainActor func addSwitch(_ p: Perspective) async {
        let t = (time * 100).rounded() / 100
        do {
            let st = try await attach(p.id, off: p.off, at: t)
            var all = switches.filter { abs($0.t - t) > 0.05 }
            all.append(Switch(t: t, clip: p.id, off: st.off, streamer: p.streamer, cam: st.layout.cam, game: st.layout.game))
            switches = all.sorted { $0.t < $1.t }
            peek = nil
            syncOther(force: true)
            say(st.refined ? "Wechsel gesetzt · per Ton synchronisiert ✓" : "Wechsel gesetzt · Zeitabgleich nach Stream-Zeit (±2s)")
        } catch { say(error.localizedDescription, error: true) }
    }

    func backToMain() {
        let t = (time * 100).rounded() / 100
        var all = switches.filter { abs($0.t - t) > 0.05 }
        all.append(Switch(t: t, clip: nil, off: 0))
        switches = all.sorted { $0.t < $1.t }
        peek = nil
        syncOther(force: true)
    }

    // MARK: subtitles

    var currentSubIndex: Int? {
        guard time >= trimStart, time <= trimEnd else { return nil }
        return subs.firstIndex { time >= $0.start && time <= $0.end }
    }

    /// mirrors subtitles.retime(): split edited text into words, distribute [start,end] by length
    static func retime(_ text: String, _ start: Double, _ end: Double) -> [Word] {
        let toks = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !toks.isEmpty, end > start else { return [] }
        let total = Double(toks.reduce(0) { $0 + $1.count + 1 })
        var t = start
        return toks.map { tok in
            let d = (end - start) * Double(tok.count + 1) / total
            defer { t += d }
            return Word(word: tok, start: (t * 1000).rounded() / 1000, end: ((t + d) * 1000).rounded() / 1000)
        }
    }

    /// edit one line; keeps word-level timing if only shifting/stretching, else redistributes
    func updateSub(_ id: UUID, text: String? = nil, start: Double? = nil, end: Double? = nil) {
        guard let i = subs.firstIndex(where: { $0.id == id }) else { return }
        var c = subs[i]
        let ns = start ?? c.start, ne = end ?? c.end
        guard ne > ns else { say("Ende muss nach dem Start liegen", error: true); return }
        let newText = (text ?? c.text).trimmingCharacters(in: .whitespaces)
        if newText == c.text, !c.words.isEmpty {
            let os = c.start, oe = c.end, k = (ne - ns) / ((oe - os) == 0 ? 1 : oe - os)
            c.words = c.words.map { Word(word: $0.word, start: ((ns + ($0.start - os) * k) * 1000).rounded() / 1000,
                                         end: ((ns + ($0.end - os) * k) * 1000).rounded() / 1000) }
        } else {
            c.words = Self.retime(newText, ns, ne)
        }
        if c.words.isEmpty { subs.remove(at: i) } else { subs[i] = c; subs.sort { $0.start < $1.start } }
    }

    func addSub() -> UUID {
        let c = SubChunk(words: Self.retime("NEU", time, min(time + 1.5, duration)))
        subs.append(c)
        subs.sort { $0.start < $1.start }
        return c.id
    }

    // MARK: title → caption (title card text goes into the TikTok caption too)

    private var lastTitle: String?

    func titleChanged() {
        let nt = overlayTitle.trimmingCharacters(in: .whitespaces)
        if let lt = lastTitle, caption.contains(lt) {
            caption = caption.replacingOccurrences(of: lt, with: nt, options: [], range: caption.range(of: lt))
        } else if !nt.isEmpty {  // title not found in caption: put it in front of the generated part
            if let r = caption.range(of: " 🎮 Clip von") { caption = nt + caption[r.lowerBound...] }
            else { caption = nt + " " + caption }
        }
        lastTitle = nt.isEmpty ? nil : nt
    }
}

func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }

func fmt(_ t: Double) -> String { String(format: "%.1f", t) }

extension Array where Element == Double {
    /// normalized frame [x, y, w, h] as a rect
    var rect: CGRect { count == 4 ? CGRect(x: self[0], y: self[1], width: self[2], height: self[3]) : CGRect(x: 0, y: 0, width: 1, height: 1) }
}
