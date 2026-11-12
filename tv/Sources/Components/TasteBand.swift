import SwiftUI

/// Why a title is on the shelf, in one sentence: the film the viewer liked
/// that brought it here, named inside the sentence and coloured in it.
///
/// The catalogue owns the words, so they are split on the placeholder rather
/// than composed here: setting the leader alone in a pill leaves the words
/// around it stranded, and a sentence broken into three views cannot wrap.
/// Under the remote the whole of it is dark on white, where the accent would
/// be its one unreadable word.
struct TasteReason: View {
    let leader: String
    var font: Font = Theme.Typography.body
    var lines = 2

    var body: some View {
        let parts = t("why.vein").components(separatedBy: "{leader}")
        FocusReader { focused in
            (Text(parts.first ?? "")
                + Text(leader)
                .foregroundStyle(focused ? Theme.Colors.onWhite : Theme.Colors.accent)
                + Text(parts.count > 1 ? parts[1] : ""))
                .font(font)
                .fits(lines)
        }
    }
}
