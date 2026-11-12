import LexisCore
import SwiftUI

/// A person's page: their face and their jobs at the head, then one rail
/// of posters per job they did on something in the library.
struct PersonScreen: View {
    let name: String
    @Environment(Navigator.self) private var navigator
    @State private var detail: PersonDetail?
    @State private var error: String?
    /// Whether the face is all the page will get: one asked for while a
    /// title's server is still being asked for it would stay missing.
    @State private var faceLearned = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                head
                    .padding(.horizontal, Theme.Layout.gutter)
                    .padding(.bottom, Theme.Space.s40)
                    .frame(maxWidth: 1200, alignment: .leading)
                if let detail {
                    ForEach(PersonScreen.rails(detail), id: \.title) { rail in
                        Rail(title: rail.title, items: rail.items, surface: .person) { navigator.open($0, from: .person) }
                    }
                } else if error == nil {
                    PlaceholderRails()
                }
            }
            .padding(.top, Theme.Space.s104)
            .padding(.bottom, Theme.Space.s64)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Colors.bg0)
        .ignoresSafeArea()
        // once: a return from a title finds the page as it was
        .onAppear { if detail == nil { load() } }
        .onExitCommand { navigator.back() }
    }

    private var head: some View {
        HStack(alignment: .top, spacing: Theme.Space.s40) {
            FaceCard(
                person: CastCredit(personId: faceLearned ? detail?.personId ?? 0 : 0, name: name, character: ""),
                focusable: false, captioned: false
            ) {}
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Theme.Typography.display)
                    .tracking(Theme.Typography.displayTracking)
                    .foregroundStyle(Theme.Colors.white)
                    .fits(2)
                    .frame(maxWidth: Theme.Layout.measure, alignment: .leading)
                if let detail {
                    let roles = [
                        ("person.acting", detail.actedIn), ("person.directing", detail.directed),
                        ("person.writing", detail.wrote), ("person.music", detail.scored),
                    ]
                    .filter { !$0.1.isEmpty }
                    if !roles.isEmpty {
                        Text(roles.map { t($0.0) }.joined(separator: "  ·  "))
                            .font(Theme.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.Colors.text)
                            .padding(.top, Theme.Space.s16)
                    }
                    // a film they directed and acted in is one film in the library
                    let total = Set(roles.flatMap { $0.1.map(\.id) }).count
                    Text(total == 0 ? t("person.nothingHere") : t("person.inLibrary", ["count": String(total)]))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.top, Theme.Space.s16)
                    // the page has no rail to land on: the remote needs somewhere
                    if total == 0 {
                        ActionButton(label: t("common.back")) { navigator.back() }
                            .padding(.top, Theme.Space.s24)
                    }
                }
                if let error {
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .padding(.top, Theme.Space.s24)
                    ActionButton(label: t("common.retry")) {
                        self.error = nil
                        load()
                    }
                    .padding(.top, Theme.Space.s24)
                }
            }
        }
    }

    /// One rail per job with a shelf's worth of titles. The jobs with fewer
    /// share one rail named after all of them, holding only what the rails
    /// above do not already show: a rail of one poster is not a row.
    private static func rails(_ detail: PersonDetail) -> [(title: String, items: [TitleItem])] {
        let jobs = [
            ("person.acting", detail.actedIn), ("person.directing", detail.directed),
            ("person.writing", detail.wrote), ("person.music", detail.scored),
        ]
        .filter { !$0.1.isEmpty }
        let full = jobs.filter { $0.1.count >= minRail }
        var rails = full.map { (title: "\(t($0.0))  ·  \($0.1.count)", items: $0.1) }
        var shown = Set(full.flatMap { $0.1.map(\.id) })
        var rest: [TitleItem] = []
        var restJobs: [String] = []
        for (key, items) in jobs where items.count < minRail {
            let fresh = items.filter { shown.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            rest += fresh
            restJobs.append(t(key))
        }
        if !rest.isEmpty { rails.append((title: restJobs.joined(separator: "  ·  "), items: rest)) }
        return rails
    }

    private static let minRail = 3

    private func load() {
        let name = name
        Task {
            let landed = await CoreClient.run { Result { try CoreClient.shared.personDetail(name: name) } }
            switch landed {
            case .success(let detail): self.detail = detail
            case .failure(let error): self.error = Format.describe(error)
            }
            // one of their titles files the faces of all its credits, theirs
            // among them, where no other source has one
            if case .success(let detail) = landed,
                let title = (detail.actedIn + detail.directed + detail.wrote + detail.scored).first
            {
                _ = await CoreClient.run { CoreClient.shared.learnFaces(titleId: title.id) }
            }
            faceLearned = true
        }
    }
}
