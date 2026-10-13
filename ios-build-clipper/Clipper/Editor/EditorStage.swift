import AVFoundation
import SwiftUI

/// Shows `crop` (normalized source rect) of the player's video stretched over the view, like canvas drawImage.
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
/// Drag the seam between facecam and game to resize the facecam area (like the web preview).
struct PreviewStage: View {
    @Bindable var m: EditorModel
    @State private var splitDragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / m.R.width
            let camH = m.camH * k
            ZStack(alignment: .top) {
                Color.black
                VStack(spacing: 0) {
                    CropPlayerView(player: m.player, crop: m.camSourceRect).frame(height: camH)
                    CropPlayerView(player: m.player, crop: m.gameSourceRect)
                }
                // credit
                Text("@\(m.clip?.streamer ?? "")")
                    .font(.system(size: 40 * k, weight: .black)).foregroundStyle(.white)
                    .shadow(color: .black, radius: 0, x: 2 * k, y: 2 * k).shadow(color: .black, radius: 3 * k)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30 * k).padding(.top, 30 * k)
                titleCard(k: k, camH: camH, width: geo.size.width)
                subtitle(k: k, width: geo.size.width)
                // seam handle
                Capsule().fill(Theme.cam).frame(width: 56, height: 6)
                    .padding(.vertical, 14).padding(.horizontal, 30)
                    .contentShape(.rect)
                    .offset(y: camH - 17)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                if splitDragStart == nil { splitDragStart = m.camH }
                                m.setSplit(splitDragStart! + g.translation.height / k)
                            }
                            .onEnded { _ in splitDragStart = nil }
                    )
            }
            .contentShape(.rect)
            .onTapGesture { m.togglePlay() }
        }
        .aspectRatio(m.R.width / m.R.height, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 10))
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
        if let ci = m.currentSubIndex {
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

/// 16:9 source with the facecam box (drag = move, corner = resize) and the game crop lines.
struct SourceStage: View {
    @Bindable var m: EditorModel
    @State private var dragStart: [Double]?

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                CropPlayerView(player: m.player, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
                let g = m.gameSourceRect
                Rectangle().stroke(Theme.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: g.width * W, height: H).offset(x: g.minX * W)
                    .allowsHitTesting(false)
                if let c = m.cam {
                    let box = CGRect(x: c[0] * W, y: c[1] * H, width: c[2] * W, height: c[3] * H)
                    Rectangle().fill(.black.opacity(0.35)).reverseMask { Rectangle().frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY) }
                        .allowsHitTesting(false)
                    Rectangle().stroke(Theme.cam, lineWidth: 3)
                        .background(Color.white.opacity(0.001))
                        .frame(width: box.width, height: box.height)
                        .overlay(alignment: .topLeading) {
                            Text("Facecam").font(.caption2.bold()).foregroundStyle(.black).padding(.horizontal, 4).background(Theme.cam).padding(4)
                        }
                        .offset(x: box.minX, y: box.minY)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            if dragStart == nil { dragStart = c }
                            m.moveCam(from: dragStart!, dx: v.translation.width / W, dy: v.translation.height / H)
                        }.onEnded { _ in dragStart = nil })
                    // resize handle (large touch target)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.cam).frame(width: 18, height: 18)
                        .padding(12).contentShape(.rect)
                        .offset(x: box.maxX - 21, y: box.maxY - 21)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            if dragStart == nil { dragStart = c }
                            m.resizeCam(from: dragStart!, dx: v.translation.width / W)
                        }.onEnded { _ in dragStart = nil })
                }
            }
        }
        .aspectRatio(m.vAR, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
    }
}

extension Theme {
    static let cam = Color(hex: 0x39D353)
}

extension View {
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle().overlay(alignment: .topLeading) { mask().blendMode(.destinationOut) }.compositingGroup()
        }
    }
}
