import SwiftData
import SwiftUI
import WhubCore

struct HostTable: View {
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.modelContext) private var context
    @State private var selection: PersistentIdentifier?
    @State private var editingHost: WhubCore.Host?
    @State private var showsForm = false
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            Table(hosts, selection: $selection) {
                TableColumn("Name") { host in
                    cell(host.name, host: host)
                }
                TableColumn("Type") { host in
                    cell(host is LocalHost ? "Local" : "Remote", host: host)
                }
                TableColumn("Base Path") { host in
                    cell(host.basePath, host: host)
                }
            }

            HStack {
                ControlGroup {
                    Button("Add Host", systemImage: "plus") {
                        editingHost = nil
                        showsForm = true
                    }
                    Button("Remove Host", systemImage: "minus") {
                        showsDeleteConfirmation = true
                    }
                    .disabled(selectedHost == nil)
                }
                .labelStyle(.iconOnly)
                Spacer()
            }
        }
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

    private func cell(_ value: String, host: WhubCore.Host) -> some View {
        Text(value)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editingHost = host
                showsForm = true
            }
    }
}
