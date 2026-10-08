import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentAnswerForwardView: View {
    @Bindable var model: AgentAnswerForward
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
            ViewThatFits(in: .horizontal) {
                HStack { editors }
                VStack { editors }
            }
            destinations
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task { await model.loadInitialDestinations() }
    }
    @ViewBuilder private var editors: some View {
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
    }
    @ViewBuilder private var destinations: some View {
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
                            Picker("Channel", selection: Binding(get: { model.channel }, set: { value in
                                model.channel = value; Task { await model.loadThreads() }
                            })) {
                                Text("Choose a channel…").tag("")
                                if !model.channel.isEmpty, model.submitted, !model.channels.contains(where: { $0.id == model.channel }) {
                                    Text("Saved channel").tag(model.channel)
                                }
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
                                if !model.thread.isEmpty, model.submitted, !model.threads.contains(where: { $0.id == model.thread }) {
                                    Text("Saved thread").tag(model.thread)
                                }
                                ForEach(model.threads) { Text($0.title).tag($0.id) }
                            }.labelsHidden().accessibilityLabel("Thread").disabled(model.channel.isEmpty)
                            if model.moreThreads != nil { Button("Older messages…") { Task { await model.loadThreads(more: true) } } }
                        }
                    }
                }.disabled(model.sending || model.submitted || model.loading)
                Text("Session author: \(model.signature)").font(.callout).foregroundStyle(.secondary)
                Text("Send as yourself: \(model.accountSignature) · visible to the selected channel’s team, including future members.").font(.callout).foregroundStyle(.secondary)
            } else {
                Label("No server connection. You can copy or save the answer.", systemImage: "externaldrive")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.loading { ProgressView().controlSize(.small) }
            if let problem = model.problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let status = model.status { Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Copy as Markdown") { if model.readable { Self.copy(model.text); model.status = "Copied as Markdown." } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Save as…", action: save)
                Spacer()
                if model.submitted {
                    Button("Retry") { Task { await model.retry() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canRetry)
                    Button("Start Over") { model.startAnotherAttempt() }.disabled(!model.canStartAnotherAttempt)
                } else if model.online {
                    Button(model.sending ? "Sending…" : "Send from session") { Task { await model.send() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canSend)
                    Button("Send as Yourself") { Task { await model.sendAsUser() } }.disabled(!model.canSendAsUser)
                }
            }
            Button("Refresh destinations") { Task { await model.refreshDestinations() } }.disabled(model.sending)
            InlineConfirmation(coordinator: model.restartConfirmation)
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
