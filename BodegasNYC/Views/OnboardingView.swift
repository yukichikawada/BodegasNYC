import SwiftUI

/// Three-page first-run intro (#21, spec D5/D6, design DD1). `RootView`
/// lays it over everything (including the loading spinner) on first launch,
/// and `BrowseView`'s Account menu brings it back ("Show Intro Again").
///
/// Ends on every path by calling `onFinish(wantsToAdd)`: Skip and "Just
/// Look Around" pass `false`, "Add a Bodega You Know" passes `true`. It
/// never asks for location and never touches the browse mode; the caller
/// decides what finishing means.
struct OnboardingView: View {
    /// True while `RootView` is still building the environment: page 3's
    /// two exits show a spinner and wait, because there is no map to land
    /// on yet (design DD8).
    let isLoading: Bool
    let onFinish: (_ wantsToAdd: Bool) -> Void

    @State private var page = 0

    private static let pageCount = 3
    private static let lastPage = pageCount - 1

    var body: some View {
        TabView(selection: $page) {
            OnboardingPage(
                systemImage: "cat",
                title: .onboardingPage1Title,
                message: .onboardingPage1Body
            )
            .tag(0)

            OnboardingPage(
                systemImage: "line.3.horizontal.decrease.circle",
                title: .onboardingPage2Title,
                message: .onboardingPage2Body
            ) {
                AmenityRows()
            }
            .tag(1)

            OnboardingPage(
                systemImage: "mappin.and.ellipse",
                title: .onboardingPage3Title,
                message: .onboardingPage3Body
            )
            .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .top, spacing: 0) {
            skipBar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: Chrome

    /// Skip sits top-trailing on pages 1 and 2. On page 3 it is hidden but
    /// keeps its space, so the page content doesn't jump when paging.
    private var skipBar: some View {
        HStack {
            Spacer()
            Button(AppCopy.onboardingSkip.copy.text) {
                onFinish(false)
            }
            .font(.body)
            .frame(minHeight: 44)
            .opacity(page < Self.lastPage ? 1 : 0)
            .disabled(page >= Self.lastPage)
            .accessibilityHidden(page >= Self.lastPage)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        // Opaque like the bottom bar, so page content scrolling up at
        // accessibility sizes or in landscape never shows through Skip.
        .background(Color(.systemBackground))
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            PageDots(count: Self.pageCount, current: page)
            VStack(spacing: 12) {
                if page < Self.lastPage {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            page += 1
                        }
                    } label: {
                        Text(AppCopy.onboardingNext.copy.text)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        onFinish(true)
                    } label: {
                        loadingLabel(AppCopy.onboardingAddAction)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)

                    Button {
                        onFinish(false)
                    } label: {
                        loadingLabel(AppCopy.onboardingBrowseAction)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }
            }
            .controlSize(.large)
            .frame(maxWidth: OnboardingLayout.maxContentWidth)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    private func loadingLabel(_ copy: AppCopy) -> some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
            }
            Text(copy.copy.text)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Layout

    /// Fixed top inset used when the 25% rule would push the content off a
    /// short or crowded screen.
    nonisolated static let compactTopInset: CGFloat = 16

    /// Page content's top inset. DD1's 25% of the available height in the
    /// regular case; a small fixed inset at accessibility Dynamic Type
    /// sizes (the pinned buttons wrap and eat half the screen) and in
    /// compact height (landscape), where 25% would leave the symbol and
    /// title cut off at rest.
    nonisolated static func topInset(height: CGFloat, isAccessibilitySize: Bool, isCompactHeight: Bool) -> CGFloat {
        isAccessibilitySize || isCompactHeight ? compactTopInset : height * 0.25
    }

    // MARK: Motion (design DD14)

    /// The overlay's enter/exit transition: slide down and fade, or a plain
    /// fade under Reduce Motion.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    /// 0.35 s ease, or a 0.25 s fade under Reduce Motion.
    static func animation(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.25 : 0.35)
    }
}

/// Shared with the Streets Walked intro sheet, the intro's fourth page (#126).
enum OnboardingLayout {
    /// Keeps lines readable on iPad and in landscape (design DD1).
    static let maxContentWidth: CGFloat = 560
}

/// One page: symbol, title, body, optional extra content, top-aligned at a
/// quarter of the height, scrolling when Dynamic Type outgrows the screen.
private struct OnboardingPage<Extra: View>: View {
    let systemImage: String
    let title: AppCopy
    let message: AppCopy
    @ViewBuilder let extra: () -> Extra

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 44))
                        .foregroundStyle(Color.catPin)
                        .accessibilityHidden(true)
                    Text(title.copy.text)
                        .font(.display(.largeTitle))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(message.copy.text)
                        .font(.title3)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    extra()
                }
                .frame(maxWidth: OnboardingLayout.maxContentWidth, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(
                    .top,
                    OnboardingView.topInset(
                        height: proxy.size.height,
                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                        isCompactHeight: verticalSizeClass == .compact
                    )
                )
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

extension OnboardingPage where Extra == EmptyView {
    init(systemImage: String, title: AppCopy, message: AppCopy) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Page 2's six data points, in `BodegaFilter.Amenity` order with its
/// captions and symbols.
private struct AmenityRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(BodegaFilter.Amenity.allCases) { amenity in
                Label(amenity.caption.copy.text, systemImage: amenity.systemImage)
                    .font(.title3)
            }
        }
        .padding(.top, 8)
    }
}

/// Custom page indicator: the system `.page` dots are white and vanish on
/// a light background (design DD1). Decorative; VoiceOver users page with
/// Next or the page swipe.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Ready") {
    OnboardingView(isLoading: false) { _ in }
}

#Preview("Loading") {
    OnboardingView(isLoading: true) { _ in }
}
