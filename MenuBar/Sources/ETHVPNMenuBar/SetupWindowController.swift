import AppKit
import SwiftUI

final class SetupWindowController {
    var onComplete: (() -> Void)?
    private var window: NSWindow?
    private var closeDelegate: WindowCloseDelegate?
    private var finished = false

    func showPanel() {
        finished = false
        if window == nil { buildWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let vm = SetupViewModel()
        let view = SetupView(vm: vm, onDone: { [weak self] in self?.finish() })
        let hc = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hc)
        win.title = "ETH VPN — Setup"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        let delegate = WindowCloseDelegate { [weak self] in self?.finish() }
        win.delegate = delegate
        closeDelegate = delegate
        window = win
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        window?.close()
        window = nil
        closeDelegate = nil
        NSApp.setActivationPolicy(.accessory)
        onComplete?()
    }
}

private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
