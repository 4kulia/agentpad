import Foundation

/// Display-only reconciliation. No clock reads, I/O, or writes to the profile archive.
struct SessionDisplayMetadata: Equatable, Sendable {
    var title: String
    var lastActivity: Date

    struct Live: Equatable, Sendable {
        var templateTitle: String? = nil
        /// Explicit name from SessionNames, also available for closed sessions.
        var manualTitle: String? = nil
        /// Explicit tab name from AgentPad Rename.
        var customTitle: String? = nil
        var terminalTitle: String? = nil
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
        let activity = [catalog?.lastActivity,
                        binding.flatMap { $0.hasScanProvenance ? $0.lastActivity : nil },
                        live?.hookStateAt].compactMap { $0 }.filter { $0 > .distantPast }.max()
        return Self(title: explicitTitle(live?.manualTitle) ?? explicitTitle(live?.customTitle)
                        ?? custom ?? ai ?? summary ?? prompt ?? terminal ?? template,
                    lastActivity: activity ?? live?.startedAt ?? .distantPast)
    }
}

extension SessionDisplayMetadata.Live {
    @MainActor init(session: Session, manualTitle: String? = nil) {
        self.init(templateTitle: session.displayAgent.title, manualTitle: manualTitle,
                  customTitle: session.customTitle, terminalTitle: session.terminalTitle,
                  hookStateAt: session.hookStateAt, startedAt: session.catalogStartedAt)
    }
}
