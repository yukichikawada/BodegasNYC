import SwiftUI

/// Non-modal: `didUpdateLocations`'s save-failure path can re-set
/// `lastTrackingError` on every subsequent location update if the
/// underlying condition doesn't resolve, so a `.alert` would re-interrupt
/// the user repeatedly. This communicates "tracking is currently degraded"
/// as ongoing state instead, dismissible without blocking map interaction.
struct TrackingErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
