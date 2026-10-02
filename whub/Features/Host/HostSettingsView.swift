import SwiftData
import SwiftUI
import WhubCore

struct HostSettingsView: View {
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.modelContext) private var context
    @State private var selection: PersistentIdentifier?
    @State private var editingHost: WhubCore.Host?
    @State private var showsForm = false
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        EditableTable(
            rows: hosts,
            columns: [
                .init(id: "name", title: "Name", value: { $0.name }),
                .init(id: "type", title: "Type", value: { $0 is LocalHost ? "Local" : "Remote" }),
                .init(id: "basePath", title: "Base Path", value: { $0.basePath }),
            ],
            selection: $selection,
            addTitle: "Add Host",
            removeTitle: "Remove Host",
            canRemove: selectedHost != nil,
            onAdd: {
                editingHost = nil
                showsForm = true
                return nil
            },
            onRemove: { showsDeleteConfirmation = true },
            onDoubleClick: { host, _ in
                editingHost = host
                showsForm = true
            }
        )
        .sheet(isPresented: $showsForm) {
            HostForm(host: editingHost)
        }
        .alert("Delete Host?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("Delete \(selectedHost?.name ?? "this host")?")
        }
        .alert("Unable to Delete Host", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var selectedHost: WhubCore.Host? {
        hosts.first { $0.persistentModelID == selection }
    }

    private func delete() {
        guard let host = selectedHost else { return }
        do {
            try HostStore(context: context).delete(host)
            selection = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
