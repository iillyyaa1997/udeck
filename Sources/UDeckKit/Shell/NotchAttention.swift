import AppKit
import SwiftUI
import UDeckCore

/// On a screen with a notch the collapsed island is the notch itself, and the
/// notch says nothing: what waits for the person is said beside it — ears, or
/// a glow along its edge, as chosen in Settings → Look (`NotchAttention`).
/// A window of its own over the menu bar, the notch's width and an ear either
/// side, that never takes a click; the panel's geometry is left as it is.
@MainActor
public final class NotchMarks {
    private let model: DeckModel
    private var windows: [String: DeckPanel] = [:]
    /// How far an ear reaches past the notch, and how far a glow below it.
    static let ear: CGFloat = 40
    static let below: CGFloat = 10

    public init(model: DeckModel) {
        self.model = model
    }

    /// A mark beside every notch there is now; none where there is none.
    public func sync(screens: [ScreenSnapshot]) {
        var wanted: [String: CGRect] = [:]
        for screen in screens {
            guard let notch = screen.notchRect else { continue }
            wanted[screen.name] = CGRect(x: notch.minX - Self.ear, y: notch.minY - Self.below,
                                         width: notch.width + 2 * Self.ear, height: notch.height + Self.below)
        }
        for (name, window) in windows where wanted[name] == nil {
            window.orderOut(nil)
            windows[name] = nil
        }
        for (name, frame) in wanted {
            let window = windows[name] ?? make()
            windows[name] = window
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()
        }
    }

    private func make() -> DeckPanel {
        let window = DeckPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.ignoresMouseEvents = true
        let view = NotchMarkView(model: model, ear: Self.ear, below: Self.below)
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        return window
    }
}

/// The ears or the glow, drawn for what waits now.
struct NotchMarkView: View {
    var model: DeckModel
    var ear: CGFloat
    var below: CGFloat

    static let waiting = Color(red: 0.94, green: 0.66, blue: 0.23)

    var body: some View {
        let count = model.attention.count
        let choice = model.settings.notchAttention ?? .standard
        GeometryReader { geometry in
            let notch = CGRect(x: ear, y: 0, width: geometry.size.width - 2 * ear, height: geometry.size.height - below)
            switch choice {
            case .earsWhileWaiting where count > 0, .earsAlways:
                ears(count: count, notch: notch, width: geometry.size.width)
                    .accessibilityElement()
                    .accessibilityIdentifier("island.notch.ears")
                    .accessibilityLabel("\(count)")
            case .glowAlongTheEdge where count > 0:
                glow(notch: notch)
                    .accessibilityElement()
                    .accessibilityIdentifier("island.notch.glow")
            default:
                Color.clear
            }
        }
    }

    /// The notch continued sideways, black as it is: a dot on the left, how
    /// many wait on the right.
    private func ears(count: Int, notch: CGRect, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                .fill(Color.black)
                .frame(width: width, height: notch.height)
            Circle()
                .fill(dot(count: count))
                .frame(width: 9, height: 9)
                .shadow(color: count > 0 ? Self.waiting.opacity(0.8) : .clear, radius: 4)
                .position(x: ear / 2 + 2, y: notch.height / 2)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.waiting)
                    .position(x: width - ear / 2 - 2, y: notch.height / 2)
            }
        }
    }

    /// The colour of the dot: waiting, or how things are.
    private func dot(count: Int) -> Color {
        if count > 0 { return Self.waiting }
        let states = model.snapshots.values.compactMap { $0.card?.state }
        if states.contains(.crit) { return .red }
        if states.contains(.warn) { return Self.waiting }
        return Color(red: 0.25, green: 0.75, blue: 0.37)
    }

    /// A glow along the notch's lower edge.
    private func glow(notch: CGRect) -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
            .stroke(Self.waiting, lineWidth: 2)
            .frame(width: notch.width, height: notch.height)
            .shadow(color: Self.waiting.opacity(0.9), radius: 5)
            .position(x: notch.midX, y: notch.height / 2)
    }
}
