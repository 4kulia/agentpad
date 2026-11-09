import SwiftUI

struct ChatLocalSearch: View {
    let model: ChatChannelModel
    @State private var query = ""
    @FocusState private var focused: Bool
    private var results: [ChatMessage] { query.isEmpty ? [] : model.searchMessages.filter { $0.text.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search loaded history", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                ChatIconButton(title: "Close search", symbol: "xmark") { model.returnFromNavigation(); model.setSearching(false) }
            }
            HStack {
                Text("Loaded history only · \(results.count) matches").foregroundStyle(ChatAppearance.secondary)
                    #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                    .chatReviewParity("caller/search/count", text: "Loaded history only · \(results.count) matches", colors: ["foreground": ChatAppearance.secondary])
                    #endif
                Spacer()
                if model.hasNavigationReturn { Button("Back to reading") { model.returnFromNavigation() }.buttonStyle(.link)
                        #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                        .chatReviewParity("caller/search/back", text: "Back to reading", colors: ["foreground": Theme.chromeForeground])
                        #endif
                        }
            }.font(Theme.display(10))
            if !query.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(results) { message in
                            Button { model.navigate(to: message) } label: {
                                VStack(alignment: .leading) {
                                    Text(message.text).lineLimit(2)
                                        #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                                        .chatReviewParity("caller/search/" + message.id + "/body", text: message.text, colors: ["foreground": Theme.chromeForeground])
                                        #endif
                                    if message.threadRootId != nil { Text("In thread").foregroundStyle(ChatAppearance.secondary)
                                            #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                                            .chatReviewParity("caller/search/" + message.id + "/thread", text: "In thread", colors: ["foreground": ChatAppearance.secondary])
                                            #endif
                                            }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }.buttonStyle(.plain)
                        }
                        if results.isEmpty { Text("No matches in loaded history").foregroundStyle(ChatAppearance.secondary)
                                #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                                .chatReviewParity("caller/search/empty", text: "No matches in loaded history", colors: ["foreground": ChatAppearance.secondary])
                                #endif
                                }
                    }
                }.frame(maxHeight: 150).font(Theme.display(12))
            }
        }.padding(12).background(Theme.chromeHover).onAppear { focused = true }
            .onExitCommand { model.returnFromNavigation(); model.setSearching(false) }
    }
}
