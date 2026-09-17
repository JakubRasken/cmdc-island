import SwiftUI

/// The Dynamic Island silhouette.
///
/// Top corners flare *outward* so the shape melts into the notch and menu bar;
/// bottom corners round inward. With `topRadius == 0` the top edge is square,
/// which is what a pill sitting flush against the top of the screen wants.
///
/// Adapted from Agents Island (MIT) — `NotchShape.swift`.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = topRadius
        let bottom = min(bottomRadius, (rect.height - top) / 1.2)

        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: top, y: top), control: CGPoint(x: top, y: 0))
        path.addLine(to: CGPoint(x: top, y: rect.height - bottom))
        path.addQuadCurve(
            to: CGPoint(x: top + bottom, y: rect.height),
            control: CGPoint(x: top, y: rect.height)
        )
        path.addLine(to: CGPoint(x: rect.width - top - bottom, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - top, y: rect.height - bottom),
            control: CGPoint(x: rect.width - top, y: rect.height)
        )
        path.addLine(to: CGPoint(x: rect.width - top, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: 0), control: CGPoint(x: rect.width - top, y: 0))
        path.closeSubpath()
        return path
    }
}

/// Blur + fade + slight scale — the content morph used on every state change.
///
/// The blur stays light: at higher radii it reads as a smear rather than a
/// focus pull.
private struct BlurFadeModifier: ViewModifier {
    var blur: CGFloat
    var opacity: Double
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
            .scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    /// Content arrives with the container's stretch rather than after it, so
    /// the silhouette is never an empty slab mid-animation.
    static var islandContentIn: AnyTransition {
        .modifier(
            active: BlurFadeModifier(blur: 2.5, opacity: 0, scale: 0.97),
            identity: BlurFadeModifier(blur: 0, opacity: 1, scale: 1)
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.88))
    }

    /// Departing content vanishes quickly so the shape can shrink cleanly,
    /// while still overlapping the arriving content — never handing off to a
    /// visible gap.
    static var islandContentOut: AnyTransition {
        .modifier(
            active: BlurFadeModifier(blur: 2, opacity: 0, scale: 0.985),
            identity: BlurFadeModifier(blur: 0, opacity: 1, scale: 1)
        )
        .animation(.easeOut(duration: 0.09))
    }

    static var islandContent: AnyTransition {
        .asymmetric(insertion: .islandContentIn, removal: .islandContentOut)
    }
}
