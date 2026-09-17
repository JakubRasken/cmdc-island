import AppKit
import SwiftUI

/// Physical notch (or fallback pill) dimensions for the target screen.
struct NotchMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    /// Vertical offset of the pill from the very top of the screen. Zero when
    /// a real notch is present, because the shape hangs off the cutout; a
    /// small gap on notched-less displays so it reads as a floating pill.
    var topInset: CGFloat { hasNotch ? 0 : 6 }

    static func detect(on screen: NSScreen) -> NotchMetrics {
        let defaults = UserDefaults.standard
        let dw = CGFloat(defaults.double(forKey: Pref.Key.notchWidthOffset))
        let dh = CGFloat(defaults.double(forKey: Pref.Key.notchHeightOffset))

        let inset = screen.safeAreaInsets.top
        if inset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchMetrics(width: max(80, width + dw), height: max(20, inset + dh), hasNotch: true)
        }
        return NotchMetrics(width: max(80, 148 + dw), height: max(20, 32 + dh), hasNotch: false)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Starting footprint, replaced by the measured island size on first layout.
/// A free constant rather than a property, because `super.init` needs it
/// before `self` is usable.
private let initialPanelSize = CGSize(width: 120, height: 30)

/// Borderless, non-activating panel pinned to the top-centre of the chosen
/// screen.
///
/// The panel is deliberately sized to the island's *current* footprint rather
/// than to a large fixed canvas. A big always-on-top window would silently
/// swallow clicks across a chunk of the menu bar and the app below it; matching
/// the visible pill means the island only ever blocks what it visibly covers.
/// It grows when the island expands and shrinks back with it.
final class NotchPanel: NSPanel {

    private let monitor: CommandCodeMonitor
    private var currentSize = initialPanelSize
    private var fullscreenTimer: Timer?

    init(monitor: CommandCodeMonitor) {
        self.monitor = monitor
        super.init(
            contentRect: NSRect(origin: .zero, size: initialPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        buildContent()
        startFullscreenWatch()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The screen chosen in settings; "auto" prefers the built-in (notched)
    /// display, falling back to the main screen.
    static func targetScreen() -> NSScreen? {
        let selection = Pref.displaySelection
        if selection.hasPrefix("id:"), let id = CGDirectDisplayID(selection.dropFirst(3)),
           let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Content

    private func buildContent() {
        guard let screen = Self.targetScreen() else { return }
        let notch = NotchMetrics.detect(on: screen)

        let view = IslandView(
            monitor: monitor,
            notch: notch,
            onSizeChange: { [weak self] size in self?.updateSize(size) }
        )
        contentView = NSHostingView(rootView: view)
        reposition()
    }

    func reposition() {
        buildContent()
        applyFrame()
        updateFullscreenHide()
    }

    /// Called by the SwiftUI layer whenever the island's footprint changes.
    private func updateSize(_ size: CGSize) {
        // A little slack so the drop shadow and the tail of the spring are not
        // clipped mid-animation.
        let target = CGSize(
            width: ceil(size.width) + 24,
            height: ceil(size.height) + 16
        )
        guard abs(target.width - currentSize.width) > 0.5
                || abs(target.height - currentSize.height) > 0.5 else { return }

        currentSize = target
        applyFrame()
    }

    private func applyFrame() {
        guard let screen = Self.targetScreen() else { return }
        let origin = CGPoint(
            x: screen.frame.midX - currentSize.width / 2,
            y: screen.frame.maxY - currentSize.height
        )
        setFrame(NSRect(origin: origin, size: currentSize), display: true)
    }

    // MARK: - Hide in fullscreen

    /// Heuristic: on a fullscreen space the menu bar is hidden, so the
    /// screen's visibleFrame grows to the top edge.
    private func startFullscreenWatch() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updateFullscreenHide()
        }
    }

    @objc private func spaceChanged() {
        updateFullscreenHide()
    }

    private func updateFullscreenHide() {
        guard Pref.hideInFullscreen, let screen = Self.targetScreen() else {
            setIslandHidden(false)
            return
        }
        let menuBarHidden = screen.visibleFrame.maxY >= screen.frame.maxY - 1
        setIslandHidden(menuBarHidden)
    }

    private func setIslandHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        guard alphaValue != alpha else { return }
        alphaValue = alpha
        ignoresMouseEvents = hidden
    }

    deinit {
        fullscreenTimer?.invalidate()
    }
}
