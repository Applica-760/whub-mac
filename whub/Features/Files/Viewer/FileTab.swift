import SwiftUI

struct FileTab: View {
    @ObservedObject var fileStore: FileStore
    let isSelected: Bool
    let isPreview: Bool
    let titleColor: Color?
    let closeShortcutEnabled: Bool
    let action: () -> Void
    let openAction: () -> Void
    let closeAction: () -> Void

    var body: some View {
        TabBar(
            title: fileStore.fileURL.lastPathComponent,
            icon: IconList.image(for: fileStore.fileURL),
            isSelected: isSelected,
            isPreview: isPreview,
            titleColor: titleColor,
            showsSelectionBorder: true,
            closeShortcutEnabled: closeShortcutEnabled,
            status: fileStore.hasUnsavedChanges ? (.primary, "未保存") : nil,
            openAction: openAction,
            action: action,
            closeAction: closeAction
        )
    }
}
