import AppKit
import AgentPadQuietTestSupport
import CryptoKit
import Foundation
import Observation
import ObjectiveC.runtime
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor @Observable final class ChatTimelineReferenceModel: ChatConversationPresentation {
    let key: ChatOrgKey
    let service: ChatService
    var isDM = false
    var dmWritable = true
    var retryAllowed = true
    var feed = ChatChannelModel.Feed()
    var b1: ChatB1Channel?
    var confirmation: ConfirmationCoordinator?
    var deletionRoot: String?
    var editing: ChatChannelModel.Editing?
    var threadRoot: String?
    var threadHasEarlier = false
    var threadUnreadID: String?
    var positions: [String: ChatScrollPosition] = [:]
    var focusedMessageID: String?
    var revealMessageID: String?
    var focusRequest: ChatFocusRequest?
    var readingPositionRestored = 0
    var searching = false
    var hasNavigationReturn = false
    var sourceStatuses: [ChatSourceStatus] = []
    var threadRequests: [ChatChannelRequests.Card] = []
    init(_ fixture: ChatChannelExecutionTests.Fixture, messages: [ChatMessage] = [], service: ChatService? = nil) {
        key = fixture.key; self.service = service ?? fixture.service
        feed.messages = messages; feed.archived = false
    }
    func notificationPlace(root: String?) -> String { "reference:\(isDM):\(root ?? "feed")" }
    func destination(root: String?) -> ConversationDestination { .channel(key, chat: ChatTimelineReferenceFixture.channel, thread: root) }
    func message(_ id: String) -> ChatMessage? { feed.messages.first { $0.id == id } }
    func conversationMessages(root: String?) -> [ChatMessage] { feed.messages }
    func openThread(_ id: String?) { threadRoot = id }
    func loadOlder() {}
    func earlierReplies() {}
    func beginReading(root: String?) {}
    func endReading(root: String?) {}
    func readIfLooking(root: String?, appActive: Bool, shown: Bool, atBottom: Bool) {}
    func markConversationRead(root: String?, clearingBoundary: Bool) {}
    func finishNavigation() {}
    func dismissTransient() -> Bool { false }
    func canEdit(_ message: ChatMessage) -> Bool {
        if isDM { return canDelete(message) && (message.authorSessionName == nil || service.supports("chat.dm.session_signature", key: key)) }
        return !feed.archived && message.channelId == ChatTimelineReferenceFixture.channel && message.authorAccountId == key.accountId
            && message.authorAgentId == nil && message.authorSessionName == nil && message.seq != nil && message.hasFixed && message.hasMutable
            && !message.deleted && !message.loading && !message.changing && message.localState == nil
    }
    func canDelete(_ message: ChatMessage) -> Bool {
        message.authorAccountId == key.accountId && message.hasFixed && !message.deleted && !message.changing && message.localState == nil
            && (!isDM || dmWritable && !message.loading)
    }
    func canRetry(_ message: ChatMessage) -> Bool { retryAllowed }
    func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool) -> Bool {
        editing = .init(messageId: message.id, root: root, text: message.localEdit?.text ?? message.text, revision: message.revision, message: message)
        return true
    }
    func cancelEditing(messageID: String?, all: Bool) { editing = nil }
    func saveEditing(members: [(account: String, handle: String)]) -> Bool { false }
    func requestDelete(_ message: ChatMessage, root: String?) -> Bool { false }
    func retry(_ message: ChatMessage) {}
    func discard(_ message: ChatMessage) {}
    func discardEdit(_ message: ChatMessage) {}
}

enum ChatTimelineReferenceFixture {
    static let channel = "f5000000-0000-4000-8000-000000000001"
    static let root = "f5000000-0000-4000-8000-000000000002"
    static let date = "2026-10-07T12:00:00Z"
    static let emoji = ["👍", "👎", "❤️", "🎉", "🚀", "👀", "✅", "🔥", "💡", "🙏", "🤔", "😂"]
    static func message(_ name: String, me: String, text: String = "A plain message with a stable reference identity.", seq: Int = 1) throws -> ChatMessage {
        let fields: [String: Any] = ["messageId": name, "channelId": channel, "authorAccountId": me,
            "seq": seq, "createdAt": date, "hasFixed": true, "hasMutable": true, "text": text,
            "mentions": [], "revision": 3, "attachments": [], "attachmentOnly": false]
        return try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    @MainActor static func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 320 * 4, bitsPerPixel: 32))
        for y in 0..<160 {
            for x in 0..<320 {
                let bar = x > 24 && x < 296 && x % 44 < 28 && y > 20 && y < 35 + (x / 44) * 17
                bitmap.setColor(bar ? NSColor(calibratedRed: 0.06, green: 0.32, blue: 0.86, alpha: 1)
                    : NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.98, alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

// Keep the manager's two real transfer slots occupied without completing a
// request, sleeping a worker thread, or touching a network. The third draft
// therefore remains queued. Cancellation disposes the URLSession requests.
final class ChatTimelineReferenceDraftProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let answer: [String: Any]
        if request.url?.path == "/v1/commands",
           let command = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: body) {
            if command.type == "attachment.complete"
                || command.type == "attachment.prepare" && command.args["name"]?.string == "draft-uploading.txt" {
                return // Hold uploading at its seeded 45%, or checking after upload.
            }
            answer = ["events": [], "result": [:]]
        } else if let url = request.url, url.path.contains("/attachments/") {
            answer = ["attachment_id": url.lastPathComponent, "state": "checking"]
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum ChatTimelineReferencePaths {
    static let environmentKey = "AGENTPAD_CHAT_NATIVE_REFERENCE_ROOT"
    static func resolved(_ url: URL) -> URL {
        // Foundation may leave an existing symlink unresolved when the final
        // capture directory does not exist yet. Resolve its existing ancestor.
        var ancestor = url
        var components: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            components.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return components.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }
    static func root(_ path: String) throws -> URL {
        guard (path as NSString).isAbsolutePath else {
            throw NSError(domain: "Reference root must be an absolute path", code: 1)
        }
        return resolved(URL(fileURLWithPath: path, isDirectory: true))
    }
    static func configuredRoot(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard let path = environment[environmentKey] else {
            throw NSError(domain: "Set \(environmentKey) to the external reference evidence root", code: 1)
        }
        return try root(path)
    }
}

@MainActor final class ChatTimelineReferenceCapture {
    let output: URL
    var records: [[String: Any]] = []
    let members: [ChatOrgView.Member]
    init(output: URL, me: String, evidenceRoot: URL? = nil) throws {
        self.output = output
        members = [.init(accountId: me, handle: "anna", name: "Anna", role: "owner"),
                   .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")]
        let root = try ChatTimelineReferencePaths.resolved(evidenceRoot ?? ChatTimelineReferencePaths.configuredRoot())
        let destination = ChatTimelineReferencePaths.resolved(output)
        guard destination.path.hasPrefix(root.path + "/") else {
            throw NSError(domain: "Reference destination outside designated evidence root", code: 1)
        }
        guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("captures.json").path) else {
            throw NSError(domain: "Refusing to overwrite frozen reference index", code: 1)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }
    func finish() throws {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "renderer": "native-product", "captures": records], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("captures.json"), options: .withoutOverwriting)
    }
    // The application singleton follows its own (offline) connection. Deliver the
    // fixture's real store snapshot synchronously before rendering shared org UI;
    // otherwise its async observer can replace a reference model between awaits.
    static func prepareOrganization(_ service: ChatService) throws {
        let current = ChatOrgCurrent.shared
        current.refresh(service)
        if let key = service.connection?.orgKey, let store = service.orgSessions[key]?.store,
           let model = current.model {
            model.set(try store.queue.read { try ChatOrgView.read($0) })
        }
    }
    func row(_ model: any ChatConversationPresentation, message: ChatMessage, width: CGFloat, thread: Bool,
             grouped: Bool = false, selected: Bool = false, archived: Bool = false) -> AnyView {
        AnyView(VStack(spacing: 0) {
            Color.clear.frame(height: 24)
            ChatNativeRowFixture(model: model, message: message, members: members, mentionable: members.map { ($0.accountId, $0.handle) },
                me: model.key.accountId, archived: archived, replies: 0, requests: model.feed.requests[message.id] ?? 0,
                inThread: thread, startsGroup: !grouped, selected: selected)
            Spacer(minLength: 0)
        }.frame(width: width, height: 600, alignment: .topLeading))
    }
    func timeline(_ model: any ChatConversationPresentation, root: String?, width: CGFloat, height: CGFloat = 600) -> AnyView {
        AnyView(ChatTimelineView(model: model, root: root, members: members, mentionable: members.map { ($0.accountId, $0.handle) },
            me: model.key.accountId, archived: model.feed.archived, ownerModel: nil).frame(width: width, height: height))
    }
    func capture(_ id: String, inventory: [String], model: any ChatConversationPresentation, messages: [ChatMessage],
                 width: CGFloat, height: CGFloat = 600, dark: Bool, root: String? = nil,
                 decoded: Bool = false, detail: [String: Any] = [:], content: AnyView,
                 afterMount: ((NSHostingView<AnyView>, NSWindow) throws -> Void)? = nil,
                 beforeBitmap: ((NSHostingView<AnyView>, NSWindow) throws -> Void)? = nil,
                 prepare: ((NSHostingView<AnyView>, NSWindow) async throws -> Void)? = nil) async throws {
        let identifier = "\(id)-\(Int(width))-\(dark ? "dark" : "light")"
        try Self.prepareOrganization(model.service)
        let styled = AnyView(content.background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, TimeZone(identifier: "Europe/Amsterdam")!))
        let host = NSHostingView(rootView: styled)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = ChatTimelineCaptureColor.colorSpace
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        APQuietSelectWindow(window)
        defer { host.rootView = AnyView(EmptyView()); window.contentView = nil; window.close() }
        if let afterMount {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try afterMount(host, window)
        }
        try await Task.sleep(for: .milliseconds(80))
        try Self.prepareOrganization(model.service)
        host.layoutSubtreeIfNeeded()
        ChatScrollAppKitSettings.apply(to: host)
        try await prepare?(host, window)
        var accepted: NSBitmapImageRep?
        var chartPixels = 0
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(decoded ? 100 : 20))
            try Self.prepareOrganization(model.service)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try beforeBitmap?(host, window)
            let bitmap = try ChatTimelineCaptureColor.bitmap(host)
            if decoded {
                chartPixels = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.blueComponent > color.redComponent * 2,
                           color.blueComponent > color.greenComponent * 1.5 { chartPixels += 1 }
                    }
                }
                if chartPixels < 150 { continue }
            }
            accepted = bitmap; break
        }
        let bitmap = try XCTUnwrap(accepted, "Decoded chart pixels absent for \(identifier)")
        var metadata = detail
        let axLabels = Self.accessibilityNodes(window).flatMap { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { Self.accessibilityAttribute(object, $0) as? String }
        }
        metadata["nativeAccessibilityStrings"] = axLabels
        // Only a fixture that actually mounts the active row opts into this check.
        // A production channel model can retain focus while a search/pins panel is shown.
        if let activeID = detail["activeMessageID"] as? String ?? detail["focusedMessageID"] as? String,
           let active = model.message(activeID), model.editing?.messageId != activeID {
            let hasReply = axLabels.contains("Reply in thread")
            let hasEdit = axLabels.contains("Edit message")
            let hasDelete = axLabels.contains("Delete message…")
            if active.hasFixed, active.localState == nil, !active.deleted || model.isDM {
                XCTAssertTrue(hasReply, "\(identifier): active message \(activeID) must retain its Reply toolbar action")
            }
            if active.authorAccountId != model.key.accountId {
                XCTAssertFalse(model.canEdit(active)); XCTAssertFalse(model.canDelete(active))
                XCTAssertFalse(hasEdit, "Another member's active row must omit Edit")
                XCTAssertFalse(hasDelete, "Another member's active row must omit Delete")
            } else if model.canEdit(active), model.canDelete(active) {
                XCTAssertTrue(hasEdit, "Eligible own active row must expose Edit")
                XCTAssertTrue(hasDelete, "Eligible own active row must expose Delete")
            }
            metadata["activeToolbar"] = ["messageID": activeID, "ownAuthor": active.authorAccountId == model.key.accountId,
                "reply": hasReply, "edit": hasEdit, "delete": hasDelete]
        }
        if let requested = detail["focusedControl"] as? String {
            let focused = Self.accessibilityNodes(window).contains { node in
                let matches = ["accessibilityLabel", "accessibilityTitle", "accessibilityHelp"].contains {
                    let value = Self.accessibilityAttribute(node, $0) as? String
                    return value == requested || requested == "More message actions" && value == "More"
                }
                return matches && Self.accessibilityFocused(node) == true
            }
            metadata["requestedControlHasLocalFocus"] = focused
            if !focused {
                metadata["captureGap"] = "The production control is present, but its local AX focus setter cannot focus it in the invisible window. Focus-ring pixels require the pre-release hardware/VoiceOver session."
            }
        }
        for required in detail["requiredVisibleText"] as? [String] ?? [] {
            XCTAssertTrue(axLabels.contains { $0.contains(required) }, "Visible AX text '\(required)' absent in \(identifier)")
        }
        metadata["decodedChartPixels"] = chartPixels
        metadata["nativeTexts"] = Self.descendants(host, NSTextView.self).map { ["text": $0.string, "frame": NSStringFromRect($0.convert($0.bounds, to: host)), "selection": NSStringFromRange($0.selectedRange())] }
        if let expected = detail["expectedNativeSelection"] as? String,
           let prefix = detail["nativeSelectionTextPrefix"] as? String {
            let text = try XCTUnwrap(Self.descendants(host, NSTextView.self).first { $0.string.hasPrefix(prefix) })
            XCTAssertEqual(NSStringFromRange(text.selectedRange()), expected, "Selection must survive bitmap capture: \(identifier)")
        }
        if detail["viewportEdge"] as? String == "top", let activeID = detail["activeMessageID"] as? String,
           let target = model.message(activeID) {
            let body = try XCTUnwrap(Self.descendants(host, NSTextView.self).first { $0.string == target.text })
            XCTAssertEqual(body.convert(.zero, to: host).y, 5, accuracy: 0.75, "Captured viewport must retain the staged edge: \(identifier)")
        }
        metadata["scrollViews"] = Self.descendants(host, NSScrollView.self).map { ["clipBounds": NSStringFromRect($0.contentView.bounds), "documentFrame": NSStringFromRect($0.documentView?.frame ?? .zero)] }
        let effectiveRoot = root ?? (width == 420 ? model.threadRoot : nil)
        metadata["anchor"] = effectiveRoot ?? "feed-top-or-model-position"
        metadata["positions"] = String(describing: model.positions)
        metadata["fixtureValues"] = try messages.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        metadata["conversation"] = model.isDM ? "dm" : "channel"
        metadata["root"] = effectiveRoot ?? NSNull()
        metadata["fixtureModel"] = model is ChatTimelineReferenceModel ? "test-only explicit presentation projection; action eligibility synthetic, no behavioral parity claim" : "production offline model"
        if metadata["members"] == nil { metadata["members"] = members.map { ["accountId": $0.accountId, "handle": $0.handle, "name": $0.name, "role": $0.role] } }
        metadata["mentionable"] = members.map { ["account": $0.accountId, "handle": $0.handle] }
        metadata["capabilities"] = Array(model.service.serverCapabilities[model.key.server] ?? []).sorted()
        metadata["feed"] = ["archived": model.feed.archived, "hasOlder": model.feed.hasOlder,
            "earlierUnread": model.feed.earlierUnread, "unreadID": model.feed.unreadID ?? NSNull(),
            "replyCounts": model.feed.replies, "requestCounts": model.feed.requests,
            "unreadReplyCounts": model.feed.unreadReplyCounts, "boundaryDismissed": model.feed.boundaryDismissed,
            "replySummaries": model.feed.replySummaries.mapValues { summary -> [String: Any] in
                ["count": summary.count, "complete": summary.complete, "participants": summary.participants.map(\.id), "latest": summary.latest?.id ?? NSNull()]
            }]
        metadata["threadHasEarlier"] = model.threadHasEarlier
        metadata["threadUnreadID"] = model.threadUnreadID ?? NSNull()
        metadata["focusedMessageID"] = model.focusedMessageID ?? NSNull()
        metadata["revealMessageID"] = model.revealMessageID ?? NSNull()
        metadata["editing"] = try model.editing.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
        metadata["confirmation"] = ["phase": String(describing: model.confirmation?.phase), "context": String(describing: model.confirmation?.context),
            "title": model.confirmation?.title ?? "", "consequences": model.confirmation?.consequences ?? ""]
        metadata["b1"] = try model.b1.map { b1 -> [String: Any] in
            ["accessible": b1.state.accessible, "canChange": b1.canChange, "loadError": b1.state.loadError ?? NSNull(),
             "metadata": try b1.state.metadata.mapValues { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
             "intents": b1.state.intents.mapValues { $0.map { ["choice": $0.choice, "present": $0.present, "error": $0.error ?? NSNull()] as [String: Any] } }]
        } ?? [:]
        metadata["sourceStatuses"] = model.sourceStatuses.map { ["id": $0.id, "source": $0.source, "agent": $0.agent, "state": $0.state,
            "initiator": $0.initiator ?? NSNull(), "owner": $0.owner ?? NSNull(), "publication": $0.publication ?? NSNull(), "error": $0.error ?? NSNull(), "local": $0.local, "answer": $0.answer ?? NSNull()] as [String: Any] }
        if let manager = model.service.attachments(model.key) {
            metadata["attachmentLimits"] = try manager.limits.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
            metadata["attachments"] = messages.flatMap { message in message.attachments.map { file in
                ["message": message.id, "file": file.id, "stamp": String(describing: manager.stamp(owner: message.attachmentOwner, message: message, file: file)), "decoded": manager.image(message, file: file) != nil] as [String: Any]
            } }
            metadata["attachmentDrafts"] = try manager.drafts.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        }
        try write(bitmap, id: identifier, inventory: inventory, width: width, height: height, dark: dark,
                  scale: window.backingScaleFactor, detail: metadata)
        XCTAssertFalse(APQuietWindowHasOSFocus(window))
        XCTAssertNil(APQuietFailure())
    }
    func write(_ bitmap: NSBitmapImageRep, id: String, inventory: [String], width: CGFloat, height: CGFloat,
               dark: Bool, scale: CGFloat, detail: [String: Any]) throws {
        guard Theme.resolved.isLight == !dark else {
            throw NSError(domain: "Reference theme does not match capture label: " + id, code: 1)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        var record = detail
        record.merge(["captureID": id, "inventoryIDs": inventory, "image": id + ".png", "sha256": Self.digest(data),
            "renderer": "native-product", "width": width, "height": height, "scale": scale,
            "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh, "theme": dark ? "dark" : "light",
            "preset": String(describing: Theme.resolved), "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier, "fixtureDate": ChatTimelineReferenceFixture.date,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "accent": NSColor.controlAccentColor.description,
            "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "fonts": ["Onest": NSFont(name: "Onest", size: 14)?.fontName ?? "MISSING",
                      "JetBrainsMono-Regular": NSFont(name: "JetBrainsMono-Regular", size: 12)?.fontName ?? "MISSING"]]) { _, new in new }
        let fixture = try JSONSerialization.data(withJSONObject: record["fixtureValues"] ?? [], options: [.sortedKeys])
        record["fixtureSHA256"] = Self.digest(fixture)
        try data.write(to: output.appendingPathComponent(id + ".png"), options: .withoutOverwriting)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(id + ".json"), options: .withoutOverwriting)
        records.append(record)
        if records.count.isMultiple(of: 50) { print("CHAT REFERENCE: \(records.count) captures; latest=\(id)") }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func accessibilityFocused(_ object: NSObject) -> Bool? {
        // AX focus is a scalar Objective-C result; NSObject.perform is only safe
        // for the object-valued attributes used by accessibilityAttribute below.
        let getter = NSSelectorFromString("isAccessibilityFocused")
        if object.responds(to: getter) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: getter), to: Getter.self)(object, getter)
        }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: legacy) else { return nil }
        return (object.perform(legacy, with: "AXFocused")?.takeUnretainedValue() as? NSNumber)?.boolValue
    }
    static func accessibilityAttribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let keys = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription", "accessibilityTitle": "AXTitle", "accessibilityValue": "AXValue", "accessibilityHelp": "AXHelp"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let key = keys[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: key)?.takeUnretainedValue()
    }
    static func accessibilityNodes(_ window: NSWindow) -> [NSObject] {
        var result: [NSObject] = [], queue: [NSObject] = [window], seen = Set<ObjectIdentifier>()
        if let content = window.contentView { queue.append(content) }
        while let object = queue.popLast(), result.count < 4000 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            queue += accessibilityAttribute(object, "accessibilityChildren") as? [NSObject] ?? []
            if let view = object as? NSView { queue += view.subviews }
        }
        return result
    }
    static func press(_ title: String, window: NSWindow, diagnosticContext: String? = nil) -> Bool {
        guard let object = accessibilityNodes(window).first(where: { node in
            ["accessibilityLabel", "accessibilityTitle"].contains { accessibilityAttribute(node, $0) as? String == title }
        }) else { return false }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if let diagnosticContext {
            let type = String(reflecting: Swift.type(of: object))
            let role = accessibilityAttribute(object, "accessibilityRole") as? String ?? "unknown"
            let encoding = object_getClass(object).flatMap { class_getInstanceMethod($0, selector) }
                .flatMap(method_getTypeEncoding).map(String.init(cString:)) ?? "unknown"
            print("W09_AX_PRESS before context=\(diagnosticContext) title=\(title) type=\(type) role=\(role) encoding=\(encoding) responds=\(object.responds(to: selector))")
        }
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let result = unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        if let diagnosticContext { print("W09_AX_PRESS after context=\(diagnosticContext) result=\(result)") }
        return result
    }
    /// Focus the actual live responder for one independently observed control.
    /// SwiftUI can retain a non-key proxy at the same frame as a focusable wrapper.
    @discardableResult
    static func focusControl(_ title: String, in host: ChatQuietHost, frame: CGRect,
                             ringWidth: CGFloat, attemptProgrammaticFocus: Bool = false) async throws -> NSView {
        APQuietSelectWindow(host.window)
        XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
        let colocated = descendants(host.view, NSView.self).filter {
            String(describing: type(of: $0)) == "KeyViewProxy" &&
                ChatTimelineParityLayout.frame($0.bounds, from: $0, in: host.view) == frame
        }
        let live = colocated.filter { $0.window === host.window && !$0.isHiddenOrHasHiddenAncestor }
        let accepting = live.filter(\.acceptsFirstResponder)
        let proxies = accepting.isEmpty && attemptProgrammaticFocus ? live : accepting
        let diagnostic = colocated.enumerated().map { index, view in
            "\(index): hidden=\(view.isHiddenOrHasHiddenAncestor), accepts=\(view.acceptsFirstResponder), "
                + "window=\(view.window === host.window), role=\(view.accessibilityRole()?.rawValue ?? "nil"), "
                + "label=\(view.accessibilityLabel() ?? "nil"), parent=\(String(describing: view.superview.map { type(of: $0) }))"
        }.joined(separator: "; ")
        XCTAssertEqual(proxies.count, 1, "Exactly one live legacy responder must match \(title): \(diagnostic)")
        guard proxies.count == 1, let proxy = proxies.first else {
            throw ChatTimelineParityLayout.failure("Ambiguous legacy responder \(title): \(diagnostic)")
        }
        XCTAssertTrue(host.window.makeFirstResponder(nil))
        let focused = host.window.makeFirstResponder(proxy)
        XCTAssertTrue(focused, "Actual legacy responder must accept public programmatic focus: " + title)
        try await host.settle()
        XCTAssertTrue(host.window.firstResponder === proxy, "Actual legacy responder must retain focus: " + title)
        guard focused, host.window.firstResponder === proxy else {
            throw ChatTimelineParityLayout.failure("Legacy responder rejected public programmatic focus " + title + ": " + diagnostic)
        }
        XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
        XCTAssertNil(APQuietFailure())
        let bitmap = try ChatTimelineCaptureColor.bitmap(host.view), scale = host.window.backingScaleFactor
        let x = Int(frame.midX * scale), y = Int(frame.minY * scale)
        let edge = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
        for offset in 1..<Int(ringWidth * scale) {
            XCTAssertEqual(bitmap.colorAt(x: x, y: y + offset), edge, "Actual legacy focus stroke width: " + title)
        }
        XCTAssertNotEqual(bitmap.colorAt(x: x, y: y + Int(ringWidth * scale)), edge,
            "Legacy focus stroke must end at its accessibility-driven width: " + title)
        return proxy
    }

    static func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }
}
