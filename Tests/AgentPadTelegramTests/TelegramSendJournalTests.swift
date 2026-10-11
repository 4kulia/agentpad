import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramSendJournalTests: XCTestCase {
    func testRecoveryIntentSurvivesInterruptedMetadataWriteAndSevenDayCleanup() throws {
        let fixture = try TelegramFixture(), key = Data(repeating: 9, count: 32), now = Date()
        let journal = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now)
        let id = try journal.create(chat: 10, draft: .init(text: "Review me"), parts: [.init()], now: now)
        // Simulate stopping between the encrypted vault and intent writes.
        try TelegramProfileStore.write(Data("[]".utf8), to: fixture.directory.appendingPathComponent("conversation/operations.json"))
        let restored = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(restored.operation(id)?.parts.first?.state, .queued)
        XCTAssertEqual(restored.recovered(id)?.text, "Review me")
        try restored.removeRecovery(id)
        let cleaned = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now.addingTimeInterval(8 * 86400))
        XCTAssertNil(cleaned.operation(id)); XCTAssertNil(cleaned.recovered(id))
    }
    func testRecoveryLimitBlocksWithoutEvictingUnsentVersions() throws {
        let fixture = try TelegramFixture()
        let journal = try TelegramSendJournal(directory: fixture.directory, databaseKey: Data(repeating: 1, count: 32), now: Date())
        for n in 0..<10 { _ = try journal.create(chat: 10, draft: .init(text: "Draft \(n)"), parts: [.init()], now: Date()) }
        XCTAssertThrowsError(try journal.create(chat: 10, draft: .init(text: "Eleventh"), parts: [.init()], now: Date()))
        XCTAssertEqual(journal.operations.count, 10)
        let first = try XCTUnwrap(journal.operations.first)
        XCTAssertEqual(journal.recovered(first.id)?.text, "Draft 0")
    }
    func testFileHashAndPermissionsAreRecheckedBeforeSending() throws {
        let fixture = try TelegramFixture()
        let journal = try TelegramSendJournal(directory: fixture.directory, databaseKey: Data(repeating: 2, count: 32), now: Date())
        let file = try journal.stage(Data("first".utf8), name: "notes.txt", mime: "text/plain", width: 0, height: 0)
        try journal.validate(file)
        try Data("other".utf8).write(to: journal.stageURL(file.id))
        XCTAssertThrowsError(try journal.validate(file))
        XCTAssertThrowsError(try journal.stage(Data("x".utf8), name: "../notes.txt", mime: "text/plain", width: 0, height: 0))
    }
    func testPendingSurvivesRestartAndSubmittingBecomesUnknown() throws {
        let fixture = try TelegramFixture(), key = Data(repeating: 3, count: 32), now = Date()
        let journal = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now)
        let operation = try journal.create(chat: 10, draft: .init(text: "Retained"), parts: [.init(), .init(), .init()], now: now)
        try journal.update(operation) { $0.parts[0].state = .pending; $0.parts[0].messageID = 12; $0.parts[1].state = .submitting }
        let restored = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now.addingTimeInterval(86400 * 8))
        XCTAssertEqual(restored.operations.first?.parts.map(\.state), [.pending, .unknown, .queued])
        XCTAssertEqual(restored.recovered(operation)?.text, "Retained")
        XCTAssertThrowsError(try TelegramSendJournal(directory: fixture.directory, databaseKey: Data(repeating: 4, count: 32), now: now))
    }
    func testLaunchSweepsOrphanedStagingButPreservesDraftsAndRecovery() throws {
        let fixture = try TelegramFixture(), key = Data(repeating: 5, count: 32), now = Date()
        let journal = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now)
        var files: [TelegramStagedAttachment] = []
        for index in 0..<20 { files.append(try journal.stage(Data([1]), name: "\(index).txt", mime: "text/plain", width: 0, height: 0)) }
        try journal.saveDraft(.init(attachments: [files[0]]), chat: 10)
        let pending = try journal.create(chat: 20, draft: .init(attachments: [files[1]]), parts: [.init(attachment: files[1].id)], now: now)
        try journal.update(pending) { $0.parts[0].state = .pending }
        let queued = try journal.create(chat: 30, draft: .init(attachments: [files[2]]), parts: [.init(attachment: files[2].id)], now: now)
        // File write completed but staged.json did not; an import was interrupted too.
        let untracked = journal.staging.appendingPathComponent(UUID().uuidString)
        try TelegramProfileStore.createDirectory(untracked)
        try TelegramProfileStore.write(Data([1]), to: untracked.appendingPathComponent("orphan.txt"))
        let abandonedImport = try journal.importDirectory()
        XCTAssertThrowsError(try journal.stage(Data([1]), name: "full.txt", mime: "text/plain", width: 0, height: 0))

        let restored = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now)
        for file in files.prefix(3) { try restored.validate(file) }
        for file in files.dropFirst(3) { XCTAssertFalse(FileManager.default.fileExists(atPath: journal.stageURL(file.id).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedImport.path))
        XCTAssertEqual(restored.operation(queued)?.parts[0].state, .queued)
        for index in 0..<17 { _ = try restored.stage(Data([1]), name: "new-\(index).txt", mime: "text/plain", width: 0, height: 0) }
        XCTAssertThrowsError(try restored.stage(Data([1]), name: "full.txt", mime: "text/plain", width: 0, height: 0))
    }
    func testRestoreTransfersFileOwnershipAndReleasesTheWholeByteQuota() throws {
        let fixture = try TelegramFixture(), key = Data(repeating: 6, count: 32), now = Date()
        let journal = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now)
        let bytes = Data(repeating: 1, count: TelegramFeedLimits.fileBytes)
        let a = try journal.stage(bytes, name: "a.txt", mime: "text/plain", width: 0, height: 0)
        let b = try journal.stage(bytes, name: "b.txt", mime: "text/plain", width: 0, height: 0)
        let operation = try journal.create(chat: 10, draft: .init(text: "caption", attachments: [a, b]),
                                           parts: [.init(attachment: a.id), .init(attachment: b.id)], now: now)
        try journal.update(operation) { $0.parts[0].state = .sent; $0.parts[1].state = .failed }
        let draft = try journal.restore(operation)
        XCTAssertEqual(draft.attachments, [b]); XCTAssertEqual(draft.text, "")
        XCTAssertNil(journal.recovered(operation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.staging.appendingPathComponent(a.id.uuidString).path))
        try journal.validate(b)
        let restarted = try TelegramSendJournal(directory: fixture.directory, databaseKey: key, now: now)
        try restarted.validate(b) // the composer now owns this file
        let resent = try restarted.create(chat: 10, draft: draft, parts: [.init(attachment: b.id)], now: now)
        try restarted.saveDraft(.init(), chat: 10)
        try restarted.update(resent) { $0.parts[0].state = .sent }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.staging.appendingPathComponent(b.id.uuidString).path))
        for index in 0..<5 { _ = try restarted.stage(bytes, name: "new-\(index).txt", mime: "text/plain", width: 0, height: 0) }
        XCTAssertThrowsError(try restarted.stage(Data([1]), name: "full.txt", mime: "text/plain", width: 0, height: 0))
    }
}
