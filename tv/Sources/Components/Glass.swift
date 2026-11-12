import SwiftUI
import UIKit

/// Liquid Glass behind a panel. SwiftUI on tvOS 27 offers glass on button
/// styles alone, so a surface takes UIKit's own effect view.
struct GlassSurface: UIViewRepresentable, Equatable {
    var style: UIGlassEffect.Style = .regular
    var radius: CGFloat = Theme.Radius.card
    var capsule = false
    /// Glass behind a control answers the remote with the system's own
    /// press and focus response.
    var interactive = false
    var tint: Color? = nil

    /// The surface the view was last set up as.
    final class Coordinator {
        var drawn: GlassSurface?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = capsule ? .capsule() : .corners(radius: .fixed(radius))
        view.isUserInteractionEnabled = false
        context.coordinator.drawn = self
        return view
    }

    /// A new effect makes the glass materialise again: it is set only when
    /// something it is built from changed.
    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        guard context.coordinator.drawn != self else { return }
        context.coordinator.drawn = self
        view.effect = effect
        view.cornerConfiguration = capsule ? .capsule() : .corners(radius: .fixed(radius))
    }

    private var effect: UIGlassEffect {
        let effect = UIGlassEffect(style: style)
        effect.isInteractive = interactive
        effect.tintColor = tint.map { UIColor($0) }
        return effect
    }
}

/// The bounds of every member of a glass group, gathered up to the group.
private struct GlassMemberKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

/// One container effect holding a capsule of glass per member, so members
/// that come within the spacing of each other merge into one shape, the
/// way the system's bars do.
private struct GlassGroupView: UIViewRepresentable {
    let frames: [CGRect]
    let spacing: CGFloat
    let style: UIGlassEffect.Style
    let tint: Color?

    func makeUIView(context: Context) -> UIVisualEffectView {
        let container = UIGlassContainerEffect()
        container.spacing = spacing
        let view = UIVisualEffectView(effect: container)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        let content = view.contentView
        while content.subviews.count > frames.count { content.subviews.last?.removeFromSuperview() }
        while content.subviews.count < frames.count {
            let effect = UIGlassEffect(style: style)
            effect.isInteractive = true
            effect.tintColor = tint.map { UIColor($0) }
            let member = UIVisualEffectView(effect: effect)
            member.cornerConfiguration = .capsule()
            content.addSubview(member)
        }
        for (member, frame) in zip(content.subviews, frames) { member.frame = frame }
    }
}

extension View {
    /// The view over a glass panel of its own size.
    func glassSurface(radius: CGFloat = Theme.Radius.card, style: UIGlassEffect.Style = .regular, tint: Color? = nil) -> some View {
        background(GlassSurface(style: style, radius: radius, tint: tint))
    }

    func glassCapsule(style: UIGlassEffect.Style = .regular, tint: Color? = nil) -> some View {
        background(GlassSurface(style: style, capsule: true, tint: tint))
    }

    /// One capsule of the enclosing glass group. The control draws no glass
    /// of its own; the group draws it under the control's bounds.
    func glassMember() -> some View {
        anchorPreference(key: GlassMemberKey.self, value: .bounds) { [$0] }
    }

    /// The glass under every member below, drawn as one group.
    func glassGroup(spacing: CGFloat, style: UIGlassEffect.Style = .regular, tint: Color? = nil)
        -> some View
    {
        backgroundPreferenceValue(GlassMemberKey.self) { anchors in
            GeometryReader { proxy in
                GlassGroupView(
                    frames: anchors.map { proxy[$0] }, spacing: spacing, style: style, tint: tint)
            }
        }
    }
}
