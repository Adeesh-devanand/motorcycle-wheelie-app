import SwiftUI
import UIKit

// MARK: - Log Viewer ViewModel

/// Loads the tail of one file off the main thread and publishes the result. Never
/// blocks the UI on file I/O.
@Observable
final class LogViewerViewModel {
    private(set) var lines: [LogLine] = []
    private(set) var skippedCount = 0
    private(set) var truncated = false
    private(set) var isLoading = false

    // Filters (applied on the main actor over the already-loaded tail).
    var categoryFilter: String? = nil
    var minLevel: LogLine.Level = .trace
    var searchText: String = ""

    let file: LogFileEntry
    private let tailLimit: Int

    init(file: LogFileEntry, tailLimit: Int = 500) {
        self.file = file
        self.tailLimit = tailLimit
    }

    /// All distinct categories present, for the filter menu.
    var categories: [String] {
        Array(Set(lines.map(\.category))).filter { !$0.isEmpty }.sorted()
    }

    var visibleLines: [LogLine] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return lines.filter { line in
            if line.level < minLevel { return false }
            if let cat = categoryFilter, line.category != cat { return false }
            if !needle.isEmpty && !line.message.lowercased().contains(needle) { return false }
            return true
        }
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        let url = file.url
        let limit = tailLimit
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = NDJSONReader.tail(url: url, maxLines: limit)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lines = result.lines
                self.skippedCount = result.skippedCount
                self.truncated = result.truncated
                self.isLoading = false
            }
        }
    }

    /// Plain-text rendering of the currently visible lines, for the clipboard.
    func visibleAsText() -> String {
        visibleLines.map { line in
            let base = String(format: "%.3f [%@] %@: %@",
                              line.time, line.level.rawValue, line.category, line.message)
            return line.values.isEmpty ? base : base + "  {" + line.valuesCompact + "}"
        }.joined(separator: "\n")
    }
}

// MARK: - Log Viewer View

struct LogViewerView: View {
    @State private var model: LogViewerViewModel
    @State private var copied = false

    init(file: LogFileEntry, tailLimit: Int = 500) {
        _model = State(wrappedValue: LogViewerViewModel(file: file, tailLimit: tailLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider().overlay(AppColors.cardBorder)
            content
        }
        .background(AppColors.background)
        .navigationTitle(model.file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = model.visibleAsText()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(model.visibleLines.isEmpty)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.load() }
    }

    // MARK: filter bar

    private var filterBar: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textTertiary)
                TextField("Search message", text: $model.searchText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
            .padding(AppSpacing.sm)
            .background(AppColors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.button))

            HStack(spacing: AppSpacing.sm) {
                levelMenu
                categoryMenu
                Spacer()
                Text("\(model.visibleLines.count) shown")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(AppSpacing.screenPadding)
    }

    private var levelMenu: some View {
        Menu {
            ForEach([LogLine.Level.trace, .debug, .info, .warn, .error], id: \.self) { lvl in
                Button {
                    model.minLevel = lvl
                } label: {
                    if model.minLevel == lvl { Label(lvl.rawValue.capitalized, systemImage: "checkmark") }
                    else { Text(lvl.rawValue.capitalized) }
                }
            }
        } label: {
            chipLabel("≥ \(model.minLevel.rawValue.uppercased())", active: model.minLevel != .trace)
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button {
                model.categoryFilter = nil
            } label: {
                if model.categoryFilter == nil { Label("All categories", systemImage: "checkmark") }
                else { Text("All categories") }
            }
            ForEach(model.categories, id: \.self) { cat in
                Button {
                    model.categoryFilter = cat
                } label: {
                    if model.categoryFilter == cat { Label(cat, systemImage: "checkmark") }
                    else { Text(cat) }
                }
            }
        } label: {
            chipLabel(model.categoryFilter ?? "ALL CATS", active: model.categoryFilter != nil)
        }
    }

    private func chipLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(AppTypography.chipLabel)
            .foregroundStyle(active ? AppColors.chipSelectedText : AppColors.chipText)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(active ? AppColors.chipSelectedFill : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.chip)
                    .strokeBorder(active ? AppColors.chipSelectedBorder : AppColors.chipBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.chip))
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            Spacer()
            ProgressView().tint(AppColors.accent)
            Spacer()
        } else if model.lines.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.truncated {
                        Text("Showing the last \(model.lines.count) lines")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.textTertiary)
                            .padding(.vertical, AppSpacing.sm)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(model.visibleLines) { line in
                        LogLineRow(line: line)
                        Divider().overlay(AppColors.cardBorder.opacity(0.5))
                    }
                    if model.skippedCount > 0 {
                        Text("\(model.skippedCount) unparseable line\(model.skippedCount == 1 ? "" : "s") skipped")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.textTertiary)
                            .padding(.vertical, AppSpacing.sm)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, AppSpacing.screenPadding)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(AppColors.textTertiary)
            Text("No readable lines in this file")
                .font(AppTypography.bodyText)
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - One dense log row

private struct LogLineRow: View {
    let line: LogLine

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Text(String(format: "%.2f", line.time))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(minWidth: 52, alignment: .trailing)
                Text(line.category.isEmpty ? "—" : line.category)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(minWidth: 56, alignment: .leading)
                Text(line.message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(levelColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !line.values.isEmpty {
                Text(line.valuesCompact)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.leading, 116)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var levelColor: Color {
        switch line.level {
        case .error: return AppColors.danger
        case .warn: return AppColors.warning
        case .info: return AppColors.textPrimary
        case .debug, .trace: return AppColors.textTertiary
        }
    }
}
