import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentAnswerForwardView: View {
    @Bindable var model: AgentAnswerForward
    var close: () -> Void
    var save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrowshape.turn.up.right").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last Agent Answer").font(.title2.weight(.semibold))
                    Text("From \(model.sourceTitle)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit Markdown").font(.headline)
                    TextEditor(text: $model.text).font(.system(.body, design: .monospaced))
                        .padding(6).background(.background).clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Answer Markdown")
                        .disabled(model.sending || model.submitted)
                }.frame(minWidth: 280).padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.online ? "Message preview" : "Preview").font(.headline)
                    ScrollView {
                        Text(ChatMarkdownText.attributed(model.online ? model.outgoingText : model.text))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.background(.background).clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Markdown preview")
                }.frame(minWidth: 280).padding(.leading, 8)
            }.frame(minHeight: 260)
            if model.online {
                if model.truncated {
                    Label("The message exceeds 16 KiB. Forward sends the shortened preview; Copy and Save keep the full text.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Organization")
                        Picker("Organization", selection: $model.organization) {
                            ForEach(model.organizations) { Text($0.title).tag($0.id) }
                        }.labelsHidden().accessibilityLabel("Organization")
                    }
                    GridRow {
                        Text("Channel")
                        HStack {
                            Picker("Channel", selection: $model.channel) {
                                Text("Choose a channel…").tag("")
                                ForEach(model.channels) { Text($0.title).tag($0.id) }
                            }.labelsHidden().accessibilityLabel("Channel")
                            if model.moreChannels != nil { Button("More channels…") { Task { await model.loadChannels(more: true) } } }
                        }
                    }
                    GridRow {
                        Text("Thread")
                        HStack {
                            Picker("Thread", selection: $model.thread) {
                                Text("New channel message").tag("")
                                ForEach(model.threads) { Text($0.title).tag($0.id) }
                            }.labelsHidden().accessibilityLabel("Thread").disabled(model.channel.isEmpty)
                            if model.moreThreads != nil { Button("Older messages…") { Task { await model.loadThreads(more: true) } } }
                        }
                    }
                }.disabled(model.sending || model.submitted || model.loading)
                Text("Posted as \(model.signature)").font(.callout).foregroundStyle(.secondary)
            } else {
                Label("No server connection. You can copy or save the answer.", systemImage: "externaldrive")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.loading { ProgressView().controlSize(.small) }
            if let problem = model.problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let status = model.status { Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Copy as Markdown") { Self.copy(model.text); model.status = "Copied as Markdown." }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Save as…", action: save)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction).disabled(model.sending)
                if model.online {
                    Button(model.sending ? "Sending…" : "Forward") { Task { await model.send() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canSend)
                }
            }
        }
        .padding(20).frame(minWidth: 720, idealWidth: 840, minHeight: 580, idealHeight: 640)
        .background(.background)
        .task { await model.loadChannels() }
        .onChange(of: model.online) { _, online in if online { Task { await model.loadChannels() } } }
        .onChange(of: model.organization) { _, _ in Task { await model.loadChannels() } }
        .onChange(of: model.channel) { _, _ in Task { await model.loadThreads() } }
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

@MainActor
final class AgentAnswerWindow: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: AgentAnswerWindow] = [:]
    private let id = UUID()
    let model: AgentAnswerForward

    static func available(_ session: Session) -> Bool {
        AgentAnswerSource.problem(session) == nil
    }

    static func open(session: Session, store: WorkspaceStore, copyOnly: Bool = false) {
        guard AgentAnswerSource.supports(session) else { return }
        Task {
            do {
                let answer = try await AgentAnswerSource.read(session: session, store: store)
                guard answer.isCurrent() else { throw AgentAnswerTranscript.Problem.changed }
                if copyOnly { AgentAnswerForwardView.copy(answer.text); return }
                let controller = AgentAnswerWindow(model: .init(text: answer.text, caller: answer.caller, sourceTitle: answer.title,
                    service: .shared, sourceIsCurrent: answer.isCurrent))
                windows[controller.id] = controller
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Last Agent Answer"
                alert.informativeText = AgentAnswerForward.message(error)
                alert.addButton(withTitle: "OK")
                if let window = session.engine.view.window { await alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
    }

    init(model: AgentAnswerForward) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Forward Last Agent Answer"
        window.isReleasedWhenClosed = false
        window.appearance = Theme.windowAppearance
        window.contentView = NSHostingView(rootView: AgentAnswerForwardView(model: model,
            close: { [weak self] in self?.close() }, save: { [weak self] in self?.save() }))
        window.minSize = NSSize(width: 720, height: 610)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private func save() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "agent-answer.md"
        let text = model.text
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8); self?.model.status = "Saved as Markdown." }
            catch { self?.model.problem = "The file could not be saved. Choose another location and retry." }
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.active = false
        Self.windows.removeValue(forKey: id)
    }
}
