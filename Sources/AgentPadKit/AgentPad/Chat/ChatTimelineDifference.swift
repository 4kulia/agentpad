import Foundation

/// Indexes are sequential: remove absent IDs in descending order, then walk the
/// target order inserting/moving in the already-mutated array. The coordinator
/// changes its data source before each corresponding AppKit operation.
struct ChatTimelineDifference: Equatable, Sendable {
    typealias RowID = NativeTimelineSnapshot.RowID
    enum Operation: Equatable, Sendable {
        case remove(Int)
        case insert(Int, RowID)
        case move(from: Int, to: Int)
    }
    let operations: [Operation]

    init?(from old: [RowID], to new: [RowID]) {
        guard Set(old).count == old.count, Set(new).count == new.count else { return nil }
        let retained = Set(new)
        var current = old
        var result: [Operation] = []
        for index in current.indices.reversed() where !retained.contains(current[index]) {
            current.remove(at: index); result.append(.remove(index))
        }
        for (index, id) in new.enumerated() {
            if index < current.count, current[index] == id { continue }
            if let source = current.firstIndex(of: id) {
                current.insert(current.remove(at: source), at: index)
                result.append(.move(from: source, to: index))
            } else {
                current.insert(id, at: index); result.append(.insert(index, id))
            }
        }
        operations = result
    }
}
