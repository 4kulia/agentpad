import SwiftUI

/// Shared identity presentation. Neither a rename nor a new session changes the color.
struct AvatarPlaceholder: Equatable, Sendable {
    enum Kind: Sendable { case person, agent }
    var stableID: String
    var name: String
    var kind: Kind

    // DESIGN-DM / mockups/avatars.html: white text has at least 4.5:1 contrast.
    static let lightPalette: [UInt32] = [0xcc262e, 0xaf4d04, 0x906105, 0x6b6f00, 0x077b30, 0x09786b,
                                       0x067588, 0x066bc0, 0x5a58df, 0x8848cf, 0xb035a4, 0xc52671]
    static let darkPalette: [UInt32] = [0xd83438, 0xbe5402, 0x9c6a0d, 0x757908, 0x058635, 0x0e8274,
                                      0x0a7f94, 0x0675d1, 0x6262ea, 0x9253da, 0xbb40af, 0xd0347b]

    static func hash(_ stableID: String) -> UInt32 {
        stableID.utf8.reduce(UInt32(0x811c9dc5)) { ($0 ^ UInt32($1)) &* 0x01000193 }
    }
    var colorIndex: Int { Int(Self.hash(stableID) % 12) }
    func color(isLight: Bool) -> UInt32 { (isLight ? Self.lightPalette : Self.darkPalette)[colorIndex] }
    func cornerRadius(size: CGFloat) -> CGFloat { size * (kind == .person ? 0.5 : 0.27) }

    static func letter(_ name: String) -> String {
        // Normalize decomposed accents before choosing a Unicode letter/number.
        let first = name.precomposedStringWithCanonicalMapping.unicodeScalars.first {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: true
            default: false
            }
        }
        return first.map { String($0).uppercased() } ?? "?"
    }
    var letter: String { Self.letter(name) }
}

/// A person is a circle; an agent is a rounded square at every display size.
struct ContactAvatar: View {
    let stableID: String
    let name: String
    let kind: AvatarPlaceholder.Kind
    var size: CGFloat = 32
    var image: NSImage?
    var localProfileID: UUID?
    var remote: ChatAvatarReference?
    var service: ChatService = .shared
    private struct Content: Hashable { var reference: ChatAvatarReference?; var context: ChatAvatarContext?; var version: ChatAvatarMetadata? }
    private struct Load: Hashable { var content: Content; var generation: Int }
    @State private var visibilityID = UUID()
    @State private var displayed: (Content, NSImage)?
    private var placeholder: AvatarPlaceholder { .init(stableID: stableID, name: name, kind: kind) }

    var body: some View {
        let rgb = placeholder.color(isLight: Theme.resolved.isLight)
        let color = Color(red: Double((rgb >> 16) & 255) / 255,
                          green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        // The context includes the access epoch, so a held image survives cache
        // eviction but stops displaying as soon as membership or rights change.
        let context = remote.flatMap { service.avatarDisplayContext($0.key) }
        let version = remote.flatMap { service.avatars.metadata[$0.subject] }
        let content = Content(reference: remote, context: context, version: version)
        let generation = remote.map { service.avatars.imageGeneration($0) } ?? 0
        let picture = image ?? localProfileID.flatMap { AgentProfileStore.shared.details.image($0) }
            ?? (displayed?.0 == content && context != nil ? displayed?.1 : nil)
            ?? remote.flatMap { service.avatars.image($0) }
        ZStack {
            if let picture {
                Image(nsImage: picture).resizable().scaledToFill().frame(width: size, height: size)
            } else {
                Text(placeholder.letter).font(Theme.display(size * 0.46, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background {
                        if kind == .person { Circle().fill(color) }
                        else { RoundedRectangle(cornerRadius: placeholder.cornerRadius(size: size)).fill(color) }
                    }
            }
        }.frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: placeholder.cornerRadius(size: size)))
            .accessibilityHidden(true)
            .task(id: Load(content: content, generation: generation)) {
                service.avatars.setVisible(remote, id: visibilityID)
                if let remote, context != nil {
                    let loaded = await service.avatars.load(remote)
                    if !Task.isCancelled { displayed = loaded.map { (content, $0) } }
                } else { displayed = nil }
            }
            .onDisappear { service.avatars.setVisible(nil, id: visibilityID); displayed = nil }
    }
}
