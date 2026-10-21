import AVFoundation
import SwiftUI

/// Shows `crop` (normalized source rect) of the player's video stretched over the view, like canvas drawImage.
/// The rect may reach beyond the source: that part stays black (zoomed-out frames).
/// Several of these can share one AVPlayer, so the preview is the real video, frame-exact.
struct CropPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let crop: CGRect

    func makeUIView(context: Context) -> CropView {
        let v = CropView()
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: CropView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.crop = crop
        v.setNeedsLayout()
    }

    final class CropView: UIView {
        let playerLayer = AVPlayerLayer()
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            backgroundColor = .black
            playerLayer.videoGravity = .resize
            layer.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let W = bounds.width / max(crop.width, 0.0001), H = bounds.height / max(crop.height, 0.0001)
            playerLayer.frame = CGRect(x: -crop.minX * W, y: -crop.minY * H, width: W, height: H)
            CATransaction.commit()
        }
    }
}

/// Vertical 9:16 result: facecam area on top, game below, credit, title card, word-highlight subtitles.
/// Drag the seam = facecam height; drag inside an area = move what it shows; pinch = zoom (like the web preview).
struct PreviewStage: View {
    @Bindable var m: EditorModel
    @State private var splitDragStart: Double?
    @State private var panStart: [Double]?
    @State private var pinchStart: [Double]?

    var body: some View {
        let shown = m.shown
        GeometryReader { geo in
            let k = geo.size.width / m.R.width
            let camH = shown.frames.cam == nil ? 0 : m.camH * k
            ZStack(alignment: .top) {
                Color.black
                VStack(spacing: 0) {
                    if let c = shown.frames.cam {
                        CropPlayerView(player: shown.player, crop: c.rect)
                            .frame(height: camH)
                            .contentShape(.rect)
                            .gesture(pan(cam: true, w: geo.size.width, h: camH))
                            .simultaneousGesture(pinch(cam: true))
                    }
                    CropPlayerView(player: shown.player, crop: shown.frames.game.rect)
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .gesture(pan(cam: false, w: geo.size.width, h: geo.size.height - camH))
                        .simultaneousGesture(pinch(cam: false))
                }
                // credit
                Text("@\(shown.streamer)")
                    .font(.system(size: 40 * k, weight: .black)).foregroundStyle(.white)
                    .shadow(color: .black, radius: 0, x: 2 * k, y: 2 * k).shadow(color: .black, radius: 3 * k)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30 * k).padding(.top, 30 * k)
                    .allowsHitTesting(false)
                titleCard(k: k, camH: m.camH * k, width: geo.size.width).allowsHitTesting(false)
                subtitle(k: k, width: geo.size.width).allowsHitTesting(false)
                // seam handle
                if shown.frames.cam != nil {
                    Capsule().fill(Theme.cam).frame(width: 64, height: 7)
                        .padding(.vertical, 16).padding(.horizontal, 40)
                        .contentShape(.rect)
                        .offset(y: camH - 19.5)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    if splitDragStart == nil { splitDragStart = m.camH }
                                    m.setSplit(splitDragStart! + g.translation.height / k)
                                }
                                .onEnded { _ in splitDragStart = nil }
                        )
                }
            }
            .contentShape(.rect)
            .onTapGesture { m.togglePlay() }
        }
        .aspectRatio(m.R.width / m.R.height, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 10))
    }

    /// drag the content: the frame moves the other way
    private func pan(cam: Bool, w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { g in
                let f = m.frames(m.target())
                guard let cur = cam ? f.cam : f.game else { return }
                if panStart == nil { panStart = cur }
                let s = panStart!
                m.moveFrame(cam: cam, from: s, dx: -g.translation.width / max(w, 1) * s[2], dy: -g.translation.height / max(h, 1) * s[3])
            }
            .onEnded { _ in panStart = nil }
    }

    private func pinch(cam: Bool) -> some Gesture {
        MagnifyGesture()
            .onChanged { g in
                let f = m.frames(m.target())
                guard let cur = cam ? f.cam : f.game else { return }
                if pinchStart == nil { pinchStart = cur }
                m.zoomFrame(cam: cam, from: pinchStart!, k: 1 / max(0.2, g.magnification))
            }
            .onEnded { _ in pinchStart = nil }
    }

    @ViewBuilder
    private func titleCard(k: CGFloat, camH: CGFloat, width: CGFloat) -> some View {
        let tt = m.overlayTitle.trimmingCharacters(in: .whitespaces)
        let rel = m.time - m.trimStart
        if !tt.isEmpty, rel >= 0, rel < m.R.title_secs {
            Text(tt)
                .font(.system(size: m.R.title_size * k, weight: .black))
                .foregroundStyle(Color(hex: 0x111111))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22 * k).padding(.vertical, 11 * k)
                .background(.white)
                .frame(maxWidth: width - 2 * 110 * k)
                .opacity(max(0, min(1, rel / 0.12, (m.R.title_secs - rel) / 0.22)))
                .position(x: width / 2, y: camH)
        }
    }

    @ViewBuilder
    private func subtitle(k: CGFloat, width: CGFloat) -> some View {
        if let ci = m.currentSubIndex, m.activePerspective(m.time) == nil {
            let ws = m.subs[ci].words
            let ai = ws.lastIndex { m.time >= $0.start } ?? 0
            let fs = m.R.font_size * k
            HStack(spacing: fs * 0.28) {
                ForEach(Array(ws.enumerated()), id: \.offset) { i, w in
                    Text(w.word.uppercased())
                        .font(.system(size: fs * (i == ai ? 1.12 : 1), weight: .black))
                        .foregroundStyle(i == ai ? Color(css: m.R.highlight) : .white)
                        .shadow(color: .black, radius: 0.5).shadow(color: .black, radius: 2 * k).shadow(color: .black.opacity(0.6), radius: 0, x: 4 * k, y: 4 * k)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.5)
            .frame(width: width)
            .position(x: width / 2, y: m.subsY * k)
        }
    }
}

/// 16:9 source of what is edited right now (the clip, or the perspective shown) with the facecam frame (green)
/// and the game frame (blue): drag = move, corner = bigger / smaller, pinch on a frame = zoom. Room around the
/// video, so frames can reach beyond it (black there in the result).
struct SourceStage: View {
    @Bindable var m: EditorModel
    @State private var dragStart: [Double]?
    @State private var pinchStart: [Double]?
    private let margin: CGFloat = 0.1

    var body: some View {
        let tg = m.target()
        let f = m.frames(tg), size = m.size(tg)
        let player = m.isMain(tg) ? m.player : m.other
        GeometryReader { geo in
            let W = geo.size.width / (1 + 2 * margin), H = W * size.height / max(size.width, 1)
            let ox = W * margin, oy = (geo.size.height - H) / 2
            ZStack(alignment: .topLeading) {
                Color(hex: 0x101013)
                CropPlayerView(player: player, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
                    .frame(width: W, height: H).offset(x: ox, y: oy)
                frameBox(cam: false, f.game, W: W, H: H, ox: ox, oy: oy)
                if let c = f.cam { frameBox(cam: true, c, W: W, H: H, ox: ox, oy: oy) }
            }
            .clipped()
            .disabled(m.joined)
        }
        .aspectRatio((1 + 2 * margin) * size.width / max(size.height, 1) / (1 + 2 * margin * 0.6), contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
    }

    @ViewBuilder
    private func frameBox(cam: Bool, _ c: [Double], W: CGFloat, H: CGFloat, ox: CGFloat, oy: CGFloat) -> some View {
        let box = CGRect(x: ox + c[0] * W, y: oy + c[1] * H, width: c[2] * W, height: c[3] * H)
        let color = cam ? Theme.cam : Theme.blue
        Rectangle().stroke(color, style: StrokeStyle(lineWidth: cam ? 3 : 2, dash: cam ? [] : [6, 4]))
            .background(color.opacity(0.06))
            .frame(width: box.width, height: box.height)
            .overlay(alignment: cam ? .topLeading : .bottomLeading) {
                Text(cam ? "Facecam" : "Spiel").font(.caption2.bold()).foregroundStyle(.black).padding(.horizontal, 4).background(color).padding(4)
            }
            .offset(x: box.minX, y: box.minY)
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if dragStart == nil { dragStart = c }
                m.moveFrame(cam: cam, from: dragStart!, dx: v.translation.width / W, dy: v.translation.height / H)
            }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { g in
                if pinchStart == nil { pinchStart = c }
                m.zoomFrame(cam: cam, from: pinchStart!, k: 1 / max(0.2, g.magnification))
            }.onEnded { _ in pinchStart = nil })
        // corner handles (large touch targets): the opposite corner stays
        ForEach(0..<4, id: \.self) { i in
            let fx = Double(i % 2), fy = Double(i / 2)
            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black, lineWidth: 1))
                .padding(12).contentShape(.rect)
                .offset(x: box.minX + fx * box.width - 20, y: box.minY + fy * box.height - 20)
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    if dragStart == nil { dragStart = c }
                    m.scaleFrame(cam: cam, from: dragStart!, corner: (fx, fy), dx: v.translation.width / W)
                }.onEnded { _ in dragStart = nil })
        }
    }
}

extension Theme {
    static let cam = Color(hex: 0x39D353)
    static let kf = Color(hex: 0xE5C100)
}
