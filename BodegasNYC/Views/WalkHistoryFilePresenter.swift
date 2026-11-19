import SwiftUI
import UIKit

/// Presents the system share sheet with a walk history export's files (#180)
/// while `export` is set, from a zero-size controller: `ShareSheetPresenter`'s
/// pattern, for file URLs (eng: not extracted into one presenter until #177's
/// link work settles). It presents from the window's frontmost controller, so
/// a sheet opened meanwhile does not swallow it. `onFinish` gets the export
/// and whether a destination completed, once, when the sheet closes.
struct WalkHistoryFilePresenter: UIViewControllerRepresentable {
    @Binding var export: WalkHistoryTransfer.Export?
    let onFinish: (WalkHistoryTransfer.Export, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.finish = { shared, completed in
            export = nil
            onFinish(shared, completed)
        }
        guard let export, coordinator.presented == nil else { return }
        guard let presenter = Self.frontmost(from: host) else {
            Task { @MainActor in coordinator.finish(export, false) }
            return
        }
        coordinator.presented = export
        let controller = UIActivityViewController(activityItems: export.files, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = host.view
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in coordinator.didFinish(completed: completed) }
        }
        presenter.present(controller, animated: true)
    }

    /// The controller to present from: the top of the host window's
    /// presentation chain, or `nil` when the host is not in a window.
    private static func frontmost(from host: UIViewController) -> UIViewController? {
        guard var top = host.view.window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    final class Coordinator {
        var presented: WalkHistoryTransfer.Export?
        var finish: (WalkHistoryTransfer.Export, Bool) -> Void = { _, _ in }

        func didFinish(completed: Bool) {
            guard let presented else { return }
            self.presented = nil
            finish(presented, completed)
        }
    }
}
