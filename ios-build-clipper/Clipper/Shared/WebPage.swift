import AVKit
import SwiftUI
import WebKit

/// A page of the website inside the app (used for the full web editor: perspectives/switches).
/// ?k=<token> makes the server set a cookie, so the page's own fetches and videos are authorized too.
struct WebPage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: c)
        v.isOpaque = false
        v.backgroundColor = .black
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}
}

struct WebEditorSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebPage(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Web-Editor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

/// Plays a video from the Mac (rendered/exported clip).
struct VideoSheet: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player { VideoPlayer(player: player).ignoresSafeArea() }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: .circle)
            }
            .padding()
        }
        .onAppear { player = AVPlayer(url: url); player?.play() }
        .onDisappear { player?.pause() }
    }
}

struct IdentifiedURL: Identifiable { let url: URL; var id: String { url.absoluteString } }
