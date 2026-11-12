import SwiftUI

/// Every visual constant of the app. Nothing else holds a colour, a radius,
/// a type size or a duration: one file is what keeps the screens one design.
enum Theme {
    enum Colors {
        static let bg0 = Color(hex: 0x0B0B0F)
        static let bg1 = Color(hex: 0x101014)
        static let bg2 = Color(hex: 0x16161C)
        static let hairline = Color(hex: 0x2E2E38)
        /// A hair below pure white and a hair toward the accent's own hue:
        /// focus fills with this, and it has to read as the single brightest
        /// thing on screen without the flash of paper-white on near-black.
        static let white = Color(hex: 0xF4F1FA)
        static let text = Color(hex: 0xEDEDF2)
        static let textSecondary = Color(hex: 0xB7B7C2)
        static let textMuted = Color(hex: 0x8F8F9A)
        static let accent = Color(hex: 0xB69CFF)
        static let onAccent = Color(hex: 0x1A1030)
        /// The ink a focused fill carries text in: the darkest tone the
        /// palette has, because focus is the strongest signal on screen.
        static let onWhite = Color(hex: 0x0B0B0F)
        static let error = Color(hex: 0xFF6B6B)
    }

    /// The glass is tinted white, faintly: on the near-black canvas the
    /// effect alone settles into a flat grey, and the tint is what lifts its
    /// rim and lets what is behind show through it.
    ///
    /// Three storeys, not two. Four per cent between the lowest and the
    /// highest surface is not an elevation, it is a rounding error: nothing
    /// on screen says what is in front of what. The ladder spans eleven.
    enum Glass {
        static let panel = Colors.white.opacity(0.05)
        static let control = Colors.white.opacity(0.08)
        /// What sits above everything: a menu held open over the screen it
        /// came from.
        static let raised = Colors.white.opacity(0.16)
        /// The one block on a page that is not a neutral surface: a hue in
        /// the glass is what makes it read as singled out rather than as
        /// another panel.
        static let accented = Colors.accent.opacity(0.18)
        /// The line between two rows of a glass panel, and the well a mark
        /// sits in on one.
        static let rule = Colors.white.opacity(0.08)
        /// A sunken field inside a glass panel.
        static let well = Colors.bg0.opacity(0.55)
    }

    enum Radius {
        static let poster: CGFloat = 8
        static let card: CGFloat = 12
        /// A row or a tile in a list of settings.
        static let row: CGFloat = 14
        /// A glass panel holding several rows.
        static let panel: CGFloat = 16
        /// A media badge, a mark set in the flow of a line.
        static let badge: CGFloat = 6
        static let pill: CGFloat = 999
    }

    /// The rhythm. Six values, and no margin written anywhere else in
    /// `tv/Sources` outside the player: the 104 and the 64 are what let a
    /// screen breathe, the 8 and the 16 are what glue together the things
    /// that belong together.
    enum Space {
        static let s8: CGFloat = 8
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s40: CGFloat = 40
        static let s64: CGFloat = 64
        static let s104: CGFloat = 104
    }

    /// SF system only: a size, a weight and a tracking are the whole of the
    /// type here. The sizes are named beside the fonts they make, because a
    /// `Font` does not answer for its own size and the floor is tested.
    enum Typography {
        /// SF compressed at this size is a letter almost no tvOS app uses
        /// although the system carries it: it is what makes a screen read as
        /// a cover rather than as a panel.
        static let displaySize: CGFloat = 108
        static let display = Font.system(size: displaySize, weight: .black).width(.compressed)
        static let displayTracking: CGFloat = -2
        /// What a name too long for one line of `display` steps down to, on two.
        static let displayWrapped = Font.system(size: 72, weight: .black).width(.compressed)
        static let titleSize: CGFloat = 44
        static let title = Font.system(size: titleSize, weight: .bold)
        static let titleTracking: CGFloat = -0.5
        static let bodySize: CGFloat = 29
        static let body = Font.system(size: bodySize, weight: .regular)
        /// A row's name: the body's size, in the weight that makes it a heading.
        static let rowTitle = Font.system(size: bodySize, weight: .bold)
        static let captionSize: CGFloat = 23
        static let caption = Font.system(size: captionSize, weight: .regular)
        /// What a caption steps down to when its title does not fit the card
        /// at the caption's size: two wrapped lines and the year still fit.
        static let captionCompactSize: CGFloat = 17
        static let captionCompact = Font.system(size: captionCompactSize, weight: .regular)
        /// The smallest size a line may shrink to before it wraps instead:
        /// `captionCompact`, the smallest this app sets anything at three metres.
        static let shrinkFloor: CGFloat = captionCompactSize
        /// A name set big inside a tile: between the caption and the title.
        static let headlineSize: CGFloat = 38
        static let headline = Font.system(size: headlineSize, weight: .bold)
        /// Signage rather than prose: role names, rail headings, section
        /// heads. Always rendered in capitals, which is what the tracking is
        /// for. It keeps its size because 20 is already low.
        static let labelSize: CGFloat = 20
        static let label = Font.system(size: labelSize, weight: .semibold)
        static let labelTracking: CGFloat = 2.4
    }

    /// A poster is 2:3, and the caption under it is reserved whether it is
    /// shown or not: it fades in on focus, so it never changes the measure.
    enum Poster {
        static let width: CGFloat = 300
        static let height: CGFloat = 450
        static let gap = Space.s24
        static let caption: CGFloat = 72
    }

    /// The poster a reason is made of, and the band that names it. Smaller
    /// than the library's, because it carries its title and year under it and
    /// the two together have to leave a whole row on the first screen.
    ///
    /// Eight of them sit whole across a 1920 screen and the ninth is cut by
    /// the right edge. That overhang is the only thing on the screen that
    /// says the row continues; a row that ends flush at the margin reads as a
    /// row that has ended.
    enum Reason {
        static let width: CGFloat = 196
        static let height: CGFloat = 294
        static let gap = Space.s24
        /// Three lines for a name that steps down and wraps, and the year under
        /// it. Reserved whole whatever the name needs, so no row moves when
        /// the one before it holds a long title.
        static let captionBand =
            3 * ceil(Typography.captionCompactSize * 1.2) + Space.s8
            + ceil(Typography.captionCompactSize * 1.2)
        /// The band and the air over it.
        static let caption = Space.s16 + captionBand
        /// A focused card lifts its picture, and the band under it moves
        /// down by the same amount, so the picture's growth is the whole of it.
        static let inset: CGFloat = ceil(height * (Focus.lift - 1) / 2)
        /// How many fit a full row on the grid a reason opens onto, where
        /// nothing is meant to hang off the edge.
        static let columns = 8
    }

    /// A title longer than this many characters does not fit one line of the
    /// caption at the card's width: past it, the caption steps down and wraps.
    static let captionWrapAt = 26

    /// The resume rail is landscape: a 16:9 thumbnail carries the frame the
    /// viewer stopped on.
    enum Landscape {
        static let width: CGFloat = 400
        static let height: CGFloat = 225
    }

    /// One episode in a season's list: a full-width row, its frame on the
    /// left and its words on the right.
    enum Episode {
        static let stillWidth: CGFloat = 320
        static let stillHeight: CGFloat = 180
        static let gap: CGFloat = 28
        static let rowGap: CGFloat = 24
        static let plate: CGFloat = 52
        static let summaryLines = 2
    }

    /// How hard the frame of an episode nobody has watched is blurred.
    enum Unseen {
        static let still: CGFloat = 18
    }

    /// The bar across the foot of a picture, saying how far in someone got.
    enum Resume {
        static let height: CGFloat = 8
        static let inset: CGFloat = 20
        static let veil: CGFloat = 0.42
        static let trough = Colors.white.opacity(0.22)
    }

    /// A cast tile is a circle, which says "a person" before a photograph
    /// has loaded.
    enum Face {
        static let size: CGFloat = 160
        static let gap: CGFloat = 24
        static let caption: CGFloat = 76
        static let initials: CGFloat = 44
    }

    /// What focus does: a picture card takes the system's highlight and
    /// grows by `lift`; a filled control takes white and grows by `wide`;
    /// selection keeps the accent.
    enum Focus {
        static let poster: CGFloat = 1.08
        static let wide: CGFloat = 1.04
        /// A tab of the bar, which grows a little more than a button: it is
        /// small, and the only thing in the bar that moves.
        static let tab: CGFloat = 1.06
        /// How much the system's highlight grows a picture, which the caption
        /// under it steps down by so the picture never covers it.
        static let lift: CGFloat = 1.1
        static let ring: CGFloat = 3
        static let seam: CGFloat = 1
    }

    /// A card is lit from above and casts below itself. Without this a card
    /// is a rectangle printed on the background; with it the screen has a
    /// near plane and a far one, which is what makes a card read as an
    /// object rather than as paper.
    enum Depth {
        static let restRadius: CGFloat = 14
        static let restY: CGFloat = 7
        static let restOpacity = 0.38
        static let focusRadius: CGFloat = 46
        static let focusY: CGFloat = 28
        static let focusOpacity = 0.74
        /// How much noise the backdrop carries. Below about six per cent it
        /// stops breaking the bands it exists to break; above twelve the
        /// screen looks dirty rather than filmic.
        static let grain = 0.09
    }

    /// How long the things that move take, in seconds.
    enum Motion {
        static let focus = 0.120
        static let dim = 0.220
        static let pill = 0.180
        static let spin = 1.0
        static let overlayIn = 0.150
        static let overlayOut = 0.250
        static let scrubSlide = 0.120
        static let heroSwap = 0.160
        /// Long enough to read as one picture dissolving into the next, short
        /// enough that a thumb resting on a card is not kept waiting.
        static let backdrop = 0.400
        static let heroSettle = 0.180
        /// The hero shutting over one reason while it opens over the next.
        static let heroLane = 0.350
    }

    /// A focused card grows around its centre, and a list clips to its
    /// bounds: a rail or a grid reserves this much around them.
    static let focusInset: CGFloat =
        ceil((Poster.height + Poster.caption) * (Focus.poster - 1) / 2) + Focus.ring * 2
    /// A face lifts its picture and moves its caption down by as much.
    static let faceInset: CGFloat = ceil(Face.size * (Focus.lift - 1) / 2)
    /// The same reservation for a rail of wide cards, whose caption moves
    /// down with the picture as a face's does.
    static let wideInset: CGFloat = ceil(Landscape.height * (Focus.lift - 1) / 2)

    /// What the home is made of, band by band: the bar, the title the remote
    /// is on, and the first reason under it. Those three are whole on the
    /// first screen, so their heights are declared rather than emergent and
    /// `ThemeTests` sums them against it. The reasons below scroll and are
    /// not counted here.
    enum Home {

        /// The title's own lettering, or the display face where it has none,
        /// at a fixed height: a tall logo never pushes the row down.
        static let heroTitle: CGFloat = 180
        /// The widest a logo is drawn; a wide one is fitted by its width.
        static let heroLogoWidth: CGFloat = 560
        /// Director, country, year, runtime: one line, no labels and no
        /// separators, the way a cinema programme sets it.
        static let heroMeta: CGFloat = 36
        /// The start of the synopsis, two lines and cut there.
        static let heroOverview = 2 * ceil(Typography.captionSize * 1.2)
        /// One line of the caption, in a control's fill when it is a door.
        static let heroBand = ceil(Typography.captionSize * 1.2) + Space.s8 * 2
        static let hero =
            heroTitle + Space.s16 + heroMeta + Space.s16 + heroOverview + Space.s16 + heroBand
        /// The air between the hero and the reason it opens over: what is left
        /// of the first screen once the bar, the hero and a reason are laid.
        static let heroGap = Space.s64 + Space.s8

        /// The reason's name, on one line of its heading face.
        static let rowLabel = ceil(Typography.bodySize * 1.2)
        /// Between a reason's name and its cards.
        static let labelGap = Space.s16
        static let row =
            Reason.inset + rowLabel + labelGap + Reason.height + Reason.caption + Reason.inset

        /// The air between two reasons once the screen scrolls. A reason
        /// already reserves the growth of a focused card above and below it,
        /// so the gap only has to separate two bands, not clear them.
        static let gap = Space.s24
        /// What has to be whole on the first screen, and on every screen a
        /// move between reasons scrolls to: a focused card past the fold is
        /// scrolled into view by the system, which moves the screen along a
        /// row.
        static let total = Layout.bar + hero + heroGap + row
    }

    /// The insets of a filled control: a button, and a chip in a wrapped row.
    enum Control {
        static let regular = CGSize(width: 32, height: 16)
        static let chip = CGSize(width: 28, height: 12)
    }

    /// tvOS lays out in 1920x1080 points on every device it runs on.
    enum Layout {
        static let screenWidth: CGFloat = 1920
        static let screenHeight: CGFloat = 1080
        static let gutter: CGFloat = 80
        /// A badge's text sits this close to its outline, under the rhythm on purpose.
        static let badgeInset: CGFloat = 2
        static let railOverlap: CGFloat = 146
        /// The top of the 60 point inset tvOS keeps clear for overscan.
        static let pillTop: CGFloat = 60
        /// The bar's capsule, and the side inset of a word in it.
        static let pillHeight: CGFloat = 76
        static let pillPadding: CGFloat = 28
        /// The band every tab screen leaves at its top for the bar.
        static let bar = pillTop + pillHeight + Space.s24
        /// The widest a column of words runs before a line gets too long to read.
        static let measure: CGFloat = 880
        static let settingsColumn: CGFloat = 340
        static let searchBand: CGFloat = 320
        /// The run-out under a grid, so the last row can be focused and grow
        /// without the scroll view ending against it.
        static let gridRunOut: CGFloat = 82
        /// Where a title's words start down its backdrop: far enough that the
        /// picture is a picture before it is a heading.
        static let detailTop: CGFloat = 260
    }

    /// Measured on the native tvOS 27 player (AVPlayerViewController), in
    /// points of the 1920 x 1080 screen; a top is counted from the top.
    enum Player {
        static let margin: CGFloat = 84
        static let rowInset: CGFloat = 80
        static let rowWidth: CGFloat = 1760
        static let bottom: CGFloat = 44
        static let gradientHeight: CGFloat = 460

        static let contextTop: CGFloat = 758
        static let contextHeight: CGFloat = 30
        static let context: CGFloat = 25
        static let titleTop: CGFloat = 802
        static let titleHeight: CGFloat = 69
        static let title: CGFloat = 57

        static let roundButton: CGFloat = 66
        static let roundButtonTop: CGFloat = 800
        static let roundButtonGap: CGFloat = 24
        static let roundGlyph: CGFloat = 30

        static let barTop: CGFloat = 903
        static let barHeight: CGFloat = 14
        static let track: CGFloat = 10
        static let chapterWidth: CGFloat = 2
        static let needleWidth: CGFloat = 2
        static let needleHeight: CGFloat = 17
        static let scrubNeedleHeight: CGFloat = 42
        static let needleOverhang: CGFloat = 4
        static let timeTop: CGFloat = 925
        static let timeHeight: CGFloat = 28
        static let time: CGFloat = 23
        static let stateGlyph: CGFloat = 35
        static let stateGap: CGFloat = 10
        static let thumbnail = CGSize(width: 400, height: 225)
        static let thumbnailGap: CGFloat = 24

        static let pillsLeft: CGFloat = 76
        static let pillTop: CGFloat = 968
        static let pillHeight: CGFloat = 68
        static let pillPadding: CGFloat = 34
        static let pillGap: CGFloat = 16
        static let pillLabel: CGFloat = 29

        static let tabShift: CGFloat = 284
        static let tabContentTop: CGFloat = 794
        static let tabContentHeight: CGFloat = 250
        static let tabContentRadius: CGFloat = 36
        static let poster = CGSize(width: 136, height: 204)
        static let posterInset: CGFloat = 23
        static let infoTextInset: CGFloat = 33
        static let infoTextGap: CGFloat = 40
        static let infoHeading: CGFloat = 31
        static let infoBody: CGFloat = 24
        static let summaryWidth: CGFloat = 1024
        static let badge: CGFloat = 17
        static let fromBeginning = CGSize(width: 368, height: 68)
        static let fromBeginningTop: CGFloat = 50
        static let fromBeginningTrailing: CGFloat = 46
        static let chapterCard = CGSize(width: 320, height: 228)
        static let chapterGap: CGFloat = 40
        static let chapterRadius: CGFloat = 20
        static let chapterTextInset: CGFloat = 14
        static let chapterNow: CGFloat = 17
        static let choiceLabel: CGFloat = 360
        static let statRow: CGFloat = 50
        static let statsTop: CGFloat = 25

        static let menuWidth: CGFloat = 450
        static let menuRowWidth: CGFloat = 440
        static let menuRow: CGFloat = 66
        static let menuRowTall: CGFloat = 86
        static let menuInset: CGFloat = 12
        static let menuHeader: CGFloat = 49
        static let menuHeaderLabel: CGFloat = 23
        static let menuRule: CGFloat = 19
        static let menuLabel: CGFloat = 25
        static let menuTextInset: CGFloat = 30
        static let menuCheckColumn: CGFloat = 85
        static let menuGap: CGFloat = 24
        static let menuTopLimit: CGFloat = 60
        static let menuRadius: CGFloat = 40

        static let panelRadius: CGFloat = 18
        static let noticeInset = CGSize(width: 40, height: 22)
        static let rowLabel: CGFloat = 28
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
