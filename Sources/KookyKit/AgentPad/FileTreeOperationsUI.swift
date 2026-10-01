import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AgentPad rows appended to the file tree's context menu.
struct FileTreeOperationRows: View {
    let node: FileNode
    let close: () -> Void

    /// Where "New…" and "Paste" land: the folder itself, or a file's folder.
    private var targetDirectory: URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    var body: some View {
        if !node.isDirectory {
            row("Quick Look") { QuickLookPanel.show(node.url) }
        }
        KookyMenuDivider()
        row("New File…") { FileOperations.newFile(in: targetDirectory) }
        row("New Folder") { FileOperations.newFolder(in: targetDirectory) }
        KookyMenuDivider()
        row("Copy", shortcut: nil) { FileOperations.copy([node.url]) }
        row("Cut") { FileOperations.copy([node.url], cut: true) }
        row(FileOperations.pasteMode() == .move ? "Move Here" : "Paste", disabled: !FileOperations.canPaste()) {
            FileOperations.paste(into: targetDirectory)
        }
        KookyMenuDivider()
        row("Rename…") { FileOperations.rename(node.url) }
        row("Duplicate") { FileOperations.duplicate(node.url) }
        row("Move to Trash", color: Theme.activityFailure) { FileOperations.trash([node.url]) }
    }

    private func row(_ title: String, shortcut: String? = nil, disabled: Bool = false, color: Color? = nil, _ action: @escaping () -> Void) -> some View {
        KookyMenuRow(title: title, localizesTitle: false, shortcut: shortcut, isDisabled: disabled, titleColor: color) {
            close()
            // Let the popover finish closing before a modal dialog opens.
            DispatchQueue.main.async(execute: action)
        }
    }
}

/// Compact buttons under the tree header, acting on the root folder.
struct FileTreeRootActions: View {
    let root: URL
    @AppStorage(FileTreePreferences.showHiddenKey) private var showHidden = true

    var body: some View {
        HStack(spacing: 2) {
            button("doc.badge.plus", "New file") { FileOperations.newFile(in: root) }
            button("folder.badge.plus", "New folder") { FileOperations.newFolder(in: root) }
            button("doc.on.clipboard", "Paste into this folder") { FileOperations.paste(into: root) }
            Spacer(minLength: 0)
            button(showHidden ? "eye" : "eye.slash", showHidden ? "Hide hidden files" : "Show hidden files") {
                showHidden.toggle()
            }
        }
        .padding(.top, 2)
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        HoverableIconButton(systemName: symbol, fontSize: 10.5, size: 22, help: help, action: action)
    }
}

extension View {
    /// Accepts files dragged from Finder (copied) or from the tree itself
    /// (moved, when the source is inside the same root — like Finder on one volume).
    func fileTreeDropTarget(directory: URL?, root: URL?) -> some View {
        modifier(FileTreeDropModifier(directory: directory, root: root))
    }
}

private struct FileTreeDropModifier: ViewModifier {
    let directory: URL?
    let root: URL?
    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if directory == nil {
            content
        } else {
            target(content)
        }
    }

    private func target(_ content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6).stroke(Theme.chromeForeground.opacity(0.35), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let directory else { return false }
                Task { @MainActor in
                    let urls = await Self.loadURLs(providers)
                    guard !urls.isEmpty else { return }
                    FileTreeDrop.perform(urls, into: directory, root: root)
                }
                return true
            }
    }

    private static func loadURLs(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await withCheckedContinuation({ (cont: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
            }), url.isFileURL {
                urls.append(url)
            }
        }
        return urls
    }
}

enum FileTreeDrop {
    /// Move when every source already lives under the tree's root, else copy.
    static func mode(for sources: [URL], root: URL?) -> FileOperations.PasteMode {
        guard let root = root?.standardizedFileURL.path else { return .copy }
        let inside = sources.allSatisfy { $0.standardizedFileURL.path.hasPrefix(root + "/") }
        return inside ? .move : .copy
    }

    @MainActor
    static func perform(_ sources: [URL], into directory: URL, root: URL?) {
        let mode = mode(for: sources, root: root)
        // Dropping an item onto its own folder is a no-op, not a duplicate.
        let real = FileOperations.realPath(directory)
        let moving = sources.filter { FileOperations.realPath($0.deletingLastPathComponent()) != real }
        guard !moving.isEmpty else { return }
        Task { @MainActor in
            let result = await FileOperations.transferInBackground(moving, into: directory, mode: mode)
            FileOperations.report(result.failures)
        }
    }
}
