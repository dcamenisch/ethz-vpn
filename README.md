<p align="center">
  <img src="icon.icon/Assets/network.badge.shield.half.filled@4x.png" width="128" alt="ETH VPN icon">
</p>

# ETH VPN

Menu bar app and CLI for connecting to the ETH Zurich VPN using openconnect with TOTP and Keychain integration. Supports multiple named profiles for different realms or accounts.

**Architecture:** Apple Silicon (arm64) only.

---

## What's included

| Component | Description |
|-----------|-------------|
| `ETH VPN.app` | Menu bar app — left-click for menu, right-click to toggle VPN |
| `ethz-vpn.sh` | CLI wrapper for terminal use |

Both share the same Keychain entries and profile store, so setup done in the app works in the shell and vice versa.

---

## Quick start (end user)

1. Download `ETH VPN.zip`, unzip, move `ETH VPN.app` anywhere (e.g. `/Applications`)
2. Double-click the app
3. The **Manage Profiles** window opens automatically on first launch
4. Click **Add Profile** and fill in:
   - **Name** — a label for this config (e.g. `Student`, `Staff`)
   - **Username** — your ETH username without `@ethz.ch`
   - **WLAN Password** — your ETH network password
   - **OTP Secret** — the base32 TOTP secret from your authenticator setup
   - **Realm** — leave as `student-net` unless you have a different group
5. Click **Save** — you'll be prompted once for your Mac admin password to install the passwordless sudo rule
6. Use the menu bar icon to connect and disconnect

Subsequent launches skip the wizard automatically.

---

## Multiple profiles

You can create as many profiles as you like (e.g. one for `student-net`, one for `staff-net`).

**In the menu bar app:**
- Open **Manage Profiles...** to add, edit, duplicate, delete, or set a default profile
- When you have more than one profile, the **Connect** menu expands into a submenu listing all profiles
- The active (last-used) profile is shown with a checkmark
- **Right-click** the menu bar icon to instantly connect (default profile) or disconnect

**In the CLI:**
```
ethz-vpn connect staff        Connect using the "staff" profile
ethz-vpn default student      Set "student" as the default
ethz-vpn profiles             List all profiles
```

---

## Developer setup

### Prerequisites

```bash
brew install openconnect dylibbundler
```

### Make targets

| Target | Description |
|--------|-------------|
| `make fetch-openconnect` | Copy installed openconnect + all dylibs into `Resources/` (run once after `brew install openconnect`) |
| `make build` | Compile the Swift app (`swift build -c release`) |
| `make bundle` | Assemble `ETH VPN.app` in `~/Applications` |
| `make install` | Same as `bundle` — copies app to `~/Applications` (no sudoers written) |
| `make dist` | Build and zip to `dist/ETH VPN.zip` for distribution |
| `make uninstall` | Remove `~/Applications/ETH VPN.app` and `/etc/sudoers.d/eth-vpn` |
| `make clean` | Remove Swift build artifacts |

### Build and distribute

```bash
# First time only — bundle openconnect into the app resources
make fetch-openconnect

# Build and produce a distributable zip
make dist
# → dist/ETH VPN.zip
```

The zip can be sent to anyone. No Homebrew required on the recipient's machine.

### Developer-only build (no bundled openconnect)

If you just want to run the app locally and already have openconnect installed via Homebrew:

```bash
make install
```

The app will fall back to the Homebrew binary automatically.

---

## CLI (`ethz-vpn.sh`)

For terminal use, symlink `ethz-vpn.sh` as `ethz-vpn`:

```bash
ln -s "$(pwd)/ethz-vpn.sh" /usr/local/bin/ethz-vpn
chmod +x ethz-vpn.sh
```

```
ethz-vpn connect [name]    Connect (optionally specify a profile name)
ethz-vpn disconnect        Disconnect
ethz-vpn status            Show connection status
ethz-vpn profiles          List all saved profiles
ethz-vpn add               Add a new profile interactively
ethz-vpn edit <name>       Edit an existing profile
ethz-vpn delete <name>     Delete a profile
ethz-vpn default <name>    Set the default profile
ethz-vpn --help            Show help
```

The CLI requires `openconnect` and `sudo` in PATH, and a sudoers rule for passwordless operation. Run the app's **Manage Profiles** window first, or use `ethz-vpn add` to configure via terminal.

---

## Credentials storage

| Secret | Where |
|--------|-------|
| WLAN password (per profile) | macOS Keychain (`eth-vpn-password-<profile-id>`) |
| OTP secret (per profile) | macOS Keychain (`eth-vpn-token-<profile-id>`) |
| Profile list | `~/.local/share/ethz-vpn-connect/profiles.json` |
| Active profile ID | `UserDefaults` (`com.apple.ETHVPNMenuBar`) |

The sudoers rule is written to `/etc/sudoers.d/eth-vpn` and allows the current user to run openconnect and `pkill` without a password.

---

## Reinstalling or moving the app

If you move the `.app` to a different path, the sudoers rule will point to the old binary location. Open **Manage Profiles...** and re-save any profile to rewrite the sudoers rule.

---

## Uninstall

```bash
make uninstall
```

Or manually:

```bash
rm -rf ~/Applications/ETH\ VPN.app
sudo rm -f /etc/sudoers.d/eth-vpn
# Remove Keychain entries for each profile (replace <id> with your profile id)
security delete-generic-password -a "$USER" -s eth-vpn-password-<id>
security delete-generic-password -a "$USER" -s eth-vpn-token-<id>
# Remove config files
rm -rf ~/.local/share/ethz-vpn-connect
```
