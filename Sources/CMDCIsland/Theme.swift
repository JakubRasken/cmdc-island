import Foundation
import SwiftUI

/// Visual constants. One dark surface, four status colours, two type sizes.
///
/// The island is a black pill, so everything is specified against black and
/// nothing here introduces a gradient, a card or a second surface.
enum Theme {

    /// The pill itself. Not pure black — a hint of blue-grey keeps it from
    /// reading as a hole punched in the screen next to the real notch.
    static let surface = Color(red: 0.043, green: 0.047, blue: 0.059)

    static let primaryText = Color.white.opacity(0.95)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)

    static let hairline = Color.white.opacity(0.08)

    // MARK: Status

    static func color(for status: CommandCodeStatus) -> Color {
        switch status {
        case .working:   return Color(red: 0.30, green: 0.85, blue: 0.46)
        case .waiting:   return Color(red: 1.00, green: 0.72, blue: 0.22)
        case .completed: return Color(red: 0.30, green: 0.85, blue: 0.46)
        case .idle:      return Color(red: 0.55, green: 0.58, blue: 0.62)
        case .unknown:   return Color(red: 0.40, green: 0.42, blue: 0.46)
        }
    }

    // MARK: Metrics

    enum Metrics {
        /// Collapsed pill height. Sits just under the notch's own height so it
        /// reads as an extension of the cutout rather than a slab on top of it.
        static let collapsedHeight: CGFloat = 26

        static let expandedWidth: CGFloat = 340

        static let dotSize: CGFloat = 7
        static let horizontalPadding: CGFloat = 12

        static let cardSpacing: CGFloat = 8
    }

    // MARK: Type

    /// The wordmark. Monospaced so `cmd` reads as a terminal token.
    static let wordmark = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let status = Font.system(size: 11, weight: .medium)
    static let title = Font.system(size: 12.5, weight: .semibold)
    static let subtitle = Font.system(size: 11, weight: .regular)
    static let detail = Font.system(size: 10, weight: .medium)
}

/// Drives the working indicator's pulse. Kept as a separate observable so the
/// animation clock never invalidates the session list.
final class PulseClock: ObservableObject {
    @Published var scale: CGFloat = 1.0

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in
            withAnimation(.easeInOut(duration: 0.9)) {
                self?.scale = (self?.scale ?? 1) > 1.0 ? 0.72 : 1.18
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scale = 1.0
    }

    deinit {
        timer?.invalidate()
    }
}
