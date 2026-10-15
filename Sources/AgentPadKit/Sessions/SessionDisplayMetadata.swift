import Foundation

struct SessionDisplayTitle: Codable, Equatable, Sendable {
    var key: SessionNameKey
    var title: String
}

/// Display-only reconciliation. No clock reads, I/O, or writes to the profile archive.
struct SessionDisplayMetadata: Equatable, Sendable {
    var title: String
    var lastActivity: Date

    struct Live: Equatable, Sendable {
        var templateTitle: String? = nil
        /// Explicit name from SessionNames, also available for closed sessions.
        var explicitName: String? = nil
        var terminalTitle: String? = nil
        var cachedTitle: String? = nil
        var hookStateAt: Date? = nil
        var startedAt: Date? = nil
    }

    static func resolve(catalog: AgentSessionRecord?, binding: AgentSessionRecord?,
                        live: Live? = nil, folderName: String) -> Self {
        let template = live?.templateTitle
            ?? AgentTemplate.builtin(id: (catalog ?? binding)?.agentId ?? "")?.title ?? "Agent"
        let folder = (folderName as NSString).lastPathComponent
        func explicitTitle(_ value: String?) -> String? { SessionTitle.nonempty(value).map(singleLine) }
        func title(_ value: String?) -> String? {
            guard let value = explicitTitle(value),
                  ![folder, template, "Session in \(folder)"].contains(where: { value.caseInsensitiveCompare($0) == .orderedSame })
            else { return nil }
            return value
        }
        // A newer discovery can supersede an older catalog snapshot. On ties
        // the catalog wins, but each missing field can still come from binding.
        let records = [catalog, binding].compactMap { $0 }.sorted {
            ($0.scannedAt ?? .distantPast) > ($1.scannedAt ?? .distantPast)
        }
        let custom = records.compactMap { explicitTitle($0.customTitle) }.first
        let ai = records.compactMap { record in
            // Older/non-Claude records retain a single title field. A title
            // derived from a summary or prompt must not jump ahead of those tiers.
            title(record.aiTitle) ?? title(record.agentTitle)
                ?? (SessionTitle.nonempty(record.summary) == nil && AgentSessionScanner.displayableUserText(record.firstPrompt) == nil
                    ? title(record.title) : nil)
        }.first
        let summary = records.compactMap { title($0.summary).map(AgentSessionScanner.cleanedTitle) }.first
        let prompt = records.compactMap { record in
            AgentSessionScanner.displayableUserText(record.firstPrompt).flatMap(title)
                .map(SessionTitle.firstPhrase).flatMap(title)
        }.first
        let terminal = title(live?.terminalTitle).flatMap { value -> String? in
            guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.hasPrefix("./"), !value.hasPrefix("../"),
                  !value.hasPrefix("file:"), !value.hasPrefix("\\"),
                  !(value.contains("/") && !value.contains(where: \.isWhitespace)) else { return nil }
            return value
        }
        return Self(title: explicitTitle(live?.explicitName)
                        ?? custom ?? ai ?? summary ?? prompt ?? explicitTitle(live?.cachedTitle) ?? terminal ?? template,
                    lastActivity: activity(catalog: catalog, binding: binding, hookStateAt: live?.hookStateAt, startedAt: live?.startedAt))
    }

    static func activity(catalog: AgentSessionRecord?, binding: AgentSessionRecord?,
                         hookStateAt: Date? = nil, startedAt: Date? = nil) -> Date {
        [catalog?.lastActivity, binding.flatMap { $0.hasScanProvenance ? $0.lastActivity : nil }, hookStateAt]
            .compactMap { $0 }.filter { $0 > .distantPast }.max() ?? startedAt ?? .distantPast
    }
}

extension SessionDisplayMetadata.Live {
    @MainActor init(session: Session, explicitName: String? = nil) {
        self.init(templateTitle: session.displayAgent.title, explicitName: explicitName ?? session.explicitName,
                  terminalTitle: session.terminalTitle,
                  cachedTitle: session.cachedDisplayTitle,
                  hookStateAt: session.hookStateAt, startedAt: session.catalogStartedAt)
    }
}

extension SessionDisplayMetadata {
    /// Window-owned references to the existing observable, in-memory stores.
    /// Reading a title never scans transcripts or opens the names database.
    @MainActor struct Sources {
        var catalog: SessionCatalog = .shared
        var profiles: AgentProfileStore = .shared
        var names: SessionNames = .shared

        func metadata(for session: Session, manualNames: [SessionNameKey: String]? = nil,
                      includeExplicitName: Bool = true) -> SessionDisplayMetadata {
            let key = session.displayTitleKey
            let catalog = key.flatMap { self.catalog.record(for: $0) }
            let binding = key.flatMap { profiles.binding(agentID: $0.agentID, conversationID: $0.conversationID)?.record }
            let name = key.flatMap { (manualNames ?? names.values)[$0] }
            var live = Live(session: session, explicitName: name)
            // Persist the automatic title separately from explicit Rename so
            // clearing a restored manual name reveals the last known title.
            if !includeExplicitName { live.explicitName = nil }
            return .resolve(catalog: catalog, binding: binding,
                live: live,
                folderName: (binding?.cwd ?? session.profileOriginalCwd ?? session.currentDirectory).lastPathComponent)
        }
    }
}
