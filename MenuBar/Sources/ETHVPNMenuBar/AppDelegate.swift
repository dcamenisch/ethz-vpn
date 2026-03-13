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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        rebuildProfilesSubmenu()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        if VPNController.shared.isOpenconnectRunning() {
            VPNController.shared.disconnect()
        }
    }

    // MARK: - First-run

    private func performFirstRunChecksIfNeeded() {
        let store = ProfileStore.shared
        guard store.hasAnyCompleteProfile,
              SudoersHelper.isInstalled(openconnectPath: VPNController.shared.resolvedOpenconnectPath())
        else { openSetupWindow(); return }
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
            statusMenuItem.title = "○ Disconnected"
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
