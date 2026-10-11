import Foundation
import Security
import XCTest
@testable import AgentPadTelegram

final class TelegramDatabaseKeysTests: XCTestCase {
    func testRandomKeyCreatedOnceAndReused() throws {
        let store = MemoryTelegramKeys()
        let keys = TelegramDatabaseKeys(store: store)
        let first = try keys.key(account: "test:a", mayCreate: true)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(try keys.key(account: "test:a", mayCreate: false), first)
        XCTAssertNotEqual(try keys.key(account: "test:b", mayCreate: true), first)
        let count = store.insertions
        let other = TelegramDatabaseKeys(store: store)
        _ = try other.key(account: "production:a", mayCreate: true)
        _ = try other.key(account: "production:a", mayCreate: true)
        XCTAssertEqual(store.insertions, count + 1)
    }
    func testMissingExistingKeyNeverCreatesReplacement() throws {
        let store = MemoryTelegramKeys()
        let keys = TelegramDatabaseKeys(store: store)
        XCTAssertThrowsError(try keys.key(account: "test:existing", mayCreate: false)) {
            XCTAssertEqual($0 as? TelegramStorageError, .keyMissing)
        }
        XCTAssertEqual(store.insertions, 0)
    }
    func testLockedAndWrongLengthKeysFailClosed() throws {
        let store = MemoryTelegramKeys(), keys: TelegramDatabaseKeys
        keys = TelegramDatabaseKeys(store: store)
        store.error = .keyUnavailable
        XCTAssertThrowsError(try keys.key(account: "test:a", mayCreate: true))
        store.error = nil
        try store.insert(Data([1]), account: "test:a")
        XCTAssertThrowsError(try keys.key(account: "test:a", mayCreate: true)) {
            XCTAssertEqual($0 as? TelegramStorageError, .invalidKey)
        }
        XCTAssertEqual(store.insertions, 1)
    }
    func testDeleteIsAccountScopedAndNotSynchronized() throws {
        let store = MemoryTelegramKeys()
        let keys = TelegramDatabaseKeys(store: store)
        let retained = try keys.key(account: "test:b", mayCreate: true)
        _ = try keys.key(account: "test:a", mayCreate: true)
        try keys.delete(account: "test:a")
        XCTAssertEqual(try keys.key(account: "test:b", mayCreate: false), retained)
        XCTAssertNil(try store.read(account: "test:a"))
        let query = TelegramKeychain.query("test:a")
        XCTAssertEqual(query[kSecAttrService as String] as? String, TelegramKeychain.service)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }
}
