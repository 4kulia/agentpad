import AgentPadTelegram
import SwiftUI

struct TelegramChatActions: View {
    var row: TelegramChatRow
    var model = TelegramService.chats
    var windowID: UUID?
    var anchor: String?
    let binding: TelegramProfileBinding?
    init(row: TelegramChatRow, model: TelegramChatsModel = TelegramService.chats, windowID: UUID? = nil, anchor: String? = nil) {
        self.row = row; self.model = model; self.windowID = windowID; self.anchor = anchor; binding = model.snapshot.binding
    }
    var body: some View {
        if row.canMarkAsRead { Button("Mark as read") { Task { await model.markAsRead(row, binding: binding) } } }
        Button("Add to folder…") {
            guard let binding, binding == model.snapshot.binding, row.id.account == binding.account, row.id.environment == binding.environment else { return }
            SidebarFolderActions.shared.present(.telegram(row.id.chat), binding: binding, windowID: windowID, anchor: anchor)
        }
        if row.canFollow {
            Toggle(row.followTitle, isOn: Binding(get: { row.followEnabled }, set: { _ in Task { await model.follow(row, binding: binding) } }))
                .disabled(row.followActivating)
        }
    }
}

struct TelegramReadNoticeView: View {
    var model = TelegramService.chats
    var body: some View {
        if let notice = model.readNotice {
            HStack {
                Text(notice.message)
                if notice.canRetry { Button("Retry") { Task { await model.retryMarkAsRead() } } }
                Button { model.readNotice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss")
            }.font(Theme.display(11)).padding(8)
        }
    }
}
