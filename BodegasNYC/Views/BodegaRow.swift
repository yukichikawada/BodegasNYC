import SwiftUI

/// A bodega's name over its address, the List tab's row, with how far it is
/// from the user when location is authorized (#68). Also the match row in
/// `DuplicateBodegaSheet` (#20), so the two stay identical: fix it here,
/// never fork it. The sheet calls `BodegaRow(bodega:)`, so its rows show no
/// distance and reserve no slot (a distance from the user would mislead
/// among bodegas 50 m from a dropped pin).
///
/// Layout (design D1, the `ReviewRow` idiom): the distance trails the name
/// on its first baseline while the whole row fits on one line, otherwise
/// (and always at the accessibility sizes) it is a third leading line under
/// the address. The name and address wrap at every size and never truncate;
/// side by side the value never wraps, stacked it may. On iPad the row is a
/// standard full-width `List` row with no max width, so the value sits at
/// the far trailing edge, as system list values do. Stacked under a bodega
/// with no address, the value sits right under the name with no icon: that
/// is deliberate, the words say what it is.
///
/// Reserved slot (design D2): while location is authorized the slot is
/// always there, a hidden placeholder as wide as the longer of "20 blocks"
/// and "0.6 miles" side by side or an empty line stacked, so no row moves
/// when a fix lands; the value fades in and out over it. Not authorized,
/// there is no slot and the row is exactly the pre-#68 row.
///
/// VoiceOver hears one element, `accessibilityText`: "Name, address, 2
/// blocks from you." (eng D7).
struct BodegaRow: View {
    let bodega: Bodega
    var distance: BlockDistance?
    /// Location is authorized: show the slot even before there is a value.
    var reservesDistanceSlot = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        layout
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Self.accessibilityText(name: bodega.name, address: bodega.address, distance: distance)
            )
    }

    /// The row's single VoiceOver label: name, the address when there is one,
    /// and the distance as a sentence when there is one, joined with ", ".
    nonisolated static func accessibilityText(name: String, address: String?, distance: BlockDistance?) -> String {
        let address = address.flatMap { $0.isEmpty ? nil : $0 }
        let sentence = distance.map { AppCopy.distanceFromYou($0).text }
        return [name, address, sentence].compactMap(\.self).joined(separator: ", ")
    }

    private var showsDistanceSlot: Bool { distance != nil || reservesDistanceSlot }

    private var valueText: String? { distance.map { AppCopy.distanceValue($0).text } }

    @ViewBuilder
    private var layout: some View {
        if !showsDistanceSlot || dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                sideBySide
                stacked
            }
        }
    }

    private var sideBySide: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                name
                Spacer(minLength: 0)
                DistanceSlot(
                    text: valueText,
                    placeholders: [
                        AppCopy.distanceValue(.blocks(20)).text,
                        AppCopy.distanceValue(.miles(0.6)).text
                    ],
                    alignment: .trailing
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            }
            address
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            name
            address
            if showsDistanceSlot {
                DistanceSlot(text: valueText, placeholders: [" "], alignment: .leading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var name: some View {
        Text(bodega.name)
            .font(.headline)
    }

    @ViewBuilder
    private var address: some View {
        if let address = bodega.address {
            Text(address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// A distance value over its reserved space (#68, design D2): hidden
/// placeholders hold the size, and the value fades in and out over them
/// (opacity only, `BrowseMotion.Distance.appearSeconds`). A value that only
/// changes is not animated: the animation is keyed on presence. Shared by
/// `BodegaRow` and the detail header; the caller sets font and color.
struct DistanceSlot: View {
    let text: String?
    let placeholders: [String]
    let alignment: Alignment

    var body: some View {
        ZStack(alignment: alignment) {
            ForEach(placeholders, id: \.self) { placeholder in
                Text(verbatim: placeholder)
                    .hidden()
                    .accessibilityHidden(true)
            }
            if let text {
                Text(verbatim: text)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: BrowseMotion.Distance.appearSeconds), value: text != nil)
    }
}
