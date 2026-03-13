#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SECRETS_DIR="${HOME}/.local/share/ethz-vpn-connect"
readonly PROFILES_FILE="${SECRETS_DIR}/profiles.json"
readonly ACTIVE_PROFILE_KEY="eth-vpn-active-profile-id"
readonly LOGGER_TAG="eth-vpn"
readonly VPN_HOST="sslvpn.ethz.ch"
readonly DEFAULT_REALM="student-net"

PASSWORD=""
TOKEN=""

cleanup() {
	PASSWORD=""
	TOKEN=""
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Color helpers (only when stdout is a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	RESET='\033[0m'
else
	RED='' GREEN='' YELLOW='' RESET=''
fi

info()    { printf '%s\n'                    "$*"; }
success() { printf "${GREEN}%s${RESET}\n"   "$*"; }
warn()    { printf "${YELLOW}%s${RESET}\n"  "$*" >&2; }
error()   { printf "${RED}%s${RESET}\n"     "$*" >&2; }

# ---------------------------------------------------------------------------
# macOS notifications
# ---------------------------------------------------------------------------
notify() {
	local title=$1 message=$2
	osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

log_event() {
	local message=$1
	logger -t "$LOGGER_TAG" "$message" 2>/dev/null || true
}

print_usage() {
	cat <<'EOF'
eth-vpn — ETH Zurich VPN helper (wraps openconnect with Keychain + profile support)

Usage: eth-vpn <command> [profile-name]

Commands:
  connect [name]    Connect using a named profile (or the default profile)
  disconnect|d      Disconnect active ETH VPN session
  status|s          Show whether openconnect is running
  profiles          List all saved profiles
  add               Add a new profile interactively
  edit <name>       Edit an existing profile
  delete <name>     Delete a profile
  default <name>    Set the default profile
  -h|--help         Show this help message

Examples:
  eth-vpn connect
  eth-vpn connect staff
  eth-vpn disconnect
  eth-vpn profiles
  eth-vpn add
  eth-vpn default student
EOF
}

require_tool() {
	local bin=$1
	if ! command -v "$bin" >/dev/null 2>&1; then
		error "Error: Required tool \"$bin\" not found in PATH."
		exit 1
	fi
}

ensure_prereqs() {
	for tool in openconnect sudo security; do
		require_tool "$tool"
	done
	if ! sudo -n true >/dev/null 2>&1; then
		info 'Info: sudo password may be requested during VPN operations.'
	fi
}

require_non_empty() {
	local label=$1 value=$2
	if [[ -z "$value" ]]; then
		error "Error: $label cannot be empty."
		return 1
	fi
}

# ---------------------------------------------------------------------------
# Keychain helpers
# ---------------------------------------------------------------------------
keychain_get() {
	local service=$1
	security find-generic-password -a "${USER}" -s "$service" -w 2>/dev/null
}

keychain_set() {
	local service=$1 value=$2
	security add-generic-password -a "${USER}" -s "$service" -w "$value" -U
}

keychain_delete() {
	local service=$1
	security delete-generic-password -a "${USER}" -s "$service" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Profile store (thin JSON parser using python3 / awk fallback)
# ---------------------------------------------------------------------------

# Requires python3 (available on every modern macOS).
_py() { python3 -c "$1" 2>/dev/null; }

profiles_list() {
	if [[ ! -f "$PROFILES_FILE" ]]; then
		echo ""
		return
	fi
	_py "
import json, sys
data = json.load(open('${PROFILES_FILE}'))
for p in data:
    print(p['id'])
"
}

profile_get_field() {
	local id=$1 field=$2
	_py "
import json
data = json.load(open('${PROFILES_FILE}'))
for p in data:
    if p['id'] == '${id}':
        print(p.get('${field}', ''))
        break
"
}

profile_exists() {
	local id=$1
	[[ -n "$(profile_get_field "$id" "id")" ]]
}

profiles_save() {
	# Called after a Python script that writes the file; nothing to do here.
	:
}

profile_upsert() {
	local id=$1 display=$2 username=$3 realm=$4
	_py "
import json, os
path = '${PROFILES_FILE}'
data = json.load(open(path)) if os.path.exists(path) else []
found = False
for p in data:
    if p['id'] == '${id}':
        p.update({'displayName': '${display}', 'username': '${username}', 'realm': '${realm}'})
        found = True
        break
if not found:
    data.append({'id': '${id}', 'displayName': '${display}', 'username': '${username}', 'realm': '${realm}'})
json.dump(data, open(path, 'w'), indent=2)
"
}

profile_delete_entry() {
	local id=$1
	_py "
import json, os
path = '${PROFILES_FILE}'
if not os.path.exists(path): exit(0)
data = json.load(open(path))
data = [p for p in data if p['id'] != '${id}']
json.dump(data, open(path, 'w'), indent=2)
"
}

get_active_profile_id() {
	defaults read com.apple.ETHVPNMenuBar "${ACTIVE_PROFILE_KEY}" 2>/dev/null \
		|| _py "
import json, os
path = '${PROFILES_FILE}'
if not os.path.exists(path): exit(1)
data = json.load(open(path))
if data: print(data[0]['id'])
" 2>/dev/null || echo ""
}

set_active_profile_id() {
	local id=$1
	defaults write com.apple.ETHVPNMenuBar "${ACTIVE_PROFILE_KEY}" "$id" 2>/dev/null || true
}

resolve_profile_id() {
	local name=${1:-}
	if [[ -n "$name" ]]; then
		# Accept either id or displayName (case-insensitive)
		local matched
		matched=$(_py "
import json, os
path = '${PROFILES_FILE}'
if not os.path.exists(path): exit(1)
data = json.load(open(path))
needle = '${name}'.lower()
for p in data:
    if p['id'].lower() == needle or p['displayName'].lower() == needle:
        print(p['id'])
        break
" 2>/dev/null || echo "")
		if [[ -z "$matched" ]]; then
			error "Error: No profile named \"${name}\" found."
			return 1
		fi
		echo "$matched"
	else
		local active
		active=$(get_active_profile_id)
		if [[ -z "$active" ]]; then
			# Fall back to first profile
			active=$(profiles_list | head -1)
		fi
		if [[ -z "$active" ]]; then
			error "Error: No profiles configured. Run \"eth-vpn add\" first."
			return 1
		fi
		echo "$active"
	fi
}

# ---------------------------------------------------------------------------
# VPN operations
# ---------------------------------------------------------------------------

openconnect_running() {
	pgrep -x openconnect >/dev/null 2>&1
}

show_vpn_ip() {
	local iface ip
	for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^utun'); do
		ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
		if [[ -n "$ip" ]]; then
			info "VPN IP ($iface): $ip"
			return
		fi
	done
}

connect() {
	local profile_name=${1:-}
	ensure_prereqs

	local id
	id=$(resolve_profile_id "$profile_name") || return 1

	local USERNAME REALM
	USERNAME=$(profile_get_field "$id" "username")
	REALM=$(profile_get_field "$id" "realm")
	REALM=${REALM:-$DEFAULT_REALM}
	require_non_empty "Username" "$USERNAME"

	if ! PASSWORD=$(keychain_get "eth-vpn-password-${id}"); then
		error "Error: Could not read password for profile \"${id}\" from Keychain. Run \"eth-vpn add\" or \"eth-vpn edit ${id}\"."
		return 1
	fi
	if ! TOKEN=$(keychain_get "eth-vpn-token-${id}"); then
		error "Error: Could not read OTP secret for profile \"${id}\" from Keychain."
		return 1
	fi

	require_non_empty "Password" "$PASSWORD"
	require_non_empty "Token" "$TOKEN"

	if openconnect_running; then
		error 'Error: openconnect already running. Use "eth-vpn disconnect" first.'
		return 1
	fi

	local display
	display=$(profile_get_field "$id" "displayName")
	info "Connecting [${display}] ${USERNAME}@${REALM}.ethz.ch via group \"${REALM}\"..."
	log_event "Connecting [${display}] ${USERNAME}@${REALM}.ethz.ch"
	set_active_profile_id "$id"

	if printf '%s\n' "$PASSWORD" | sudo openconnect -b -u "${USERNAME}@${REALM}.ethz.ch" -g "$REALM" \
		--useragent=AnyConnect --passwd-on-stdin --token-mode=totp \
		--token-secret="sha1:base32:${TOKEN}" --no-external-auth "$VPN_HOST"; then
		success 'VPN connected successfully.'
		log_event "VPN connected for [${display}] ${USERNAME}@${REALM}.ethz.ch"
		notify "ETH VPN" "Connected as ${USERNAME}@${REALM}.ethz.ch (${display})"
		show_vpn_ip
	else
		local status=$?
		error "Error: openconnect exited with status ${status}."
		log_event "VPN connection failed (${status}) for [${display}] ${USERNAME}@${REALM}.ethz.ch"
		notify "ETH VPN" "Connection failed (status ${status})"
		return $status
	fi
}

disconnect() {
	require_tool sudo
	if openconnect_running; then
		log_event "Disconnecting openconnect"
		sudo pkill -SIGINT -x openconnect >/dev/null 2>&1 || true
		local i=0
		while openconnect_running && (( i < 10 )); do
			sleep 0.5
			(( i++ )) || true
		done
		if openconnect_running; then
			warn 'Warning: openconnect still running after SIGINT.'
			notify "ETH VPN" "Disconnect may have failed — process still running"
		else
			success 'VPN disconnected successfully.'
			log_event "VPN disconnected successfully"
			notify "ETH VPN" "Disconnected"
		fi
	else
		info 'No openconnect process found.'
		return 1
	fi
}

status() {
	if openconnect_running; then
		info 'openconnect is running (PIDs):'
		pgrep -ax openconnect
		show_vpn_ip
	else
		info 'VPN is currently disconnected.'
	fi
}

# ---------------------------------------------------------------------------
# Profile management commands
# ---------------------------------------------------------------------------

cmd_profiles() {
	local ids
	ids=$(profiles_list)
	if [[ -z "$ids" ]]; then
		info "No profiles configured. Run \"eth-vpn add\" to create one."
		return
	fi
	local active
	active=$(get_active_profile_id)
	info "Saved profiles:"
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		local display username realm
		display=$(profile_get_field "$id" "displayName")
		username=$(profile_get_field "$id" "username")
		realm=$(profile_get_field "$id" "realm")
		local marker=""
		[[ "$id" == "$active" ]] && marker=" [default]"
		printf '  %-20s  %s@%s%s\n' "${display}${marker}" "$username" "$realm" ""
	done <<< "$ids"
}

cmd_add() {
	ensure_prereqs
	echo 'Adding a new VPN profile. Press Ctrl+C to abort.'
	echo
	local display username realm password otp

	read -rp $'Profile name (e.g. Student, Staff): ' display
	display=${display//[[:space:]]/ }
	require_non_empty "Profile name" "$display"

	local id
	id=$(echo "$display" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
	if profile_exists "$id"; then
		error "Error: A profile with id \"${id}\" already exists. Use \"eth-vpn edit ${id}\" to update it."
		return 1
	fi

	read -rp $'ETH Username (without @...): ' username
	username=${username//[[:space:]]/}
	require_non_empty "Username" "$username"

	read -rsp $'ETHZ WLAN Password: ' password; echo
	require_non_empty "Password" "$password"

	read -rsp $'ETHZ OTP Secret: ' otp; echo
	require_non_empty "OTP secret" "$otp"

	read -rp $'VPN realm/group [student-net]: ' realm
	realm=${realm:-$DEFAULT_REALM}
	realm=${realm//[[:space:]]/}
	require_non_empty "Realm" "$realm"

	mkdir -p "$SECRETS_DIR"
	profile_upsert "$id" "$display" "$username" "$realm"
	keychain_set "eth-vpn-password-${id}" "$password"
	keychain_set "eth-vpn-token-${id}" "$otp"

	# Set as default if it's the first profile
	local first_id
	first_id=$(profiles_list | head -1)
	if [[ "$first_id" == "$id" ]]; then
		set_active_profile_id "$id"
	fi

	success "Profile \"${display}\" saved."
}

cmd_edit() {
	local name=${1:-}
	if [[ -z "$name" ]]; then error "Usage: eth-vpn edit <profile-name>"; return 1; fi

	local id
	id=$(resolve_profile_id "$name") || return 1

	local cur_display cur_username cur_realm
	cur_display=$(profile_get_field "$id" "displayName")
	cur_username=$(profile_get_field "$id" "username")
	cur_realm=$(profile_get_field "$id" "realm")

	info "Editing profile \"${cur_display}\". Press Enter to keep current value."
	echo

	local display username realm password otp

	read -rp $"Profile name [${cur_display}]: " display
	display=${display:-$cur_display}

	read -rp $"ETH Username [${cur_username}]: " username
	username=${username:-$cur_username}
	username=${username//[[:space:]]/}

	read -rsp $'ETHZ WLAN Password (leave blank to keep): ' password; echo
	if [[ -z "$password" ]]; then
		password=$(keychain_get "eth-vpn-password-${id}" || echo "")
	fi
	require_non_empty "Password" "$password"

	read -rsp $'ETHZ OTP Secret (leave blank to keep): ' otp; echo
	if [[ -z "$otp" ]]; then
		otp=$(keychain_get "eth-vpn-token-${id}" || echo "")
	fi
	require_non_empty "OTP secret" "$otp"

	read -rp $"VPN realm/group [${cur_realm}]: " realm
	realm=${realm:-$cur_realm}
	realm=${realm//[[:space:]]/}
	require_non_empty "Realm" "$realm"

	profile_upsert "$id" "$display" "$username" "$realm"
	keychain_set "eth-vpn-password-${id}" "$password"
	keychain_set "eth-vpn-token-${id}" "$otp"
	success "Profile \"${display}\" updated."
}

cmd_delete() {
	local name=${1:-}
	if [[ -z "$name" ]]; then error "Usage: eth-vpn delete <profile-name>"; return 1; fi

	local id
	id=$(resolve_profile_id "$name") || return 1
	local display
	display=$(profile_get_field "$id" "displayName")

	read -rp $"Delete profile \"${display}\"? [y/N]: " confirm
	if [[ "${confirm,,}" != "y" ]]; then
		info "Aborted."
		return 0
	fi

	keychain_delete "eth-vpn-password-${id}"
	keychain_delete "eth-vpn-token-${id}"
	profile_delete_entry "$id"

	local active
	active=$(get_active_profile_id)
	if [[ "$active" == "$id" ]]; then
		local next
		next=$(profiles_list | head -1)
		[[ -n "$next" ]] && set_active_profile_id "$next"
	fi

	success "Profile \"${display}\" deleted."
}

cmd_default() {
	local name=${1:-}
	if [[ -z "$name" ]]; then error "Usage: eth-vpn default <profile-name>"; return 1; fi

	local id
	id=$(resolve_profile_id "$name") || return 1
	set_active_profile_id "$id"
	local display
	display=$(profile_get_field "$id" "displayName")
	success "Default profile set to \"${display}\"."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local cmd=${1:-}
	case "$cmd" in
		connect|c)
			connect "${2:-}"
			;;
		disconnect|d|dc)
			disconnect
			;;
		status|s)
			status
			;;
		profiles|list)
			cmd_profiles
			;;
		add)
			cmd_add
			;;
		edit)
			cmd_edit "${2:-}"
			;;
		delete|remove)
			cmd_delete "${2:-}"
			;;
		default)
			cmd_default "${2:-}"
			;;
		-h|--help)
			print_usage
			;;
		*)
			print_usage
			return 1
			;;
	esac
}

main "$@"
