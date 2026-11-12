import LexisCore
import SwiftUI

/// A title in a reason: its poster, and under it the name and the year,
/// spelled out whether the remote is on the card or not.
///
/// Always spelled out, because a reason scrolls past the hero. On the first
/// screen the hero names what the remote is on; one row down it is gone, and
/// the caption is then the only thing that says what is on the shelf.
struct ReasonCard: View {
    let item: TitleItem
    /// Set for a title someone is part way through, wherever it is shown.
    var resume: Resume? = nil
    /// The episode a show carries on with, said in place of its kind and year.
    var episode: String? = nil
    /// Where the title stands in its saga, said in place of its name: on the
    /// sagas' row the saga is what the card is about.
    var place: SagaPlace? = nil
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            FocusReader { focused in
                // the system's lift: it tilts under the thumb on the remote
                art(focused: focused)
                    .frame(width: Theme.Reason.width, height: Theme.Reason.height)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                    )
                    .hoverEffect(.highlight)
                    .cardShadow(radius: Theme.Radius.poster, focused: focused, lift: Theme.Focus.lift)
                    // Hung under the picture rather than stacked with it: tvOS
                    // scrolls a focused view whose frame nears the screen's
                    // foot, and a frame reaching down to the caption moved a
                    // screen of rows at a step along one.
                    .overlay(alignment: .top) {
                        caption
                            .offset(y: Theme.Reason.height
                                + (focused ? Theme.Reason.height * (Theme.Focus.lift - 1) / 2 : 0))
                            .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
                    }
            }
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .padding(.bottom, Theme.Reason.caption)
        .accessibilityLabel(
            place.map { "\(item.name), \($0.name), \($0.said)" }
                ?? item.year.map { "\(item.name) \($0)" } ?? item.name)
    }

    /// The monogram alone where there is no poster: the name is under the
    /// card now, and a plate that repeats it says it twice.
    private func art(focused: Bool) -> some View {
        ZStack {
            Theme.Colors.bg1
            ArtworkImage(kind: .poster(titleId: item.id)) {
                Text(Format.monogram(item.name))
                    .font(Theme.Typography.title)
                    .tracking(1)
                    .foregroundStyle(Theme.Colors.textMuted)
            }
            if let resume {
                ResumeBar(progress: resume.progress, size: CGSize(width: Theme.Reason.width, height: Theme.Reason.height), left: resume.left, showLeft: focused)
            }
        }
        .frame(width: Theme.Reason.width, height: Theme.Reason.height)
    }

    private var caption: some View {
        let name = place?.name ?? item.name
        let long = name.count > Theme.captionWrapAt
        return VStack(spacing: Theme.Space.s8) {
            Text(name)
                .font(long ? Theme.Typography.captionCompact : Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.text)
                .fits(long ? 3 : 1, size: long ? Theme.Typography.captionCompactSize : Theme.Typography.captionSize)
                .multilineTextAlignment(.center)
            Text(place?.said ?? episode ?? item.kindAndYear)
                .font(Theme.Typography.captionCompact)
                .foregroundStyle(Theme.Colors.textMuted)
        }
        .frame(width: Theme.Reason.width, height: Theme.Reason.captionBand, alignment: .top)
        .padding(.top, Theme.Space.s16)
    }
}

/// The last tile of a reason: the affordance that says the row holds more
/// than it shows, standing where the next poster would.
struct ReasonMoreCard: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            FocusReader { focused in
                VStack(spacing: 0) {
                    Text(t("row.more"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(focused ? Theme.Colors.onWhite : Theme.Colors.text)
                        .fits(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Space.s16)
                        .frame(width: Theme.Reason.width, height: Theme.Reason.height)
                        .background {
                            // the glass stays mounted under the fill: building it
                            // again at every focus move costs a new effect view
                            ZStack {
                                GlassSurface(style: .clear, radius: Theme.Radius.poster, interactive: true)
                                .opacity(focused ? 0 : 1)
                                if focused {
                                    RoundedRectangle(
                                        cornerRadius: Theme.Radius.poster, style: .continuous
                                    )
                                    .fill(Theme.Colors.white)
                                }
                            }
                        }
                        .cardShadow(radius: Theme.Radius.poster, focused: focused)
                }
                .scaleEffect(focused ? Theme.Focus.poster : 1)
                .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
            }
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        // the caption band the other cards hang their names in, held outside
        // the button so its frame is the tile's alone, as theirs are
        .padding(.bottom, Theme.Reason.caption)
    }
}

/// A title as a tile: its poster, or a monogram where there is none, with
/// the caption under it fading in on focus so the card never changes size.
/// Wide is the landscape card of the resume rail, carrying the frame the
/// viewer stopped on and its name under it, always shown.
struct PosterCard: View {
    let item: TitleItem
    var wide = false
    var resume: Resume? = nil
    /// Where the title stands in its saga, said in place of its name.
    var place: SagaPlace? = nil
    var onFocus: (() -> Void)? = nil
    let onPress: () -> Void

    private var width: CGFloat { wide ? Theme.Landscape.width : Theme.Poster.width }
    private var height: CGFloat { wide ? Theme.Landscape.height : Theme.Poster.height }
    private var radius: CGFloat { wide ? Theme.Radius.card : Theme.Radius.poster }

    var body: some View {
        Button(action: onPress) {
            FocusReader { focused in
                VStack(spacing: 0) {
                    // the system's lift, which tilts under the thumb and lights
                    // the glass: no ring of its own over it
                    art(focused: focused)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .hoverEffect(.highlight)
                        .cardShadow(radius: radius, focused: focused, lift: Theme.Focus.lift)
                    Group {
                        if wide {
                            // a scene says nothing of the title it is from
                            Text(item.name)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.text)
                                .fits(1)
                                .padding(.top, Theme.Space.s16)
                        } else {
                            // a 2:3 poster writes its title in the band below it
                            caption(focused: focused)
                        }
                    }
                    .offset(y: focused ? height * (Theme.Focus.lift - 1) / 2 : 0)
                    .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
                }
                .frame(width: width)
                .onChange(of: focused) { _, now in if now { onFocus?() } }
            }
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .accessibilityLabel(item.year.map { "\(item.name) \($0)" } ?? item.name)
    }

    private func art(focused: Bool) -> some View {
        ZStack {
            Theme.Colors.bg1
            ArtworkImage(kind: wide ? .thumb(titleId: item.id) : .poster(titleId: item.id)) {
                VStack(spacing: Theme.Space.s16) {
                    Text(Format.monogram(item.name))
                        .font(Theme.Typography.title.weight(.heavy))
                        .tracking(1)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text(item.name)
                        .font(Theme.Typography.captionCompact)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .multilineTextAlignment(.center)
                        .fits(2, size: Theme.Typography.captionCompactSize)
                }
                .padding(.horizontal, Theme.Space.s16)
            }
            if let resume {
                ResumeBar(progress: resume.progress, size: CGSize(width: width, height: height), left: resume.left, showLeft: focused)
            }
        }
        .frame(width: width, height: height)
    }

    /// Reserved whether shown or not: a long name steps down and wraps.
    private func caption(focused: Bool) -> some View {
        VStack(spacing: Theme.Space.s8) {
            let name = place?.name ?? item.name
            let long = name.count > Theme.captionWrapAt
            Text(name)
                .font(long ? Theme.Typography.captionCompact : Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.text)
                .fits(long ? 2 : 1, size: long ? Theme.Typography.captionCompactSize : Theme.Typography.captionSize)
                .multilineTextAlignment(.center)
            Text(place?.said ?? item.kindAndYear)
                .font(long ? Theme.Typography.captionCompact : Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMuted)
        }
        .frame(width: width, height: Theme.Poster.caption, alignment: .top)
        .padding(.top, Theme.Space.s16)
        .opacity(focused ? 1 : 0)
        .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
    }
}

/// How far into a title someone got, and what is left of it. The two travel
/// together everywhere: a bar without the time under the remote says the
/// title was started and not how much evening it would take to finish.
struct Resume: Equatable {
    let progress: Double
    let left: Double

    /// Nil for a title nobody has started, and for one the core has no
    /// length for, where a bar would be drawn against nothing.
    init?(position: Double, duration: Double) {
        guard position > 0, duration > 0 else { return nil }
        progress = min(1, position / duration)
        left = max(0, duration - position)
    }
}

/// The bar across the foot of a picture: how far in someone got, over a
/// veil so it reads against a bright lower edge.
struct ResumeBar: View {
    let progress: Double
    /// The picture's own frame, which every caller already fixes.
    let size: CGSize
    var left: Double? = nil
    var showLeft = false

    var body: some View {
        let track = max(size.width - 2 * Theme.Resume.inset, 0)
        ZStack(alignment: .bottom) {
            Scrim(direction: .vertical)
                .frame(height: size.height * Theme.Resume.veil)
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                if showLeft, let left {
                    Text(t("title.remaining", ["time": Format.runtime(left)]))
                        .font(Theme.Typography.captionCompact.weight(.semibold))
                        .foregroundStyle(Theme.Colors.white)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Resume.trough)
                    Capsule().fill(Theme.Colors.accent)
                        .frame(width: track * min(max(progress, 0), 1))
                }
                .frame(width: track, height: Theme.Resume.height)
            }
            .padding(.horizontal, Theme.Resume.inset)
            .padding(.bottom, Theme.Resume.inset)
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
    }
}

/// The last tile of a rail that goes somewhere: the poster's footprint,
/// outlined, with a word in it.
struct MoreCard: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            FocusReader { focused in
                VStack(spacing: 0) {
                    Text(t("row.more"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(focused ? Theme.Colors.onWhite : Theme.Colors.text)
                        .frame(width: Theme.Poster.width, height: Theme.Poster.height)
                        .background {
                            // the glass stays mounted under the fill: building it again
                            // at every focus move costs a new effect view
                            ZStack {
                                GlassSurface(style: .clear, radius: Theme.Radius.poster, interactive: true)
                                    .opacity(focused ? 0 : 1)
                                if focused {
                                    RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                                        .fill(Theme.Colors.white)
                                }
                            }
                        }
                        .cardShadow(radius: Theme.Radius.poster, focused: focused)
                    Color.clear.frame(height: Theme.Poster.caption).padding(.top, Theme.Space.s16)
                }
                .scaleEffect(focused ? Theme.Focus.poster : 1)
                .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
            }
        }
        .buttonStyle(CardButtonStyle(shadow: false))
    }
}

/// A poster's place in a grid before its page has landed: focusable, so a
/// grid can be scrolled past a page nobody has read yet.
struct PosterSlot: View {
    var body: some View {
        Button {} label: {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                    .fill(Theme.Colors.bg1)
                    .frame(width: Theme.Poster.width, height: Theme.Poster.height)
                    .cardShadow(radius: Theme.Radius.poster, focused: false)
                Color.clear.frame(height: Theme.Poster.caption).padding(.top, Theme.Space.s16)
            }
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .accessibilityLabel(t("library.loading"))
    }
}

/// A person as a tile: a circle, their photograph or their initials, and
/// their name and part under it, always shown where `captioned`.
struct FaceCard: View {
    let person: CastCredit
    var focusable = true
    /// Off beside a heading that already names them.
    var captioned = true
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            FocusReader { focused in
                VStack(spacing: 0) {
                    ZStack {
                        Theme.Colors.bg2
                        if person.personId != 0 {
                            ArtworkImage(kind: .face(personId: person.personId)) { initials }
                        } else {
                            initials
                        }
                    }
                    .frame(width: Theme.Face.size, height: Theme.Face.size)
                    .clipShape(Circle())
                    // lifted by hand: the system's highlight draws its platter
                    // as a rounded square whatever shape the content has
                    .cardShadow(radius: Theme.Face.size / 2, focused: focused)
                    .scaleEffect(focused ? Theme.Focus.lift : 1)
                    .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
                    if captioned {
                        VStack(spacing: Theme.Space.s8) {
                            Text(person.name)
                                .font(Theme.Typography.captionCompact)
                                .foregroundStyle(Theme.Colors.text)
                                .fits(person.character.isEmpty ? 2 : 1, size: Theme.Typography.captionCompactSize)
                                .multilineTextAlignment(.center)
                            if !person.character.isEmpty {
                                Text(person.character)
                                    .font(Theme.Typography.captionCompact)
                                    .foregroundStyle(Theme.Colors.textMuted)
                                    .fits(2, size: Theme.Typography.captionCompactSize)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: Theme.Face.size, height: Theme.Face.caption, alignment: .top)
                        .padding(.top, Theme.Space.s16)
                        .offset(y: focused ? Theme.Face.size * (Theme.Focus.lift - 1) / 2 : 0)
                        .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        // never .focusable: on a button it adds a second focusable around
        // it, which takes the focus the label's FocusReader never sees
        .disabled(!focusable)
        .accessibilityLabel(person.character.isEmpty ? person.name : "\(person.name), \(person.character)")
    }

    private var initials: some View {
        Text(Format.initials(person.name))
            .font(.system(size: Theme.Face.initials, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.Colors.textSecondary)
    }
}

/// A title's own lettering over its words: the words always give the
/// block its height, the logo is drawn over them when the core has one.
struct TitleTreatment: View {
    let titleId: Int64
    let name: String
    var font: Font = Theme.Typography.display
    /// The box the lettering is fitted into. A logo is a picture of a name
    /// and every one comes at a different aspect, so it is the box rather
    /// than either side that keeps two titles the same size on a screen.
    var maxWidth: CGFloat = 820
    var maxHeight: CGFloat = 140
    var lines = 2
    /// The face a name too long for one line of `font` is set in instead,
    /// on its `lines`; nil wraps it in `font`.
    var wrapped: Font?

    var body: some View {
        let picture = Logo.shared.slot(titleId).picture
        ZStack(alignment: .bottomLeading) {
            Group {
                if let wrapped {
                    ViewThatFits(in: .horizontal) {
                        Text(name).font(font).fixedSize()
                        Text(name).font(wrapped).fits(lines)
                    }
                } else {
                    Text(name).font(font).fits(lines)
                }
            }
            .tracking(Theme.Typography.displayTracking)
            .foregroundStyle(Theme.Colors.white)
            .opacity(picture == nil ? 1 : 0)
            if let picture, picture.aspect > 0 {
                let height = min(maxHeight, maxWidth / CGFloat(picture.aspect))
                Image(uiImage: picture.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: height * CGFloat(picture.aspect), height: height)
                    .accessibilityLabel(name)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.dim), value: picture != nil)
        .onAppear { Logo.shared.show(titleId) }
        .onDisappear { Logo.shared.hide(titleId) }
        .onChange(of: titleId) { old, new in
            Logo.shared.hide(old)
            Logo.shared.show(new)
        }
    }
}

/// One title's lettering, observed on its own like an artwork slot.
@MainActor
@Observable
final class LogoSlot {
    fileprivate(set) var picture: Logo.Picture?
}

/// The lettering pictures, kept apart from the artwork because they carry
/// an aspect the layout needs.
@MainActor
final class Logo {
    static let shared = Logo()
    struct Picture { let image: UIImage; let aspect: Float }
    /// How many times a logo still downloading is asked after, half a second apart.
    private static let patience = 16
    /// Weighed by decoded bytes, a few megabytes a logo at 2000 pixels: an
    /// evicted one is decoded again when a title shows it.
    private let slots: NSCache<NSNumber, LogoSlot> = {
        let cache = NSCache<NSNumber, LogoSlot>()
        cache.totalCostLimit = 32 << 20
        return cache
    }()

    /// The slots of the logos on screen with how many views show each, held
    /// apart from the cache: an evicted logo still on screen would be decoded
    /// again and flash back to its words.
    private var shown: [Int64: (slot: LogoSlot, count: Int)] = [:]

    /// The title's slot, asked for on first use.
    func slot(_ titleId: Int64) -> LogoSlot {
        if let held = shown[titleId] { return held.slot }
        let key = NSNumber(value: titleId)
        if let known = slots.object(forKey: key) { return known }
        let slot = LogoSlot()
        slots.setObject(slot, forKey: key)
        Task {
            var picture: Picture?
            // a logo the core is still downloading is asked after again, for
            // a few seconds: the hero shows the words meanwhile
            for _ in 0..<Logo.patience {
                let (settled, found) = await CoreClient.run(on: CoreClient.slow) { () -> (Bool, Picture?) in
                    switch try? CoreClient.shared.logoNow(titleId: titleId) {
                    case .ready(let path, let aspect)?:
                        // drawn at most 1000 points wide, at 2x
                        let image = Artwork.decode(path, maxPixels: 2000)
                        return (true, image.map { Picture(image: UIImage(cgImage: $0), aspect: aspect) })
                    case .fetching?: return (false, nil)
                    default: return (true, nil)
                    }
                }
                picture = found
                if settled { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            slot.picture = picture
            let cost = picture?.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            slots.setObject(slot, forKey: key, cost: cost)
        }
        return slot
    }

    func show(_ titleId: Int64) {
        if let held = shown[titleId] {
            shown[titleId] = (held.slot, held.count + 1)
        } else {
            shown[titleId] = (slot(titleId), 1)
        }
    }

    func hide(_ titleId: Int64) {
        guard let held = shown[titleId] else { return }
        shown[titleId] = held.count > 1 ? (held.slot, held.count - 1) : nil
    }
}

extension TitleItem {
    /// The line under a card's name: a series says so before its year, since
    /// its poster alone does not tell it from a film.
    var kindAndYear: String {
        let year = year.map(String.init)
        guard kind == .show else { return year ?? " " }
        return [t("card.series"), year].compactMap { $0 }.joined(separator: " · ")
    }
}
