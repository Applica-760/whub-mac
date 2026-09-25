import SwiftData
import SwiftUI
import WhubCore

struct HostTable: View {
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @State private var selection: PersistentIdentifier?
    @State private var editingHost: WhubCore.Host?
    @State private var showsForm = false

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
                    Button("Remove Host", systemImage: "minus") {}
                        .disabled(true)
                }
                .labelStyle(.iconOnly)
                Spacer()
            }
        }
        .sheet(isPresented: $showsForm) {
            HostForm(host: editingHost)
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
