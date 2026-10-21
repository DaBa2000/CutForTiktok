import Foundation

/// SQLite answers 0/1 for `subs IS NOT NULL AS ready`, Python answers true/false.
@propertyWrapper
struct LooseBool: Codable, Hashable {
    var wrappedValue: Bool
    init(wrappedValue: Bool) { self.wrappedValue = wrappedValue }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let b = try? c.decode(Bool.self) { wrappedValue = b }
        else if let i = try? c.decode(Int.self) { wrappedValue = i != 0 }
        else { wrappedValue = false }
    }
    func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(wrappedValue) }
}

extension KeyedDecodingContainer {
    func decode(_ t: LooseBool.Type, forKey k: Key) throws -> LooseBool {
        try decodeIfPresent(t, forKey: k) ?? LooseBool(wrappedValue: false)
    }
}

/// A clip as listed by /api/clips, /api/editlist, /api/foryou.
struct ClipItem: Codable, Identifiable, Hashable {
    let id: String
    let streamer: String
    var title: String?
    var overlay_title: String?
    var views: Int?
    var duration: Double?
    var status: String?
    var error: String?
    var thumbnail: String?
    var created_at: String?
    @LooseBool var ready: Bool        // prepared (transcript done): editor can open
    @LooseBool var downloaded: Bool   // source video is there, watchable already
    var parts: Int?                   // clips merged into this one (several people clipped the same moment)

    var displayTitle: String { title ?? "" }
    var createdDate: Date? { parseDate(created_at) }
    var thumbURL: URL? { thumbnail.flatMap(URL.init(string:)) }
}

struct Prefetch: Codable, Hashable { var current: String?; var queued: Int? }

struct ClipsResponse: Codable {
    var clips: [ClipItem]
    var streamers: [String]?
    var rendering: [String]?
    var schedules: [String: Schedule]?
    var next_sync: Double?
    var prefetch: Prefetch?
    var pins: [String]?
    var used: [String: Int]?
    var config: ConfigInfo?  // active configuration (which streamers For You / Discovery show)
}

// MARK: - configurations (Einstellungen): which streamers are shown, pinned channels

struct ConfigInfo: Codable, Hashable { var id: String; var name: String }

struct ConfigItem: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var streamers: [String]?  // nil = all streamers of accounts.txt (new ones too)
    var pins: [String]?
}

struct ConfigsResponse: Codable {
    var active: String
    var configs: [ConfigItem]
    var streamers: [String]  // all
}

/// Scheduler rating of an exported clip, best first.
enum Tier: String, CaseIterable, Codable {
    case insane, very_good, good, filler
    var label: String { ["insane": "🔥 insane", "very_good": "sehr gut", "good": "gut", "filler": "Filler"][rawValue]! }
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

struct Settings: Codable {
    var scheduler: Bool
    var fill_after: Int?    // minutes without a post -> extension posts a good/filler clip (0 = off)
    var last_posted: Double?  // epoch ms
}

/// /api/queue: exported, not yet posted
struct QueueItem: Codable, Identifiable, Hashable {
    let id: String
    var streamer: String
    var title: String?
    var caption: String?
    var thumbnail: String?
    var tier: Tier?
}

struct Schedule: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var streamer: String?
    var at: Double  // epoch ms
    var state: String?
    var error: String?
    var date: Date { Date(timeIntervalSince1970: at / 1000) }
}

struct Perspective: Codable, Identifiable, Hashable {
    let id: String
    var streamer: String
    var title: String?
    var views: Int?
    var thumbnail: String?
    var duration: Double?
    var from: Double
    var to: Double
    var off: Double
    @LooseBool var ready: Bool
}

/// Facecam + game frame of a layout ([x, y, w, h] of the source, see layout.py); cam nil = no facecam.
struct Frames: Codable, Hashable {
    var cam: [Double]?
    var game: [Double]
}

// MARK: - editor

struct Word: Codable, Hashable { var word: String; var start: Double; var end: Double }
struct SubChunk: Codable, Hashable, Identifiable {
    var id = UUID()
    var words: [Word]
    enum CodingKeys: String, CodingKey { case words }
    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
    var text: String { words.map(\.word).joined(separator: " ") }
}

/// Perspective switch: from main time `t` on, the other clip (nil = back to the main clip), `off` = other - main time.
/// cam/game: frames chosen for that perspective (nil game = that streamer's default layout).
struct Switch: Codable, Hashable {
    var t: Double
    var clip: String?
    var off: Double
    var streamer: String?
    var cam: [Double]?
    var game: [Double]?

    enum CodingKeys: String, CodingKey { case t, clip, off, streamer, cam, game }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(clip, forKey: .clip)
        try c.encode(off, forKey: .off)
        try c.encodeIfPresent(streamer, forKey: .streamer)
        if clip != nil, let game {  // own frames: explicit cam (null = no facecam)
            try c.encode(cam, forKey: .cam)
            try c.encode(game, forKey: .game)
        }
    }
}

/// Layout change during the clip (layout.py): from `t` on these frames, reached over `ease` seconds (0 = jump).
struct Keyframe: Codable, Hashable, Identifiable {
    var id = UUID()
    var t: Double
    var cam: [Double]?
    var game: [Double]?
    var ease: Double = 0
    enum CodingKeys: String, CodingKey { case t, cam, game, ease }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(cam, forKey: .cam)
        try c.encode(game, forKey: .game)
        try c.encode(ease, forKey: .ease)
    }
}

struct RenderDims: Codable, Hashable {
    var width: Double, height: Double, cam_height: Double, subs_y: Double, font_size: Double
    var highlight: String, title_secs: Double, title_size: Double
}

struct ClipDetail: Codable {
    let id: String
    var streamer: String
    var title: String?
    var status: String
    var caption: String?
    var overlay_title: String?
    var cam: [Double]?
    var cam_h: Double?
    var game: [Double]?     // game frame (nil on older clips: from game_x + zoom)
    var game_x: Double?
    var zoom: Double?
    var keyframes: [Keyframe]?
    var segments: String?   // joined clip: layout per part (edited in the web editor)
    var trim_start: Double?
    var trim_end: Double?
    var subs: [SubChunk]?
    var switches: String?  // JSON text in the DB
    var cuts: String?      // JSON text: ranges removed from the final video
    var raw_path: String?
    var out_path: String?
    var error: String?
    var render: RenderDims
}

struct Cut: Codable, Hashable { var start: Double; var end: Double }

/// Body of POST /api/clip/<id> (autosave) and /api/clip/<id>/export, same as the web editor sends.
struct SaveBody: Encodable {
    var cam: [Double]?
    var game: [Double]
    var keyframes: [Keyframe]
    var trim_start: Double
    var trim_end: Double
    var subs: [SubChunk]
    var caption: String
    var overlay_title: String
    var cam_h: Int
    var switches: [Switch]
    var cuts: [Cut]

    enum CodingKeys: String, CodingKey { case cam, game, keyframes, trim_start, trim_end, subs, caption, overlay_title, cam_h, switches, cuts }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(cam, forKey: .cam)  // explicit null = no facecam
        try c.encode(game, forKey: .game)
        try c.encode(keyframes, forKey: .keyframes)
        try c.encode(trim_start, forKey: .trim_start)
        try c.encode(trim_end, forKey: .trim_end)
        try c.encode(subs, forKey: .subs)
        try c.encode(caption, forKey: .caption)
        try c.encode(overlay_title, forKey: .overlay_title)
        try c.encode(cam_h, forKey: .cam_h)
        try c.encode(switches, forKey: .switches)
        try c.encode(cuts, forKey: .cuts)
    }
}

// MARK: - dates

private let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let iso = ISO8601DateFormatter()
private let sqlite: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
}()

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return iso.date(from: s) ?? isoFrac.date(from: s) ?? sqlite.date(from: s)
}

/// "12 min", "3 h", or "12.10. 18:30" like the website
func ago(_ d: Date?) -> String {
    guard let d else { return "" }
    let m = Date().timeIntervalSince(d) / 60
    if m < 60 { return "\(Int(m.rounded())) min" }
    if m < 1440 { return "\(Int((m / 60).rounded())) h" }
    return d.formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour().minute())
}
