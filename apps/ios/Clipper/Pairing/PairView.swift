import SwiftUI

struct PairView: View {
    @Environment(Connection.self) private var connection
    @State private var scanning = false
    @State private var manual = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Logo().font(.system(size: 34, weight: .heavy)).padding(.top, 60)
                Text("Steuere CutForTiktok auf deinem Mac vom iPhone aus – gleiche Clips, gleicher Stand.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.mute)

                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Auf dem Mac `uv run cutfortiktok review` starten")
                    step(2, "Im Browser http://localhost:8080/pair öffnen (📱 oben rechts)")
                    step(3, "QR-Code scannen – iPhone und Mac im selben WLAN")
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: .rect(cornerRadius: 14))

                Button { scanning = true } label: {
                    Label("QR-Code scannen", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton())
                .disabled(busy)

                DisclosureGroup("Link manuell einfügen") {
                    TextField("clipper://pair?u=…&k=…", text: $manual, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(10).background(Theme.panel2, in: .rect(cornerRadius: 9))
                    Button("Verbinden") { connect(manual) }.buttonStyle(SecondaryButton()).disabled(manual.isEmpty || busy)
                }
                .tint(Theme.mute)

                if busy { ProgressView("Verbinde…") }
                if let error { Text(error).foregroundStyle(.red).font(.footnote).multilineTextAlignment(.center) }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .fullScreenCover(isPresented: $scanning) {
            QRScannerSheet { code in scanning = false; connect(code) }
        }
    }

    private func step(_ n: Int, _ t: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.footnote.bold()).frame(width: 22, height: 22).background(Theme.acc, in: .circle)
            Text(t).font(.subheadline)
        }
    }

    private func connect(_ code: String) {
        guard let (server, token) = Connection.parse(code) else {
            error = "Das ist kein Clipper-QR-Code."
            return
        }
        busy = true; error = nil
        Task {
            do { try await connection.pair(server: server, token: token) }
            catch { self.error = "\(server.host() ?? ""): \(error.localizedDescription)" }
            busy = false
        }
    }
}

struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            QRScannerView(onCode: onCode).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.9), lineWidth: 3).frame(width: 250, height: 250)
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3.bold()).padding(12).background(.ultraThinMaterial, in: .circle)
                    }
                }
                Spacer()
                Text("QR-Code von localhost:8080/pair ins Feld halten")
                    .font(.subheadline.weight(.semibold)).padding(12).background(.ultraThinMaterial, in: .capsule)
            }
            .padding()
        }
    }
}
