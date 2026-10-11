import XCTest

@MainActor
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do { _ = try await expression(); XCTFail(message.isEmpty ? "Expected an error" : message, file: file, line: line) }
    catch { handler(error) }
}

@MainActor
func XCTAssertNoThrowAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression() } catch { XCTFail("\(message) \(error)", file: file, line: line) }
}

@MainActor
func XCTAssertEqualAsync<T: Equatable>(_ expression: @autoclosure () async throws -> T, _ expected: T,
                                      _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertEqual(value, expected, message, file: file, line: line) }
    catch { XCTFail("\(error)", file: file, line: line) }
}

@MainActor
func XCTAssertNilAsync<T>(_ expression: @autoclosure () async throws -> T?, _ message: String = "",
                          file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertNil(value, message, file: file, line: line) }
    catch { XCTFail("\(error)", file: file, line: line) }
}

@MainActor
func XCTAssertFalseAsync(_ expression: @autoclosure () async throws -> Bool, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertFalse(value, message, file: file, line: line) }
    catch { XCTFail("\(error)", file: file, line: line) }
}
