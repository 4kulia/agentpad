import AppKit
import SwiftUI

/// Explicit sections keep headers out of the variable-length ForEach content
/// that SwiftUI can reuse when a query changes from agents to people.
struct ChatMentionSection: Equatable, Identifiable {
    enum Kind: String, CaseIterable { case people = "People", agents = "Agents" }
    struct Row: Equatable, Identifiable {
        let candidate: ChatMentionCandidate
        let index: Int
        var id: String { candidate.id }
    }
    let id: Kind
    let rows: [Row]
    var title: String { id.rawValue }

    static func grouped(_ candidates: [ChatMentionCandidate]) -> [Self] {
        var index = 0
        return Kind.allCases.compactMap { kind in
            let members = candidates.filter { ($0.agentId == nil) == (kind == .people) }
            guard !members.isEmpty else { return nil }
            let rows = members.map { candidate in
                defer { index += 1 }
                return Row(candidate: candidate, index: index)
            }
            return Self(id: kind, rows: rows)
        }
    }
}

struct ChatMentionMenu: View {
    let content: ChatMentionPopup.Content

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                Text(content.title).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                    .padding(.horizontal, 8).frame(height: 28)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(content.sections) { section in
                            VStack(spacing: 0) {
                                Text(section.title).font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).frame(height: 24)
                                ForEach(section.rows) { row in
                                    Button { content.choose(row.candidate) } label: {
                                        HStack(spacing: 8) {
                                            ContactAvatar(stableID: row.candidate.agentId ?? row.candidate.id,
                                                          name: row.candidate.label, kind: row.candidate.agentId == nil ? .person : .agent, size: 28)
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 5) {
                                                    Text(row.candidate.label).lineLimit(1)
                                                    if row.candidate.agentId != nil { ChatBotBadge() }
                                                }
                                                Text("@\(row.candidate.address)").font(Theme.display(10))
                                                    .foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                            if row.candidate.addToChannel {
                                                Text("Add to channel").font(Theme.display(9)).lineLimit(2)
                                            }
                                        }.padding(.horizontal, 8).frame(height: 48)
                                            .contentShape(Rectangle())
                                            .background(row.index == content.selected ? ChatAppearance.accent.opacity(0.14) : .clear,
                                                        in: RoundedRectangle(cornerRadius: 5))
                                    }.buttonStyle(.plain).id(row.index).help("@\(row.candidate.address)")
                                        .accessibilityLabel(row.candidate.accessibilityName)
                                        .accessibilityValue(row.index == content.selected ? "Selected" : "")
                                }
                            }
                        }
                    }
                }
            }.padding(5).font(Theme.display(12)).foregroundStyle(Theme.chromeForeground)
                .background(ChatAppearance.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ChatAppearance.border))
                .onChange(of: content.selected) { _, value in proxy.scrollTo(value) }
        }
    }
}

/// An editor-owned child window: neither SwiftUI clipping nor the composer's
/// focus-ring overlay can cover it. It never takes keyboard focus from NSTextView.
@MainActor
final class ChatMentionPopup: NSObject {
    struct Content {
        var sections: [ChatMentionSection]
        var selected: Int
        var title: String
        var choose: (ChatMentionCandidate) -> Void
        var height: CGFloat { 38 + min(300, CGFloat(sections.reduce(0) { $0 + $1.rows.count }) * 48 + CGFloat(sections.count) * 24) }
    }
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private weak var editor: ChatMentionEditor.Editor?
    private var content: Content?
    private(set) var panel: Panel?
    private var host: NSHostingView<AnyView>?
    private var refreshScheduled = false

    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(to editor: ChatMentionEditor.Editor) {
        detach()
        self.editor = editor
        guard let window = editor.window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
            center.addObserver(self, selector: #selector(geometryChanged), name: name, object: window)
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            center.addObserver(self, selector: #selector(windowHidden), name: name, object: window)
        }
        if let clip = editor.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(geometryChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
        scheduleRefresh()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        hide()
        editor = nil
    }

    func update(_ content: Content?) {
        self.content = content
        // updateNSView precedes final layout, so calculate the caret afterwards.
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    @objc private func geometryChanged(_ notification: Notification) { scheduleRefresh() }
    @objc private func windowHidden(_ notification: Notification) { hide() }

    func hide() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    func refresh() {
        guard let editor, let window = editor.window, window.isVisible, window.isKeyWindow,
              window.firstResponder === editor, !editor.isHiddenOrHasHiddenAncestor, !editor.hasMarkedText(),
              let scroll = editor.enclosingScrollView, let windowContent = window.contentView,
              let content, !content.sections.isEmpty else { hide(); return }
        let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let viewport = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        let windowBounds = window.convertToScreen(windowContent.convert(windowContent.bounds, to: nil))
        let bounds = windowBounds.intersection(window.screen?.visibleFrame ?? windowBounds).insetBy(dx: 6, dy: 6)
        guard bounds.width > 0, bounds.height > 0, viewport.intersects(bounds) else { hide(); return }
        let frame = Self.frame(caret: caret, viewport: viewport, bounds: bounds, height: content.height)
        if panel == nil {
            let made = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            made.isReleasedWhenClosed = false
            made.isOpaque = false; made.backgroundColor = .clear; made.hasShadow = true
            made.hidesOnDeactivate = true; made.animationBehavior = .none
            made.collectionBehavior = [.fullScreenAuxiliary]
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            made.contentView = host
            self.host = host; panel = made
        }
        guard let panel, let host else { return }
        host.rootView = AnyView(ChatMentionMenu(content: content)
            .frame(width: frame.width, height: frame.height).preferredColorScheme(Theme.chromeColorScheme))
        panel.appearance = Theme.windowAppearance
        panel.setFrame(frame, display: true)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    /// All inputs are screen coordinates (origin at the bottom left).
    static func frame(caret: CGRect, viewport: CGRect, bounds: CGRect, height: CGFloat) -> CGRect {
        let width = min(312, viewport.width, bounds.width)
        let above = max(0, bounds.maxY - caret.maxY - 4)
        let below = max(0, caret.minY - 4 - bounds.minY)
        let opensAbove = above >= height || above >= below
        let actualHeight = min(height, opensAbove ? above : below, bounds.height)
        let y = opensAbove ? caret.maxY + 4 : caret.minY - 4 - actualHeight
        return CGRect(x: min(max(caret.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(y, bounds.minY), bounds.maxY - actualHeight), width: width, height: actualHeight)
    }
}
