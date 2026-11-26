import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var statusMenuItem: NSMenuItem!
    private var connectMenuItem: NSMenuItem!        // shown when disconnected, no profiles
    private var profilesConnectMenuItem: NSMenuItem! // submenu when profiles exist
    private var disconnectMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    var setupWindowController: SetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()  // calls rebuildProfilesSubmenu() at end
        setupVPNController()
        performFirstRunChecksIfNeeded()
        updateUI(for: VPNController.shared.state)  // icon + labels only
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSetupTapped),
            name: .vpnSecretsNotFound,
            object: nil
        )
    }

    // MARK: - Menu construction

    private func buildMenu() {
        menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        // Simple "Connect" — shown when only one profile or no profiles yet
        connectMenuItem = NSMenuItem(title: "Connect", action: #selector(connectDefaultTapped), keyEquivalent: "")
        connectMenuItem.target = self
        menu.addItem(connectMenuItem)

        // "Connect ▶" submenu — shown when multiple profiles exist
        profilesConnectMenuItem = NSMenuItem(title: "Connect", action: nil, keyEquivalent: "")
        profilesConnectMenuItem.submenu = NSMenu()
        menu.addItem(profilesConnectMenuItem)

        disconnectMenuItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectTapped), keyEquivalent: "")
        disconnectMenuItem.target = self
        menu.addItem(disconnectMenuItem)

        menu.addItem(.separator())

        let copyLog = NSMenuItem(title: "Copy Connection Log", action: #selector(copyLogTapped), keyEquivalent: "")
        copyLog.target = self
        menu.addItem(copyLog)

        let manageProfiles = NSMenuItem(title: "Manage Profiles...", action: #selector(showSetupTapped), keyEquivalent: "")
        manageProfiles.target = self
        menu.addItem(manageProfiles)

        launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Do NOT assign statusItem.menu — that would suppress custom click handling.
        // Instead, handle clicks manually so right-click can toggle the VPN.
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            // Fire on both down and up for left/right so we catch the right-click
            // regardless of which phase AppKit delivers for a status-item button.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp, .rightMouseDown])
        }
        rebuildProfilesSubmenu()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // A right-click on a status-item button can arrive as .rightMouseDown or
        // .rightMouseUp depending on macOS version; a Control+left-click is the
        // standard equivalent. Treat all of these as "right-click → toggle".
        //
        // NOTE: On the macOS 27 dev beta the status-item button translates every
        // right-click into a left-click before it reaches AppKit (NSApp.currentEvent
        // and even a local event monitor both report .leftMouse*), so right-click
        // toggle is inert there and a click just opens the menu. This detection is
        // kept so it resumes working once that OS regression is fixed.
        let isRightClick = event.map { e in
            e.type == .rightMouseDown
                || e.type == .rightMouseUp
                || (e.type == .leftMouseUp && e.modifierFlags.contains(.control))
        } ?? false

        if isRightClick {
            VPNController.shared.toggleConnection()
        } else {
            // Left-click: show the menu
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil  // remove again so right-click still works next time
        }
    }

    private func rebuildProfilesSubmenu() {
        let store = ProfileStore.shared
        let profiles = store.profiles
        let submenu = profilesConnectMenuItem.submenu!
        submenu.removeAllItems()

        for profile in profiles {
            let item = NSMenuItem(title: profile.displayName, action: #selector(connectProfileTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            if store.activeProfileID == profile.id {
                item.state = .on
            }
            submenu.addItem(item)
        }

        if profiles.count > 1 {
            connectMenuItem.isHidden = true
            profilesConnectMenuItem.isHidden = false
        } else {
            // 0 or 1 profile: use simple item
            connectMenuItem.isHidden = false
            profilesConnectMenuItem.isHidden = true
            if let only = profiles.first {
                connectMenuItem.title = "Connect (\(only.displayName))"
            } else {
                connectMenuItem.title = "Connect"
            }
        }
    }

    // MARK: - VPN wiring

    private func setupVPNController() {
        VPNController.shared.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.updateUI(for: state) }
        }
        VPNController.shared.onError = { [weak self] message in
            self?.showConnectionError(message)
        }
    }

    private func showConnectionError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not connect to the ETH VPN"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Manage Profiles…")
        alert.addButton(withTitle: "Copy Log")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn: openSetupWindow()
        case .alertThirdButtonReturn:  copyLogTapped()
        default: break
        }
    }

    @objc private func copyLogTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(VPNController.shared.log.joined(separator: "\n"), forType: .string)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if VPNController.shared.isOpenconnectRunning() {
            VPNController.shared.disconnect()
        }
    }

    // MARK: - First-run

    private let firstRunDoneKey = "eth-vpn-did-complete-first-run"

    private func performFirstRunChecksIfNeeded() {
        // Only guide the user through setup on the very first launch. After that
        // the menu-bar icon just appears; setup stays reachable via "Manage
        // Profiles…", and `connect()` still prompts if credentials are missing.
        guard !UserDefaults.standard.bool(forKey: firstRunDoneKey) else { return }
        UserDefaults.standard.set(true, forKey: firstRunDoneKey)

        let store = ProfileStore.shared
        let ready = store.hasAnyCompleteProfile && PrivilegedHelper.isInstalled()
        if !ready { openSetupWindow() }
    }

    @objc func showSetupTapped() {
        openSetupWindow()
    }

    private func openSetupWindow() {
        if setupWindowController == nil {
            setupWindowController = SetupWindowController()
            setupWindowController?.onComplete = { [weak self] in
                self?.setupWindowController = nil
                self?.rebuildProfilesSubmenu()
                self?.updateUI(for: VPNController.shared.state)
            }
        }
        setupWindowController?.showPanel()
    }

    // MARK: - UI

    private func updateUI(for state: VPNState) {
        switch state {
        case .connected(let ip):
            setIcon(systemName: "lock.fill")
            let label = ip.isEmpty ? "Connected" : "Connected — \(ip)"
            if let active = ProfileStore.shared.activeProfile {
                statusMenuItem.title = "● \(label) (\(active.displayName))"
            } else {
                statusMenuItem.title = "● \(label)"
            }
        case .connecting:
            setIcon(systemName: "clock")
            statusMenuItem.title = "Connecting..."
        case .disconnecting:
            setIcon(systemName: "clock")
            statusMenuItem.title = "Disconnecting..."
        case .disconnected:
            setIcon(systemName: "lock.open.fill")
            if let error = VPNController.shared.lastError {
                statusMenuItem.title = "⚠ " + (error.count > 60 ? error.prefix(57) + "…" : error)
                statusMenuItem.toolTip = error
            } else {
                statusMenuItem.title = "○ Disconnected"
                statusMenuItem.toolTip = nil
            }
        }

        connectMenuItem.isEnabled = !state.isConnected && !state.isTransitioning
        profilesConnectMenuItem.isEnabled = !state.isConnected && !state.isTransitioning
        disconnectMenuItem.isHidden = !state.isConnected
    }

    private func setIcon(systemName: String) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
            button.image?.isTemplate = true
        }
    }

    // MARK: - Actions

    @objc private func connectDefaultTapped() {
        VPNController.shared.connect()
    }

    @objc private func connectProfileTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == id })
        else { return }
        VPNController.shared.connect(profile: profile)
    }

    @objc private func disconnectTapped() {
        VPNController.shared.disconnect()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginMenuItem.state = .off
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginMenuItem.state = .on
            }
        } catch {
            // Silently ignore — registration may fail if app is not in /Applications
        }
    }
}
