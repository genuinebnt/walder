import SwiftUI
import QuickLookUI

/// Opens macOS's own Quick Look panel for a file.
///
/// Space bar in a file browser is muscle memory, and Quick Look shows things
/// Lumen's preview does not — colour profile, EXIF, the system's own zoom — so
/// it is worth handing over to rather than reimplementing.
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var urls: [URL] = []
    private var index = 0

    /// Shows `urls`, starting at `start`. Toggles closed if already showing.
    func show(_ urls: [URL], startingAt start: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        self.index = min(max(start, 0), urls.count - 1)

        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.currentPreviewItemIndex = index
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem? {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
