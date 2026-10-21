import SwiftUI

/// Shows the editor; "Exportieren & weiter" / "Ignorieren" swap in the next clip of the list's order,
/// after the last one `onEnd` leaves the editor.
struct EditorHost: View {
    let startId: String
    let onEnd: () -> Void
    @State private var id: String?
    @Environment(ClipOrder.self) private var order

    init(startId: String, onEnd: @escaping () -> Void) {
        self.startId = startId
        self.onEnd = onEnd
    }

    init(startId: String, path: Binding<[String]>) {
        self.init(startId: startId) { path.wrappedValue.removeAll() }
    }

    var body: some View {
        Group {
            if let id {
                EditorView(clipId: id) { done in
                    if let next = order.next(after: done) { self.id = next } else { onEnd() }
                }
                .id(id)
            }
        }
        .onAppear { if id == nil { id = startId } }
    }
}
