import SwiftUI
import WhubCore

struct HostForm: View {
    let host: WhubCore.Host?
    @Environment(\.dismiss) private var dismiss
    @State private var type: HostType
    @State private var name: String
    @State private var basePath: String
    @State private var hostname: String
    @State private var user: String
    @State private var port: Int
    @State private var identityFile: String

    init(host: WhubCore.Host? = nil) {
        self.host = host
        let remote = host as? RemoteHost
        _type = State(initialValue: remote == nil ? .local : .remote)
        _name = State(initialValue: remote?.name ?? "")
        _basePath = State(initialValue: host?.basePath ?? "")
        _hostname = State(initialValue: remote?.hostname ?? "")
        _user = State(initialValue: remote?.user ?? "")
        _port = State(initialValue: remote?.port ?? 22)
        _identityFile = State(initialValue: remote?.identityFile ?? "")
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

                if type == .local {
                    LabeledContent("Name", value: "local")
                } else {
                    TextField("Name", text: $name)
                    TextField("Hostname", text: $hostname)
                    TextField("User", text: $user)
                    TextField("Port", value: $port, format: .number)
                    TextField("Identity File", text: $identityFile)
                }

                TextField("Base Path", text: $basePath)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {}
                    .disabled(true)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private enum HostType: String, CaseIterable, Identifiable {
    case local = "Local"
    case remote = "Remote"

    var id: Self { self }
}
