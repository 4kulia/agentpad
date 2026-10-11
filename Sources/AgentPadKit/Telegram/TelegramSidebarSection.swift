import AgentPadTelegram
import SwiftUI

struct TelegramSidebarSection: View {
    let store: WorkspaceStore
    @Bindable var model: TelegramChatsModel
    @State private var interactionID = UUID()
    @State private var hovering = false
    @FocusState private var focused: TelegramChatID?
    private enum Control { case settings, more, less, find }
    @FocusState private var focusedControl: Control?

    private var projection: AttentionSidebarModel.Projection { AttentionSidebarModel.shared.projection }
    private var snapshot: TelegramChatSnapshot { projection.telegram }
    var body: some View {
        if model.connected {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Telegram").font(Theme.display(11, weight: .semibold))
                    Spacer()
                    Text("\(snapshot.foundCount)").font(Theme.display(10)).monospacedDigit()
                    Button { SupportTabs.shared.settings(.telegram) } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).accessibilityLabel("Telegram settings").focused($focusedControl, equals: .settings)
                }.foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 9).padding(.bottom, 4)
                if let status = model.status {
                    Text(status).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 9)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<((snapshot.visibleCount + 49) / 50), id: \.self) { page in
                        rows(offset: page * 50)
                    }
                }
                if snapshot.overflow > 0 {
                    Button { Task { await model.expand() } } label: {
                        Label("\(snapshot.overflow) more", systemImage: "chevron.down")
                    }.buttonStyle(.plain).font(Theme.display(11)).padding(9)
                        .focused($focusedControl, equals: .more)
                        .help("Show up to 10 more · \(snapshot.overflow) remaining · \(snapshot.attention.overflowChatCount) with addressed messages\(snapshot.state == .complete ? "" : " · found so far")")
                        .accessibilityLabel("Show \(min(10, snapshot.overflow)) more Telegram conversations; \(snapshot.overflow) remaining")
                }
                if snapshot.expanded {
                    Button("Show less") { Task { await model.expand(showLess: true) } }
                        .buttonStyle(.plain).font(Theme.display(11)).padding(9).help("Return to the default 8-row limit")
                        .focused($focusedControl, equals: .less)
                }
                if snapshot.foundCount == 0 {
                    Button("Find a chat  ⌘P") { store.search.source = .telegram; store.search.begin() }
                        .buttonStyle(.plain).font(Theme.display(10)).padding(.horizontal, 9)
                        .focused($focusedControl, equals: .find)
                }
            }.padding(.top, 20)
                .onHover { hovering = $0; updateHold() }
                .onChange(of: focused) { _, _ in updateHold() }
                .onChange(of: focusedControl) { _, _ in updateHold() }
                .onChange(of: snapshot.firstRows.map(\.id)) { old, new in
                    if let focused, let position = old.firstIndex(of: focused), !new.contains(focused) {
                        self.focused = new.isEmpty ? nil : new[min(position, new.count - 1)]
                        if new.isEmpty { focusedControl = snapshot.overflow > 0 ? .more : .find }
                    }
                }
                .onChange(of: store.panelIsPresented) { _, presented in if !presented { releaseHold() } }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                    if (notification.object as? NSWindow) === store.active?.activeSession?.engine.view.window { releaseHold() }
                }
                .onDisappear { let id = interactionID; Task { await model.hold(false, owner: id) } }
                .accessibilityElement(children: .contain).accessibilityLabel("Telegram conversations")
        }
    }
    @ViewBuilder private func rows(offset: Int) -> some View {
        Group {
            if let rows = projection.telegramPages[offset] {
                ForEach(rows) { row in
                    Button { TelegramTabs.open(row, from: store) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: row.symbol).frame(width: 23)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).font(Theme.display(12)).lineLimit(1)
                                Text(row.shelfCaption).font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if row.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(ChatAppearance.secondary) }
                        }.frame(height: 39).padding(.horizontal, 9).contentShape(Rectangle())
                            .background(store.active?.activeSession?.toolRoute == .telegram(row.id) ? Theme.chromeSelection : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).focused($focused, equals: row.id).chatFocusRing()
                        .foregroundStyle(Theme.chromeForeground)
                        .help("\(row.title) · \(row.displayKind)\(row.inArchive ? " · Archive" : "") · \(row.unreadCount) unread messages")
                        // Ordinary unread is metadata, never an Attention badge.
                        .accessibilityLabel("\(row.title), \(row.shelfCaption), \(row.unreadCount) unread messages")
                        .contextMenu {
                            Button(row.pinned ? "Unpin" : "Pin here") { Task { await model.mode(row, row.pinned ? .auto : .pinned) } }
                            Button("Don't show") { Task { await model.mode(row, .hidden) } }
                        }
                }
            } else {
                Color.clear.frame(height: CGFloat(min(50, snapshot.visibleCount - offset)) * 39)
                    .accessibilityLabel("Loading Telegram chats")
            }
        }.task(id: snapshot.revision) { await model.loadPage(offset) }
    }
    private func updateHold() {
        let held = hovering || focused != nil || focusedControl != nil, id = interactionID
        Task { await model.hold(held, owner: id) }
    }
    private func releaseHold() {
        hovering = false; focused = nil; focusedControl = nil
        let id = interactionID; Task { await model.hold(false, owner: id) }
    }
}
