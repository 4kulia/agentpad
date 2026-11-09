import AppKit

/// One backing-pixel width is used by cache lookup, measurement and cell frames.
struct ChatTimelineWidth: Hashable, Sendable {
    let points: CGFloat
    let scale: CGFloat

    init(_ width: CGFloat, scale: Double) {
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        points = max(1, floor((width.isFinite ? width : 1) * self.scale)) / self.scale
    }

    func content(inset: CGFloat) -> CGFloat { max(1, floor((points - inset) * scale)) / scale }
}

struct ChatTimelineCacheKey: Hashable, Sendable {
    let id: NativeTimelineSnapshot.RowID
    let epoch: UUID
    let width: ChatTimelineWidth
    let revision: UInt64
}

/// Bounded LRU. Only immutable content/plans go here, never views or domain owners.
@MainActor final class ChatTimelineCache<Value> {
    struct Entry { let value: Value; let cost: Int; var access: UInt64 }
    let entryLimit: Int
    let costLimit: Int
    private var entries: [ChatTimelineCacheKey: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0
    private(set) var hits = 0
    private(set) var misses = 0
    var count: Int { entries.count }

    init(entries: Int, bytes: Int) {
        precondition(entries > 0 && bytes > 0)
        entryLimit = entries; costLimit = bytes
    }

    func value(for key: ChatTimelineCacheKey) -> Value? {
        guard var entry = entries[key] else { misses += 1; return nil }
        clock &+= 1; entry.access = clock; entries[key] = entry; hits += 1
        return entry.value
    }

    func insert(_ value: Value, for key: ChatTimelineCacheKey, cost newCost: Int) {
        remove(key)
        guard newCost >= 0, newCost <= costLimit else { return }
        while entries.count >= entryLimit || cost > costLimit - newCost {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
        clock &+= 1
        entries[key] = Entry(value: value, cost: newCost, access: clock)
        cost += newCost
    }

    func retain(ids: Set<NativeTimelineSnapshot.RowID>, epoch: UUID) {
        for key in Array(entries.keys) where key.epoch != epoch || !ids.contains(key.id) { remove(key) }
    }

    func removeAll() { entries.removeAll(); cost = 0 }

    private func remove(_ key: ChatTimelineCacheKey) {
        if let entry = entries.removeValue(forKey: key) { cost -= entry.cost }
    }
}

/// Measurement reserves each row's frames. Selectable text can settle to a
/// smaller backing-pixel height within its whole-point body reservation.
struct ChatTimelineRowLayoutPlan: Equatable, Sendable {
    let id: NativeTimelineSnapshot.RowID
    let width: ChatTimelineWidth
    let layoutRevision: UInt64
    var height: CGFloat = 0
    var intrinsicWidth: CGFloat = 0
    var renderedWidth: CGFloat { max(width.points, intrinsicWidth) }
    var header: CGRect = .zero
    var body: CGRect = .zero
    var avatar: CGRect = .zero
    var badge: CGRect = .zero
    var timestamp: CGRect = .zero
    var footnote: CGRect = .zero
    var action: CGRect = .zero
    var rules: [CGRect] = []
    var capsule: CGRect = .zero
    var editor: CGRect = .zero
    var editorFooter: ChatNativeEditorFooterLayout?
    var accessories: ChatNativeAccessoryLayout?
    var attachments: ChatNativeAttachmentLayout?
    var replySummary: ChatNativeReplySummaryLayout?
    var membership: ChatNativeMembershipLayout?
    var metadata: ChatNativeMetadataLayout?
    var sources: ChatNativeSourceLayout?
    var request: ChatNativeRequestLayout?
    /// The semantic reading body excludes header/avatar and row padding, but
    /// includes the W03 stale footnote beneath selectable text.
    var contentBody: CGRect {
        var frame = footnote.isEmpty ? body : body.union(footnote)
        if let membership { frame.size.height = max(frame.height, membership.bottom - frame.minY) }
        if let attachments { frame.size.height = max(frame.height, attachments.bottom - frame.minY) }
        if let accessories { frame.size.height = max(frame.height, accessories.bottom - frame.minY) }
        if let replySummary { frame.size.height = max(frame.height, replySummary.bottom - frame.minY) }
        if let metadata, !metadata.frame.isEmpty { frame = frame.union(metadata.frame) }
        if let sources, !sources.frame.isEmpty { frame = frame.union(sources.frame) }
        return frame
    }
}

struct ChatTimelineShellContent {
    struct BodyInput: Equatable {
        let markdown: String
        let addresses: [String]
        let fontSize: CGFloat
        let style: ChatMessageText.Style
    }
    let header: NSAttributedString
    let body: NSAttributedString
    let style: NativeTimelineSnapshot.Style
    var selectable = false
    var bodyInput: BodyInput?
    var timestamp = NSAttributedString()
    var timeTooltip = ""
    var headerTooltip = ""
    var badge = NSAttributedString()
    var footnote = NSAttributedString()
    var action = NSAttributedString()
    var avatar: AvatarPlaceholder?
    var accessibilityLabel = ""
    var cost: Int { 512 + [header, body, timestamp, badge, footnote, action].reduce(0) { $0 + $1.length * 24 } }
}

@MainActor final class ChatTimelineLayout {
    // Budgets cover revisited widths/revisions. The coordinator separately holds
    // one compact plan per current row, never historical plans or attributed text.
    let heights: ChatTimelineCache<ChatTimelineRowLayoutPlan>
    let contents: ChatTimelineCache<ChatTimelineShellContent>
    private(set) var measurementCount = 0

    init(entryLimit: Int = 512, contentBytes: Int = 4 * 1_024 * 1_024, layoutBytes: Int = 256 * 1_024) {
        heights = ChatTimelineCache(entries: entryLimit, bytes: layoutBytes)
        contents = ChatTimelineCache(entries: entryLimit, bytes: contentBytes)
    }

    func key(_ row: NativeTimelineSnapshot.Row, snapshot: NativeTimelineSnapshot,
             width: ChatTimelineWidth, revision: UInt64) -> ChatTimelineCacheKey {
        .init(id: row.id, epoch: snapshot.presentationEpoch, width: width, revision: revision)
    }

    func content(_ row: NativeTimelineSnapshot.Row, snapshot: NativeTimelineSnapshot,
                 width: ChatTimelineWidth) -> ChatTimelineShellContent {
        let key = key(row, snapshot: snapshot, width: width, revision: row.contentRevision)
        if let cached = contents.value(for: key) { return cached }
        let style = snapshot.style
        func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            ChatNativeTextStyle.font(style.metrics.displayFont, size: size, weight: weight)
        }
        func label(_ text: String, size: CGFloat, color: String = "secondary", weight: NSFont.Weight = .regular,
                   pushOut: Bool = false) -> NSAttributedString {
            ChatNativeTextStyle.label(text, font: font(size, weight: weight), color: style.color(color), pushOut: pushOut)
        }
        var value = ChatTimelineShellContent(header: NSAttributedString(), body: NSAttributedString(), style: style)
        switch row.payload {
        case .message(let message):
            let source = message.content.message
            let identity = ChatAuthorIdentity(source)
            let body: NSAttributedString
            var bodyInput: ChatTimelineShellContent.BodyInput?
            let selectable = !source.deleted && (source.hasMutable || source.localState != nil)
            if selectable {
                let input = ChatTimelineShellContent.BodyInput(
                    markdown: source.attachmentDisplayText(available: message.content.attachments.available),
                    addresses: message.content.bodyAddresses ?? message.content.addresses,
                    fontSize: message.inThread ? 13 : 14,
                    style: .init(foreground: style.color("foreground"), accent: style.color("systemAccent", fallback: .controlAccentColor),
                                 appearance: style.appearance))
                bodyInput = input
                body = ChatMessageText.attributed(input.markdown, addresses: input.addresses,
                    fontSize: input.fontSize, style: input.style)
            } else {
                var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                if source.deleted { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                body = ChatNativeTextStyle.label(source.deleted ? "Message deleted" : "Loading…", font: font,
                                                 color: style.color("foreground").withAlphaComponent(0.5))
            }
            value = .init(header: message.startsGroup ? label(message.content.author, size: message.inThread ? 12 : 13,
                                                              color: "foreground", weight: .semibold, pushOut: true) : NSAttributedString(),
                          body: body, style: style, selectable: selectable)
            value.bodyInput = bodyInput
            value.headerTooltip = message.content.authorTooltip
            if let date = ChatFeedLayout.date(source.createdAt) {
                let format = Date.FormatStyle(date: .omitted, time: .shortened, locale: style.metrics.locale,
                    calendar: style.metrics.calendar, timeZone: style.metrics.calendar.timeZone)
                let timeFont = font(9).fontDescriptor.addingAttributes([.featureSettings: [
                    [NSFontDescriptor.FeatureKey.typeIdentifier: 6, NSFontDescriptor.FeatureKey.selectorIdentifier: 0]]])
                value.timestamp = ChatNativeTextStyle.label(date.formatted(format), font: NSFont(descriptor: timeFont, size: 9) ?? font(9), color: style.color("secondary"))
                value.timeTooltip = date.formatted(.dateTime.year().month().day().hour().minute().second().timeZone())
            } else { value.timeTooltip = source.createdAt }
            if identity.isBot {
                value.badge = ChatNativeTextStyle.label("BOT", font: ChatNativeTextStyle.font(style.metrics.monoFont, size: 9), color: style.color("secondary"))
            }
            if message.startsGroup { value.avatar = .init(stableID: identity.avatarID, name: message.content.author, kind: identity.isBot ? .agent : .person) }
            if selectable, source.stale != nil {
                value.footnote = ChatNativeTextStyle.label("updating…", font: .systemFont(ofSize: 10), color: style.color("foreground").withAlphaComponent(0.5))
            }
            value.accessibilityLabel = "\(message.content.author)\(identity.isBot ? ", BOT" : ""), \(value.timeTooltip)"
        case .day(_, let text), .threadSummary(let text):
            value = .init(header: NSAttributedString(), body: label(text, size: 10), style: style)
        case .empty(let text):
            value = .init(header: NSAttributedString(), body: label(text, size: 13), style: style)
        case .olderControl(let text):
            value.action = ChatNativeTextStyle.label(text, font: font(11), color: style.color("foreground"))
        case .unread:
            value = .init(header: NSAttributedString(), body: label("New messages", size: 10, color: "attention", weight: .medium, pushOut: true), style: style)
            value.action = label("Mark as read", size: 10, color: "attention", pushOut: true)
        case .earlierUnread:
            value = .init(header: NSAttributedString(), body: label("There are earlier unread messages", size: 11, color: "attention"), style: style)
        case .legacyRequest(let request):
            value.accessibilityLabel = request.title + ", " + request.stateWord
        case .inset: break
        }
        contents.insert(value, for: key, cost: value.cost)
        return value
    }

    func plan(_ row: NativeTimelineSnapshot.Row, snapshot: NativeTimelineSnapshot,
              width: ChatTimelineWidth) -> ChatTimelineRowLayoutPlan {
        let key = key(row, snapshot: snapshot, width: width, revision: row.layoutRevision)
        if let cached = heights.value(for: key) { return cached }
        var plan = ChatTimelineRowLayoutPlan(id: row.id, width: width, layoutRevision: row.layoutRevision)
        let content = content(row, snapshot: snapshot, width: width)
        func size(_ text: NSAttributedString, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGSize {
            ChatNativeTextStyle.size(text, width: maxWidth, scale: width.scale)
        }
        func frame(_ size: CGSize, x: CGFloat, y: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: x, y: y), size: size) }
        func centered(_ extent: CGFloat) -> CGFloat { ((width.points - extent) * width.scale / 2).rounded() / width.scale }
        if case .inset(let height) = row.payload { plan.height = height }
        else {
            measurementCount += 1
            switch row.payload {
            case .message(let message):
                let inset: CGFloat = message.inThread ? 18 : 24
                let x = inset + 44, top: CGFloat = message.startsGroup ? 12 : 3
                let proposedWidth = width.content(inset: x + inset)
                func messagePlan(contentWidth: CGFloat, columnTop: CGFloat, constrainsHeight: Bool = false) -> ChatTimelineRowLayoutPlan {
                    var plan = ChatTimelineRowLayoutPlan(id: row.id, width: width, layoutRevision: row.layoutRevision)
                    // SwiftUI's empty timestamp still reserves a zero-width line.
                    // Keep its observed 14-point frame for invalid source dates.
                    let time = content.timestamp.length == 0 ? CGSize(width: 0, height: 14) : size(content.timestamp)
                    let badgeText = size(content.badge)
                    let badge = badgeText == .zero ? .zero : CGSize(width: badgeText.width + 8, height: badgeText.height + 2)
                    let header = size(content.header, maxWidth: max(1, contentWidth - time.width - 7 - (badge.width > 0 ? badge.width + 7 : 0)))
                    let headerHeight = message.startsGroup ? max(19, header.height, badge.height, time.height) : 0
                    plan.header = frame(header, x: x, y: columnTop + (headerHeight - header.height) / 2)
                    if message.startsGroup {
                        plan.avatar = CGRect(x: inset, y: top, width: 32, height: 32)
                        if badge.width > 0 { plan.badge = frame(badge, x: x + header.width + 7, y: columnTop + (headerHeight - badge.height) / 2) }
                        plan.timestamp = frame(time, x: x + header.width + 7 + (badge.width > 0 ? badge.width + 7 : 0), y: columnTop + (headerHeight - time.height) / 2)
                    } else {
                        plan.timestamp = frame(time, x: inset + (32 - time.width) / 2, y: top + 3)
                    }
                    // Match the SwiftUI representable's whole-point reservation.
                    // The text view retains TextKit's native vertical resizing.
                    let bodySize = content.selectable
                        ? CGSize(width: contentWidth, height: ceil(Self.measure(content.body, width: contentWidth)))
                        : size(content.body, maxWidth: contentWidth)
                    plan.body = frame(bodySize, x: x, y: columnTop + headerHeight + (message.startsGroup ? 3 : 0))
                    if message.content.editing != nil, !message.content.message.deleted {
                        let footer = ChatNativeEditorFooterLayout(message: message, state: snapshot.state,
                            width: contentWidth, scale: width.scale)
                        plan.editorFooter = footer
                        plan.editor = CGRect(x: x, y: plan.body.minY, width: contentWidth, height: footer.frame.maxY)
                        plan.body = plan.editor; plan.footnote = .zero
                    }
                    plan.membership = ChatNativeMembershipLayout(message: message, style: snapshot.style, body: plan.body)
                    let textBottom = plan.membership?.bottom ?? plan.body.maxY
                    if plan.editor.isEmpty, content.footnote.length > 0 {
                        plan.footnote = frame(size(content.footnote), x: x, y: textBottom + 2)
                    }
                    var tail = plan.footnote.isEmpty ? plan.body : plan.body.union(plan.footnote)
                    tail.size.height = max(tail.height, textBottom - tail.minY)
                    plan.attachments = ChatNativeAttachmentLayout(message: message, style: snapshot.style,
                        body: tail, constrainsHeight: constrainsHeight)
                    tail.size.height = max(tail.height, (plan.attachments?.bottom ?? tail.maxY) - tail.minY)
                    var accessories = ChatNativeAccessoryLayout(message: message, state: snapshot.state,
                        style: snapshot.style, body: tail, includeReplySource: false)
                    tail.size.height = max(tail.height, accessories.bottom - tail.minY)
                    // Metadata receives the column's proposal independently of an
                    // intrinsic Loading… label. Its plan keeps its rendered width.
                    var metadataBody = tail
                    metadataBody.size.width = contentWidth
                    plan.metadata = ChatNativeMetadataLayout(message: message, style: snapshot.style, body: metadataBody)
                    accessories.bottom = plan.metadata?.bottom ?? accessories.bottom
                    // Reply-source buttons receive the column proposal even when
                    // the body is an intrinsic deleted/loading label.
                    accessories.appendReplySource(message: message, style: snapshot.style, body: metadataBody)
                    plan.accessories = accessories
                    tail.size.height = max(tail.height, (plan.accessories?.bottom ?? tail.maxY) - tail.minY)
                    // The source HStack fills the content column even when the
                    // deleted/loading body above has only an intrinsic text width.
                    var sourceBody = tail
                    sourceBody.size.width = contentWidth
                    plan.sources = ChatNativeSourceLayout(message: message, snapshot: snapshot, body: sourceBody)
                    tail.size.height = max(tail.height, (plan.sources?.bottom ?? tail.maxY) - tail.minY)
                    // Reply summaries receive the same column proposal as the
                    // legacy stack, including below intrinsic deleted/loading labels.
                    var summaryBody = tail
                    summaryBody.size.width = contentWidth
                    plan.replySummary = ChatNativeReplySummaryLayout(message: message, snapshot: snapshot, body: summaryBody)
                    plan.height = max(plan.avatar.maxY, plan.contentBody.maxY) + (message.startsGroup ? 7 : 3)
                    return plan
                }
                let measured = messagePlan(contentWidth: proposedWidth, columnTop: top)
                let editing = message.content.editing != nil && !message.content.message.deleted
                let finalWidth = editing ? max(proposedWidth, ChatNativeEditorHost.minimumFormattingWidth) : proposedWidth
                let flexibleAttachment = !message.content.attachments.problems.isEmpty
                    && message.content.message.attachments.contains { !$0.isImage }
                if finalWidth == proposedWidth && !flexibleAttachment { plan = measured }
                else {
                    let placed = messagePlan(contentWidth: finalWidth, columnTop: top, constrainsHeight: true)
                    let spare = max(0, measured.contentBody.maxY - placed.contentBody.maxY)
                    plan = messagePlan(contentWidth: finalWidth, columnTop: top + spare / 2, constrainsHeight: true)
                    plan.height = measured.height
                    plan.intrinsicWidth = x + finalWidth + inset
                }
            case .day:
                let label = size(content.body), inset: CGFloat = snapshot.conversation.root == nil ? 24 : 18
                let capsule = CGSize(width: label.width + 20, height: label.height + 6)
                plan.height = capsule.height + 16
                plan.capsule = frame(capsule, x: centered(capsule.width), y: 8)
                plan.body = frame(label, x: plan.capsule.minX + 10, y: 11)
                let lineWidth = max(0, plan.capsule.minX - 12 - inset)
                let rightLineWidth = max(0, width.points - inset - (plan.capsule.maxX + 12))
                plan.rules = [CGRect(x: inset, y: (plan.height - 1) / 2, width: lineWidth, height: 1),
                              CGRect(x: plan.capsule.maxX + 12, y: (plan.height - 1) / 2, width: rightLineWidth, height: 1)]
            case .unread:
                // The legacy HStack proposes space to the button, label and
                // flexible rule after reserving its fixed rule and gaps.
                let available = max(1, width.points - 48 - 32 - 30)
                let action = size(content.action, maxWidth: available / 3)
                let label = size(content.body, maxWidth: max(1, (available - action.width) / 2))
                let height = max(label.height, action.height)
                plan.height = height + 24
                plan.body = frame(label, x: 66, y: 16 + (height - label.height) / 2)
                plan.action = frame(action, x: width.points - 24 - action.width, y: 16 + (height - action.height) / 2)
                plan.rules = [CGRect(x: 24, y: 16 + (height - 1) / 2, width: 32, height: 1),
                              CGRect(x: plan.body.maxX + 10, y: 16 + (height - 1) / 2, width: max(0, plan.action.minX - plan.body.maxX - 20), height: 1)]
            case .threadSummary:
                let label = size(content.body)
                plan.body = frame(label, x: 18, y: 18); plan.height = label.height + 36
                plan.rules = [CGRect(x: plan.body.maxX + 8, y: 18 + (label.height - 1) / 2, width: max(0, width.points - 18 - plan.body.maxX - 8), height: 1)]
            case .olderControl:
                let action = size(content.action)
                plan.height = action.height + 16
                plan.action = frame(action, x: centered(action.width), y: 8)
            case .legacyRequest(let request):
                plan.request = ChatNativeRequestLayout(request: request, style: snapshot.style, width: width)
                plan.height = plan.request?.height ?? 0
            case .empty, .earlierUnread:
                let padding: CGFloat = if case .empty = row.payload { 24 } else { 8 }
                let label = size(content.body, maxWidth: max(1, width.points - padding * 2))
                plan.body = frame(label, x: centered(label.width), y: padding)
                plan.height = label.height + padding * 2
            case .inset: break
            }
        }
        heights.insert(plan, for: key, cost: 256)
        return plan
    }

    private static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        // No displayed text view, shared TextKit state, cell construction or I/O.
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager(); manager.backgroundLayoutEnabled = false
        let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return max(1, manager.usedRect(for: container).height)
    }

    func retain(snapshot: NativeTimelineSnapshot) {
        let ids = Set(snapshot.rowIDs)
        heights.retain(ids: ids, epoch: snapshot.presentationEpoch)
        contents.retain(ids: ids, epoch: snapshot.presentationEpoch)
    }

    func removeAll() { heights.removeAll(); contents.removeAll() }
}
