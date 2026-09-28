import SwiftUI

struct ProjectNavigation {
    let urls: [URL]
    @Binding var selection: URL?

    func move(by offset: Int) {
        guard let index = urls.firstIndex(where: { $0 == selection }),
              urls.indices.contains(index + offset) else { return }
        selection = urls[index + offset]
    }
}

private struct ProjectNavigationKey: FocusedValueKey {
    typealias Value = ProjectNavigation
}

extension FocusedValues {
    var projectNavigation: ProjectNavigation? {
        get { self[ProjectNavigationKey.self] }
        set { self[ProjectNavigationKey.self] = newValue }
    }
}
