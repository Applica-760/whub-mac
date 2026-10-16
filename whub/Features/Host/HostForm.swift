import SwiftData
import SwiftUI
import WhubCore

struct HostForm: View {
    let host: WhubCore.Host?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var type: HostType
    @State private var name: String
    @State private var basePath: String
    @State private var hostname: String
    @State private var user: String
    @State private var port: Int
    @State private var identityFile: String
    @State private var devServerURL: String
    @State private var prodServerURL: String
    @State private var errorMessage: String?

    init(host: WhubCore.Host? = nil) {
        self.host = host
        let remote = host as? RemoteHost
        _type = State(initialValue: remote == nil ? .local : .remote)
        _name = State(initialValue: host?.name ?? "")
        _basePath = State(initialValue: host?.basePath ?? "")
        _hostname = State(initialValue: remote?.hostname ?? "")
        _user = State(initialValue: remote?.user ?? "")
        _port = State(initialValue: remote?.port ?? 22)
        _identityFile = State(initialValue: remote?.identityFile ?? "")
        _devServerURL = State(initialValue: remote?.devServerURL ?? "")
        _prodServerURL = State(initialValue: remote?.prodServerURL ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(host == nil ? "Add Host" : "Edit Host")
                .font(.title2)

            Form {
                Picker("Type", selection: $type) {
                    ForEach(HostType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .disabled(host != nil)

                TextField("Name", text: $name)
                if type == .remote {
                    TextField("Hostname", text: $hostname)
                    TextField("User", text: $user)
                    TextField("Port", value: $port, format: .number)
                    TextField("Identity File", text: $identityFile)
                    TextField("Dev Server URL", text: $devServerURL)
                    TextField("Prod Server URL", text: $prodServerURL)
                }

                TextField("Base Path", text: $basePath)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save)
            }
        }
        .padding(24)
        .frame(width: 480)
        .alert("Unable to Save Host", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let store = HostStore(context: context)
        do {
            if let local = host as? LocalHost {
                try store.editLocal(local, name: name, basePath: basePath)
            } else if let remote = host as? RemoteHost {
                try store.editRemote(
                    remote,
                    name: name,
                    basePath: basePath,
                    hostname: hostname,
                    user: user,
                    port: port,
                    identityFile: identityFile,
                    devServerURL: devServerURL,
                    prodServerURL: prodServerURL
                )
            } else if type == .local {
                try store.addLocal(name: name, basePath: basePath)
            } else {
                try store.addRemote(
                    name: name,
                    basePath: basePath,
                    hostname: hostname,
                    user: user,
                    port: port,
                    identityFile: identityFile,
                    devServerURL: devServerURL,
                    prodServerURL: prodServerURL
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum HostType: String, CaseIterable, Identifiable {
    case local = "Local"
    case remote = "Remote"

    var id: Self { self }
}
