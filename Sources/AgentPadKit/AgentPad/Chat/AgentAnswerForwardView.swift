import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentAnswerForwardView: View {
    @Bindable var model: AgentAnswerForward
    var save: () -> Void
    var cancel: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
          PopupScrollBody {
           VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last Agent Answer").font(.title3.weight(.semibold))
                    Text("From \(model.sourceTitle)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            destinations
            editors
            Text("Session author: \(model.signature)").font(.caption).foregroundStyle(.secondary)
            if model.online {
                Text("Send as yourself: \(model.accountSignature) · visible to the selected channel’s team, including future members.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.loading { ProgressView().controlSize(.small) }
            if let problem = model.problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let status = model.status { Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Copy as Markdown") { if model.readable { Self.copy(model.text); model.status = "Copied as Markdown." } }
                    .keyboardShortcut("c", modifiers: [.command, .shift]).accessibilityIdentifier("forwardCopy")
                Button("Save as…", action: save).accessibilityIdentifier("forwardSave")
                Button("Refresh destinations") { Task { await model.refreshDestinations() } }.disabled(model.sending)
            }
            InlineConfirmation(coordinator: model.restartConfirmation)
           }.padding(24)
          }
          Divider()
          HStack {
              if model.submitted {
                  Button("Retry") { Task { await model.retry() } }.disabled(!model.canRetry)
                  Button("Start Over") { model.startAnotherAttempt() }.disabled(!model.canStartAnotherAttempt)
              } else if model.online {
                  Button("Send as Yourself") { Task { await model.sendAsUser() } }.disabled(!model.canSendAsUser)
                      .accessibilityIdentifier("forwardSendAsYourself")
              }
              Spacer()
              Button("Cancel", action: cancel).disabled(model.sending).accessibilityIdentifier("forwardCancel")
              if !model.submitted, model.online {
                  Button(model.sending ? "Sending…" : "Send from session") { Task { await model.send() } }
                      .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                      .disabled(!model.canSend).accessibilityIdentifier("forwardSend")
              }
          }.padding(.horizontal, 20).padding(.vertical, 13)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("forwardForm")
        .task { await model.loadInitialDestinations() }
    }
    @ViewBuilder private var editors: some View {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit Markdown").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $model.text).font(.system(.body, design: .monospaced))
                        .frame(height: 80).scrollContentBackground(.hidden)
                        .padding(6).background(Theme.chromeMuted.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.chromeMuted.opacity(0.2)))
                        .accessibilityLabel("Answer Markdown")
                        .accessibilityIdentifier("forwardMarkdown")
                        .disabled(model.sending || model.submitted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.online ? "Message preview" : "Preview").font(.headline)
                    PopupScrollBody(maxHeight: 140) {
                        Text(ChatMarkdownText.attributed(model.online ? model.outgoingText : model.text))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.background(Theme.chromeMuted.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.chromeMuted.opacity(0.2)))
                        .accessibilityLabel("Markdown preview")
                }
    }
    @ViewBuilder private var destinations: some View {
            if model.online {
                if model.truncated {
                    Label("The message exceeds 16 KiB. Forward sends the shortened preview; Copy and Save keep the full text.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Organization").font(Theme.display(11)).foregroundStyle(.secondary)
                            Picker("Organization", selection: $model.organization) {
                                ForEach(model.organizations) { Text($0.title).tag($0.id) }
                            }.labelsHidden().accessibilityLabel("Organization").frame(maxWidth: .infinity)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Channel").font(Theme.display(11)).foregroundStyle(.secondary)
                            HStack {
                                Picker("Channel", selection: Binding(get: { model.channel }, set: { value in
                                    model.channel = value; Task { await model.loadThreads() }
                                })) {
                                    Text("Choose a channel…").tag("")
                                    if !model.channel.isEmpty, model.submitted, !model.channels.contains(where: { $0.id == model.channel }) {
                                        Text("Saved channel").tag(model.channel)
                                    }
                                    ForEach(model.channels) { Text($0.title).tag($0.id) }
                                }.labelsHidden().accessibilityLabel("Channel").frame(maxWidth: .infinity)
                                if model.moreChannels != nil { Button("More channels…") { Task { await model.loadChannels(more: true) } } }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Thread").font(Theme.display(11)).foregroundStyle(.secondary)
                        HStack {
                            Picker("Thread", selection: $model.thread) {
                                Text("New channel message").tag("")
                                if !model.thread.isEmpty, model.submitted, !model.threads.contains(where: { $0.id == model.thread }) {
                                    Text("Saved thread").tag(model.thread)
                                }
                                ForEach(model.threads) { Text($0.title).tag($0.id) }
                            }.labelsHidden().accessibilityLabel("Thread").frame(maxWidth: .infinity).disabled(model.channel.isEmpty)
                            if model.moreThreads != nil { Button("Older messages…") { Task { await model.loadThreads(more: true) } } }
                        }
                    }
                }.disabled(model.sending || model.submitted || model.loading)
            } else {
                Label("No server connection. You can copy or save the answer.", systemImage: "externaldrive")
                    .font(.callout).foregroundStyle(.secondary)
            }
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
