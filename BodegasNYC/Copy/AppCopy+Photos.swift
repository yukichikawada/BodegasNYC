import Foundation

// MARK: - Photo position (#107)

/// The position is data, so these are templates. `index` is zero-based, the
/// text one-based; the voice test runs them over a fixture set.
nonisolated extension AppCopy {
    /// The viewer's counter (design D5): "3 of 12".
    static func photoCounter(index: Int, count: Int) -> CopyString {
        CopyString(kind: .value, text: "\(index + 1) of \(count)")
    }

    /// A thumbnail's and a viewer page's VoiceOver label: "Photo 3 of 12".
    static func photoPositionLabel(index: Int, count: Int) -> CopyString {
        CopyString(kind: .value, text: "Photo \(index + 1) of \(count)")
    }

    /// Posted when the viewer's page changes (design D19): "Photo 3 of 12.".
    static func photoPageAnnouncement(index: Int, count: Int) -> CopyString {
        CopyString(kind: .body, text: "Photo \(index + 1) of \(count).")
    }
}

// MARK: - Upload sheet counts (#107 PR 2)

/// Counts are data, so these are templates and plural helpers; the voice
/// test runs them over fixtures covering one, many and zero.
nonisolated extension AppCopy {
    /// The sheet's trailing button after a pass with failures: "Retry 1".
    static func retryCountLabel(_ count: Int) -> CopyString {
        CopyString(kind: .label, text: "Retry \(count)")
    }

    /// A caption's counter from 120 characters (design D9): "128/140".
    static func captionCount(_ count: Int, limit: Int) -> CopyString {
        CopyString(kind: .value, text: "\(count)/\(limit)")
    }

    /// A caption field's VoiceOver label (design D19): "Caption for photo 2".
    /// `index` is zero-based.
    static func captionFieldLabel(index: Int) -> CopyString {
        CopyString(kind: .value, text: "Caption for photo \(index + 1)")
    }

    /// The progress footer while a pass runs (design D10): "Uploading 3 of 8.".
    /// `index` is zero-based.
    static func uploadProgress(index: Int, count: Int) -> CopyString {
        CopyString(kind: .body, text: "Uploading \(index + 1) of \(count).")
    }

    /// The footer after a pass with failures (design D10):
    /// "2 went up. 1 didn't. Try again.", "None went up. Try again.".
    static func uploadPassFailed(uploaded: Int, failed: Int) -> CopyString {
        let text = uploaded == 0
            ? "None went up. Try again."
            : "\(uploaded) went up. \(failed) didn't. Try again."
        return CopyString(kind: .body, text: text)
    }

    /// The first section's footer when picks dropped out (design D11):
    /// "1 photo couldn't be loaded.", "3 photos couldn't be loaded.".
    static func photosUnloadable(_ count: Int) -> CopyString {
        CopyString(kind: .body, text: "\(photoCount(count)) couldn't be loaded.")
    }

    /// The alert title when none of the picks could be read.
    static func photosUnloadableTitle(_ count: Int) -> CopyString {
        CopyString(kind: .title, text: count == 1 ? "Couldn't load that photo." : "Couldn't load those photos.")
    }

    /// The discard dialog's title (design D10): "Discard 2 photos?".
    static func discardPhotosTitle(_ count: Int) -> CopyString {
        CopyString(kind: .title, text: "Discard \(photoCount(count))?")
    }

    /// "1 photo", "3 photos".
    private static func photoCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }
}
