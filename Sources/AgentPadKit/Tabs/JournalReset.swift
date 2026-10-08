import Foundation
import GRDB

extension ChatJournal {
    /// A corrupt database cannot provide trustworthy counts. Say so instead of
    /// implying that an empty query means no data will be lost.
    var resetLosses: String {
        (try? queue.read { db in
            let tables = [("run_commands", "Queued commands and results"), ("assignments", "Publication assignments"),
                          ("approvals", "Approvals"), ("runs", "Run records"), ("automatic_request_blocks", "Automatic-request blocks"),
                          ("channel_authorities", "Channel permissions"), ("publication_surfaces", "Local publication bindings")]
            return try tables.map { table, label in "\(label): \(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0)" }.joined(separator: ", ")
        }) ?? "The journal cannot be read; loss counts are unknown."
    }
    static let resetConsequences = "The executor command queue (including undelivered results), publication assignments, approvals, run records, automatic-request blocks, channel authority and local publication bindings are forgotten. The connection will recheck its server state. This does not stop processes recorded in the journal. The journal and its SQLite sidecars are backed up before resetting."
}

extension ProcessTabs {
    func resetJournal(service: ChatService = .shared, teams: TeamTabs = .shared) {
        guard let scope = teams.currentScope,
              let session = router.open(.teamActivity(scope)), let state = session.tabState else { return }
        teams.select("delivery", state: state)
        let problem = service.journalProblem
        let identity = FileIdentity(service.files.journalURL)
        let losses = service.journal?.resetLosses
        state.confirmation.request(.init(tabID: session.id, targetID: "run-journal"),
            title: "Reset the run journal?",
            consequences: ChatJournal.resetConsequences + "\n" + (losses ?? "The damaged journal cannot be read; loss counts are unknown."),
            verb: "Reset journal", destructive: true,
            stillValid: { service.journalProblem == problem && FileIdentity(service.files.journalURL) == identity && service.journal?.resetLosses == losses },
            operation: {
                try service.resetJournal()
                state.message = "The run journal was reset. Backup: " + (service.journal?.resetBackup?.path ?? "no previous journal existed")
            })
    }
}
