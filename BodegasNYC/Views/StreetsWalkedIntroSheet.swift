import CoreLocation
import SwiftUI
import UIKit

/// The Streets Walked intro (#126, design D3 to D8): the intro's fourth page,
/// as a sheet over the map. `MapScreenView` presents it once, the first time
/// the map is quiet after onboarding, and again from the Streets Walked
/// menu's "How Streets Walked Works".
///
/// `.large` only on opaque `systemBackground` (D5): the onboarding page's
/// composition at its compact 16pt top inset, `.catPin` 44pt `figure.walk`
/// (the fourth spine symbol, D3), headline in the display register with the
/// header trait (D4), body `.title3` `textMuted`, a `.headline` permission
/// heading over a `.primary` permission paragraph. The bar is pinned on the
/// same opaque ground unless that would leave under 200pt to read (AX sizes
/// in compact height), where it scrolls at the end of the page (D8).
///
/// Content is read live from the view model and the permission client, so
/// a return from Settings refreshes the status in place, without resetting
/// the scroll. Start Recording only records the tap and dismisses: the
/// presenter runs the menu's path once the sheet is gone (AC6).
struct StreetsWalkedIntroSheet: View {
    let viewModel: StreetsWalkedViewModel
    let locationPermissionClient: LocationPermissionClient
    /// Start Recording: the presenter starts after the dismissal.
    let onStartRecording: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var barHeight: CGFloat = 0

    private var content: StreetsWalkedIntroContent {
        StreetsWalkedIntroContent.make(
            recordingState: viewModel.recordingState,
            authorizationStatus: locationPermissionClient.authorizationStatus
        )
    }

    var body: some View {
        let content = content
        NavigationStack {
            GeometryReader { proxy in
                let pinsBar = StreetsWalkedIntro.pinsButtonBar(
                    availableHeight: proxy.size.height,
                    barHeight: barHeight
                )
                ScrollView {
                    VStack(spacing: 0) {
                        page(content)
                        if !pinsBar { buttonBar(content) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if pinsBar { buttonBar(content) }
                }
            }
            .navigationTitle(AppCopy.StreetsWalkedIntro.title.copy.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppCopy.doneAction.copy.text) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color(.systemBackground))
    }

    /// Symbol, headline, status (reopen only), what it does, permission
    /// heading and paragraph, where to find it later; each its own element.
    private func page(_ content: StreetsWalkedIntroContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "figure.walk")
                .font(.system(size: 44))
                .foregroundStyle(Color.catPin)
                .accessibilityHidden(true)
            Text(AppCopy.StreetsWalkedIntro.headline.copy.text)
                .font(.display(.largeTitle))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let status = content.status {
                Text(status.copy.text)
                    .font(.subheadline)
                    .foregroundStyle(status == .recordingOn ? Color.textMuted : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("streetsWalkedIntro.status")
            }
            muted(.whatItDoes)
            Text(AppCopy.StreetsWalkedIntro.permissionHeading.copy.text)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(content.permission.copy.text)
                .font(.title3)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("streetsWalkedIntro.permission")
            muted(.findItLater)
        }
        .frame(maxWidth: OnboardingLayout.maxContentWidth, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, OnboardingView.compactTopInset)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    private func muted(_ copy: AppCopy.StreetsWalkedIntro) -> some View {
        Text(copy.copy.text)
            .font(.title3)
            .foregroundStyle(Color.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The onboarding page 3 bar: full width, `.controlSize(.large)`, 12pt
    /// apart, on the sheet's opaque ground. Nothing when there is no action.
    @ViewBuilder
    private func buttonBar(_ content: StreetsWalkedIntroContent) -> some View {
        if !content.actions.isEmpty {
            VStack(spacing: 12) {
                ForEach(content.actions, id: \.self) { action in
                    button(action)
                }
            }
            .controlSize(.large)
            .frame(maxWidth: OnboardingLayout.maxContentWidth)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        }
    }

    @ViewBuilder
    private func button(_ action: StreetsWalkedIntroContent.Action) -> some View {
        switch action {
        case .startRecording:
            Button {
                onStartRecording()
                dismiss()
            } label: {
                label(AppCopy.startRecordingAction.copy.text)
            }
            .buttonStyle(.borderedProminent)
        case .notNow:
            Button {
                dismiss()
            } label: {
                label(AppCopy.StreetsWalkedIntro.notNowAction.copy.text)
            }
            .buttonStyle(.bordered)
        case .openSettings:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                label(AppCopy.YourBlocks.openSettings.copy.text)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Full width and allowed to wrap at any size (D8).
    private func label(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}
