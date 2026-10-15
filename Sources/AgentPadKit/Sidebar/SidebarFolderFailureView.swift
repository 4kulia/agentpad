import SwiftUI

struct SidebarFolderFailureView: View {
    @Bindable var model: SidebarFoldersModel
    var body: some View {
        if let error = model.error {
            HStack {
                Text(error).foregroundStyle(ChatAppearance.attention)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.failures.isEmpty { Button("Retry") { model.retry() } }
                Button("Dismiss") { model.dismissFailure() }
            }.font(Theme.display(10)).padding(.vertical, 8).disabled(model.retrying)
        }
    }
}
