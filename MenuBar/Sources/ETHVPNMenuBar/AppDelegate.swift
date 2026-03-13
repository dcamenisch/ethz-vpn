import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    // Menu items we need to update
    private var statusMenuItem: NSMenuItem!
    private var connectMenuItem: NSMenuItem!
    private var disconnectMenuItem: NSMenuItem!
    private var reconnectMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    var setupWindowController: SetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        setupVPNController()
        performFirstRunChecksIfNeeded()
        if SecretsHelper.areComplete() {
            updateUI(for: VPNController.shared.state)
        }
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

        connectMenuItem = NSMenuItem(title: "Connect", action: #selector(connectTapped), keyEquivalent: "")
        connectMenuItem.target = self
        menu.addItem(connectMenuItem)

        disconnectMenuItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectTapped), keyEquivalent: "")
        disconnectMenuItem.target = self
        menu.addItem(disconnectMenuItem)

        menu.addItem(.separator())

        reconnectMenuItem = NSMenuItem(title: "Reconnect", action: #selector(reconnectTapped), keyEquivalent: "")
        reconnectMenuItem.target = self
        menu.addItem(reconnectMenuItem)

        menu.addItem(.separator())

        let setup = NSMenuItem(title: "Setup / Reinstall Helper...", action: #selector(showSetupTapped), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - VPN wiring

    private func setupVPNController() {
        VPNController.shared.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateUI(for: state)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if VPNController.shared.isOpenconnectRunning() {
            VPNController.shared.disconnect()
        }
    }

    // MARK: - First-run

    private func performFirstRunChecksIfNeeded() {
        guard !SecretsHelper.areComplete() || !SudoersHelper.isInstalled(openconnectPath: VPNController.shared.resolvedOpenconnectPath()) else { return }
        openSetupWindow()
    }

    @objc func showSetupTapped() {
        openSetupWindow()
    }

    private func openSetupWindow() {
        if setupWindowController == nil {
            setupWindowController = SetupWindowController()
            setupWindowController?.onComplete = { [weak self] in
                self?.setupWindowController = nil
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
            let ipLabel = ip.isEmpty ? "Connected" : "Connected — \(ip)"
            statusMenuItem.title = "● \(ipLabel)"
            connectMenuItem.isHidden = true
            disconnectMenuItem.isHidden = false
            reconnectMenuItem.isHidden = false

        case .connecting:
            setIcon(systemName: "clock")
            statusMenuItem.title = "Connecting..."
            connectMenuItem.isHidden = true
            disconnectMenuItem.isHidden = true
            reconnectMenuItem.isHidden = true

        case .disconnecting:
            setIcon(systemName: "clock")
            statusMenuItem.title = "Disconnecting..."
            connectMenuItem.isHidden = true
            disconnectMenuItem.isHidden = true
            reconnectMenuItem.isHidden = true

        case .disconnected:
            setIcon(systemName: "lock.open.fill")
            statusMenuItem.title = "○ Disconnected"
            connectMenuItem.isHidden = false
            disconnectMenuItem.isHidden = true
            reconnectMenuItem.isHidden = true
        }
    }

    private func setIcon(systemName: String) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
            button.image?.isTemplate = true
        }
    }

    // MARK: - Actions

    @objc private func connectTapped() {
        VPNController.shared.connect()
    }

    @objc private func disconnectTapped() {
        VPNController.shared.disconnect()
    }

    @objc private func reconnectTapped() {
        VPNController.shared.reconnect()
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
