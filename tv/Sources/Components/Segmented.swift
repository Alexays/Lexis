import SwiftUI

/// A choice among a few words: the picked one wears the accent, the one
/// under the remote grows white.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selected: Value
    let onPick: (Value) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            ForEach(options, id: \.value) { option in
                Button {
                    onPick(option.value)
                } label: {
                    Text(option.label).font(Theme.Typography.caption)
                }
                .buttonStyle(FilledControlStyle(
                    selected: option.value == selected, horizontal: Theme.Control.chip.width, vertical: Theme.Control.chip.height))
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(option.value == selected ? .isSelected : [])
            }
        }
        .padding(Theme.Space.s8)
        .glassCapsule(tint: Theme.Glass.panel)
    }
}

/// A labelled text field, plain or secret.
struct Field: View {
    let label: String
    @Binding var value: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(label).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textMuted)
            Group {
                if secure {
                    SecureField("", text: $value)
                } else {
                    TextField("", text: $value)
                }
            }
            .font(Theme.Typography.caption)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(label)
        }
        .frame(maxWidth: Theme.Layout.measure, alignment: .leading)
        .padding(.bottom, Theme.Space.s16)
    }
}
