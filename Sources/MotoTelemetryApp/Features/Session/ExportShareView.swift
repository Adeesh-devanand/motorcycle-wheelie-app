import SwiftUI

/// ShareLink for a session directory (ndjson + manifest + audio).
/// Exports the session as a transferable bundle of all files in the session dir.
struct ExportShareView: View {
    let sessionDirectoryURL: URL
    let runSummary: String

    @State private var exportItems: [URL] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if exportItems.isEmpty {
                Button {
                    loadExportItems()
                } label: {
                    Label("Prepare Export", systemImage: "square.and.arrow.up")
                }
                .disabled(isLoading)
            } else {
                ShareLink(items: exportItems) { url in
                    SharePreview(
                        url.lastPathComponent,
                        icon: Image(systemName: fileIcon(for: url))
                    )
                } label: {
                    Label("Share Session", systemImage: "square.and.arrow.up")
                }
            }
        }
        .accessibilityLabel("Export session data")
    }

    // MARK: - Loading

    private func loadExportItems() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: sessionDirectoryURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                DispatchQueue.main.async { isLoading = false }
                return
            }

            let supported = contents.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["ndjson", "json", "caf", "m4a", "wav"].contains(ext)
            }

            DispatchQueue.main.async {
                exportItems = supported
                isLoading = false
            }
        }
    }

    // MARK: - Helpers

    private func fileIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "ndjson", "json": "doc.text"
        case "caf", "m4a", "wav": "waveform"
        default: "doc"
        }
    }
}
