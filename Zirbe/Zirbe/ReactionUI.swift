// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The reaction (tapback) UI: the emoji picker shown on a long-press, and the
// badge cluster that hangs off a bubble's corner. The picker doubles as the
// bubble's action menu (it carries Forward), replacing the plain context menu.
// A reaction the user just added shows tentatively until its short undo window
// passes; the conversation owns that timing, so these views are purely visual.

import SwiftUI
import ZirbeCore

/// The six reactions Zirbe offers, mirroring the set people already know from
/// Messages so a tapback reads the same here.
enum ReactionPalette {
    static let emoji = ["👍", "👎", "❤️", "😂", "‼️", "❓"]
    /// How long a just-added reaction can be pulled back before it actually
    /// sends. Within this window a remove or change never becomes an email; after
    /// it, the reaction is out and final.
    static let undoWindow: Duration = .seconds(5)
}

/// The long-press menu on a bubble: a row of reaction emoji across the top and
/// the bubble's actions (Forward) below, the way Messages stacks a tapback bar
/// over its context menu. Presented as a popover anchored to the bubble.
struct ReactionMenu: View {
    /// The emoji the user has already chosen on this message (pending or sent),
    /// highlighted so the menu shows their current reaction.
    let selected: String?
    /// True once the reaction has been sent: it can't be changed anymore, so the
    /// emoji row is shown for reference but disabled.
    let locked: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onForward: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(ReactionPalette.emoji, id: \.self) { emoji in
                    Button { onReact(emoji) } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .padding(6)
                            .background(
                                selected == emoji ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, locked ? 2 : 8)
            .opacity(locked ? 0.55 : 1)

            if locked {
                Text("Sent reactions can’t be changed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }

            Divider()
            Button { onReply() } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            Divider()
            Button { onForward() } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 264)
    }
}

/// The reactions on a bubble, drawn as small overlapping capsules that overhang
/// its corner. Same emoji from several people collapse to one capsule with a
/// count; the user's own reaction is tinted, and a reaction still inside its undo
/// window is drawn faintly to read as not-yet-final.
struct ReactionCluster: View {
    /// The sent reactions on this message, from everyone.
    let reactions: [Reaction]
    /// The user's just-added emoji still inside its undo window, if any.
    let pendingEmoji: String?
    let selfAddress: String

    private struct Chip: Identifiable {
        let emoji: String
        let count: Int
        let mine: Bool
        let tentative: Bool
        var id: String { emoji }
    }

    private var chips: [Chip] {
        let me = selfAddress.lowercased()
        var order: [String] = []
        var counts: [String: Int] = [:]
        var mine: Set<String> = []
        for reaction in reactions {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
            if reaction.reactor.address.lowercased() == me { mine.insert(reaction.emoji) }
        }
        var result = order.map {
            Chip(emoji: $0, count: counts[$0] ?? 1, mine: mine.contains($0), tentative: false)
        }
        // The pending reaction is the user's own and not yet sent: merge it into a
        // matching capsule (bumping the count) or add its own, marked tentative.
        if let pendingEmoji {
            if let index = result.firstIndex(where: { $0.emoji == pendingEmoji }) {
                let existing = result[index]
                result[index] = Chip(emoji: existing.emoji, count: existing.count + 1, mine: true, tentative: true)
            } else {
                result.append(Chip(emoji: pendingEmoji, count: 1, mine: true, tentative: true))
            }
        }
        return result
    }

    var body: some View {
        HStack(spacing: -6) {
            ForEach(chips) { chip in
                HStack(spacing: 2) {
                    Text(chip.emoji).font(.system(size: 13))
                    if chip.count > 1 {
                        Text("\(chip.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    chip.mine ? AnyShapeStyle(Color.accentColor.opacity(0.20)) : AnyShapeStyle(Color.zirbeReceived),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(Color.zirbeCanvas, lineWidth: 1.5))
                .opacity(chip.tentative ? 0.55 : 1)
            }
        }
    }
}
