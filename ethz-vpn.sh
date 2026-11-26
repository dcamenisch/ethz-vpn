#!/usr/bin/env bash
# ethz-vpn: command line front end for the ETHZ VPN app.
# Profiles are managed in the app; secrets are sealed by the app's Secure
# Enclave key, so connecting goes through the app binary (Touch ID prompt).

set -euo pipefail

readonly HELPER=/Library/PrivilegedHelperTools/ethz-vpn/ethz-vpn-helper
readonly PROFILES_FILE="$HOME/.local/share/ethz-vpn-connect/profiles.json"

find_app() {
	local dir
	for dir in "/Applications/ETHZ VPN.app" "$HOME/Applications/ETHZ VPN.app"; do
		if [[ -x "$dir/Contents/MacOS/ETHZVPNMenuBar" ]]; then
			printf '%s\n' "$dir/Contents/MacOS/ETHZVPNMenuBar"
			return
		fi
	done
	echo "Error: ETHZ VPN.app not found in /Applications or ~/Applications." >&2
	return 1
}

running() { pgrep -x openconnect >/dev/null 2>&1; }

vpn_ip() {
	local iface
	for iface in $(ifconfig -l | tr ' ' '\n' | grep '^utun'); do
		ifconfig "$iface" | awk '/inet / {print $2; exit}'
	done | head -1
}

cmd_connect() {
	if running; then
		echo "Already connected. Run \"ethz-vpn disconnect\" first." >&2
		return 1
	fi
	local app
	app=$(find_app)
	"$app" --connect "$@"
	echo "Connected. VPN IP: $(vpn_ip)"
}

cmd_disconnect() {
	running || { echo "Not connected."; return 0; }
	sudo -n "$HELPER" disconnect
	echo "Disconnected."
}

cmd_status() {
	if running; then echo "Connected. VPN IP: $(vpn_ip)"; else echo "Not connected."; fi
}

cmd_profiles() {
	[[ -f $PROFILES_FILE ]] || { echo "No profiles. Add one in the ETHZ VPN app."; return; }
	python3 -c '
import json, sys
for p in json.load(open(sys.argv[1])):
    print("%-20s %s@%s" % (p["displayName"], p["username"], p["realm"]))' "$PROFILES_FILE"
}

usage() {
	cat <<'EOF'
Usage: ethz-vpn <command>

  connect [profile]   Connect (default profile if omitted), asks for Touch ID
  disconnect          Disconnect
  status              Show connection status
  profiles            List profiles (manage them in the app)
EOF
}

case ${1:-} in
	connect|c)       shift; cmd_connect "$@" ;;
	disconnect|d)    cmd_disconnect ;;
	status|s)        cmd_status ;;
	profiles|list)   cmd_profiles ;;
	-h|--help)       usage ;;
	*)               usage; exit 1 ;;
esac
