import AppKit
import SwiftUI

struct SearchEverywhereField: View {
    let store: WorkspaceStore
    @Bindable var model: EverywhereSearchModel
    var body: some View {
        HStack(spacing: 7) {
            if model.returnAvailable {
                Button { model.dismiss(); model.openResults(); model.returnAvailable = false } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(.plain).help("Back to results").accessibilityLabel("Back to results")
            }
            Image(systemName: "magnifyingglass").foregroundStyle(ChatAppearance.secondary)
            SearchTextFieldRepresentable(store: store, model: model)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear query")
            }
            Text("⌘P").font(.system(size: 10)).foregroundStyle(ChatAppearance.secondary)
        }.font(Theme.display(11)).padding(.horizontal, 10).frame(maxWidth: 470).frame(height: 24)
            .background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.fieldFocused ? ChatAppearance.accent : Theme.chromeSeparator))
            .background(SearchInteractionRegion(focus: model.fieldFocus, suggestions: false))
            .padding(.horizontal, 12)
            .onChange(of: model.query) { _, _ in model.update() }
            .onChange(of: [store.active?.id, store.active?.activePaneId, store.active?.activeSession?.id]) { _, _ in model.dismiss() }
            .onChange(of: model.names.values) { _, _ in model.localSearch() }
            .onChange(of: model.catalog.revision) { _, _ in model.localSearch() }
            .onChange(of: ChatOrgCurrent.identity()) { _, _ in
                model.connectionChanged()
            }
            .onChange(of: ChatService.shared.searchAvailability) { _, _ in
                model.messages.checkContext(); model.serverSearch(debounce: true)
            }
    }
}

struct SearchSnippetText: View {
    let text: String
    let query: String
    var body: some View {
        Text(highlighted).font(Theme.display(12)).lineLimit(3)
    }
    private var highlighted: AttributedString {
        var result = AttributedString(text)
        for word in (try? SearchQuery(query).words) ?? [] {
            var start = result.startIndex
            while start < result.endIndex, let range = result[start...].range(of: word, options: .caseInsensitive) {
                result[range].backgroundColor = ChatAppearance.accent.opacity(0.16)
                result[range].font = .system(size: 12, weight: .semibold)
                start = range.upperBound
            }
        }
        return result
    }
}

struct SearchSuggestionsView: View {
    @Bindable var model: EverywhereSearchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.quick.isEmpty {
                        heading("Quick matches")
                        ForEach(model.quick) { item in
                            row("q:" + item.id) {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol).frame(width: 20)
                                    Text(item.title).lineLimit(1); Spacer(); Text(item.subtitle).font(.caption).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    if model.hasTeam, model.source != .sessions {
                        heading("Messages")
                        if model.messages.loading { ProgressView().controlSize(.small).padding(8) }
                        ForEach(Array(model.messages.hits.prefix(3))) { hit in
                            row("m:" + hit.id) { SearchSnippetText(text: hit.snippet, query: model.query) }
                        }
                        if let notice = model.messages.error ?? model.messages.availability().message { noticeText(notice) }
                    }
                    if model.source != .messages {
                        heading("Agent sessions")
                        if model.localLoading { ProgressView().controlSize(.small).padding(8) }
                        ForEach(Array(model.local.prefix(3))) { hit in
                            row("l:" + hit.id) { localRow(hit, names: model.names.values) }
                        }
                        ForEach(Array(model.metadata.prefix(3))) { record in
                            row("d:" + record.id) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.resolvedTitle(manual: model.names.values[record.nameKey])).lineLimit(1)
                                    Text("Metadata · \(record.agentId) · \(record.cwdPath)").font(.caption).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                                }
                            }
                        }
                        SearchIndexNotice(controller: model.indexing)
                        if let error = model.localError { noticeText(error) }
                    }
                    if !model.query.isEmpty, (try? SearchQuery(model.query)) == nil { noticeText(SearchProblem.invalidQuery.localizedDescription) }
                    if !model.hasTeam { noticeText(ChatSearchAvailability.noTeam.message!) }
                }.padding(8)
            }.frame(maxHeight: 490)
            Divider()
            Button { model.showResults() } label: { HStack { Text("View all results"); Spacer(); Text("⌘↵").foregroundStyle(ChatAppearance.secondary) }.padding(12) }
                .buttonStyle(.plain)
        }.background(ChatAppearance.surface, in: RoundedRectangle(cornerRadius: 10))
            .background(SearchInteractionRegion(focus: model.fieldFocus, suggestions: true))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.chromeSeparator))
            .shadow(color: .black.opacity(0.2), radius: 14, y: 5).foregroundStyle(Theme.chromeForeground)
    }
    private func row<Content: View>(_ id: String, @ViewBuilder content: () -> Content) -> some View {
        Button { model.activate(id) } label: { content().frame(maxWidth: .infinity, alignment: .leading).padding(9).contentShape(Rectangle()) }
            .buttonStyle(.plain).background(model.selected == id ? ChatAppearance.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityAddTraits(model.selected == id ? [.isSelected] : [])
    }
    private func heading(_ text: String) -> some View { Text(text).font(Theme.display(10, weight: .semibold)).foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 9).padding(.top, 9) }
    private func noticeText(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(ChatAppearance.secondary).padding(9) }
    private func localRow(_ hit: LocalSearchHit, names: [SessionNameKey: String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hit.record.resolvedTitle(manual: names[hit.record.nameKey])).font(Theme.display(12, weight: .medium)).lineLimit(1)
            SearchSnippetText(text: hit.turn.text, query: model.query)
            Text("\(hit.record.agentId) · Turn \(hit.turn.ordinal)\(hit.record.automatic ? " · Automatic" : "")").font(.caption).foregroundStyle(ChatAppearance.secondary)
        }
    }
}

struct SearchIndexNotice: View {
    @Bindable var controller: SearchIndexController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !controller.status.state.enabled {
                Text("Agent conversations are indexed only on this Mac and never uploaded.").font(.caption).foregroundStyle(ChatAppearance.secondary)
                Button(controller.status.state.cleared ? "Rebuild index" : "Enable indexing") {
                    Task { await controller.enable(rebuild: controller.status.state.cleared) }
                }.controlSize(.small)
            } else if controller.status.scanning || controller.status.partial || controller.status.state.paused || controller.status.error != nil {
                HStack {
                    Text(controller.status.label).font(.caption).foregroundStyle(ChatAppearance.secondary)
                    Button("Search settings") { SupportTabs.shared.settings(.search) }.font(.caption).buttonStyle(.plain)
                }
            }
            if let error = controller.actionError { Text(error).font(.caption).foregroundStyle(ChatAppearance.failure) }
        }.padding(9)
    }
}
