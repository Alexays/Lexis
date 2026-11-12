import SwiftUI

/// The bar and the time line under it, as the native player draws them:
/// played and buffered spans and chapter marks on the track, a needle at the
/// playhead, the elapsed time under the needle with the state mark beside
/// it, and the remaining time at the right edge.
struct TransportBar: View {
    let position: Double
    let duration: Double
    let bufferedSeconds: Double
    let scrubbing: Bool
    let chapters: [ChapterMark]
    let indicator: TransportIndicator?

    /// The playhead's own fraction, written only when it lands on another
    /// point of the track.
    @State private var progress = 0.0
    @State private var elapsedWidth: CGFloat = 0
    @State private var markWidth: CGFloat = 0
    @State private var timeWidth: CGFloat = 0
    @State private var remainingWidth: CGFloat = 0

    private static let width = Theme.Player.rowWidth

    private var played: Double { duration <= 0 ? 0 : min(max(position / duration, 0), 1) }

    private var bufferedFraction: Double {
        guard duration > 0 else { return 0 }
        let ahead = min(max(0, duration - position), max(0, bufferedSeconds)) / duration
        return min(1, played + ahead)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Player.timeTop - Theme.Player.barTop - Theme.Player.barHeight) {
            track
            timeRow
        }
        .frame(width: Self.width, alignment: .leading)
        .onChange(of: position, initial: true) { _, _ in follow() }
        .onChange(of: duration) { _, _ in follow() }
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                PlayerInk.remaining
                PlayerInk.buffered.frame(width: Self.width * bufferedFraction)
                PlayerInk.played.frame(width: Self.width * progress)
            }
            .frame(width: Self.width, height: Theme.Player.track)
            .clipShape(Capsule())
            if duration > 0 {
                ForEach(chapters.indices, id: \.self) { index in
                    PlayerInk.chapter
                        .frame(width: Theme.Player.chapterWidth, height: Theme.Player.track)
                        .offset(x: (chapters[index].start / duration * Self.width).rounded())
                }
            }
            // A scrub's needle reaches up to the frame resting on its tip.
            PlayerInk.played
                .frame(
                    width: Theme.Player.needleWidth,
                    height: scrubbing ? Theme.Player.scrubNeedleHeight : Theme.Player.needleHeight)
                .offset(
                    x: progress * Self.width - Theme.Player.needleWidth / 2,
                    y: scrubbing
                        ? Theme.Player.barHeight / 2 + Theme.Player.needleOverhang - Theme.Player.scrubNeedleHeight / 2
                        : 0)
        }
        .frame(width: Self.width, height: Theme.Player.barHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.bar")
    }

    private var timeRow: some View {
        ZStack(alignment: .topLeading) {
            if duration > 0 {
                let withHours = duration >= 3600 || position >= 3600
                Text("-" + Format.clock(max(0, duration - position), withHours: withHours))
                    .modifier(TimeLabel())
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { remainingWidth = $0 }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .accessibilityIdentifier("player.remaining")
                HStack(spacing: Theme.Player.stateGap) {
                    if let indicator, indicator.leads {
                        StateMark(indicator: indicator)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { markWidth = $0 }
                    }
                    Text(Format.clock(position, withHours: withHours))
                        .modifier(TimeLabel())
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { elapsedWidth = $0 }
                        .accessibilityIdentifier("player.elapsed")
                    if let indicator, !indicator.leads { StateMark(indicator: indicator) }
                }
                // the mark is taller than the time: the row keeps the time's
                // height so the elapsed reads on the remaining's line
                .frame(height: Theme.Player.timeHeight)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { timeWidth = $0 }
                .offset(x: elapsedOffset)
            }
        }
        .frame(width: Self.width, height: Theme.Player.timeHeight, alignment: .topLeading)
    }

    /// The elapsed time centred under the needle with its mark beside it,
    /// clamped by the track's left end and by the remaining label at the
    /// right, never on top of it.
    private var elapsedOffset: CGFloat {
        let lead = indicator?.leads == true ? markWidth + Theme.Player.stateGap : 0
        let end = max(0, Self.width - timeWidth - (remainingWidth > 0 ? remainingWidth + Theme.Space.s24 : 0))
        return min(max(progress * Self.width - elapsedWidth / 2 - lead, 0), end)
    }

    /// A scrub is followed as the hand moves. Anything else steps without
    /// animation, and only when the playhead reaches another point: a film
    /// crosses one every few seconds, and a glide between reports would keep
    /// the main thread interpolating the bar on every frame for nothing.
    private func follow() {
        if scrubbing {
            withAnimation(.interactiveSpring) { progress = played }
            return
        }
        guard (played * Self.width).rounded() != (progress * Self.width).rounded() else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { progress = played }
    }
}

/// The circled mark of a pause, a skip or a scan, with a scan's speed on
/// its outer side.
private struct StateMark: View {
    let indicator: TransportIndicator

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            if indicator.leads, let speed = indicator.speed { Text("\(speed)×") }
            Image(systemName: indicator.symbol)
                .font(.system(size: Theme.Player.stateGlyph * 0.8, weight: .medium))
                .frame(width: Theme.Player.stateGlyph, height: Theme.Player.stateGlyph)
            if !indicator.leads, let speed = indicator.speed { Text("\(speed)×") }
        }
        .font(.system(size: Theme.Player.time, weight: .semibold))
        .foregroundStyle(PlayerInk.time)
        .fixedSize()
        .accessibilityIdentifier("player.state.\(indicator.symbol)")
    }
}

private struct TimeLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: Theme.Player.time, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(PlayerInk.time)
            .lineLimit(1)
            .fixedSize()
    }
}
