import AgentPadTelegram
import AppKit
import Foundation
import Observation
import SwiftUI

/// Runtime-only presentation boundary for the generic chooser. Telegram
/// references are profile-bound and are never encoded into workspace state.
@MainActor @Observable final class SidebarFolderActions {
    static let shared = SidebarFolderActions()
    struct Request: Identifiable, Equatable {
        let id = UUID()
        var item: SidebarItemReference
        var binding: TelegramProfileBinding?
        var windowID: UUID?
        var anchor: String?
    }
    var request: Request?
    let folders: SidebarFoldersModel
    init(folders: SidebarFoldersModel = SidebarFoldersModel()) { self.folders = folders }
    @MainActor @Observable final class Draft {
        var query = ""
        var selection: UUID?
        var newName: String?
        var newFolderID: UUID?
        var working = false
        var hasText: Bool { !query.isEmpty || newName != nil }
    }
    private struct Key: Hashable {
        let window: UUID
        let item: SidebarItemReference
        let binding: TelegramProfileBinding?
    }
    private var drafts: [Key: Draft] = [:]
    private var pages: [Key: PopupCoordinator.NativePage] = [:]
    func present(_ item: SidebarItemReference, binding: TelegramProfileBinding? = nil, windowID: UUID? = nil, anchor: String? = nil) {
        if case .telegram = item, binding == nil { return }
        folders.start()
        let request = Request(item: item, binding: binding, windowID: windowID, anchor: anchor)
        self.request = request
        let stores = TabRouter.shared.stores().filter { !$0.isTerminated }
        let owner = windowID.flatMap { id in stores.first { $0.windowID == id } }
            ?? (windowID == nil ? stores.first { $0.popups.window === NSApp.keyWindow } : nil)
        guard let owner else { return }
        let key = Key(window: owner.windowID, item: item, binding: binding)
        if let page = pages[key] { owner.popups.presentNative(page); return }
        let draft = drafts[key] ?? Draft()
        drafts[key] = draft
        let page = PopupCoordinator.NativePage(title: "Add to folder…", keepsDraft: { draft.hasText })
        let coordinator = owner.popups, folders = self.folders
        page.onDismiss = { [weak self] reason in
            guard let self else { return }
            if self.request?.item == item && self.request?.windowID == windowID { self.request = nil }
            if reason != .dismiss || !draft.hasText { self.drafts[key] = nil; self.pages[key] = nil }
        }
        page.content = { [weak page, weak coordinator] in
            AnyView(AddToFolderChooser(request: request, model: folders, draft: draft, cancel: {
                guard let page else { return }; coordinator?.dismiss(page, reason: .cancel)
            }, dismiss: {
                guard let page else { return }; coordinator?.dismiss(page, reason: .applied)
            }))
        }
        if coordinator.presentNative(page) { pages[key] = page }
    }
    func invalidateTelegram(binding: TelegramProfileBinding?) {
        if case .telegram = request?.item, request?.binding != binding { request = nil }
        for (key, page) in pages where key.binding != nil && key.binding != binding {
            if let owner = TabRouter.shared.stores().first(where: { $0.windowID == key.window }) {
                owner.popups.dismiss(page, reason: .cancel)
            }
            pages[key] = nil; drafts[key] = nil
        }
    }
}
