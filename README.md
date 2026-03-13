# ETH VPN

Menu bar app and CLI for connecting to the ETH Zurich VPN using openconnect with TOTP and Keychain integration.

**Architecture:** Apple Silicon (arm64) only.

---

## What's included

| Component | Description |
|-----------|-------------|
| `ETH VPN.app` | Menu bar app — click to connect/disconnect |
| `vpn.sh` | CLI wrapper for terminal use |

Both share the same Keychain entries and config files, so setup done in the app works in the shell and vice versa.

---

## Quick start (end user)

1. Download `ETH VPN.zip`, unzip, move `ETH VPN.app` anywhere (e.g. `/Applications`)
2. Double-click the app
3. Complete the one-time setup wizard:
   - **Username** — your ETH username without `@ethz.ch`
   - **WLAN Password** — your ETH network password
   - **OTP Secret** — the base32 TOTP secret from your authenticator setup
   - **Realm** — leave as `student-net` unless you have a different group
4. Click **Save** — you'll be prompted once for your Mac admin password to install the passwordless sudo rule
5. Use the menu bar icon to connect and disconnect

Subsequent launches skip the wizard automatically.

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

## CLI (`vpn.sh`)

For terminal use, source or symlink `vpn.sh` as `eth-vpn`:

```bash
ln -s "$(pwd)/vpn.sh" /usr/local/bin/eth-vpn
chmod +x vpn.sh
```

```
eth-vpn connect       Connect to ETH VPN
eth-vpn disconnect    Disconnect
eth-vpn reconnect     Disconnect then reconnect
eth-vpn status        Show connection status
eth-vpn setup         Create or update secrets in Keychain (CLI equivalent of the setup wizard)
eth-vpn migrate       Migrate old encrypted secret files to Keychain
eth-vpn --help        Show help
```

The CLI requires `openconnect` and `sudo` in PATH, and a sudoers rule for passwordless operation. Run the app's setup wizard first (or `eth-vpn setup` to configure via terminal).

---

## Credentials storage

| Secret | Where |
|--------|-------|
| WLAN password | macOS Keychain (`eth-vpn-password`) |
| OTP secret | macOS Keychain (`eth-vpn-token`) |
| Username | `~/.local/share/ethz-vpn-connect/ethzvpnusername.txt` |
| Realm | `~/.local/share/ethz-vpn-connect/ethzvpnrealm.txt` |

The sudoers rule is written to `/etc/sudoers.d/eth-vpn` and allows the current user to run openconnect and `pkill` without a password.

---

## Reinstalling or moving the app

If you move the `.app` to a different path, the sudoers rule will point to the old binary location. Use **Setup / Reinstall Helper...** in the menu bar to rewrite it.

---

## Uninstall

```bash
make uninstall
```

Or manually:

```bash
rm -rf ~/Applications/ETH\ VPN.app
sudo rm -f /etc/sudoers.d/eth-vpn
# Remove Keychain entries
security delete-generic-password -a "$USER" -s eth-vpn-password
security delete-generic-password -a "$USER" -s eth-vpn-token
# Remove config files
rm -rf ~/.local/share/ethz-vpn-connect
```
