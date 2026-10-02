import SwiftUI

/// The top of the right panel: team requests waiting for this user's
/// decision, each with its details and Allow / Decline in place. Shown only
/// while something is waiting. Stage 1 holds join requests; agent calls from
/// colleagues join this list in stage 2 (docs/agentpad/TEAM.md 6.4).
struct TeamPanelSection: View {
    var service = TeamService.shared
    @State private var expanded: UUID?

    var body: some View {
        if !service.pendingPairings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SessionSectionLabel(title: "team · needs you", count: service.pendingPairings.count)
                ForEach(service.pendingPairings) { pending in
                    row(pending)
                }
            }
        }
    }

    private func row(_ pending: TeamService.PendingPairing) -> some View {
        let isOpen = expanded == pending.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded = isOpen ? nil : pending.id }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.chromeForeground)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(pending.name) wants to join")
                            .font(Theme.display(12.5, weight: .medium))
                            .foregroundStyle(Theme.chromeForeground)
                            .lineLimit(1)
                        Text("code \(pending.code)")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.chromeMuted)
                    }
                    Spacer(minLength: 6)
                    Text("waiting")
                        .font(Theme.display(10, weight: .medium))
                        .foregroundStyle(agentStateWordColor(.attention))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow only if \(pending.name) sees the same code: \(pending.code). Once allowed, you see each other's presence; later, your agents can call each other — always with the owner's approval.")
                        .font(Theme.display(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pending.peerId)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.chromeMuted.opacity(0.75))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button("Allow") { service.decide(attempt: pending.attempt, approve: true) }
                            .keyboardShortcut(.defaultAction)
                        Button("Decline") { service.decide(attempt: pending.attempt, approve: false) }
                        Spacer()
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
        .onAppear { if expanded == nil { expanded = pending.id } }
    }
}
