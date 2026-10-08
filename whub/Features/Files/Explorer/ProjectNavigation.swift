import SwiftUI

struct ProjectNavigation {
    let locations: [FileLocation]
    @Binding var selection: FileLocation?

    func move(by offset: Int) {
        guard let index = locations.firstIndex(where: { $0 == selection }),
              locations.indices.contains(index + offset) else { return }
        selection = locations[index + offset]
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
