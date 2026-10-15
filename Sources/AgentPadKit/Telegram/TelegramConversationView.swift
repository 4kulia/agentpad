import AgentPadTelegram
import AppKit
import SwiftUI

struct TelegramConversationView: View {
    @Bindable var state: TabState
    let id: TelegramChatID
    var chats: TelegramChatsModel
    var applicationInteractive: () -> Bool
    @State var model: TelegramConversationModel
    @State var showHiddenGeneral = false
    @State var pane = UUID()
    @State private var box = WindowBox()
    @State private var coordinate = UUID()
    @State private var viewport = ChatScrollViewport()
    @State private var frames: [String: CGRect] = [:]
    @State private var sponsoredGeometry = TelegramSponsoredGeometry()
    @State private var feedViewport = CGRect.zero
    @State private var overlayFrames: [CGRect] = []
    @State private var visibilityUpdates = TelegramFeedVisibilityUpdates()
    @State private var sponsoredRequests = Set<TelegramSponsoredRef>()
    @State private var sponsoredActive = false
    @State private var menuTracking = false
    @State private var anchor: String?
    @State private var loadingAnchor: String?
    @State private var anchorOffset: CGFloat = 0
    @State private var restoringAnchor: String?
    @State private var atBottom = true
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editor = ChatEditorControl()
    @State private var editorHeight: CGFloat = 64
    init(state: TabState, id: TelegramChatID, chats: TelegramChatsModel = TelegramService.chats, applicationInteractive: @escaping () -> Bool = { TelegramService.isInteractive }) {
        self.state = state; self.id = id; self.chats = chats; self.applicationInteractive = applicationInteractive
        let model = state.telegramModel.flatMap { $0.id == id ? $0 : nil } ?? TelegramService.conversations.model(id)
        state.telegramModel = model
        _model = State(initialValue: model)
    }
    private var connectedAccount: Bool {
        chats.snapshot.account?.account == id.account && chats.snapshot.account?.environment == id.environment
    }
    private var presentation: ConversationSnapshot { model.presentation }
    private var canAddToFolder: Bool { state.telegramRow?.kind.eligible == true && (id.topic == nil || id.topic?.forumID != nil) }
    private var botDialog: TelegramBotDialog? {
        model.botDialog.flatMap { $0.pane == nil || $0.pane == pane ? $0 : nil }
    }
    private var sponsoredDialog: TelegramSponsoredDialog? { model.sponsoredDialog.flatMap { $0.pane == pane ? $0 : nil } }
    private var jumpToLatestVisible: Bool { !atBottom || model.snapshot.hasNewer }
    private var allowsKeyboardAction: Bool {
        connectedAccount && box.view.map {
            NavigationPresentationGate.allowsAcknowledgement($0, appActive: applicationInteractive())
        } == true
    }
    var body: some View {
        VStack(spacing: 0) {
            header.addToFolderAnchor(.telegram(id.chat),
                windowID: TabRouter.shared.stores().first { $0.allSessions.contains { $0.tabState === state } }?.windowID,
                enabled: !model.snapshot.capabilities.canSend && allowsKeyboardAction)
            if !connectedAccount {
                unavailable("Connect this Telegram account to open this conversation.")
                Button("Telegram settings") { SupportTabs.shared.settings(.telegram) }.padding()
            } else if model.snapshot.capabilities.canRead {
                if model.snapshot.isTopicList {
                    if model.snapshot.kind == .bot { botControls }
                    topicList
                }
                else {
                    if id.topic != nil { topicBar }
                    if model.snapshot.kind == .bot, !model.snapshot.bot.description.isEmpty {
                        Text(model.snapshot.bot.description).font(Theme.display(12)).foregroundStyle(.secondary)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    timeline
                }
                if let problem = model.problem ?? model.snapshot.error {
                    HStack { Text(problem); Spacer(); Button(model.snapshot.isTopicList ? "Reload topics" : "Retry history") { model.load(latest: true) } }
                        .font(Theme.display(11)).foregroundStyle(ChatAppearance.failure).padding(10)
                }
                if let notice = model.notice { Text(notice).font(Theme.display(11)).foregroundStyle(.secondary).padding(8) }
                TelegramReadNoticeView(model: chats)
                if !model.snapshot.operations.isEmpty { operations }
                if model.snapshot.capabilities.canSend {
                    botControls
                    composer.addToFolderAnchor(.telegram(id.chat),
                        windowID: TabRouter.shared.stores().first { $0.allSessions.contains { $0.tabState === state } }?.windowID,
                        enabled: allowsKeyboardAction)
                }
                else {
                    VStack(spacing: 6) {
                        Text(model.snapshot.capabilities.reason)
                        if model.snapshot.kind == .channel, let url = telegramURL { Link("Open in Telegram", destination: url) }
                    }.font(Theme.display(12)).padding(16)
                }
            } else {
                unavailable(model.snapshot.error ?? model.snapshot.capabilities.reason)
                if [.unknown, .forum, .bot, .channel].contains(model.snapshot.kind) || id.topic != nil { Button("Retry") { model.load(latest: true) }.padding() }
            }
        }
        .background(ChatAppearance.surface)
        .attentionPlace([.telegram(id.root, message: 0)])
        .background(WindowReader(box: box, didAttach: observe, visibilityChanged: { _ in observe() }))
        .task(id: chats.snapshot.account) {
            guard connectedAccount, let provider = chats.provider as? any TelegramConversationProvider else { return }
            await model.observe(pane: pane, provider: provider)
        }
        .task(id: chats.metadataRevision) {
            let binding = chats.snapshot.binding
            let row = await chats.row(id.root)
            guard !Task.isCancelled, chats.snapshot.binding == binding else { return }
            state.telegramRow = row
        }
        .onChange(of: model.snapshot.revision) { _, _ in
            if let topic = model.snapshot.topicInfo { state.telegramTopicTitle = topic.name }
            else if id.topic == nil { state.telegramTopicTitle = nil }
            observe()
        }
        .alert(botDialog?.title ?? "Telegram", isPresented: Binding(get: { botDialog != nil }, set: { if !$0, botDialog != nil { model.botDialog = nil } }), presenting: botDialog) { dialog in
            if dialog.url != nil { Button("Open") { model.confirmBotURL(dialog) } }
            Button(dialog.url == nil ? "OK" : "Cancel", role: .cancel) { model.botDialog = nil }
        } message: { dialog in Text(dialog.text) }
        .sheet(item: Binding(get: { sponsoredDialog }, set: { if $0 == nil, sponsoredDialog != nil { model.dismissSponsoredDialog() } })) { dialog in
            sponsoredDialogView(dialog)
        }
        .onChange(of: sponsoredDialog?.id) { _, _ in observe() }
        .onChange(of: botDialog?.id) { _, _ in observe() }
        .onChange(of: editor.focused) { _, focused in if !focused { model.typing(false, pane: pane) } }
        .onDisappear {
            visibilityUpdates.cancel()
            sponsoredActive = false
            model.typing(false, pane: pane)
            model.observe(.init(pane: pane, epoch: model.snapshot.epoch, active: false, shown: false, ordinaryIDs: []))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuTracking = true; observe() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuTracking = false; observe() }
        .onReceive(NotificationCenter.default.publisher(for: NavigationPresentationGate.didChange)) { _ in observe() }
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers == [.command, .shift], allowsKeyboardAction,
                  editor.view?.hasMarkedText() != true, NSApp.currentEvent.map({ $0.type == .keyDown && $0.isARepeat }) != true,
                  canAddToFolder else { return .ignored }
            model.addToFolder(chats: chats, windowID: TabRouter.shared.stores().first { $0.allSessions.contains { $0.tabState === state } }?.windowID); return .handled
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: state.telegramRow?.symbol ?? "paperplane").font(.system(size: 25)).foregroundStyle(ChatAppearance.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(connectedAccount ? model.snapshot.topicInfo?.name ?? state.telegramTopicTitle ?? state.telegramRow?.title ?? model.snapshot.title : "Telegram").font(Theme.display(15, weight: .semibold))
                Text(model.snapshot.presence.isEmpty ? "Telegram · \(state.telegramRow?.displayKind ?? "Chat")" : model.snapshot.presence)
                    .font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
            }
            Spacer()
            if connectedAccount, let row = state.telegramRow, canAddToFolder {
                Menu {
                    TelegramChatActions(row: row, model: chats, windowID: TabRouter.shared.stores().first { $0.allSessions.contains { $0.tabState === state } }?.windowID)
                    if row.attention != nil {
                        Button("Hide until next message") { Task { await chats.provider?.snoozeAttention(row.id, undo: false) } }
                    }
                    if row.snoozed {
                        Button("Undo hide until next message") { Task { await chats.provider?.snoozeAttention(row.id, undo: true) } }
                    }
                    Button(row.hidden ? "Restore" : "Don’t show") { Task { await chats.mode(row, row.hidden ? .auto : .hidden) } }
                    if let url = telegramURL { Link("Open in Telegram", destination: url) }
                    Menu("Download cache · \(model.snapshot.cacheLimitMiB) MiB") {
                        ForEach([128, 256, 512, 1024], id: \.self) { limit in Button("\(limit) MiB") { model.cacheLimit(limit) } }
                        Divider()
                        Button("Clear downloaded photos and documents") { model.clearCache() }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
        }.padding(16).overlay(alignment: .bottom) { Divider() }
    }
    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "paperplane").font(.largeTitle)
            Text(text).foregroundStyle(ChatAppearance.secondary).multilineTextAlignment(.center)
            if connectedAccount, model.snapshot.kind != .secret, let url = telegramURL { Link("Open in Telegram", destination: url) }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var telegramURL: URL? {
        let name = model.snapshot.username.isEmpty ? state.telegramRow?.username ?? "" : model.snapshot.username
        if !name.isEmpty, name.count <= 32, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
            return URL(string: "https://t.me/" + name)
        }
        // No fabricated chat/message link for private destinations. The app
        // fallback is explicit; message links use TDLib's checked resolver.
        return URL(string: "tg://")
    }
    private var timeline: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if presentation.hasOlder {
                            Button(model.snapshot.loading ? "Loading…" : "Load earlier messages") {
                                loadingAnchor = anchor ?? model.snapshot.messages.first?.id
                                anchorOffset = loadingAnchor.flatMap { frames[$0]?.minY } ?? 0
                                viewport.stopFollowing(); model.loadOlder()
                            }.buttonStyle(.link).disabled(model.snapshot.loading).frame(maxWidth: .infinity).padding(10)
                        }
                        if model.snapshot.messages.isEmpty { Text(model.snapshot.loading ? "Loading messages…" : "No messages yet").foregroundStyle(.secondary).padding(24) }
                        ForEach(presentation.rows) { row in
                            if case .sponsored(let ref) = row, let ad = model.snapshot.sponsored.messages.first(where: { $0.ref == ref }) {
                                TelegramSponsoredCard(ad: ad, coordinate: coordinate, active: sponsoredActive && sponsoredRequests.contains(ref),
                                    action: { sponsoredAction($0, ref: ref) }, info: { model.sponsoredInfo(ad, pane: pane, why: $0) }).disabled(model.sponsoredBusy).id(row.id)
                            } else if let message = model.snapshot.messages.first(where: { $0.id == row.id }) { messageRow(message).id(row.id) }
                        }
                        if model.snapshot.kind == .channel, !model.snapshot.hasNewer {
                            sponsoredStatus
                        }
                        Color.clear.frame(height: 16).id("bottom")
                    }
                    .background(ChatScrollAccess(viewport: viewport) { bottom in atBottom = bottom })
                }
                .onAppear {
                    feedViewport = CGRect(origin: .zero, size: geometry.size)
                    if let saved = model.scrollAnchor { viewport.stopFollowing(); proxy.scrollTo(saved, anchor: .top) }
                    observe()
                }
                .onPreferenceChange(ConversationFrames.self) { values in
                    if let restoringAnchor, let frame = values[restoringAnchor] {
                        self.restoringAnchor = nil
                        let delta = frame.minY - anchorOffset
                        viewport.preserveContentOffset(delta)
                        if abs(delta) > 0.5 { return }
                    }
                    frames = values
                    let rect = CGRect(origin: .zero, size: geometry.size)
                    feedViewport = rect
                    anchor = ConversationFrames.anchor(values, viewport: rect)
                    if let anchor { model.scrollAnchor = atBottom ? nil : anchor }
                    observe()
                }
                .onPreferenceChange(TelegramSponsoredFrames.self) { value in
                    sponsoredGeometry = value; feedViewport = CGRect(origin: .zero, size: geometry.size)
                    observe()
                }
                .onChange(of: geometry.size) { _, size in feedViewport = CGRect(origin: .zero, size: size); observe() }
                .onChange(of: model.requestedMessage) { _, target in
                    if let target, let row = model.snapshot.messages.first(where: { $0.messageID == target }) {
                        viewport.stopFollowing(); proxy.scrollTo(row.id, anchor: .center); model.requestedMessage = nil
                    }
                }
                .onChange(of: model.snapshot.messages) { old, new in
                    if let target = model.requestedMessage, let row = new.first(where: { $0.messageID == target }) {
                        viewport.stopFollowing(); proxy.scrollTo(row.id, anchor: .center); model.requestedMessage = nil
                        return
                    }
                    if let loadingAnchor, new.first?.id != old.first?.id {
                        restoringAnchor = loadingAnchor
                        proxy.scrollTo(loadingAnchor, anchor: .top); self.loadingAnchor = nil
                    } else if !viewport.following, let anchor, let frame = frames[anchor], new.contains(where: { $0.id == anchor }), old != new {
                        anchorOffset = frame.minY; restoringAnchor = anchor
                        proxy.scrollTo(anchor, anchor: .top)
                    } else if viewport.following { viewport.jumpToBottom() }
                }
                .onChange(of: model.snapshot.loading) { _, loading in
                    if !loading, let loadingAnchor {
                        restoringAnchor = loadingAnchor; proxy.scrollTo(loadingAnchor, anchor: .top)
                        self.loadingAnchor = nil
                    }
                }
                .overlay(alignment: .bottom) {
                    if jumpToLatestVisible {
                        Button("Jump to latest") {
                            if model.snapshot.hasNewer { model.load(latest: true) }
                            viewport.jumpToBottom(); proxy.scrollTo("bottom", anchor: .bottom)
                        }.buttonStyle(.borderedProminent)
                            .background(GeometryReader { measured in
                                Color.clear.preference(key: TelegramFeedOverlayFrames.self, value: [measured.frame(in: .named(coordinate))])
                            }).padding(10)
                    }
                }
                .coordinateSpace(name: coordinate)
                .onPreferenceChange(TelegramFeedOverlayFrames.self) { values in overlayFrames = values; observe() }
                .onChange(of: atBottom) { _, _ in observe() }
            }
        }
    }
    private func messageRow(_ message: TelegramMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(message.author.prefix(1))).font(Theme.display(12, weight: .semibold))
                .frame(width: 28, height: 28).background(Theme.chromeHover, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(message.author).font(Theme.display(12, weight: .semibold))
                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                    if message.edited { Text("edited").font(Theme.display(10)).foregroundStyle(.secondary) }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 5) {
                    if let reply = message.replyPreview { Text(reply).font(Theme.display(11)).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(ChatAppearance.accent).frame(width: 2) } }
                    if !message.text.isEmpty {
                        if message.protectedContent { Text(TelegramEntityRenderer.attributed(message)).font(Theme.display(13)) }
                        else { Text(TelegramEntityRenderer.attributed(message)).font(Theme.display(13)).textSelection(.enabled) }
                    }
                    if case .unsupported(let label) = message.content {
                        Text(label).font(Theme.display(12)).foregroundStyle(.secondary)
                        Button("Open in Telegram") { model.openMessageInTelegram(message.messageID) }.buttonStyle(.link).font(Theme.display(11))
                    }
                    if let file = message.attachment { attachment(file, message: message) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { measured in Color.clear.preference(key: ConversationFrames.self, value: [message.id: measured.frame(in: .named(coordinate))]) })
                HStack(spacing: 10) {
                    if model.snapshot.kind == .channel, let count = message.viewCount {
                        Label(count.formatted(), systemImage: "eye").font(Theme.display(10)).foregroundStyle(.secondary)
                    }
                    if message.outgoing { Text(delivery(message.delivery)).font(Theme.display(10)).foregroundStyle(.secondary) }
                    if model.snapshot.capabilities.canSend, message.messageID > 0 {
                        Button("Reply") { model.reply(to: message.id); editor.focus() }.buttonStyle(.link).font(Theme.display(10))
                    }
                    if case .failed = message.delivery, model.snapshot.capabilities.canSend {
                        Button("Retry") { model.retry(message.id) }.buttonStyle(.link).font(Theme.display(10)).disabled(!message.canRetry)
                    }
                }
                if let reason = message.retryReason { Text(reason).font(Theme.display(10)).foregroundStyle(.secondary) }
                if let keyboard = message.inlineKeyboard { botKeyboard(keyboard, reply: false) }
                if message.keyboardUnavailable {
                    Button("Keyboard unavailable · Open in Telegram") { model.openMessageInTelegram(message.messageID) }
                        .buttonStyle(.link).font(Theme.display(11))
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }
    private func attachment(_ file: TelegramFile, message: TelegramMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(file.name, systemImage: file.mime.hasPrefix("image/") ? "photo" : "doc.text")
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(Theme.display(10)).foregroundStyle(.secondary)
            if file.downloading || file.uploading {
                ProgressView(value: min(1, Double(file.downloading ? file.downloaded : file.uploaded) / Double(max(1, file.size))))
                if file.downloading { Button("Cancel download") { model.download(message, cancel: true) }.buttonStyle(.link) }
            }
            if message.protectedContent { Text("Protected content · Open in Telegram").font(Theme.display(10)) }
            else if file.complete {
                HStack { Button("Preview") { model.preview(message) }; Button("Save…") { model.save(message) } }.buttonStyle(.link)
            } else if !file.downloading { Button("Download") { model.download(message) }.buttonStyle(.link) }
        }.font(Theme.display(12)).padding(10).frame(maxWidth: 350, alignment: .leading).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 7))
    }
    private var operations: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.snapshot.operations) { operation in
                HStack {
                    Text("Send: " + operation.states.joined(separator: " · ")).lineLimit(2)
                    if operation.canRecover { Button("Restore draft") { model.recover(operation.id) }.disabled(!model.draft.isEmpty) }
                    if !operation.states.contains("pending") && !operation.states.contains("submitting") {
                        Button("Dismiss recovery") { model.discardRecovery(operation.id) }
                    }
                }
            }
        }.font(Theme.display(11)).padding(.horizontal, 16).padding(.vertical, 8)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reply = model.draft.replyTo {
                HStack {
                    Text("Reply: " + (model.snapshot.messages.first { $0.messageID == reply }.map { String($0.text.prefix(100)) } ?? "Message \(reply)" )).lineLimit(1)
                    Spacer(); Button("Cancel reply") { model.cancelReply() }
                }.font(Theme.display(11))
            }
            ForEach(model.draft.attachments) { file in
                HStack {
                    if let image = model.draftThumbnails[file.id] { Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 36, height: 36) }
                    else { Image(systemName: "paperclip") }
                    Text(file.name).lineLimit(1); Spacer(); Button("Remove") { model.removeFile(file.id) }
                }.font(Theme.display(11))
            }
            if model.importing { Text("Preparing files…").font(Theme.display(11)) }
            if !model.draft.attachments.isEmpty, model.draft.text.utf16.count > model.snapshot.captionLimit {
                Text("Text will be sent first, followed by each file separately.").font(Theme.display(11)).foregroundStyle(.secondary)
            }
            if let inline = model.inlineNotice {
                HStack {
                    Text(inline).font(Theme.display(11))
                    Spacer()
                    Button("Open in Telegram") { model.applyBotResult(.openTelegram("Inline mode is available in Telegram"), pane: pane) }
                    Button("Send as text") { model.sendInlineAsText() }
                    if model.inlineCheck == .unavailable { Button("Retry") { model.retryInlineCheck() } }
                }
            }
            Text("Send as \(model.snapshot.capabilities.sender)" + (model.snapshot.topicInfo.map { " · \($0.name)" } ?? ""))
                .font(Theme.display(10)).foregroundStyle(.secondary)
            ChatComposerBox(control: editor, attachments: nil, owner: nil, root: nil, fileUI: true,
                            mentionTitle: "Insert @", canSend: model.canSend, chooseFiles: model.chooseFiles, send: model.send, formattingEnabled: false) {
                ChatMentionEditor(text: Binding(get: { model.draft.text }, set: { text in model.change { $0.text = text }; model.typing(!text.isEmpty && editor.focused, pane: pane) }),
                    selection: $selection, candidates: [], control: editor, heightChanged: { editorHeight = $0 }, placeholder: composerPlaceholder,
                    accessibilityName: "Telegram message", attachments: { model.paste($0) }, dropAttachments: { model.paste($0, fromDrop: true) }, suppressCommandReturnRepeat: true,
                    key: { code, modifiers in
                        guard let view = editor.view, view.window?.firstResponder === view, allowsKeyboardAction else { return false }
                        switch TelegramComposerKey.action(code: code, modifiers: modifiers, markedText: editor.view?.hasMarkedText() == true, repeatKey: NSApp.currentEvent.map({ $0.type == .keyDown && $0.isARepeat }) == true) {
                        case .send: model.send(); return true
                        case .addToFolder: model.addToFolder(chats: chats, windowID: TabRouter.shared.stores().first { $0.allSessions.contains { $0.tabState === state } }?.windowID); return true
                        case .native: return false
                        }
                    }).frame(height: max(52, min(160, editorHeight)))
            }
            Text("⌘Return to send · Return for a new line").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
        }.padding(14)
    }
    private func observe() {
        // Revoke queued views immediately; geometry evaluation can wait for
        // the rest of this turn's message, ad and overlay preference updates.
        model.invalidatePresentation(pane: pane)
        visibilityUpdates.schedule(evaluateVisibility)
    }
    private func evaluateVisibility() {
        let shown = box.view.map { view in
            view.window?.isVisible == true && view.window?.isMiniaturized != true && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty && view.window.map { !NavigationPresentationGate.obscures($0) } == true
        } ?? false
        let active = TelegramService.isInteractive && !menuTracking && model.sponsoredDialog == nil && model.botDialog == nil
            && (!jumpToLatestVisible || !overlayFrames.isEmpty)
            && box.view.map { NavigationPresentationGate.allowsAcknowledgement($0, appActive: NSApp.isActive) } == true
        let visibility = TelegramFeedVisibility.capture(scroll: viewport.scroll, viewport: feedViewport,
                                                        overlays: jumpToLatestVisible ? overlayFrames : [])
        let ids = Set(model.snapshot.messages.filter { message in
            frames[message.id].map { visibility?.isVisible($0, requiring: .partial) == true } ?? false
        }.map(\.messageID))
        sponsoredActive = active && shown
        let requested = ConversationFrames.visible(sponsoredGeometry.cards, viewport: feedViewport)
        sponsoredRequests = Set(model.snapshot.sponsored.messages.filter { requested.contains($0.id) }.map(\.ref))
        let ads = model.snapshot.sponsored.messages.map { ad in
            TelegramSponsoredVisibility(ref: ad.ref, fullyLoaded: sponsoredGeometry.ready.contains(ad.id) && ad.fullyLoaded,
                fullTextVisible: sponsoredGeometry.text[ad.id].map {
                    visibility?.isVisible($0, requiring: .full) == true
                } ?? false)
        }
        model.observe(.init(pane: pane, epoch: model.snapshot.epoch, active: active, shown: shown, ordinaryIDs: ids,
                            sponsored: ads, sponsoredRequests: sponsoredRequests))
    }
    private func delivery(_ state: TelegramMessage.Delivery) -> String {
        switch state { case .received: ""; case .submitting: "Submitting…"; case .pending: "Sending…"; case .sent: "Sent"; case .read: "Read"; case .failed(let error): error; case .unknown: "Delivery unknown · Check Telegram" }
    }
}

enum TelegramEntityRenderer {
    static func attributed(_ message: TelegramMessage) -> AttributedString {
        attributed(text: message.text, entities: message.entities)
    }
    static func attributed(text: String, entities: [TelegramTextEntity]) -> AttributedString {
        let result = NSMutableAttributedString(string: text)
        for entity in entities {
            let range = NSRange(location: entity.offset, length: entity.length)
            guard range.location >= 0, range.length > 0, range.location + range.length <= result.length else { continue }
            switch entity.kind {
            case .bold: result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: range)
            case .italic: result.addAttribute(.obliqueness, value: 0.2, range: range)
            case .underline: result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .strikethrough: result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code, .pre: result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: range)
            case .link: if let string = entity.url, let url = URL(string: string), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { result.addAttribute(.link, value: url, range: range) }
            case .blockquote: result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            case .spoiler: result.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
            }
        }
        return AttributedString(result)
    }
}
