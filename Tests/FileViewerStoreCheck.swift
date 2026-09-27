import Foundation

@main
struct FileViewerStoreCheck {
    static func main() {
        let store = FileViewerStore()
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        let c = URL(fileURLWithPath: "/c")

        store.preview(a)
        store.preview(b)
        assert(store.fileURLs == [b] && store.previewFileURL == b)

        store.open(b)
        store.preview(c)
        assert(store.fileURLs == [b, c] && store.previewFileURL == c)

        store.preview(b)
        assert(store.selectedFileURL == b && store.previewFileURL == c)

        store.close(c)
        assert(store.fileURLs == [b] && store.previewFileURL == nil)
    }
}
