import SwiftUI
import UIKit

/// The full-screen photo viewer (#107 PR 1), presented as a
/// `.fullScreenCover` from a gallery thumbnail with the zoom transition.
///
/// Takes a snapshot of the gallery's photos at open (eng O3): nothing
/// elsewhere changes them while it is up, and a flag does not refetch.
/// `currentID` starts at the tapped photo and reports the page back, so the
/// gallery can scroll that thumbnail into view before the return zoom.
///
/// Pages are `TabView(.page)`; each page is a `UIScrollView` zoom page
/// (eng C2: SwiftUI pinch inside a paged container loses to the pager). At
/// 1x the image fits the bounds exactly, so horizontal pans go to the pager;
/// zoomed, the page's own scroll view takes them, so paging only happens at
/// 1x.
///
/// Always dark, as in Photos (design D3); semantic colors only. Controls
/// show on open and never auto-hide; a single tap toggles them (opacity,
/// `PhotoMotion.chromeSeconds`), except under VoiceOver where they stay.
///
/// A photo with a caption shows it in an opaque band over the bottom of the
/// page while the controls are visible (design D2, PR 2). The page stays full
/// screen (QA P2); the zoom page fits and centres the photo in the space
/// above the band. Hiding the controls hides the band and the photo gets
/// the full screen.
///
/// The upload sheet opens it in local mode (design D13): prepared JPEGs, no
/// Flag menu (`makeFlagViewModel` is `nil`) and no captions.
struct PhotoViewer: View {
    let items: [PhotoViewerItem]
    @Binding var currentID: PhotoViewerItem.ID
    /// Builds the flag form for a photo; the sheet is presented over the
    /// viewer, which stays open (eng A2). `nil` hides the menu.
    let makeFlagViewModel: ((Photo.ID) -> FlagIssueViewModel)?
    let sessionStore: SessionStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// The app's scheme, read above the viewer's own forced-dark
    /// environment: the flag sheet is a standard form and keeps it.
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var controlsVisible = true
    @State private var groundOpacity: Double = 1
    @State private var zoomRequests = PhotoZoomRequests()
    @State private var flagIssueViewModel: FlagIssueViewModel?
    /// Same hand-off as `BodegaDetailView`: the alert is shown from the
    /// sheet's `onDismiss`, never while the sheet is still leaving.
    @State private var flagSubmittedPendingConfirmation = false
    @State private var showingFlagConfirmation = false
    @State private var captionExpanded = false
    /// The viewer's full-screen frame and the band's top edge, both global:
    /// the band covers `viewerFrame.maxY - bandTop` of the page's bottom.
    @State private var viewerFrame: CGRect = .zero
    @State private var bandTop: CGFloat = 0
    /// VoiceOver focus goes back to the menu button after the flag sheet
    /// closes (design D19).
    @AccessibilityFocusState private var menuFocused: Bool

    private var position: PhotoViewerPosition {
        PhotoViewerPosition(ids: items.map(\.id), currentID: currentID)
    }

    private var showsControls: Bool { controlsVisible || voiceOverEnabled }

    private var currentCaption: String? {
        items.first { $0.id == currentID }?.caption
    }

    /// The band is up only with the controls and a caption.
    private var bandCaption: String? { showsControls ? currentCaption : nil }

    /// How much of the page's bottom the band covers; 0 without a band.
    private var bandObstruction: CGFloat {
        guard bandCaption != nil, bandTop > 0 else { return 0 }
        return max(0, viewerFrame.maxY - bandTop)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .opacity(groundOpacity)
                    .ignoresSafeArea()
                pager
                // The band overlays the bottom of the full-screen page (the
                // page never resizes, QA P2); the page fits the photo in the
                // space above it through `bandObstruction`.
                if let bandCaption {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        PhotoCaptionBand(
                            caption: bandCaption,
                            maxExpandedHeight: viewerFrame.height * PhotoMotion.captionMaxHeightFraction,
                            isExpanded: $captionExpanded
                        )
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }, action: {
                            bandTop = $0
                        })
                    }
                    .opacity(groundOpacity)
                    .transition(.opacity)
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { viewerFrame = $0 })
            .ignoresSafeArea()
            .containerBackground(.clear, for: .navigation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { controls }
            .toolbarVisibility(showsControls ? .visible : .hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .environment(\.colorScheme, .dark)
        .presentationBackground(.clear)
        .accessibilityAction(.escape) { dismiss() }
        .onChange(of: currentID) {
            zoomRequests.pageChanged()
            captionExpanded = false
            AccessibilityNotification.Announcement(position.announcement.text).post()
        }
        .onChange(of: showsControls) { _, visible in
            if !visible { captionExpanded = false }
        }
        .sheet(item: $flagIssueViewModel, onDismiss: {
            if flagSubmittedPendingConfirmation {
                flagSubmittedPendingConfirmation = false
                showingFlagConfirmation = true
            } else {
                menuFocused = true
            }
        }, content: { flagIssueViewModel in
            FlagIssueView(viewModel: flagIssueViewModel, sessionStore: sessionStore) { _ in
                flagSubmittedPendingConfirmation = true
                self.flagIssueViewModel = nil
            }
            .environment(\.colorScheme, systemColorScheme)
        })
        .alert(AppCopy.flagSubmittedTitle.copy.text, isPresented: $showingFlagConfirmation) {
            Button(AppCopy.okAction.copy.text, role: .cancel) { menuFocused = true }
        } message: {
            Text(AppCopy.flagSubmittedBody.copy.text)
        }
    }

    private var pager: some View {
        TabView(selection: $currentID) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, photo in
                PhotoPage(
                    source: photo.source,
                    isCurrent: photo.id == currentID,
                    label: AppCopy.photoPositionLabel(index: index, count: items.count).text,
                    caption: photo.caption,
                    bottomObstruction: bandObstruction,
                    zoomCommand: zoomRequests.command(for: photo.id),
                    onSingleTap: toggleControls,
                    onZoomAction: { action in
                        zoomRequests.request(action, for: photo.id)
                    },
                    onZoomCommandApplied: { serial in
                        zoomRequests.consume(serial: serial)
                    },
                    onSwipeDownChanged: { translation in
                        groundOpacity = PhotoMotion.SwipeDown.groundOpacity(translation: translation)
                    },
                    onSwipeDownEnded: { dismissed in
                        if dismissed {
                            dismiss()
                        } else {
                            withAnimation(PhotoMotion.SwipeDown.snapBackAnimation) {
                                groundOpacity = 1
                            }
                        }
                    }
                )
                .tag(photo.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Label(AppCopy.photoViewerCloseLabel.copy.text, systemImage: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("photoViewer.close")
        }
        ToolbarItem(placement: .principal) {
            Text(position.counter.text)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .accessibilityIdentifier("photoViewer.counter")
        }
        if let makeFlagViewModel {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(AppCopy.flagPhotoAction.copy.text, systemImage: "flag") {
                        flagIssueViewModel = makeFlagViewModel(currentID)
                    }
                } label: {
                    Label(AppCopy.photoViewerMoreLabel.copy.text, systemImage: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("photoViewer.more")
                .accessibilityFocused($menuFocused)
            }
        }
    }

    private func toggleControls() {
        guard !voiceOverEnabled else { return }
        withAnimation(PhotoMotion.chromeAnimation) {
            controlsVisible.toggle()
        }
    }
}

/// A VoiceOver zoom request for one page. `serial` makes a repeat of the
/// same action a new request; `photoID` keeps it off every other page.
nonisolated struct PhotoZoomCommand: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case zoomIn
        case reset
    }

    let serial: Int
    let photoID: Photo.ID
    let action: Action
}

/// The viewer's one pending VoiceOver zoom request. A page consumes it once
/// applied and a page change drops it, so a page view that TabView
/// recreates (its last-applied serial forgotten) never replays it.
nonisolated struct PhotoZoomRequests: Equatable, Sendable {
    private(set) var pending: PhotoZoomCommand?
    private var nextSerial = 1

    mutating func request(_ action: PhotoZoomCommand.Action, for photoID: Photo.ID) {
        pending = PhotoZoomCommand(serial: nextSerial, photoID: photoID, action: action)
        nextSerial += 1
    }

    /// Clears the request `serial` names; a newer one stays pending.
    mutating func consume(serial: Int) {
        if pending?.serial == serial { pending = nil }
    }

    mutating func pageChanged() {
        pending = nil
    }

    func command(for photoID: Photo.ID) -> PhotoZoomCommand? {
        pending?.photoID == photoID ? pending : nil
    }
}
