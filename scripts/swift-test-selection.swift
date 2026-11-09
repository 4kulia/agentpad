import Foundation

struct TestSelection: Decodable {
    let names: [String]
    let filters: [String]
    let skips: [String]
    let specifier: String?
}

let selection = try JSONDecoder().decode(
    TestSelection.self, from: FileHandle.standardInput.readDataToEndOfFile()
)
var skips = selection.skips
if let override = ProcessInfo.processInfo.environment["_SWIFTPM_SKIP_TESTS_LIST"] {
    if override.hasPrefix("/"), FileManager.default.fileExists(atPath: override) {
        if let contents = try? String(contentsOfFile: override, encoding: .utf8) {
            skips = contents.split(separator: "\n").map(String.init)
        }
    } else {
        skips = override.split(separator: ":").map(String.init)
    }
}

// SwiftTestCommand.filteredTests / skippedTests use Foundation String.range,
// backed by NSRegularExpression, on the complete discovered test specifier.
// https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/Commands/SwiftTestCommand.swift#L1335
let selected = selection.names.filter { name in
    let included: Bool
    if !selection.filters.isEmpty {
        included = selection.filters.contains { name.range(of: $0, options: .regularExpression) != nil }
    } else if let specifier = selection.specifier {
        included = name == specifier
    } else {
        included = true
    }
    return included && !skips.contains { name.range(of: $0, options: .regularExpression) != nil }
}
try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(selected))
