import SwiftUI

struct UndoHistoryView: View {
    @EnvironmentObject private var vm: BundleViewModel
    @Environment(\.dismiss) private var dismiss

    private var editedItems: [ObjectItem] { vm.items.filter { $0.isModified } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Original object data is saved automatically and remains available after reopening this bundle.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        Task { await vm.restoreAllObjects() }
                    } label: {
                        Label("Restore entire bundle to its original copy", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(editedItems.isEmpty)
                }

                Section("Edited objects · \(editedItems.count)") {
                    if editedItems.isEmpty {
                        Text("There are no edited objects.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(editedItems) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).lineLimit(1)
                                Text("\(item.type) · object \(item.index) · ID \(item.pathId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Undo") {
                                Task { await vm.restoreObject(item) }
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Edit history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
