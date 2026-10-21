import AVFoundation
import Observation
import SwiftUI

/// State of one clip in the editor; geometry mirrors web/editor.html (and pipeline.effective_render on the Mac).
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
    var camH: Double = 640 { didSet { markDirty() } }
    var gameX: Double = 0.5 { didSet { markDirty() } }
    var zoom: Double = 0 { didSet { markDirty() } }
    var trimStart: Double = 0 { didSet { markDirty() } }
    var trimEnd: Double = 0 { didSet { markDirty() } }
    var subs: [SubChunk] = [] { didSet { markDirty() } }
    var overlayTitle = "" { didSet { markDirty() } }
    var caption = "" { didSet { markDirty() } }
    var switches: [Switch] = []  // perspective switches + cuts are edited in the web editor, sent back unchanged
    var cuts: [Cut] = []
    private var loading = true  // suppress dirty while filling in
    private var saveTask: Task<Void, Never>?

    // playback
    let player = AVPlayer()
    var time: Double = 0
    var duration: Double = 0
    var playing = false
    var videoSize = CGSize(width: 1920, height: 1080)
    private var observer: Any?

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
            apply(c)
            let asset = AVURLAsset(url: api.mediaURL("/raw/\(id)"))
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, tf) = try await track.load(.naturalSize, .preferredTransform)
                let s = size.applying(tf)
                videoSize = CGSize(width: abs(s.width), height: abs(s.height))
            }
            duration = try await asset.load(.duration).seconds
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            loading = true
            if c.trim_end == nil { trimEnd = duration }
            if cam == nil { lastCam = defaultCam() }
            loading = false
            await seek(trimStart)
        } catch {
            preparing = false
            loadError = error.localizedDescription
        }
    }

    private func apply(_ c: ClipDetail) {
        loading = true
        clip = c
        cam = c.cam
        camH = c.cam_h ?? c.render.cam_height
        gameX = c.game_x ?? 0.5
        zoom = c.zoom ?? 0
        trimStart = c.trim_start ?? 0
        trimEnd = c.trim_end ?? 0
        subs = (c.subs ?? []).sorted { $0.start < $1.start }
        overlayTitle = c.overlay_title ?? c.title ?? ""
        caption = c.caption ?? ""
        switches = (c.switches?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([Switch].self, from: $0) } ?? []
        cuts = (c.cuts?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([Cut].self, from: $0) } ?? []
        lastTitle = overlayTitle.trimmingCharacters(in: .whitespaces).isEmpty ? nil : overlayTitle.trimmingCharacters(in: .whitespaces)
        dirty = false
        loading = false
    }

    /// every change is saved shortly after: edit state + the streamer's facecam layout (no render)
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
        SaveBody(cam: cam, game_x: gameX, zoom: zoom, trim_start: trimStart, trim_end: trimEnd, subs: subs, caption: caption,
                 overlay_title: overlayTitle, cam_h: Int(camH.rounded()), switches: switches, cuts: cuts)
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

    @MainActor func redetect() async {
        busy = true; defer { busy = false }
        struct Detected: Decodable { var cam: [Double]? }
        do {
            let r: Detected = try await api.post("/api/clip/\(id)/redetect")
            if let c = r.cam { cam = c; fitCam() } else { say("Keine Facecam gefunden", error: true) }
        } catch { say(error.localizedDescription, error: true) }
    }

    /// web editor saved meanwhile → take over its state
    @MainActor func reloadFromServer() async {
        if let c: ClipDetail = try? await api.get("/api/clip/\(id)") { apply(c) }
    }

    // MARK: playback

    private func tick(_ t: Double) {
        time = t
        playing = player.rate > 0
        if playing, t >= trimEnd, trimEnd > 0 {  // loop inside the trimmed part
            player.pause()
            Task { await seek(trimStart) }
        }
    }

    @MainActor func seek(_ t: Double) async {
        time = t
        await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() }
        else {
            if time >= trimEnd - 0.05 || time < trimStart - 0.05 { Task { await seek(trimStart); player.play() } }
            else { player.play() }
        }
    }

    // MARK: geometry (normalized source coords, aspect locked to the output's cam area)

    var camAspect: Double { R.width / camH }
    var vAR: Double { videoSize.width / max(1, videoSize.height) }
    var subsY: Double { min(max(R.subs_y, camH + 170), R.height - 300) }  // mirrors effective_render()

    func defaultCam() -> [Double] { let w = 0.3; return [0.68, 0.02, w, w * vAR / camAspect] }

    func setHasCam(_ on: Bool) {
        if on { cam = lastCam ?? defaultCam(); fitCam() } else { lastCam = cam; cam = nil }
    }

    /// keep facecam box at the area's aspect: same center, same width if possible
    func fitCam() {
        guard var c = cam else { return }
        let cx = c[0] + c[2] / 2, cy = c[1] + c[3] / 2
        var w = c[2], h = w * vAR / camAspect
        if h > 1 { h = 1; w = h * camAspect / vAR }
        if w > 1 { w = 1; h = w * vAR / camAspect }
        c = [clamp(cx - w / 2, 0, 1 - w), clamp(cy - h / 2, 0, 1 - h), w, h].map { ($0 * 10000).rounded() / 10000 }
        if c != cam { cam = c }
    }

    func setSplit(_ px: Double) {
        let v = (clamp(px, 240, 1400) / 2).rounded() * 2
        if v != camH { camH = v; fitCam() }
    }

    func moveCam(from start: [Double], dx: Double, dy: Double) {
        let (w, h) = (start[2], start[3])
        cam = [clamp(start[0] + dx, 0, 1 - w), clamp(start[1] + dy, 0, 1 - h), w, h].map { ($0 * 10000).rounded() / 10000 }
    }

    func resizeCam(from start: [Double], dx: Double) {
        let (x, y) = (start[0], start[1])
        var w = clamp(start[2] + dx, 0.05, 1 - x)
        var h = w * vAR / camAspect
        if y + h > 1 { h = 1 - y; w = h * camAspect / vAR }
        cam = [x, y, w, h].map { ($0 * 10000).rounded() / 10000 }
    }

    /// game area height in output px (no facecam: the game fills the whole frame)
    var gameAreaH: Double { R.height - (cam == nil ? 0 : camH) }

    /// game crop window in source pixels (full height); zoom widens it towards the whole frame
    /// width, the game is then shown with black bars above/below (mirrors render.py)
    var gameWindow: (x: Double, w: Double) {
        let vw = videoSize.width, vh = videoSize.height
        let fw = min(vw, vh * R.width / gameAreaH), w = fw + clamp(zoom, 0, 1) * (vw - fw)
        return (clamp(gameX * vw - w / 2, 0, vw - w), w)
    }

    /// visible game height in output px (< gameAreaH when zoomed out = black bars)
    var gameH: Double { min(gameAreaH, R.width * videoSize.height / gameWindow.w) }

    /// facecam area source rect (normalized), cropped to the area's aspect like ffmpeg increase+crop
    var camSourceRect: CGRect {
        let vw = videoSize.width, vh = videoSize.height
        var (sx, sy, sw, sh) = cam.map { ($0[0] * vw, $0[1] * vh, $0[2] * vw, $0[3] * vh) } ?? (0, 0, vw, vh)
        if sw / sh > camAspect { let nw = sh * camAspect; sx += (sw - nw) / 2; sw = nw }
        else { let nh = sw / camAspect; sy += (sh - nh) / 2; sh = nh }
        return CGRect(x: sx / vw, y: sy / vh, width: sw / vw, height: sh / vh)
    }

    var gameSourceRect: CGRect {
        let g = gameWindow
        return CGRect(x: g.x / videoSize.width, y: 0, width: g.w / videoSize.width, height: 1)
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
