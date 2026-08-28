import SwiftUI

// MARK: - Diagnostics ViewModel

/// Enumerates the logs directory and parses the newest session summary off the
/// main thread. All file I/O (enumerate, summary parse, delete) is dispatched to
/// a background queue and results are published back on the main actor.
@Observable
final class DiagnosticsViewModel {
    private(set) var snapshot = LogFileBrowser.Snapshot.empty
    private(set) var summary: SessionSummary?
    private(set) var isLoading = false

    private let browser = LogFileBrowser()

    var totalBytesText: String { snapshot.totalBytesText }
    var exceedsSoftLimit: Bool { snapshot.totalBytes > LogFileBrowser.softSizeLimitBytes }
    var isEmpty: Bool { snapshot.isEmpty }

    /// Newest session and raw files, for the share-all action.
    var newestSession: LogFileEntry? { browser.newest(.session, in: snapshot) }
    var newestRaw: LogFileEntry? { browser.newest(.raw, in: snapshot) }

    var shareAllURLs: [URL] {
        [newestSession?.url, newestRaw?.url].compactMap { $0 }
    }

    func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let snap = self.browser.snapshot()
            var summary: SessionSummary?
            if let newest = self.browser.newest(.session, in: snap) {
                let result = NDJSONReader.allLines(url: newest.url)
                summary = SessionSummaryParser.parse(
                    fileName: newest.name, lines: result.lines, skipped: result.skippedCount
                )
            }
            DispatchQueue.main.async {
                self.snapshot = snap
                self.summary = summary
                self.isLoading = false
            }
        }
    }

    func delete(_ entry: LogFileEntry) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? FileManager.default.removeItem(at: entry.url)
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func deleteAll() {
        let urls = snapshot.files.map(\.url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for url in urls { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { self?.reload() }
        }
    }
}

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @State private var model = DiagnosticsViewModel()
    @State private var pendingDelete: LogFileEntry?
    @State private var confirmDeleteAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                if model.isEmpty && !model.isLoading {
                    emptyState
                } else {
                    totalSizeCard
                    if let summary = model.summary {
                        SessionSummaryCard(summary: summary)
                    }
                    fileListSection
                }
            }
            .padding(AppSpacing.screenPadding)
        }
        .background(AppColors.background)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !model.shareAllURLs.isEmpty {
                            ShareLink(items: model.shareAllURLs) {
                                Label("Share newest session + raw", systemImage: "square.and.arrow.up.on.square")
                            }
                        }
                        Button(role: .destructive) {
                            confirmDeleteAll = true
                        } label: {
                            Label("Delete all logs", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.reload() }
        .confirmationDialog(
            "Delete all \(model.snapshot.files.count) log files?",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all logs (\(model.totalBytesText))", role: .destructive) {
                model.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every session and raw log on this device. Export anything you need first.")
        }
        .confirmationDialog(
            "Delete this log file?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete \(entry.name)", role: .destructive) {
                model.delete(entry)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    // MARK: total size

    private var totalSizeCard: some View {
        TelemetryCard {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack {
                    Text("Total on disk")
                        .font(AppTypography.cardSubtitle)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text(model.totalBytesText)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(model.exceedsSoftLimit ? AppColors.warning : AppColors.textPrimary)
                }
                if model.exceedsSoftLimit {
                    Label("Logs exceed ~100 MB — consider deleting old logs after exporting.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.warning)
                }
            }
        }
    }

    // MARK: file list

    private var fileListSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Log Files")
                .sectionHeaderStyle()
            ForEach(model.snapshot.files) { entry in
                LogFileRow(entry: entry) {
                    pendingDelete = entry
                }
            }
        }
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textTertiary)
            Text("No logs yet")
                .font(AppTypography.cardTitle)
                .foregroundStyle(AppColors.textPrimary)
            Text("Logs are written while you record. Once you ride, session and raw sensor logs will appear here to view and export.")
                .font(AppTypography.cardSubtitle)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.xxl)
    }
}

// MARK: - Log File Row

private struct LogFileRow: View {
    let entry: LogFileEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            NavigationLink {
                LogViewerView(file: entry)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(entry.kind == .raw)   // raw files are for export, not the line viewer

            // WORKING ShareLink on the REAL file URL — deliberately NOT the
            // decorative "Prepare Export" pattern in ExportShareView. A file URL
            // is directly Transferable, so this exports the actual bytes.
            ShareLink(item: entry.url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.accent)
                    .frame(width: 36, height: 36)
                    .background(AppColors.surfaceButton)
                    .clipShape(Circle())
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.danger)
                    .frame(width: 36, height: 36)
                    .background(AppColors.surfaceButton)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.cardPadding)
        .background(AppColors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                .strokeBorder(AppColors.cardBorder, lineWidth: 1)
        )
    }

    private var rowContent: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: entry.kind == .raw ? "waveform" : "doc.text")
                .font(.system(size: 16))
                .foregroundStyle(entry.kind == .raw ? AppColors.angleMetric : AppColors.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: AppSpacing.sm) {
                    Text(entry.kind.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    if entry.kind == .session {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
                Text("\(Self.dateText(entry.modifiedDate)) · \(entry.sizeText)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm:ss"
        return f
    }()

    private static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
