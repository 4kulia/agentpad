import AgentPadTelegram
import AppKit
import SwiftUI

struct SidebarUnreadBadge: View {
    var count: Int
    var unmuted = true
    var provisional = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let color = unmuted ? ChatAppearance.accent : ChatAppearance.secondary
        Text(count > 999 ? "999+" : "\(count)").font(Theme.display(9, weight: .semibold)).monospacedDigit()
            .foregroundStyle(color).padding(.horizontal, 4).padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(contrast == .increased ? color : .clear))
            .accessibilityLabel("\(provisional ? "At least " : "")\(count) unread")
    }
}

struct SidebarAttentionDot: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Circle().fill(ChatAppearance.attention).frame(width: 6, height: 6)
            .overlay(Circle().strokeBorder(contrast == .increased ? Theme.chromeForeground : .clear))
            .accessibilityLabel("In Needs attention")
    }
}

struct SidebarFolderTag: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    static func customColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 181/255, green: 161/255, blue: 221/255) : Color(red: 120/255, green: 88/255, blue: 173/255)
    }
    var body: some View {
        let color = text == "TG" ? ChatAppearance.accent : Self.customColor(scheme)
        Text(text).font(Theme.display(8)).foregroundStyle(color).padding(.horizontal, 3).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.3)))
    }
}

struct SidebarFolderEntryView<Content: View, Actions: View>: View {
    var entry: SidebarFolderEntry
    var expanded: Bool
    var sticky: Bool
    var selected = false
    var toggle: () -> Void
    var drop: @MainActor @Sendable (SidebarDragRegistry.Value) -> Void = { _ in }
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false
    var body: some View {
        Group {
            if sticky {
                Section { content() } header: { header }
            } else {
                VStack(alignment: .leading, spacing: 0) { header; content() }
            }
        }
    }
    private var header: some View {
        HStack(spacing: 3) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text(entry.title).font(Theme.display(10, weight: .semibold)).lineLimit(1)
                    if let tag = entry.tag { SidebarFolderTag(text: tag) }
                    if entry.foreign > 0 {
                        Text("+\(entry.foreign) from another team").font(Theme.display(9)).lineLimit(1)
                            .help("+\(entry.foreign) from another team")
                    }
                    Spacer(minLength: 2)
                    if entry.badgeCount > 0 { SidebarUnreadBadge(count: entry.badgeCount, unmuted: entry.unmuted > 0, provisional: entry.provisional) }
                    if entry.attention { SidebarAttentionDot() }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(entry.accessibilityLabel)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Left and right arrows collapse or expand this folder")
            Menu(content: actions) { Image(systemName: "ellipsis").font(.system(size: 10)).frame(width: 20, height: 25) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hovering || selected ? 1 : 0).accessibilityLabel("Actions for \(entry.title)")
        }.foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 4).frame(height: 25)
            .background(Theme.chromeBackground)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? ChatAppearance.accent : .clear, lineWidth: 2))
            .padding(.top, 9).id(ChatSidebarRowID.entry(entry.id))
            .help(entry.title).onHover { hovering = $0 }
            .sidebarContextMenu(selected: selected, content: actions)
            .onDrop(of: [SidebarDragRegistry.itemType], isTargeted: nil) { providers in
                guard case .custom = entry.kind else { return false }
                return SidebarDragRegistry.receive(providers, action: drop)
            }
    }
}

/// Only an opaque token is offered, with NSItemProvider's own-process visibility.
/// External applications cannot load it, and no general pasteboard is written.
@MainActor enum SidebarDragRegistry {
    static let itemType = "app.agentpad.private.sidebar-item"
    static let entryType = "app.agentpad.private.sidebar-entry"
    struct Value: Sendable { var item: SidebarItemReference?; var entry: String?; var binding: TelegramProfileBinding? }
    private static var values: [String:(Date,Value)] = [:]
    static func provider(_ value: Value) -> NSItemProvider {
        values = values.filter { Date().timeIntervalSince($0.value.0) < 120 }
        let token = UUID().uuidString
        values[token] = (Date(), value)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: value.item == nil ? entryType : itemType, visibility: .ownProcess) { completion in
            completion(Data(token.utf8), nil); return nil
        }
        return provider
    }
    static func receive(_ providers: [NSItemProvider], entry: Bool = false, action: @escaping @MainActor @Sendable (Value) -> Void) -> Bool {
        let type = entry ? entryType : itemType
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let token = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let value = values[token], Date().timeIntervalSince(value.0) < 120 else { return }
                action(value.1)
            }
        }
        return true
    }
}

extension View {
    func sidebarContextMenu<Actions: View>(selected: Bool, @ViewBuilder content: @escaping () -> Actions) -> some View {
        modifier(SidebarContextMenu(selected: selected, actions: content))
    }
}

private struct SidebarContextMenu<Actions: View>: ViewModifier {
    var selected: Bool
    @ViewBuilder var actions: () -> Actions
    @State private var presented = false
    func body(content: Content) -> some View {
        content.contextMenu(menuItems: actions)
            .background(SidebarMenuKey(enabled: selected) { presented = true }.frame(width: 0, height: 0))
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 8, content: actions).buttonStyle(.plain).padding(12)
                    .simultaneousGesture(TapGesture().onEnded { presented = false })
            }
            .onChange(of: SidebarFolderActions.shared.request?.id) { _, request in
                if request != nil { presented = false }
            }
    }
}

private struct SidebarMenuKey: NSViewRepresentable {
    var enabled: Bool
    var action: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.enabled = enabled; view.action = action }
    final class KeyView: NSView {
        var enabled = false
        var action: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, event.window === self.window else { return event }
                let modifiers = event.modifierFlags.intersection([.command,.option,.control,.shift])
                guard (event.keyCode == 109 && modifiers == .shift) || (event.keyCode == 110 && modifiers.isEmpty) else { return event }
                self.action?(); return nil
            }
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
