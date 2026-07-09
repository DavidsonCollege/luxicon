import SwiftUI

/// One-tap person picker for the Control Center / Action button flow:
/// pick who's across the table, land straight in the record screen.
struct QuickRecordPickerView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Person) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.people.isEmpty {
                    ContentUnavailableView(
                        "No people yet",
                        systemImage: "person.2",
                        description: Text("Add someone in Luxicon first.")
                    )
                } else {
                    List(store.people) { person in
                        Button {
                            onSelect(person)
                        } label: {
                            HStack {
                                Text(person.name).font(.headline)
                                Spacer()
                                Image(systemName: "record.circle")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Record 1-on-1 with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
