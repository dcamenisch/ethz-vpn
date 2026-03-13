#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SECRETS_DIR="${HOME}/.local/share/ethz-vpn-connect"
readonly USERNAME_FILE="${SECRETS_DIR}/ethzvpnusername.txt"
readonly REALM_FILE="${SECRETS_DIR}/ethzvpnrealm.txt"
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

info()    { printf '%s\n'           "$*"; }
success() { printf "${GREEN}%s${RESET}\n"  "$*"; }
warn()    { printf "${YELLOW}%s${RESET}\n" "$*" >&2; }
error()   { printf "${RED}%s${RESET}\n"   "$*" >&2; }

# ---------------------------------------------------------------------------
# macOS notifications
# ---------------------------------------------------------------------------
notify() {
	local title=$1 message=$2
	osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

# ---------------------------------------------------------------------------

log_event() {
	local message=$1
	logger -t "$LOGGER_TAG" "$message" 2>/dev/null || true
}

print_usage() {
	cat <<'EOF'
eth-vpn — ETH Zurich VPN helper (wraps openconnect with Keychain integration)

Usage: eth-vpn <command>

Commands:
  connect|c        Connect to ETH VPN
  disconnect|d|dc  Disconnect active ETH VPN session
  reconnect|r      Disconnect (if running) then connect
  status|s         Show whether openconnect is running
  setup            Create or update secrets in Keychain
  migrate          Migrate old encrypted secret files to Keychain
  -h|--help        Show this help message

Examples:
  eth-vpn connect
  eth-vpn disconnect
  eth-vpn reconnect
  eth-vpn setup
  eth-vpn migrate
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
	local label=$1
	local value=$2
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

ensure_secrets_exist() {
	local missing=()
	if ! security find-generic-password -a "${USER}" -s "eth-vpn-password" >/dev/null 2>&1; then
		missing+=("eth-vpn-password (Keychain)")
	fi
	if ! security find-generic-password -a "${USER}" -s "eth-vpn-token" >/dev/null 2>&1; then
		missing+=("eth-vpn-token (Keychain)")
	fi
	if [[ ! -f "$USERNAME_FILE" ]]; then
		missing+=("$USERNAME_FILE")
	fi
	if (( ${#missing[@]} )); then
		error "Error: Secrets missing (${missing[*]}). Run \"eth-vpn setup\" first."
		return 1
	fi
}

openconnect_running() {
	pgrep -x openconnect >/dev/null 2>&1
}

current_realm() {
	local realm=$DEFAULT_REALM
	if [[ -f "$REALM_FILE" ]]; then
		realm=$(<"$REALM_FILE")
		realm=${realm//[[:space:]]/}
	fi
	realm=${realm:-$DEFAULT_REALM}
	printf '%s' "$realm"
}

show_vpn_ip() {
	# openconnect typically creates utun0..utunN; find the one with an inet addr
	local iface ip
	for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^utun'); do
		ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
		if [[ -n "$ip" ]]; then
			info "VPN IP ($iface): $ip"
			return
		fi
	done
}

write_plain_secret() {
	local value=$1
	local dest=$2
	local tmp
	local prev_umask
	prev_umask=$(umask)
	umask 077
	tmp=$(mktemp "${dest}.XXXX")
	umask "$prev_umask"
	printf '%s\n' "$value" >"$tmp"
	chmod 600 "$tmp"
	mv "$tmp" "$dest"
}

connect() {
	ensure_prereqs
	ensure_secrets_exist
	if ! PASSWORD=$(keychain_get "eth-vpn-password"); then
		error "Error: Could not read eth-vpn-password from Keychain. Run \"eth-vpn setup\" first."
		return 1
	fi
	if ! TOKEN=$(keychain_get "eth-vpn-token"); then
		error "Error: Could not read eth-vpn-token from Keychain. Run \"eth-vpn setup\" first."
		return 1
	fi
	require_non_empty "Password" "$PASSWORD"
	require_non_empty "Token" "$TOKEN"
	local USERNAME
	USERNAME=$(<"$USERNAME_FILE")
	USERNAME=${USERNAME//[[:space:]]/}
	require_non_empty "Username" "$USERNAME"
	local REALM
	REALM=$(current_realm)
	require_non_empty "Realm" "$REALM"
	if openconnect_running; then
		error 'Error: openconnect already running. Use "eth-vpn disconnect" first.'
		return 1
	fi
	info "Connecting ${USERNAME}@${REALM}.ethz.ch via group \"${REALM}\"..."
	log_event "Connecting ${USERNAME}@${REALM}.ethz.ch"
	if printf '%s\n' "$PASSWORD" | sudo openconnect -b -u "${USERNAME}@${REALM}.ethz.ch" -g "$REALM" \
		--useragent=AnyConnect --passwd-on-stdin --token-mode=totp \
		--token-secret="sha1:base32:${TOKEN}" --no-external-auth "$VPN_HOST"; then
		success 'VPN connected successfully.'
		log_event "VPN connected for ${USERNAME}@${REALM}.ethz.ch"
		notify "ETH VPN" "Connected as ${USERNAME}@${REALM}.ethz.ch"
		show_vpn_ip
	else
		local status=$?
		error "Error: openconnect exited with status ${status}. Check the log output above."
		log_event "VPN connection failed (${status}) for ${USERNAME}@${REALM}.ethz.ch"
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
			log_event "VPN disconnect: openconnect still running after SIGINT"
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

reconnect() {
	disconnect 2>/dev/null || true
	sleep 1
	connect
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

setup() {
	ensure_prereqs
	info 'You are about to overwrite ETH VPN secrets. Press Ctrl+C to abort.'
	echo
	read -rp $'ETH Username (without @...): ' USERNAME
	USERNAME=${USERNAME//[[:space:]]/}
	require_non_empty "Username" "$USERNAME"
	read -rsp $'ETHZ WLAN Password: ' PASSWORD; echo
	require_non_empty "WLAN password" "$PASSWORD"
	read -rsp $'ETHZ OTP Secret: ' TOKEN; echo
	require_non_empty "OTP secret" "$TOKEN"
	local realm_input
	read -rp $'VPN realm/group [student-net]: ' realm_input
	local REALM
	REALM=${realm_input:-$DEFAULT_REALM}
	REALM=${REALM//[[:space:]]/}
	require_non_empty "Realm" "$REALM"
	umask 077
	mkdir -p "$SECRETS_DIR"
	chmod 700 "$SECRETS_DIR"
	if keychain_set "eth-vpn-password" "$PASSWORD"; then
		success 'WLAN password saved to Keychain (eth-vpn-password).'
	else
		error 'Error: Failed to save password to Keychain.'
		return 1
	fi
	if keychain_set "eth-vpn-token" "$TOKEN"; then
		success 'OTP secret saved to Keychain (eth-vpn-token).'
	else
		error 'Error: Failed to save OTP secret to Keychain.'
		return 1
	fi
	write_plain_secret "$USERNAME" "$USERNAME_FILE"
	write_plain_secret "$REALM" "$REALM_FILE"
	success "Setup complete. Username and realm stored in ${SECRETS_DIR}."
	# Migration notice: remove old encrypted files if they exist
	local old_token="${SECRETS_DIR}/ethzvpntoken.secret"
	local old_pass="${SECRETS_DIR}/ethzvpnpass.secret"
	if [[ -f "$old_token" || -f "$old_pass" ]]; then
		warn "Note: Old encrypted secret files found. You can safely delete them:"
		[[ -f "$old_token" ]] && warn "  rm ${old_token}"
		[[ -f "$old_pass" ]] && warn "  rm ${old_pass}"
	fi
}

migrate() {
	local old_token="${SECRETS_DIR}/ethzvpntoken.secret"
	local old_pass="${SECRETS_DIR}/ethzvpnpass.secret"

	if [[ ! -f "$old_token" && ! -f "$old_pass" ]]; then
		info 'No old encrypted secret files found. Nothing to migrate.'
		return 0
	fi

	info 'Found old encrypted secret files:'
	[[ -f "$old_pass" ]] && info "  ${old_pass}"
	[[ -f "$old_token" ]] && info "  ${old_token}"
	echo

	require_tool openssl

	local encpass
	if ! encpass=$(security find-generic-password -a "${USER}" -s "eth-vpn-encpass" -w 2>/dev/null); then
		read -rsp $'Encryption Password (used when secrets were created): ' encpass; echo
	else
		info '(Encryption password read from Keychain.)'
	fi
	require_non_empty "Encryption password" "$encpass"

	if [[ -f "$old_pass" ]]; then
		local decrypted_pass
		if ! decrypted_pass=$(printf '%s\n' "$encpass" | openssl enc -aes-256-cbc -pbkdf2 -d -a -in "$old_pass" -pass stdin 2>/dev/null); then
			error 'Error: Failed to decrypt password file. Wrong encryption password?'
			return 1
		fi
		require_non_empty "Decrypted password" "$decrypted_pass"
		if keychain_set "eth-vpn-password" "$decrypted_pass"; then
			success 'WLAN password migrated to Keychain (eth-vpn-password).'
		else
			error 'Error: Failed to save password to Keychain.'
			return 1
		fi
	fi

	if [[ -f "$old_token" ]]; then
		local decrypted_token
		if ! decrypted_token=$(printf '%s\n' "$encpass" | openssl enc -aes-256-cbc -pbkdf2 -d -a -in "$old_token" -pass stdin 2>/dev/null); then
			error 'Error: Failed to decrypt token file. Wrong encryption password?'
			return 1
		fi
		require_non_empty "Decrypted token" "$decrypted_token"
		if keychain_set "eth-vpn-token" "$decrypted_token"; then
			success 'OTP secret migrated to Keychain (eth-vpn-token).'
		else
			error 'Error: Failed to save OTP secret to Keychain.'
			return 1
		fi
	fi

	echo
	read -rp $'Delete old encrypted files? [y/N]: ' confirm
	if [[ "${confirm,,}" == "y" ]]; then
		[[ -f "$old_pass" ]]  && rm -f "$old_pass"  && info "Deleted ${old_pass}"
		[[ -f "$old_token" ]] && rm -f "$old_token" && info "Deleted ${old_token}"
		# Remove old encpass Keychain item if present
		security delete-generic-password -a "${USER}" -s "eth-vpn-encpass" 2>/dev/null && \
			info 'Removed eth-vpn-encpass from Keychain.' || true
		success 'Migration complete. Old files removed.'
	else
		success 'Migration complete. Old files kept (remove them manually when ready).'
	fi
}

main() {
	local cmd=${1:-}
	case "$cmd" in
		connect|c)
			connect
			;;
		disconnect|d|dc)
			disconnect
			;;
		reconnect|r)
			reconnect
			;;
		status|s)
			status
			;;
		setup)
			setup
			;;
		migrate)
			migrate
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
