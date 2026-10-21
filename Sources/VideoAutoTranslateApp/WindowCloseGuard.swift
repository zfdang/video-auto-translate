import SwiftUI
import AppKit

struct WindowCloseGuard: NSViewRepresentable {
    let appState: AppState
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var appState: AppState?
        weak var previous: NSWindowDelegate?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard appState?.confirmReplacingProject() != false else { return false }
            if appState?.project.isDirty == true { appState?.clearRecoveryCheckpoint() }
            return true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previous?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.appState = appState
        DispatchQueue.main.async {
            if let window = view.window, window.delegate !== context.coordinator {
                context.coordinator.previous = window.delegate
                window.delegate = context.coordinator
            }
        }
    }
}
