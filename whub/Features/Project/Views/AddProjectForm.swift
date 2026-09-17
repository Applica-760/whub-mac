import SwiftData
import SwiftUI
import WhubCore

struct AddProjectForm: View {
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var controller = ProjectCreationController()

    var body: some View {
        @Bindable var controller = controller

        VStack(spacing: 32) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    Text("Name")
                    TextField("Name", text: $controller.name)
                        .labelsHidden()
                        .frame(width: 320)
                }
                GridRow {
                    Text("Workspace Path")
                    TextField("Workspace Path", text: $controller.workspacePath)
                        .labelsHidden()
                        .frame(width: 320)
                }
                GridRow {
                    Text("Type")
                    Picker("Type", selection: $controller.resourceType) {
                        ForEach(ProjectCreationController.ResourceType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320, alignment: .leading)
                }

                if controller.resourceType == .local {
                    GridRow {
                        Text("Local Path")
                        TextField("Local Path", text: $controller.localPath)
                            .labelsHidden()
                            .frame(width: 320)
                    }
                } else {
                    GridRow {
                        Text("Host")
                        Picker("Host", selection: $controller.hostID) {
                            Text("Select a host").tag(PersistentIdentifier?.none)
                            ForEach(hosts) { host in
                                Text(host.name).tag(Optional(host.persistentModelID))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 320, alignment: .leading)
                    }
                    GridRow {
                        Text("Remote Path")
                        TextField("Remote Path", text: $controller.remotePath)
                            .labelsHidden()
                            .frame(width: 320)
                    }
                }

                GridRow {
                    Text("Git URL")
                    TextField("Git URL", text: $controller.gitURL)
                        .labelsHidden()
                        .frame(width: 320)
                }
                GridRow {
                    Text("Status")
                    Toggle("Enable Status", isOn: $controller.statusEnabled)
                        .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Add") {
                    if controller.add(context: context, hosts: hosts) {
                        dismiss()
                    }
                }
                .disabled(!controller.canAdd(hosts: hosts))
            }
        }
        .padding(28)
        .frame(width: 520)
        .textFieldStyle(.roundedBorder)
        .alert("Unable to Add Project", isPresented: $controller.showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage)
        }
    }
}
