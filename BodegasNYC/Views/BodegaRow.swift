import SwiftUI

/// A bodega's name over its address, the List tab's row. Also the match row
/// in `DuplicateBodegaSheet` (#20), so the two stay identical: fix it here,
/// never fork it. Wraps at every Dynamic Type size (no line limit).
struct BodegaRow: View {
    let bodega: Bodega

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bodega.name)
                .font(.headline)
            if let address = bodega.address {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
