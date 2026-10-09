import Combine
import Foundation

final class EditorStore: ObservableObject {
    @Published private(set) var fileLocations: [FileLocation] = []
    @Published private(set) var selectedLocation: FileLocation?
    @Published private(set) var previewLocation: FileLocation?
    let local = LocalEditorStore()
    let remote = RemoteViewerStore()
    private var changes: AnyCancellable?
    private var isClosing = false

    init() {
        changes = Publishers.Merge(local.objectWillChange, remote.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func file(for location: FileLocation) -> FileStore? {
        local.fileStores[location]?.document ?? remote.file(for: location)
    }

    func refresh() {
        remote.refresh()
    }

    func open(_ location: FileLocation) {
        guard location.localURL != nil || remote.states[location] != nil else { return }
        local.load(location)
        if !fileLocations.contains(location) {
            fileLocations.append(location)
        }
        selectedLocation = location
        if previewLocation == location { previewLocation = nil }
    }

    func preview(_ location: FileLocation) {
        guard location.localURL != nil || remote.states[location] != nil else { return }
        if fileLocations.contains(location) && previewLocation != location {
            selectedLocation = location
            return
        }
        if let previewLocation, let index = fileLocations.firstIndex(of: previewLocation) {
            if previewLocation != location {
                local.close(previewLocation)
                remote.close(previewLocation)
            }
            fileLocations[index] = location
        } else if !fileLocations.contains(location) {
            fileLocations.append(location)
        }
        local.load(location)
        previewLocation = location
        selectedLocation = location
    }

    func close(_ location: FileLocation) {
        guard !isClosing, fileLocations.contains(location) else { return }
        isClosing = true
        defer { isClosing = false }
        guard local.fileStores[location]?.confirmClose() != false else { return }
        guard let index = fileLocations.firstIndex(of: location) else { return }
        fileLocations.remove(at: index)
        local.close(location)
        remote.close(location)
        if previewLocation == location { previewLocation = nil }
        guard selectedLocation == location else { return }
        selectedLocation = index < fileLocations.count ? fileLocations[index] : fileLocations.last
    }

    func move(_ location: FileLocation, before target: FileLocation?) {
        guard let reordered = reorderedTabs(fileLocations, moving: location, before: target, identifiedBy: \.self)
        else { return }
        fileLocations = reordered
        if previewLocation == location { previewLocation = nil }
    }

    func select(_ location: FileLocation) {
        guard fileLocations.contains(location) else { return }
        selectedLocation = location
    }
}
