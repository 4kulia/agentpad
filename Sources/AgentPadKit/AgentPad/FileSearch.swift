import AppKit
import SwiftUI

/// Find-a-file-by-name for the session's folder.
enum FileSearch {
    /// Folders that are tooling output, never what someone looks for by name.
    static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", ".venv", "venv", "__pycache__",
        "DerivedData", "Pods", ".next", ".turbo", ".cache", ".gradle", "target",
    ]
    static let maxVisited = 50_000

    struct Hit: Identifiable, Equatable, Sendable {
        let url: URL
        let relativePath: String
        let isDirectory: Bool
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    /// Every word must appear in the path relative to `root` (case- and
    /// accent-insensitive). Hits whose NAME contains the whole query rank
    /// first, then shorter paths.
    static func search(root: URL, query: String, limit: Int = 200, isCancelled: () -> Bool = { false }) -> [Hit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsPackageDescendants]
              )
        else { return [] }
        let rootPath = root.standardizedFileURL.path
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let phrase = query.trimmingCharacters(in: .whitespaces)
        var hits: [Hit] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maxVisited || (visited % 256 == 0 && isCancelled()) { return [] }
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory, skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if name == ".DS_Store" { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : name
            guard words.allSatisfy({ relative.range(of: $0, options: options) != nil }) else { continue }
            hits.append(Hit(url: url.standardizedFileURL, relativePath: relative, isDirectory: isDirectory))
        }
        return hits.sorted { a, b in
            let aName = a.name.range(of: phrase, options: options) != nil
            let bName = b.name.range(of: phrase, options: options) != nil
            if aName != bName { return aName }
            if a.relativePath.count != b.relativePath.count { return a.relativePath.count < b.relativePath.count }
            return a.relativePath < b.relativePath
        }
        .prefix(limit)
        .map { $0 }
    }
}

/// Search field + results, shown in the files sidebar in place of the tree
/// while a query is typed.
struct FileSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.chromeMuted)
            TextField("Find file", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.display(12))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.chromeMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.chromeHover))
        .padding(.top, 4)
    }
}

struct FileSearchResults: View {
    let root: URL
    let query: String
    let onSelect: (URL) -> Void

    @State private var hits: [FileSearch.Hit] = []
    @State private var isSearching = false

    var body: some View {
        Group {
            if hits.isEmpty {
                VStack(spacing: Theme.space2) {
                    if isSearching { ProgressView().controlSize(.small) }
                    else {
                        Text("No files match")
                            .font(Theme.display(12))
                            .foregroundStyle(Theme.chromeMuted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(hits) { hit in
                            FileSearchRow(hit: hit, onSelect: onSelect)
                        }
                    }
                    .padding(.horizontal, Theme.space2)
                    .padding(.vertical, Theme.space1)
                }
            }
        }
        // Debounced by `task(id:)`: typing cancels the previous run.
        // Results from another folder must never stay actionable.
        .onChange(of: root) { _, _ in hits = [] }
        .task(id: "\(root.path)\u{0}\(query)") {
            isSearching = true
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let root = root, query = query
            let flag = CancellationFlag()
            let found = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    FileSearch.search(root: root, query: query, isCancelled: { flag.isSet })
                }.value
            } onCancel: {
                flag.set()
            }
            guard !Task.isCancelled else { return }
            hits = found
            isSearching = false
        }
    }
}

private struct FileSearchRow: View {
    let hit: FileSearch.Hit
    let onSelect: (URL) -> Void
    @State private var isHovered = false
    @State private var isMenuOpen = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hit.isDirectory ? "folder" : "doc")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(hit.name)
                    .font(Theme.display(12.5))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                let parent = (hit.relativePath as NSString).deletingLastPathComponent
                if !parent.isEmpty {
                    Text(parent)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.chromeFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isHovered ? Theme.chromeHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { if !hit.isDirectory { NSWorkspace.shared.open(hit.url) } }
        .onTapGesture { onSelect(hit.url) }
        .onDrag { NSItemProvider(object: hit.url as NSURL) }
        .overlay(RightClickCatcher { _ in isMenuOpen = true })
        .attentionPopover(isPresented: $isMenuOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                RevealInFinderMenuRow(url: hit.url) { isMenuOpen = false }
                AgentPadMenuRow(title: "Copy Path", localizesTitle: false) {
                    isMenuOpen = false
                    writeToGeneralPasteboard(hit.url.path)
                }
                FileTreeOperationRows(
                    node: FileNode(url: hit.url, name: hit.name, isDirectory: hit.isDirectory, isSymlink: false),
                    close: { isMenuOpen = false }
                )
            }
            .padding(Theme.space1)
            .frame(minWidth: 220)
            .background(Theme.chromeBackground)
        }
        .help(hit.relativePath)
    }
}

/// Lets a detached worker see that the task that started it was cancelled.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
