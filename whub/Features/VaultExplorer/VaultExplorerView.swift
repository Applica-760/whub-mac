import SwiftUI

struct VaultExplorerView: View {
    private let items = ["inbox", "ideas", "archives", "README.md"]

    var body: some View {
        List(items, id: \.self) { item in
            Label(item, systemImage: item.contains(".") ? "doc.text" : "folder")
        }
        .navigationTitle("Vault")
    }
}

#Preview {
    VaultExplorerView()
}
