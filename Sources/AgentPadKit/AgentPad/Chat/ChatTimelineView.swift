import AppKit
import SwiftUI

private struct ChatTimelineFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, rhs in rhs }) }
}

/// Shared geometry and keyboard behavior; channel and each thread keep separate
/// positions in the tab model. No network or read marks come from row appearance.
struct ChatTimelineView: View {
    let model: ChatChannelModel
    let root: String?
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let me: String
    let archived: Bool
    let ownerModel: ChatChannelOwnerModel?
    @State private var box = WindowBox()
    @State private var coordinate = UUID()
    @State private var selectedID: String?
    @State private var loadingAnchor: String?
    @State private var nativeViewport = ChatScrollViewport()
    @State private var started = false
    @State private var visibleIDs = Set<String>()
    @FocusState private var focused: Bool
    private let bottomID = "chat-timeline-bottom"

    private var messages: [ChatMessage] { model.conversationMessages(root: root) }
    private var position: ChatScrollPosition { model.positions[root ?? ""] ?? ChatScrollPosition() }
    private var place: String { root.map { "t:\($0)" } ?? "c:\(model.channel)" }
    private var rows: [ChatFeedLayout.Row] { ChatFeedLayout.rows(messages, unreadID: root == nil ? model.feed.unreadID : model.threadUnreadID) }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if root == nil && model.feed.earlierUnread {
                            Text("There are earlier unread messages").font(Theme.display(11)).foregroundStyle(ChatAppearance.attention)
                                .frame(maxWidth: .infinity).padding(8)
                        }
                        if root == nil ? model.feed.hasOlder : model.threadHasEarlier {
                            Button(root == nil ? "Load earlier messages" : "Earlier replies") {
                                loadingAnchor = position.anchor ?? messages.first?.id
                                nativeViewport.stopFollowing()
                                if root == nil { model.loadOlder() } else { model.earlierReplies() }
                            }.buttonStyle(.link).font(Theme.display(11)).frame(maxWidth: .infinity).padding(8)
                        }
                        if messages.isEmpty {
                            Text(root == nil ? "No messages yet" : "Loading thread…")
                                .font(Theme.display(13)).foregroundStyle(ChatAppearance.secondary).frame(maxWidth: .infinity).padding(24)
                        }
                        ForEach(rows) { row in
                            VStack(spacing: 0) {
                                if let date = row.date { dateDivider(date) }
                                if row.startsUnread { unreadDivider }
                                if let root, row.message.threadRootId == root,
                                   row.id == messages.first(where: { $0.threadRootId == root })?.id {
                                    HStack {
                                        Text((model.b1?.supports("chat.thread_summary") == true ? model.b1?.state.metadata[root]?.threadSummary?.label : nil)
                                             ?? ChatReplySummary(messages: messages.filter { $0.threadRootId == root }, complete: !model.threadHasEarlier).label)
                                        Rectangle().fill(Theme.chromeHairline).frame(height: 1)
                                    }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(18)
                                }
                                ChatMessageRow(model: model, message: row.message, members: members, mentionable: mentionable, me: me,
                                               archived: archived, replies: model.feed.replies[row.id] ?? 0,
                                               requests: root == nil ? model.feed.requests[row.id] ?? 0 : 0, inThread: root != nil,
                                               startsGroup: row.startsGroup, selected: selectedID == row.id || model.revealMessageID == row.id)
                            }
                            .id(row.id)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: ChatTimelineFrames.self, value: [row.id: geometry.frame(in: .named(coordinate))])
                            })
                        }
                        if root != nil {
                            // UX1 requests already have their one card under the source.
                            // Older F5 requests without a source still need their details.
                            ForEach(model.threadRequests.filter { card in !model.sourceStatuses.contains { $0.id == card.requestId } }) { card in
                                ChatRequestCardRow(card: card, members: members, ownerModel: ownerModel).padding(.horizontal, 18)
                            }
                        }
                        Color.clear.frame(height: 20).id(bottomID)
                    }
                    .padding(.top, 16)
                    .background(ChatScrollAccess(viewport: nativeViewport) { bottom in
                        guard started else { return }
                        var state = position
                        state.measured(bottom: bottom, anchor: state.anchor)
                        if state != position { model.positions[root ?? ""] = state }
                        box.atBottom = bottom
                        readIfLooking()
                    })
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ChatTimelineFrames.self, value: [bottomID: geometry.frame(in: .named(coordinate))])
                    })
                }
                .coordinateSpace(name: coordinate)
                .focusable().focused($focused)
                .accessibilityLabel(root == nil ? "Channel messages" : "Thread messages")
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? ChatAppearance.accent : .clear, lineWidth: 2))
                .onChange(of: model.focusRequest, initial: true) { _, request in
                    if request?.area == (root == nil ? .feed : .thread) { focused = true }
                }
                .onKeyPress(.downArrow) { move(1, proxy: proxy); return .handled }
                .onKeyPress(.upArrow) { move(-1, proxy: proxy); return .handled }
                .onKeyPress(.escape) {
                    model.dismissTransient() ? .handled : .ignored
                }
                .onPreferenceChange(ChatTimelineFrames.self) { frames in
                    guard started else { return }
                    let bottom = nativeViewport.atBottom
                    let visible = frames.filter { $0.key != bottomID && $0.value.maxY > 0 && $0.value.minY < viewport.size.height }
                    visibleIDs = Set(visible.keys)
                    let anchor = visible.min { $0.value.minY < $1.value.minY }?.key
                    var state = position
                    state.measured(bottom: bottom, anchor: anchor)
                    if state != position { model.positions[root ?? ""] = state }
                    box.atBottom = bottom
                    readIfLooking()
                }
                .onChange(of: messages) { old, new in
                    var state = position
                    let follow = state.update(new, me: me) || nativeViewport.following
                    model.positions[root ?? ""] = state
                    if let target = model.revealMessageID, new.contains(where: { $0.id == target }) {
                        nativeViewport.stopFollowing()
                        if !old.contains(where: { $0.id == target }) { proxy.scrollTo(target, anchor: .center) }
                    } else if let loadingAnchor, new.first?.id != old.first?.id {
                        proxy.scrollTo(loadingAnchor, anchor: .top)
                        self.loadingAnchor = nil
                    } else if follow { nativeViewport.jumpToBottom() }
                    readIfLooking()
                }
                .onChange(of: model.revealMessageID) { _, target in
                    if let target, messages.contains(where: { $0.id == target }) {
                        nativeViewport.stopFollowing(); proxy.scrollTo(target, anchor: .center); selectedID = target
                    }
                }
                .onChange(of: model.editing?.messageId) { _, target in
                    if let target, model.editing?.root == root { nativeViewport.stopFollowing(); proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: model.focusedMessageID, initial: true) { _, target in
                    if let target, messages.contains(where: { $0.id == target }) {
                        selectedID = target
                        if root != nil || (model.feed.replySummaries[target]?.count ?? 0) == 0 { focused = true }
                        if !visibleIDs.contains(target) { nativeViewport.stopFollowing(); proxy.scrollTo(target, anchor: .center) }
                    }
                }
                .onChange(of: model.readingPositionRestored) { _, _ in
                    if position.atBottom { nativeViewport.jumpToBottom() }
                    else if let anchor = position.anchor { nativeViewport.stopFollowing(); proxy.scrollTo(anchor, anchor: .top) }
                }
                .onAppear {
                    ChatNotifications.show(place, view: box.id) { [box, weak model] in box.shown && box.atBottom && model?.searching == false && model?.hasNavigationReturn == false }
                    var state = position
                    let follow = state.update(messages, me: me)
                    model.positions[root ?? ""] = state
                    if let target = model.revealMessageID, messages.contains(where: { $0.id == target }) { nativeViewport.stopFollowing(); proxy.scrollTo(target, anchor: .center) }
                    else if follow { nativeViewport.jumpToBottom() }
                    else if let anchor = state.anchor { nativeViewport.stopFollowing(); proxy.scrollTo(anchor, anchor: .top) }
                    started = true
                    nativeViewport.measure()
                }
                .overlay(alignment: .bottom) {
                    if !position.atBottom && position.initialized {
                        Button {
                            model.finishNavigation()
                            nativeViewport.jumpToBottom()
                        } label: {
                            Label(position.unseen.isEmpty ? "Jump to latest" : "New messages · \(position.unseen.count)", systemImage: "arrow.down")
                                .font(Theme.display(11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                        }.buttonStyle(.plain).foregroundStyle(ChatAppearance.surface)
                            .background(ChatAppearance.accent, in: Capsule()).padding(.bottom, 8)
                    }
                }
            }
        }
        .background(WindowReader(box: box, visibilityChanged: { visible in
            if visible { model.beginReading(root: root); readIfLooking() }
            else { model.endReading(root: root) }
        }))
        .onDisappear { started = false; model.endReading(root: root); ChatNotifications.hide(place, view: box.id) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readIfLooking() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in readIfLooking() }
    }

    private func move(_ direction: Int, proxy: ScrollViewProxy) {
        let ids = rows.map(\.id)
        selectedID = ChatFeedLayout.selection(moving: direction, in: ids, from: selectedID)
        nativeViewport.stopFollowing()
        if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
    }

    private func readIfLooking() {
        guard started, let view = box.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        model.beginReading(root: root)
        model.readIfLooking(root: root, appActive: ChatNotifications.appActive(), shown: box.shown, atBottom: box.atBottom)
    }

    private func dateDivider(_ date: Date) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            Text((Calendar.current.isDateInToday(date) ? "Today, " : "") + date.formatted(date: .abbreviated, time: .omitted))
                .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(Theme.chromeHairline))
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
        }.padding(.horizontal, root == nil ? 24 : 18).padding(.vertical, 8)
    }

    private var unreadDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(ChatAppearance.attention.opacity(0.45)).frame(width: 32, height: 1)
            Text("New messages").font(Theme.display(10, weight: .medium))
            Rectangle().fill(ChatAppearance.attention.opacity(0.45)).frame(height: 1)
            Button("Mark as read") { model.markConversationRead(root: root) }
                .buttonStyle(.plain).font(Theme.display(10))
        }.foregroundStyle(ChatAppearance.attention).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
    }
}

struct ChatLocalSearch: View {
    let model: ChatChannelModel
    @State private var query = ""
    @FocusState private var focused: Bool
    private var results: [ChatMessage] { query.isEmpty ? [] : model.searchMessages.filter { $0.text.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search loaded history", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                ChatIconButton(title: "Close search", symbol: "xmark") { model.returnFromNavigation(); model.setSearching(false) }
            }
            HStack {
                Text("Loaded history only · \(results.count) matches").foregroundStyle(ChatAppearance.secondary)
                Spacer()
                if model.hasNavigationReturn { Button("Back to reading") { model.returnFromNavigation() }.buttonStyle(.link) }
            }.font(Theme.display(10))
            if !query.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(results) { message in
                            Button { model.navigate(to: message) } label: {
                                VStack(alignment: .leading) {
                                    Text(message.text).lineLimit(2)
                                    if message.threadRootId != nil { Text("In thread").foregroundStyle(ChatAppearance.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }.buttonStyle(.plain)
                        }
                        if results.isEmpty { Text("No matches in loaded history").foregroundStyle(ChatAppearance.secondary) }
                    }
                }.frame(maxHeight: 150).font(Theme.display(12))
            }
        }.padding(12).background(Theme.chromeHover).onAppear { focused = true }
            .onExitCommand { model.returnFromNavigation(); model.setSearching(false) }
    }
}
