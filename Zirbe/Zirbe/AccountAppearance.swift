// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import SwiftUI
import ZirbeCore

extension AccountColor {
    var swatch: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .purple: .purple
        case .teal: .teal
        case .red: .red
        case .yellow: .yellow
        }
    }

    var name: String { rawValue.capitalized }
}

struct AccountDot: View {
    let color: AccountColor
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color.swatch)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AccountLabel: View {
    let account: Account

    var body: some View {
        HStack(spacing: 6) {
            AccountDot(color: account.color)
            Text(account.title)
                .lineLimit(1)
        }
    }
}
