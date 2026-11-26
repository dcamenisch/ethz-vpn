import AppKit
import SwiftUI

enum StatusStyle {
    case connected, connecting, disconnected, failed

    static var current: StatusStyle {
        let vpn = VPNController.shared
        switch vpn.state {
        case .connected: return .connected
        case .connecting, .disconnecting: return .connecting
        case .disconnected: return vpn.lastError == nil ? .disconnected : .failed
        }
    }

    var color: NSColor {
        switch self {
        case .connected:    return .systemGreen
        case .connecting:   return .systemOrange
        case .disconnected: return .systemGray
        case .failed:       return .systemRed
        }
    }
}

/// The "ETHZ" badge shown in the menu bar.
enum StatusBadge {
    static func image(_ style: StatusStyle) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .heavy),
            .kern: 0.8,
        ]
        let text = NSAttributedString(string: "ETHZ", attributes: attrs)
        let size = NSSize(width: ceil(text.size().width) + 11, height: 16)

        let image = NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 1.25), xRadius: 4.5, yRadius: 4.5)
            let filled = style == .connected || style == .connecting
            let ink: NSColor = filled ? .white : (style == .failed ? .systemRed : .black)
            if filled {
                style.color.setFill()
                shape.fill()
            } else {
                ink.setStroke()
                shape.lineWidth = 1.3
                shape.stroke()
            }
            let label = NSMutableAttributedString(attributedString: text)
            label.addAttribute(.foregroundColor, value: ink, range: NSRange(location: 0, length: label.length))
            let s = label.size()
            label.draw(at: NSPoint(x: (rect.width - s.width) / 2 + 0.4, y: (rect.height - s.height) / 2))
            return true
        }
        image.isTemplate = style == .disconnected
        image.accessibilityDescription = "ETHZ VPN"
        return image
    }
}

/// Live status header at the top of the menu.
struct StatusCard: View {
    private let vpn = VPNController.shared

    var body: some View {
        let style = StatusStyle.current
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: style.color).gradient)
                    .shadow(color: Color(nsColor: style.color).opacity(0.45), radius: 5, y: 1)
                Image(systemName: symbol(style))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: style == .connecting)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title(style))
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle(style))
                    .font(.system(size: 11))
                    .foregroundStyle(style == .failed ? Color(nsColor: .systemRed) : .secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if style == .connected, let since = vpn.connectedSince {
                Text(since, style: .timer)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 290, alignment: .leading)
    }

    private func symbol(_ style: StatusStyle) -> String {
        switch style {
        case .connected:    return "checkmark.shield.fill"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .disconnected: return "shield.slash"
        case .failed:       return "exclamationmark.triangle.fill"
        }
    }

    private func title(_ style: StatusStyle) -> String {
        switch style {
        case .connected:    return "Connected to ETHZ"
        case .connecting:
            if case .disconnecting = vpn.state { return "Disconnecting" }
            return "Connecting"
        case .disconnected: return "Not connected"
        case .failed:       return "Connection failed"
        }
    }

    private func subtitle(_ style: StatusStyle) -> String {
        let profile = ProfileStore.shared.activeProfile
        switch style {
        case .connected:
            guard case .connected(let ip) = vpn.state, !ip.isEmpty else { return profile?.displayName ?? "" }
            return [profile?.displayName, ip].compactMap { $0 }.joined(separator: ", ")
        case .connecting:
            return profile.map { "Signing in to \($0.server)" } ?? ""
        case .disconnected:
            return profile.map { "\($0.displayName) profile ready" } ?? "Add a profile to get started"
        case .failed:
            return vpn.lastError ?? ""
        }
    }
}
