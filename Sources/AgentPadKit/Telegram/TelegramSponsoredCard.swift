import AgentPadTelegram
import AppKit
import AVKit
import SwiftUI

struct TelegramSponsoredGeometry: Equatable {
    var cards: [String: CGRect] = [:]
    var text: [String: CGRect] = [:]
    var ready = Set<String>()
}
struct TelegramSponsoredFrames: PreferenceKey {
    static let defaultValue = TelegramSponsoredGeometry()
    static func reduce(value: inout TelegramSponsoredGeometry, nextValue: () -> TelegramSponsoredGeometry) {
        let next = nextValue()
        value.cards.merge(next.cards, uniquingKeysWith: { _, b in b }); value.text.merge(next.text, uniquingKeysWith: { _, b in b }); value.ready.formUnion(next.ready)
    }
}

struct TelegramSponsoredCard: View {
    let ad: TelegramSponsoredMessage
    let coordinate: UUID
    let active: Bool
    let action: (TelegramSponsoredAction) -> Void
    let info: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var owner = UUID()
    private var cache: TelegramSponsoredRenderCache { .shared }
    private var playback: TelegramSponsoredPlayback { .shared }
    private var failure: String? { ad.error ?? ad.media.compactMap(\.error).first ?? ad.media.compactMap { $0.url.flatMap { cache.errors[$0] } }.first }
    private var ready: Bool { ad.fullyLoaded && ad.media.allSatisfy { $0.url.flatMap { cache.assets[$0] } != nil } }
    private var color: Color {
        let builtIn: [UInt32] = [0xCC5049, 0xD67722, 0x955CDB, 0x40A920, 0x309EBA, 0x368AD1, 0xC7508B]
        let fallback = builtIn.indices.contains(ad.accentColorID) ? builtIn[ad.accentColorID] : 0x368AD1
        let rgb = (scheme == .dark ? ad.darkColors : ad.lightColors).first ?? fallback
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ready {
                textContent
                    .background(GeometryReader { geometry in Color.clear.preference(key: TelegramSponsoredFrames.self,
                        value: .init(text: [ad.id: geometry.frame(in: .named(coordinate))], ready: [ad.id])) })
                if let media = ad.media.first(where: { $0.role == .content }), let url = media.url, let asset = cache.assets[url] {
                    mediaContent(media, url: url, asset: asset)
                }
                HStack(spacing: 12) {
                    Button(ad.button) { action(.click(ad.ref, .button, confirmed: false)) }.buttonStyle(.borderedProminent).tint(color)
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { informationButtons }
                    VStack(alignment: .leading, spacing: 8) { informationButtons }
                }
            } else {
                HStack {
                    Text(failure == nil ? "Loading sponsored message…" : "Ad unavailable").font(Theme.display(12, weight: .semibold))
                    Spacer()
                    if failure == nil { ProgressView().controlSize(.small); Button("Cancel") { action(.cancelMedia(ad.ref)) } }
                    else { Button("Retry") { cache.retry(ad.media); action(.retryMedia(ad.ref)) } }
                }
                if let failure { Text(failure).font(Theme.display(11)).foregroundStyle(.secondary) }
            }
        }
        .padding(17).frame(maxWidth: 710, alignment: .leading)
        .background { background }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35), lineWidth: 1))
        .background(GeometryReader { geometry in Color.clear.preference(key: TelegramSponsoredFrames.self,
            value: .init(cards: [ad.id: geometry.frame(in: .named(coordinate))])) })
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 22)
        .accessibilityElement(children: .contain).accessibilityLabel(ad.recommended ? "Recommended message" : "Official sponsored message")
        .onAppear { cache.retain(owner, media: ad.media); reconcileAnimation() }
        .onChange(of: ad.media) { _, media in cache.retain(owner, media: media); reconcileAnimation() }
        .onChange(of: ready) { _, _ in reconcileAnimation() }
        .onChange(of: active) { _, _ in reconcileAnimation() }
        .onDisappear { cache.release(owner) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in playback.stop(owner: owner) }
    }
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                if let media = ad.media.first(where: { $0.role == .sponsor }), let url = media.url, let image = cache.assets[url]?.image {
                    Button { action(.click(ad.ref, .sponsorPhoto, confirmed: false)) } label: {
                        Image(decorative: image, scale: 1).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Open sponsor")
                }
                Button(ad.title) { action(.click(ad.ref, .title, confirmed: false)) }
                    .buttonStyle(.plain).font(Theme.display(13, weight: .semibold)).foregroundStyle(color).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text(ad.recommended ? LocalizedStringKey("Recommended") : LocalizedStringKey("Sponsored")).font(Theme.display(10, weight: .semibold)).foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 4).stroke(color)).fixedSize()
            }
            if !ad.text.isEmpty {
                Text(TelegramEntityRenderer.attributed(text: ad.text, entities: ad.entities)).font(Theme.display(13)).fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if let index = ad.entities.firstIndex(where: { $0.url == url.absoluteString }) { action(.click(ad.ref, .link(index), confirmed: false)) }
                        return .handled
                    })
            }
            if !ad.sponsorInfo.isEmpty { Text(ad.sponsorInfo).font(Theme.display(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !ad.additionalInfo.isEmpty { Text(ad.additionalInfo).font(Theme.display(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    @ViewBuilder private var informationButtons: some View {
        Button("Why do I see this?") { info(true) }.buttonStyle(.link).font(Theme.display(11))
        if !ad.sponsorInfo.isEmpty || !ad.additionalInfo.isEmpty { Button("Sponsor info") { info(false) }.buttonStyle(.link).font(Theme.display(11)) }
        if ad.canReport { Button("Report ad") { action(.report(ad.ref, step: nil, option: nil)) }.buttonStyle(.link).font(Theme.display(11)) }
    }
    @ViewBuilder private var background: some View {
        let palette = scheme == .dark ? ad.darkColors : ad.lightColors
        let colors = palette.map { Color(red: Double(($0 >> 16) & 255) / 255, green: Double(($0 >> 8) & 255) / 255, blue: Double($0 & 255) / 255) }
        RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: (colors.isEmpty ? [color] : colors).map { $0.opacity(scheme == .dark ? 0.09 : 0.05) }, startPoint: .topLeading, endPoint: .bottomTrailing))
        if ready, let media = ad.media.first(where: { $0.role == .background }), let url = media.url, let image = cache.assets[url]?.image {
            HStack(spacing: 32) {
                ForEach(0..<4) { _ in Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 36, height: 36) }
            }.opacity(0.07).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private func mediaContent(_ media: TelegramSponsoredMedia, url: URL, asset: TelegramSponsoredAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                let target: TelegramSponsoredClick = media.kind == .video && !asset.hasAudio ? .silentVideoMedia : .media
                action(.click(ad.ref, target, confirmed: false))
            } label: {
                ZStack {
                    if playback.owner == owner, let player = playback.player { TelegramSponsoredPlayer(player: player).allowsHitTesting(false) }
                    else { Image(decorative: playback.owner == owner ? playback.frame ?? asset.image : asset.image, scale: 1).resizable().scaledToFit() }
                    if media.kind == .video { Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundStyle(.white).shadow(radius: 3) }
                }.frame(maxWidth: 540, maxHeight: 320).clipped().contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(media.kind == .video && asset.hasAudio ? "Play sponsored video" : "Open sponsored media link")
            if media.kind == .video { Button("Expand video") { action(.click(ad.ref, .expandVideo, confirmed: false)) }.buttonStyle(.link).font(Theme.display(11)) }
            if media.kind == .animation, playback.owner != owner, asset.frames > 1 || asset.movie != nil {
                Button("Play animation") { playback.play(owner: owner, asset: asset, url: url, muted: true) }.buttonStyle(.link).font(Theme.display(11)).disabled(!active)
            }
        }
    }
    private func reconcileAnimation() {
        guard active, ready, let media = ad.media.first(where: { $0.role == .content && $0.kind == .animation }),
              let url = media.url, let asset = cache.assets[url] else { playback.stop(owner: owner); return }
        if playback.owner != owner { playback.play(owner: owner, asset: asset, url: url, muted: true) }
    }
}

struct TelegramSponsoredPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.allowsVideoFrameAnalysis = false
        view.showsFullScreenToggleButton = false; view.player = player; return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}


extension TelegramConversationView {
    @ViewBuilder var sponsoredStatus: some View {
        switch model.snapshot.sponsored.state {
        case .idle, .loading: HStack { ProgressView().controlSize(.small); Text("Loading sponsored messages…") }.font(Theme.display(11)).padding(16)
        case .error:
            HStack {
                Text("Ad unavailable")
                Button("Retry") { sponsoredAction(.retry) }.disabled(model.snapshot.sponsored.retryNotBefore > Date())
            }.font(Theme.display(12)).padding(16)
        case .ready, .empty: EmptyView()
        }
    }
    func sponsoredAction(_ action: TelegramSponsoredAction, ref: TelegramSponsoredRef? = nil) {
        model.sponsoredAction(action, pane: pane, ref: ref) { target in
            TelegramTabs.openSponsored(target, state: state)
        }
    }
    func sponsoredDialogView(_ dialog: TelegramSponsoredDialog) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(dialog.title).font(Theme.display(17, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(dialog.text).font(Theme.display(13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(dialog.options) { option in
                        Button(option.text) { sponsoredAction(.report(dialog.ref, step: dialog.step, option: option.id), ref: dialog.ref) }
                            .frame(maxWidth: .infinity, alignment: .leading).disabled(model.sponsoredBusy)
                    }
                }
            }.frame(maxHeight: 300)
            HStack {
                if dialog.why { Link("About Telegram Ads", destination: URL(string: "https://core.telegram.org/api/sponsored-messages")!) }
                Spacer()
                Button(dialog.click == nil && dialog.step == nil ? "Done" : "Cancel") { model.dismissSponsoredDialog() }.keyboardShortcut(.cancelAction)
                if let target = dialog.click {
                    Button("Open website") {
                        model.sponsoredDialog = nil
                        sponsoredAction(.click(dialog.ref, target, confirmed: true), ref: dialog.ref)
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 440)
    }
}
