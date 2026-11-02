import SwiftUI

// MARK: - Account menu (#21, #127, #147)

extension BrowseView {
    /// Account toolbar item: a `Menu` (#21) in three sections (#147 DS2):
    /// the account ("Your Account…" opens the Account sheet, #127 DS1, or
    /// Sign In), Show Intro Again, then the sharing switch with the Privacy
    /// Policy directly under it as its explanation. The same rows signed in
    /// or out (DS7). Same label as before, so the #44 toolbar layout is
    /// unchanged.
    var accountMenu: some View {
        Menu {
            Section {
                if sessionStore.isSignedIn {
                    Button(AppCopy.Account.menuItem.menuItemWithEllipsis) { showingAccount = true }
                } else {
                    Button("Sign In") {
                        showingSignIn = true
                    }
                }
            }
            Section {
                Button(AppCopy.onboardingReplayMenuItem.copy.text) {
                    withAnimation(OnboardingView.animation(reduceMotion: reduceMotion)) {
                        showingOnboarding = true
                    }
                }
            }
            Section {
                // A native toggle (a checkmark item, DS6): flipping it closes
                // the menu and nothing else happens (DS7).
                Toggle(AppCopy.Telemetry.shareUsage.copy.text, isOn: telemetryIsEnabled)
                Link(AppCopy.Account.privacyPolicy.copy.text, destination: AppCopy.Account.privacyPolicyURL)
            }
        } label: {
            Label(
                "Account",
                systemImage: sessionStore.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle"
            )
        }
        .accessibilityFocused($accountMenuFocused)
    }

    /// The setting, written only through `Telemetry.setEnabled(_:)` (eng E3).
    private var telemetryIsEnabled: Binding<Bool> {
        Binding(
            get: { telemetry.isEnabled },
            set: { telemetry.setEnabled($0) }
        )
    }
}

// MARK: - Browse events (#147)

/// `browse_tab_switched` on each change of tab, and `filter_applied` on each
/// change of the required amenities. Search text is not an amenity, so
/// typing never emits.
struct BrowseTelemetryEvents: ViewModifier {
    let telemetry: Telemetry
    let activeTab: BrowseView.Tab
    let filter: BodegaFilter

    func body(content: Content) -> some View {
        content
            .onChange(of: activeTab) { _, tab in
                telemetry.capture(.tabSwitched(tab: tab == .map ? .map : .list))
            }
            .onChange(of: filter.requiredAmenities) { _, amenities in
                telemetry.capture(.filterApplied(amenityCount: amenities.count))
            }
    }
}
