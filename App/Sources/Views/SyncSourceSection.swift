import SwiftUI

/// One "keep this list synced from a URL" settings section: URL field,
/// collapsible auth-header rows, Sync Now, and a status footer. Used for
/// both vocabulary and people sync in MyVoiceView.
struct SyncSourceSection: View {
    let title: String
    let urlPlaceholder: String
    @Binding var sourceURL: String
    @Binding var headers: [Store.HTTPHeader]
    let lastSync: Date?
    let syncError: String?
    /// Footer before the URL is configured.
    let idleFooter: String
    /// Footer once synced — states the semantics (replace vs merge).
    let syncedFooter: String
    let onSave: () -> Void
    let onSync: () -> Void

    var body: some View {
        Section {
            TextField(urlPlaceholder, text: $sourceURL)
                .textEntry(.url)
                .onSubmit {
                    onSave()
                    onSync()
                }
            if !sourceURL.isEmpty {
                DisclosureGroup("Request Headers") {
                    // Id-based bindings, not ForEach($...): rows outlive
                    // removal by one render pass, and a positional binding
                    // read after the array shrinks crashes.
                    ForEach(headers) { header in
                        HStack {
                            // Explicit remove button: swipe-to-delete is
                            // unreliable inside a DisclosureGroup.
                            Button {
                                headers.removeAll { $0.id == header.id }
                                onSave()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            TextField("Header", text: headerBinding(header.id, \.name))
                                .textEntry(.header)
                                .frame(maxWidth: 140)
                            Divider()
                            TextField("Value", text: headerBinding(header.id, \.value))
                                .textEntry(.header)
                        }
                        .font(.callout.monospaced())
                    }
                    .onDelete { offsets in
                        headers.remove(atOffsets: offsets)
                        onSave()
                    }
                    Button {
                        headers.append(Store.HTTPHeader())
                    } label: {
                        Label("Add Header", systemImage: "plus")
                    }
                }
                Button {
                    onSave()
                    onSync()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let syncError {
                Text("Sync failed: \(syncError)")
                    .foregroundStyle(.red)
            } else if let lastSync, !sourceURL.isEmpty {
                Text("Synced \(lastSync.formatted(.relative(presentation: .named))). \(syncedFooter)")
            } else {
                Text(idleFooter)
            }
        }
    }

    /// Binding into a header row by id; reads return "" and writes no-op
    /// once the row has been removed, so a stale row can't trap.
    private func headerBinding(
        _ id: UUID, _ keyPath: WritableKeyPath<Store.HTTPHeader, String>
    ) -> Binding<String> {
        Binding(
            get: { headers.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let i = headers.firstIndex(where: { $0.id == id }) else { return }
                headers[i][keyPath: keyPath] = newValue
            }
        )
    }
}
