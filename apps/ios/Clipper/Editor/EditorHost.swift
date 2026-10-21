import SwiftUI

/// Shows the editor; "Exportieren & weiter" / "Ignorieren" swap in the next clip of the list's order.
struct EditorHost: View {
    let startId: String
    @Binding var path: [String]
    @State private var id: String?
    @Environment(ClipOrder.self) private var order

    var body: some View {
        Group {
            if let id {
                EditorView(clipId: id) { done in
                    if let next = order.next(after: done) { self.id = next } else { path.removeAll() }
                }
                .id(id)
            }
        }
        .onAppear { if id == nil { id = startId } }
    }
}
