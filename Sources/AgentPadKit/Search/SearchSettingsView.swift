import SwiftUI

struct SearchSettingsView: View {
    @Bindable var controller: SearchIndexController
    @State private var confirmingClear = false
    @State private var busy = false
    var autostart = true
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Search").font(Theme.display(24, weight: .semibold))
            Text("Search team messages and conversations saved on this Mac.").foregroundStyle(ChatAppearance.secondary)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Index agent conversations").font(.headline)
                        Text("Search the text of Claude Code and Codex conversations. New and updated conversations are indexed in the background.")
                            .font(.callout).foregroundStyle(ChatAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Index agent conversations", isOn: Binding(get: { controller.status.state.enabled }, set: { value in
                        run { if value { await controller.enable() } else { await controller.disable() } }
                    })).labelsHidden().toggleStyle(.switch).disabled(busy || controller.status.state.cleared || controller.status.state.clearing)
                }
                Label("Agent conversations are indexed only on this Mac and never uploaded.", systemImage: "lock")
                    .font(.callout).foregroundStyle(ChatAppearance.accent)
                Divider()
                HStack {
                    Label(controller.status.label, systemImage: controller.status.scanning ? "arrow.triangle.2.circlepath" : controller.status.state.enabled ? "checkmark.circle" : "pause.circle")
                    Spacer()
                    Text(controller.status.bytes == 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: controller.status.bytes, countStyle: .file)).monospacedDigit()
                }.font(.callout)
                if controller.status.scanning {
                    ProgressView(value: Double(controller.status.processed), total: Double(max(1, controller.status.discovered)))
                }
                Text("\(controller.status.processed) of \(controller.status.discovered) conversations · \(controller.status.skipped) skipped")
                    .font(.caption).foregroundStyle(ChatAppearance.secondary).monospacedDigit()
                Text(statusExplanation).font(.callout).foregroundStyle(ChatAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if controller.status.state.cleared {
                        Button("Rebuild index") { run { await controller.enable(rebuild: true) } }.buttonStyle(.borderedProminent)
                    } else if !controller.status.state.enabled {
                        Button("Enable indexing") { run { await controller.enable() } }.buttonStyle(.borderedProminent)
                    } else {
                        Button(controller.status.state.paused ? "Resume indexing" : "Pause indexing") { run { await controller.pause(!controller.status.state.paused) } }
                        Button("Rescan") { Task { await controller.index.refresh(force: true); await controller.updateStatus() } }.disabled(controller.status.scanning || controller.status.state.paused)
                        Button("Rebuild index") { run { await controller.enable(rebuild: true) } }
                    }
                    if !controller.status.state.cleared || controller.status.state.clearing || controller.status.bytes > 0 {
                        Button("Clear index", role: .destructive) { confirmingClear = true }
                    }
                }.disabled(busy)
                if confirmingClear {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Clear the local search index?").font(.headline)
                        Text("This removes the index and turns indexing off until you choose Rebuild index. Your original conversations and session names are kept.").font(.callout)
                        HStack {
                            Button("Clear index", role: .destructive) { confirmingClear = false; run { await controller.clear() } }
                            Button("Cancel") { confirmingClear = false }
                        }.disabled(busy)
                    }.padding(14).background(ChatAppearance.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if let error = controller.actionError { Text(error).foregroundStyle(ChatAppearance.failure).font(.callout) }
            }.padding(20).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.chromeSeparator))
            VStack(alignment: .leading, spacing: 8) {
                Label("Coverage", systemImage: "externaldrive").font(.headline)
                Text("Claude Code and Codex: user and assistant text, Markdown and code. Other agents: names, first prompts and folders.")
                Text("Tool output, reasoning, system instructions, executor conversations, project files, attachments and remote machines are excluded.")
                Text("Large records and unavailable sources produce partial results. The index uses up to 1 GB, including working files.")
            }.font(.callout).foregroundStyle(ChatAppearance.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Message search", systemImage: "text.bubble").font(.headline)
                Text("Messages are searched on your connected team server. Clearing this local index does not change team messages.")
            }.font(.callout).foregroundStyle(ChatAppearance.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("All sessions · ⌘⇧H", systemImage: "clock").font(.headline)
                Text("Session names, first prompts and folders remain searchable when conversation indexing is off.")
            }.font(.callout).foregroundStyle(ChatAppearance.secondary)
        }.padding(28).frame(maxWidth: 780, alignment: .leading)
            .foregroundStyle(Theme.chromeForeground).background(ChatAppearance.surface).tint(ChatAppearance.accent)
            .task { if autostart { controller.start() } }
    }
    private var statusExplanation: String {
        if controller.status.state.cleared { return "Indexing is off. Choose Rebuild index to start again." }
        if !controller.status.state.enabled { return "Text search and background updates are off. A saved index stays on this Mac until you clear it." }
        if controller.status.state.paused { return "Background updates are paused. You can still search the existing index." }
        return "Stored in AgentPad’s Application Support folder. Rebuilt from the original agent conversation files."
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await action(); busy = false }
    }
}
