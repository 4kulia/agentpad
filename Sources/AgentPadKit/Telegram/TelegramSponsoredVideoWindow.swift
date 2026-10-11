import AgentPadTelegram
import AppKit
import Observation
import SwiftUI

/// A single actual fullscreen video surface. Flags follow the window state,
/// never a sheet or the user's uncompleted request to enter fullscreen.
@MainActor @Observable final class TelegramSponsoredVideoWindow: NSObject, NSWindowDelegate {
    static let shared = TelegramSponsoredVideoWindow()
    private(set) var fullscreen = false
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private weak var model: TelegramConversationModel?
    @ObservationIgnored private var pane: UUID?
    @ObservationIgnored private var epoch: UUID?
    @ObservationIgnored private var ref: TelegramSponsoredRef?
    @ObservationIgnored private let owner = UUID()
    func show(_ ad: TelegramSponsoredMessage, model: TelegramConversationModel, pane: UUID, openChat: @escaping (TelegramChatID) -> Void) {
        guard let media = ad.media.first(where: { $0.role == .content && $0.kind == .video }), let url = media.url,
              let asset = TelegramSponsoredRenderCache.shared.assets[url], asset.movie != nil else { model.notice = "Ad video unavailable · Retry"; return }
        if ref == ad.ref, self.model === model, let window { window.makeKeyAndOrderFront(nil); return }
        close()
        self.model = model; self.pane = pane; epoch = model.snapshot.epoch; ref = ad.ref
        TelegramSponsoredRenderCache.shared.retain(owner, media: ad.media)
        TelegramSponsoredPlayback.shared.play(owner: owner, asset: asset, url: url, muted: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = ad.recommended ? "Recommended · \(ad.title)" : "Sponsored · \(ad.title)"
        window.isReleasedWhenClosed = false; window.collectionBehavior = [.fullScreenPrimary]; window.delegate = self
        self.window = window
        let content = TelegramSponsoredVideoContent(ad: ad, controller: self) { [weak model, weak self] mediaClick in
            guard let model, let self, model.currentAd(ad.ref) != nil else { return }
            let target: TelegramSponsoredClick = mediaClick ? .fullscreenMedia : self.fullscreen ? .fullscreenButton : .button
            model.sponsoredAction(.click(ad.ref, target, confirmed: false), pane: pane, ref: ad.ref, openChat: openChat)
        }
        window.contentView = NSHostingView(rootView: content)
        window.center(); window.makeKeyAndOrderFront(nil); window.toggleFullScreen(nil)
    }
    func reconcile(model: TelegramConversationModel) {
        guard self.model === model else { return }
        if epoch != model.snapshot.epoch || ref.flatMap(model.currentAd) == nil { close() }
    }
    func confirm(_ url: URL, ref: TelegramSponsoredRef, model: TelegramConversationModel, pane: UUID,
                 target: TelegramSponsoredClick, openChat: @escaping (TelegramChatID) -> Void) -> Bool {
        guard self.model === model, self.ref == ref, let window else { return false }
        let alert = NSAlert()
        alert.messageText = "Open \(url.host ?? "website")?"; alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open website"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak model] response in
            guard response == .alertFirstButtonReturn, let model, model.currentAd(ref) != nil, model.panes.contains(pane) else { return }
            model.sponsoredAction(.click(ref, target, confirmed: true), pane: pane, ref: ref, openChat: openChat)
        }
        return true
    }
    func close(pane: UUID? = nil) {
        guard pane == nil || pane == self.pane else { return }
        let old = window; window = nil; old?.delegate = nil; old?.close(); clear()
    }
    private func clear() {
        TelegramSponsoredRenderCache.shared.release(owner)
        model = nil; pane = nil; epoch = nil; ref = nil; fullscreen = false
    }
    func windowWillClose(_ notification: Notification) { window = nil; clear() }
    func windowDidEnterFullScreen(_ notification: Notification) { fullscreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullscreen = false }
}

private struct TelegramSponsoredVideoContent: View {
    let ad: TelegramSponsoredMessage
    let controller: TelegramSponsoredVideoWindow
    let click: (Bool) -> Void
    @State private var paused = false
    var body: some View {
        VStack(spacing: 16) {
            Text((ad.recommended ? "Recommended · " : "Sponsored · ") + ad.title).font(.headline)
            if let player = TelegramSponsoredPlayback.shared.player {
                Button { click(true) } label: { TelegramSponsoredPlayer(player: player).allowsHitTesting(false).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()) }
                    .buttonStyle(.plain).disabled(!controller.fullscreen).accessibilityLabel("Open sponsored video link")
                HStack {
                    Button(paused ? "Play" : "Pause") { paused.toggle(); if paused { player.pause() } else { player.play() } }
                    Button("Restart") { player.seek(to: .zero); player.play(); paused = false }
                    Spacer()
                    Button(ad.button) { click(false) }.buttonStyle(.borderedProminent)
                    Button("Close") { controller.close() }.keyboardShortcut(.cancelAction)
                }
            }
        }.padding(20).background(.black).foregroundStyle(.white)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            TelegramSponsoredPlayback.shared.player?.pause(); paused = true
        }
    }
}
