import SwiftUI

/// The one look every filled control shares: glass at rest, the accent
/// where the control is the selected state, and white where the remote is,
/// grown a little. Selection is a state; focus is the remote. The ink is
/// always set here, dark on white and on the accent, so a focused control
/// reads whatever the label draws.
struct FilledControlStyle: ButtonStyle {
    var selected = false
    var scale: CGFloat = Theme.Focus.wide
    var radius: CGFloat = Theme.Radius.pill
    var horizontal: CGFloat = Theme.Control.regular.width
    var vertical: CGFloat = Theme.Control.regular.height
    /// False for a member of a glass group, which draws the glass itself.
    var glass = true

    func makeBody(configuration: Configuration) -> some View {
        FilledControlBody(
            configuration: configuration, selected: selected, scale: scale, radius: radius,
            horizontal: horizontal, vertical: vertical, glass: glass)
    }
}

private struct FilledControlBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let scale: CGFloat
    let radius: CGFloat
    let horizontal: CGFloat
    let vertical: CGFloat
    let glass: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .foregroundStyle(ink)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background {
                // the glass stays mounted under the fill: building it again
                // at every focus move costs a new effect view
                ZStack {
                    if glass {
                        GlassSurface(
                            radius: radius, capsule: radius >= Theme.Radius.pill, interactive: true,
                            tint: Theme.Glass.control)
                    }
                    if let fill {
                        LitGlass(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), color: fill)
                    }
                }
            }
            .scaleEffect(focused ? scale : 1)
            .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
    }

    /// Nil at rest: glass shows through there.
    private var fill: Color? {
        if focused { return Theme.Colors.white }
        return selected ? Theme.Colors.accent : nil
    }

    private var ink: Color {
        if selected { return Theme.Colors.onAccent }
        return focused ? Theme.Colors.onWhite : Theme.Colors.text
    }
}

/// A lit control: its colour laid over the glass rather than in place of it,
/// so the picture still shows through, a bright rim along its top edge, and
/// a glow of its own colour.
struct LitGlass<Outline: InsettableShape>: View {
    let shape: Outline
    let color: Color

    var body: some View {
        shape.fill(color.opacity(0.82))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Theme.Colors.white.opacity(0.9), Theme.Colors.white.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.5))
            .shadow(color: color.opacity(0.35), radius: 18)
    }
}

/// A button with words, or with a mark alone and its words spoken: Play is
/// the only action that spells itself out.
struct ActionButton: View {
    var label: String = ""
    var glyph: Glyph? = nil
    var spoken: String? = nil
    var primary = false
    var compact = false
    /// The body size over a film, read from across the room.
    var font = Theme.Typography.caption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s16) {
                if let glyph { GlyphView(glyph: glyph, size: 22) }
                if !label.isEmpty { Text(label).font(font) }
            }
            .frame(minHeight: 34)
        }
        .buttonStyle(FilledControlStyle(selected: primary, horizontal: compact ? 20 : 32))
        .accessibilityLabel(spoken ?? label)
    }
}

/// A card's button. The label still draws the card and reads its own focus,
/// because each one is shaped differently; what the style owns is the depth,
/// the shadow the card casts, which cannot be expressed by a label on its own.
///
/// A card whose shape it knows takes `shadow: false` and lays the shadow on
/// that shape itself, with `cardShadow`.
struct CardButtonStyle: ButtonStyle {
    var shadow = true

    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration, shadow: shadow)
    }
}

private struct CardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let shadow: Bool
    @Environment(\.isFocused) private var focused

    @ViewBuilder var body: some View {
        let card = configuration.label
        if shadow {
            card
                .shadow(
                    color: .black.opacity(
                        focused ? Theme.Depth.focusOpacity : Theme.Depth.restOpacity),
                    radius: focused ? Theme.Depth.focusRadius : Theme.Depth.restRadius,
                    y: focused ? Theme.Depth.focusY : Theme.Depth.restY)
                .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
        } else {
            card
        }
    }
}

/// The shadow a card casts.
///
/// On a card that is a picture it goes behind the picture, on the shape the
/// picture is clipped to. A shadow is computed from the alpha of everything
/// under it, so laid on the card as a whole it would be cast by the caption's
/// letters as much as by the poster, and every focus move would re-blur an
/// offscreen copy of the picture, its ring and its text together. Behind the
/// shape it is one opaque rectangle.
struct CardShadow: ViewModifier {
    let radius: CGFloat
    let focused: Bool
    /// How much the card grows on focus by an effect the shadow is laid
    /// outside of, as the system's highlight is: it clips what it lifts.
    var lift: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.Colors.bg0)
                    .shadow(
                        color: .black.opacity(
                            focused ? Theme.Depth.focusOpacity : Theme.Depth.restOpacity),
                        radius: focused ? Theme.Depth.focusRadius : Theme.Depth.restRadius,
                        y: focused ? Theme.Depth.focusY : Theme.Depth.restY)
                    .scaleEffect(focused ? lift : 1)
            }
            .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
    }
}

extension View {
    func cardShadow(radius: CGFloat, focused: Bool, lift: CGFloat = 1) -> some View {
        modifier(CardShadow(radius: radius, focused: focused, lift: lift))
    }
}

/// A card's label reads whether its button is under the remote here,
/// where the button is its nearest focusable ancestor; beside the button
/// the environment never says so.
struct FocusReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.isFocused) private var focused

    var body: some View { content(focused) }
}
