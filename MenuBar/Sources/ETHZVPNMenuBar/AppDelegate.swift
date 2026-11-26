import AppKit
import Network
import ServiceManagement
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var setupWindowController: SetupWindowController?
    private var networkMonitor: NWPathMonitor?
    private var pulseTimer: Timer?
    private var menuIsOpen = false

    private let autoConnectKey = "eth-vpn-auto-connect"
    private let firstRunDoneKey = "eth-vpn-did-complete-first-run"
    private var vpn: VPNController { .shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        // No statusItem.menu: clicks are handled manually so right-click can toggle.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp, .rightMouseDown])

        vpn.onStateChange = { [weak self] _ in DispatchQueue.main.async { self?.stateChanged() } }
        vpn.onError = { [weak self] message in self?.showConnectionError(message) }
        NotificationCenter.default.addObserver(self, selector: #selector(openProfiles), name: .vpnSecretsNotFound, object: nil)

        updateIcon()
        runFirstLaunchSetup()
        autoConnectIfEnabled()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if vpn.isOpenconnectRunning() { vpn.disconnect() }
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        // macOS 27 beta delivers right-clicks on status items as left-clicks, so
        // the toggle only works there with Control-click until that is fixed.
        let isRightClick = NSApp.currentEvent.map {
            $0.type == .rightMouseDown || $0.type == .rightMouseUp
                || ($0.type == .leftMouseUp && $0.modifierFlags.contains(.control))
        } ?? false

        if isRightClick {
            vpn.toggleConnection()
        } else {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    private func stateChanged() {
        updateIcon()
        if menuIsOpen { menuNeedsUpdate(menu) }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let style = StatusStyle.current
        button.image = StatusBadge.image(style)
        pulseTimer?.invalidate()
        pulseTimer = nil
        button.alphaValue = style == .disconnected ? 0.75 : 1
        if style == .connecting {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak button] _ in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.5
                    button?.animator().alphaValue = (button?.alphaValue ?? 1) > 0.7 ? 0.45 : 1
                }
            }
        }
    }

    // MARK: - Menu (rebuilt on open and on state changes while open)

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let card = NSHostingView(rootView: StatusCard())
        card.frame.size = card.fittingSize
        let cardItem = NSMenuItem()
        cardItem.view = card
        menu.addItem(cardItem)
        menu.addItem(.separator())

        let profiles = ProfileStore.shared.profiles
        let activeID = ProfileStore.shared.activeProfile?.id
        let idle = { if case .disconnected = self.vpn.state { return true }; return false }()

        if vpn.state.isConnected {
            menu.addItem(item("Disconnect", #selector(disconnect), symbol: "xmark.shield"))
        } else if profiles.count > 1 {
            let connect = item("Connect", nil, symbol: "checkmark.shield")
            connect.submenu = NSMenu()
            for profile in profiles {
                let entry = item(profile.displayName, #selector(connectProfile(_:)))
                entry.representedObject = profile.id
                entry.state = profile.id == activeID ? .on : .off
                entry.isEnabled = idle
                connect.submenu?.addItem(entry)
            }
            connect.isEnabled = idle
            menu.addItem(connect)
        } else {
            let title = profiles.first.map { "Connect \($0.displayName)" } ?? "Connect"
            let connect = item(title, idle ? #selector(connectDefault) : nil, symbol: "checkmark.shield")
            menu.addItem(connect)
        }

        menu.addItem(.separator())
        menu.addItem(item("Manage Profiles", #selector(openProfiles), symbol: "person.crop.circle"))
        menu.addItem(item("Copy Connection Log", #selector(copyLog), symbol: "doc.on.clipboard"))
        menu.addItem(.separator())
        menu.addItem(toggle("Connect at Launch", UserDefaults.standard.bool(forKey: autoConnectKey), #selector(toggleAutoConnect)))
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ETHZ VPN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector?, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func toggle(_ title: String, _ isOn: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = isOn ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc private func connectDefault() { vpn.connect() }
    @objc private func disconnect() { vpn.disconnect() }

    @objc private func connectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == id }) else { return }
        vpn.connect(profile: profile)
    }

    @objc private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vpn.log.joined(separator: "\n"), forType: .string)
    }

    @objc private func openProfiles() {
        if setupWindowController == nil {
            setupWindowController = SetupWindowController()
            setupWindowController?.onComplete = { [weak self] in
                self?.setupWindowController = nil
                self?.updateIcon()
            }
        }
        setupWindowController?.showPanel()
    }

    @objc private func toggleAutoConnect() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: autoConnectKey), forKey: autoConnectKey)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            showAlert("Could not change Launch at Login", "\(error.localizedDescription)\n\nMake sure the app is in /Applications.")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // MARK: - Startup

    private func runFirstLaunchSetup() {
        guard !UserDefaults.standard.bool(forKey: firstRunDoneKey) else { return }
        UserDefaults.standard.set(true, forKey: firstRunDoneKey)
        if !ProfileStore.shared.hasAnyCompleteProfile || !PrivilegedHelper.isInstalled() { openProfiles() }
    }

    /// At login the network is often not up yet, so wait for it (up to 30s).
    private func autoConnectIfEnabled() {
        guard UserDefaults.standard.bool(forKey: autoConnectKey),
              ProfileStore.shared.hasAnyCompleteProfile,
              !vpn.state.isConnected else { return }
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        let fire = { [weak self] in
            guard let self, self.networkMonitor === monitor else { return }
            monitor.cancel()
            self.networkMonitor = nil
            self.vpn.connect()
        }
        monitor.pathUpdateHandler = { if $0.status == .satisfied { fire() } }
        monitor.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: fire)
    }

    // MARK: - Alerts

    private func showConnectionError(_ message: String) {
        let choice = showAlert("Could not connect to ETHZ VPN", message, buttons: ["OK", "Manage Profiles", "Copy Log"])
        if choice == .alertSecondButtonReturn { openProfiles() }
        if choice == .alertThirdButtonReturn { copyLog() }
    }

    @discardableResult
    private func showAlert(_ title: String, _ message: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
