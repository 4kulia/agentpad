import AgentPadTelegram
import Foundation
import Observation
import SwiftUI

/// Layout reports are in the folder scroll view's coordinate space, so lazy
/// prefetch alone cannot load every expanded list. Release before adding windows
/// to keep the provider's single five-window budget valid during a scroll.
@MainActor @Observable final class SidebarFolderViewport {
    enum Slot: Hashable { case telegram(TelegramListKey, Int), custom(UUID, Int) }
    @ObservationIgnored private var frames: [Slot:CGRect] = [:]
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private let owner = UUID()

    var height: CGFloat = 0
    func update(_ slot: Slot, frame: CGRect?, telegram: TelegramChatsModel, folders: SidebarFoldersModel) {
        frames[slot] = frame
        schedule(telegram: telegram, folders: folders)
    }
    func schedule(telegram: TelegramChatsModel, folders: SidebarFoldersModel) {
        task?.cancel()
        task = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            let visible = self.frames.filter { $0.value.maxY > 0 && $0.value.minY < self.height }
                .sorted { $0.value.minY < $1.value.minY }
            var windows: [TelegramListKey:Set<Int>] = [:], ranges: [UUID:Range<Int>] = [:]
            var direct: [(TelegramListKey,Int)] = []
            for (slot, _) in visible {
                switch slot {
                case .telegram(let list, let start): direct.append((list,start))
                case .custom(let id, let index):
                    let old = ranges[id] ?? index..<(index + 1)
                    ranges[id] = min(index,old.lowerBound)..<max(index + 1,old.upperBound)
                }
            }
            for (list,start) in direct.prefix(5) { windows[list, default: []].insert(start) }
            var budget = 5 - windows.values.reduce(0) { $0 + $1.count }
            for (list,start) in direct {
                for neighbor in [start - 50,start + 50] where budget > 0 && neighbor >= 0 {
                    guard neighbor < (telegram.snapshot.lists.first { $0.key == list }?.capacity ?? 0), windows[list]?.contains(neighbor) != true else { continue }
                    windows[list, default: []].insert(neighbor); budget -= 1
                }
            }
            var customBudget = 76
            for id in ranges.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                let range = ranges[id]!, size = min(range.count, customBudget)
                ranges[id] = range.lowerBound..<(range.lowerBound + size); customBudget -= size
            }
            for id in ranges.keys.sorted(by: { $0.uuidString < $1.uuidString }) where customBudget > 0 {
                let range = ranges[id]!, count = folders.custom[id]?.items.count ?? range.upperBound
                let before = min(25,range.lowerBound,customBudget)
                let after = min(25,max(0,count - range.upperBound),customBudget - before)
                ranges[id] = (range.lowerBound - before)..<(range.upperBound + after)
                customBudget -= before + after
            }
            folders.viewport(ranges)
            let ordered = direct.map { TelegramChatsModel.Window(list: $0.0,start: $0.1) }
                + windows.flatMap { key, starts in starts.sorted().map { TelegramChatsModel.Window(list: key,start: $0) } }
            var seen = Set<TelegramChatsModel.Window>()
            telegram.folderViewport(ordered.filter { seen.insert($0).inserted },owner: self.owner)
        }
    }
    func clear(telegram: TelegramChatsModel, folders: SidebarFoldersModel) {
        task?.cancel(); frames = [:]; folders.viewport([:])
        telegram.folderViewport([],owner: owner)
    }
}

extension View {
    func folderViewport(_ slot: SidebarFolderViewport.Slot, tracker: SidebarFolderViewport,
                        telegram: TelegramChatsModel, folders: SidebarFoldersModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("sidebar-folders")) } action: {
            tracker.update(slot, frame: $0, telegram: telegram, folders: folders)
        }.onDisappear { tracker.update(slot, frame: nil, telegram: telegram, folders: folders) }
    }
}
