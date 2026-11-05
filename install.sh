#!/usr/bin/env bash
# wireguard | install.sh  — https://github.com/<you>/wireguard
#
# One-command installer for the "PiVPNhole" stack on any VPS (free-tier friendly):
#   [ Pi-hole (ad-blocking DNS) ] -> [ Unbound (recursive resolver) ] -> [ PiVPN (WireGuard) ]
#
# Clients connect with WireGuard and route DNS ONLY through the tunnel
# (split-tunnel), so bandwidth used stays tiny. Ideal for AWS/GCP/Oracle
# free tiers and cheap VPS boxes.
#
# Run as root:
#   sudo bash install.sh [options]
# or remote:
#   curl -fsSL https://raw.githubusercontent.com/<you>/wireguard/main/install.sh \
#     | sudo bash -s -- --client phone --client laptop
#
# Options:
#   --client NAME        Add a WireGuard client profile with this name (repeatable).
#                        Default: one profile named "phone".
#   --web-password PASS  Pi-hole dashboard password (default: random, printed at end).
#   --port N             WireGuard listen port (default: 51820).
#   --skip-firewall      Do not touch ufw (provider/firewall-cloud still needed).
#   -h | --help          Show this help.
#
# Provider-side note: the cloud firewall must allow udp/<port> from anywhere.
# The script prints the exact commands for AWS/GCP at the end.

set -u

# ---------------------------------------------------------------- constants
PIHOLE_INSTALLER_URL="https://install.pi-hole.net"
PIVPN_INSTALLER_URL="https://install.pivpn.io"
DNS_UPSTREAM="127.0.0.1#5335"
WG_SUBNET_CANDIDATES=(10.100.0.0 10.101.0.0 10.102.0.0 10.103.0.0 10.104.0.0)
WG_SUBNET_CLASS="24"
WG_MTU="1420"

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
LOG_FILE="/var/log/pivpnhole-install.log"

CLIENTS=()
WG_PORT=51820
WEB_PASSWORD=""
SKIP_FIREWALL=false

# ---------------------------------------------------------------- logging
log()  { printf "%b  %s\n"  "${GREEN}✓${NC}" "$*"; }
warn() { printf "%b  %s\n"  "${YELLOW}!${NC}" "$*"; }
die()  { printf "%b  %s\n"  "${RED}✗${NC}"   "$*" >&2; exit 1; }
step() { printf "\n%s==> %s%s\n" "$GREEN" "$*" "$NC"; }

# ---------------------------------------------------------------- args
usage() { grep -E '^#   (--|Options|client|web-password|port|skip)' "$0" | sed 's/^#//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --client)        CLIENTS+=("$2"); shift 2 ;;
        --web-password)  WEB_PASSWORD="$2"; shift 2 ;;
        --port)          WG_PORT="$2"; shift 2 ;;
        --skip-firewall) SKIP_FIREWALL=true; shift ;;
        -h|--help)       usage ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done
[[ ${#CLIENTS[@]} -gt 0 ]] || CLIENTS=("phone")

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"

. /etc/os-release 2>/dev/null || true
case "${ID:-unknown}" in
    debian|ubuntu|raspbian) log "OS: ${PRETTY_NAME:-$ID} (supported)" ;;
    *) die "Unsupported OS '${ID:-unknown}'. Supports Debian/Ubuntu only." ;;
esac
[[ "$WG_PORT" =~ ^[0-9]+$ ]] && [[ "$WG_PORT" -ge 1 ]] && [[ "$WG_PORT" -le 65535 ]] \
    || die "Bad port: $WG_PORT"
for c in "${CLIENTS[@]}"; do
    [[ "$c" =~ ^[A-Za-z0-9_-]{1,15}$ ]] || die "Client name '$c' invalid (alnum/dash/underscore, max 15 chars)."
done

# log everything; keep stdout clean-ish for CLI piping as well
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

public_ip() {
    curl -4 -s -m 5 https://api.ipify.org 2>/dev/null \
      || curl -4 -s -m 5 https://ipv4.icanhazip.com 2>/dev/null \
      || hostname -I | awk '{print $1}'
}

# ---------------------------------------------------------------- phase 0: base
step "Updating packages and installing prerequisites"
apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl unbound expect bind9-dnsutils net-tools qrencode dnsutils || \
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl unbound expect bind9-dnsutils net-tools qrencode

log "Prerequisites ready."

# ---------------------------------------------------------------- phase 1: unbound
step "Installing unbound (recursive resolver on 127.0.0.1:5335)"
cat > /etc/unbound/unbound.conf.d/pi-hole.conf <<'UNBOUND_EOF'
server:
    # If no logfile is specified, syslog is used
    verbosity: 0

    interface: 127.0.0.1
    port: 5335

    # not needed since pi-hole already verifies DNSSEC for clients
    do-ip6: no

    do-udp: yes
    do-tcp: yes

    # hygiene / privacy
    hide-identity: yes
    hide-version: yes

    # performance
    prefetch: yes
    cache-min-ttl: 300
    serve-expired: yes
    msg-cache-size: 10000
    rrset-cache-size: 20000
UNBOUND_EOF

systemctl restart unbound 2>/dev/null || service unbound restart
sleep 2

# older/newer unbound versions may reject the custom cache sizes gracefully
if ! unbound-checkconf >/dev/null 2>&1; then
    warn "Unbound config rejected (older/newer version?), retrying without cache-size lines..."
    sed -i '/msg-cache-size\|rrset-cache-size/d' /etc/unbound/unbound.conf.d/pi-hole.conf
    systemctl restart unbound 2>/dev/null || service unbound restart
    sleep 2
    unbound-checkconf >/dev/null 2>&1 || die "Unbound config still invalid - check /etc/unbound/unbound.conf.d/pi-hole.conf"
fi

if dig @127.0.0.1 -p 5335 cloudflare.com +short +time=5 | grep -q '[0-9]'; then
    log "Unbound is UP and resolving recursively."
else
    die "Unbound did not answer a test query - aborting."
fi

# ---------------------------------------------------------------- phase 2: gateways
step "Provider firewall / cloud gateways"
OPEN_CMD=""

GCP_META=$(curl -s -m 2 -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/name' 2>/dev/null || true)
AWS_META=$(curl -s -m 2 "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || true)

if [[ -n "$GCP_META" ]]; then
    warn "GCP detected. Run this ONCE on your workstation (not on the VPS):"
    echo "    gcloud compute firewall-rules create allow-wireguard-pivpn \\"
    echo "      --direction=INGRESS --action=allow --rules=udp:${WG_PORT} \\"
    echo "      --source-ranges=0.0.0.0/0 --description 'WireGuard for PiVPN split-tunnel DNS'"
elif [[ -n "$AWS_META" ]]; then
    warn "AWS detected. In the Console: EC2 -> Security Groups -> Inbound ->"
    echo "    Add rule: Type 'Custom UDP', Port range ${WG_PORT}, Source 0.0.0.0/0, Description 'WireGuard'"
else
    warn "If the provider firewall blocks UDP, allow udp/${WG_PORT} in the provider's firewall panel."
fi

# host-level firewall (ufw) can be adjusted right away
if $SKIP_FIREWALL; then
    warn "Skipping host firewall config as requested."
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "active"; then
    ufw allow "${WG_PORT}/udp" >/dev/null 2>&1
    log "ufw: allowed udp/${WG_PORT} (DNS port 53 and the dashboard stay closed to the internet)"
fi

# ---------------------------------------------------------------- phase 3: pi-hole
if command -v pihole >/dev/null 2>&1; then
    warn "Pi-hole already installed - configuring upstream only."
    pihole-FTL --config dns.upstreams "[ ${DNS_UPSTREAM} ]" 2>/dev/null | tail -1 >/dev/null \
        || echo "pihole-FTL --config dns.upstreams failed" >&2
else
    step "Installing Pi-hole (expected dialogs automated; upstream = unbound)"

    curl -fsSL "$PIHOLE_INSTALLER_URL" -o /tmp/ph-install.sh
    chmod +x /tmp/ph-install.sh

    # The Pi-hole v6 installer is driven by `dialog`, so we drive it with expect.
    # PIHOLE_DNS_1 pre-fills the "Custom" DNS input in the installer.
    cat > /tmp/ph.expect <<'EXPECT_EOF'
log_file /tmp/ph-install-automation.log
set timeout 1200
exp_internal 0
spawn sudo env TERM=xterm PIHOLE_DNS_1=127.0.0.1#5335 DEBIAN_FRONTEND=noninteractive bash /tmp/ph-install.sh

# 1. welcome msgbox
expect {
    -exact "Pi-hole Automated Installer" { sleep 1; send "\r" }
    timeout { puts "TIMEOUT at welcome"; exit 1 }
}
# 2. open-source msgbox
expect {
    -exact "Open Source Software" { sleep 1; send "\r" }
    timeout { puts "TIMEOUT at opensource"; exit 1 }
}
# 3. static IP yesno (default button = "Exit"; tab selects "Continue")
expect {
    -exact "Static IP" { sleep 1; send "\t\r" }
    timeout { puts "TIMEOUT at staticip"; exit 1 }
}
# 4. DNS menu: typing 'C' cycles Google->Comodo->Cloudflare->Custom
expect {
    -exact "Select Upstream DNS Provider" { sleep 1; send "CCC\r" }
    timeout { puts "TIMEOUT at dnsmenu"; exit 1 }
}
# 5. custom DNS input is pre-filled from env PIHOLE_DNS_1 = 127.0.0.1#5335
expect {
    -exact "Specify Upstream DNS Provider" { sleep 1; send "\r" }
    timeout { puts "TIMEOUT at dnsinput"; exit 1 }
}
# 6. confirm settings
expect {
    -exact "Are these settings correct" { sleep 1; send "\r" }
    timeout { puts "TIMEOUT at dnsconfirm"; exit 1 }
}
# 7. blocklists yesno (default Yes = StevenBlack list)
expect {
    -exact "Blocklists" { sleep 1; send "\r" }
    timeout { puts "TIMEOUT at blocklists"; exit 1 }
}
# 8. query logging yesno (default Yes)
expect {
    -exact "Enable Logging" { sleep 1; send "\r" }
    timeout { puts "TIMEOUT at logging"; exit 1 }
}
# 9. privacy level radiolist (level 0 default)
expect {
    -exact "privacy mode" { sleep 1; send "\r" }
    timeout { puts "TIMEOUT at privacy"; exit 1 }
}
# 10. final "Installation Complete" msgbox
expect {
    -exact "Installation Complete" { sleep 1; send "\r" }
    timeout { puts "TIMEOUT at complete"; exit 1 }
}
expect {
    eof { puts "\nPIHOLE_DONE" }
    timeout { puts "TIMEOUT at eof"; exit 1 }
}
EXPECT_EOF

    if ! expect /tmp/ph.expect 2>&1 | grep -q "PIHOLE_DONE"; then
        echo
        warn "----- last 30 lines of installer output -----"
        tail -30 /tmp/ph-install-automation.log 2>/dev/null
        die "Pi-hole install failed. You can finish manually with: sudo bash /tmp/ph-install.sh"
    fi
    rm -f /tmp/ph.expect
    log "Pi-hole installed."

    if [[ "$(pihole-FTL --config dns.upstreams 2>/dev/null | tr -d ' []')" == "${DNS_UPSTREAM}" ]]; then
        log "Pi-hole upstream locked to ${DNS_UPSTREAM} (unbound)."
    else
        warn "Upstream is not ${DNS_UPSTREAM}; fixing..."
        pihole-FTL --config dns.upstreams "[ ${DNS_UPSTREAM} ]" >/dev/null 2>&1
    fi
fi

# dashboard password
if [[ -z "$WEB_PASSWORD" ]]; then
    WEB_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)"
fi
pihole setpassword "$WEB_PASSWORD" >/dev/null 2>&1

if curl -s -o /dev/null http://127.0.0.1/admin/ 2>/dev/null; then
    log "Pi-hole dashboard answers locally."
else
    die "Pi-hole dashboard did not respond on 127.0.0.1:80/admin."
fi

# ---------------------------------------------------------------- phase 4: pivpn
if command -v pivpn >/dev/null 2>&1 && [[ -f /etc/pivpn/wireguard/setupVars.conf ]]; then
    warn "PiVPN already installed - skipping."
else
    step "Installing PiVPN (WireGuard server, split-tunnel)"

    # default interface (not always ens4)
    DEFAULT_IF="$(ip route show default 2>/dev/null | sed -n 's/.*\sdev\s\([^ ]*\).*/\1/p' | head -1)"
    [[ -n "$DEFAULT_IF" ]] || die "Could not detect the default network interface."

    # pick a non-clashing 10.x.0.0/24 subnet
    WG_SUBNET=""
    for cand in "${WG_SUBNET_CANDIDATES[@]}"; do
        X="$(echo "$cand" | cut -d. -f2)"
        if ! ip -4 route show | grep -q "10\.${X}\."; then
            WG_SUBNET="$cand"
            break
        fi
    done
    [[ -n "$WG_SUBNET" ]] || die "No free 10.x.0.0/24 subnet found for WireGuard."
    VPN_GW="${WG_SUBNET%.*}.1"

    # which user should own the client configs? (uid >= 1000)
    INSTALL_USER="${SUDO_USER:-}"
    if [[ -z "$INSTALL_USER" ]] || [[ "$(id -u "$INSTALL_USER" 2>/dev/null || echo 0)" -lt 1000 ]]; then
        INSTALL_USER="$(awk -F: '$3>=1000 && $3<=60000 {print $1; exit}' /etc/passwd)"
    fi
    [[ -n "$INSTALL_USER" ]] || die "No regular user found for PiVPN config files; create a user first."
    INSTALL_HOME="$(grep -m1 "^${INSTALL_USER}:" /etc/passwd | cut -d: -f6)"
    INSTALL_HOME="${INSTALL_HOME%/}"

    log "WireGuard subnet: ${WG_SUBNET}/${WG_SUBNET_CLASS} (DNS/dashboard gateway: ${VPN_GW})"
    log "Interface: ${DEFAULT_IF}   Client-config owner: ${INSTALL_USER} (${INSTALL_HOME}/configs)"

    cat > /tmp/pivpn-unattended.conf <<PIVPN_EOF
VPN=wireguard
IPv4dev=${DEFAULT_IF}
pivpnenableipv6=0
install_user=${INSTALL_USER}
UNATTUPG=1
pivpnNET=${WG_SUBNET}
subnetClass=${WG_SUBNET_CLASS}
ALLOWED_IPS="${VPN_GW}/32"
pivpnPORT=${WG_PORT}
pivpnMTU=${WG_MTU}
PIVPN_EOF

    if ! curl -fsSL "$PIVPN_INSTALLER_URL" \
         | sudo -E bash -s -- --unattended /tmp/pivpn-unattended.conf --use-pihole \
         > /tmp/pivpn-install.log 2>&1; then
        tail -25 /tmp/pivpn-install.log
        die "PiVPN install failed - see /tmp/pivpn-install.log"
    fi
    rm -f /tmp/pivpn-unattended.conf

    systemctl is-active wg-quick@wg0 >/dev/null 2>&1 || die "wg0 did not come up - see /tmp/pivpn-install.log."
    log "PiVPN installed and wg0 up."
fi

# re-read actual values the installer settled on
VPN_GW="$(grep -m1 '^pivpnDNS1=' /etc/pivpn/wireguard/setupVars.conf | cut -d= -f2)"
VPN_GW="${VPN_GW:-10.100.0.1}"
INSTALL_USER="${INSTALL_USER:-user}"
INSTALL_HOME="${INSTALL_HOME:-/home/${INSTALL_USER}}"

# ---------------------------------------------------------------- phase 5: profiles
step "Creating WireGuard client profiles: ${CLIENTS[*]}"
for c in "${CLIENTS[@]}"; do
    if [[ -f "/etc/wireguard/configs/${c}.conf" ]]; then
        warn "Profile '${c}' already exists - skipping."
        continue
    fi
    sudo -u "$INSTALL_USER" pivpn add -n "$c" >/dev/null 2>&1 \
        || pivpn add -n "$c" >/dev/null 2>&1 \
        || sudo pivpn add -n "$c" >/dev/null 2>&1 \
        || die "Could not create profile '${c}'."

    # real PNG QR next to the config file (note: -t PNG, NOT the terminal
    # type 'ANSIUTF8' which writes escape sequences into the "image")
    if qrencode -t PNG -s 8 -m 2 \
        -r "/etc/wireguard/configs/${c}.conf" \
        -o "${INSTALL_HOME}/configs/${c}-qr.png" 2>/dev/null; then
        chown "$(id -u "${INSTALL_USER}"):$(id -gn "${INSTALL_USER}")" \
            "${INSTALL_HOME}/configs/${c}-qr.png" 2>/dev/null
        log "Profile '${c}' -> ${INSTALL_HOME}/configs/${c}.conf"
        log "   QR image -> ${INSTALL_HOME}/configs/${c}-qr.png (scan with the WireGuard app)"
    else
        warn "QR PNG generation failed for '${c}' - on-device QR still works: pivpn -qr ${c}"
    fi
done

# ---------------------------------------------------------------- summary
PUB_IP="$(public_ip)"
cat <<SUMMARY

${GREEN}============================================================${NC}
       PIVPNHOLE INSTALLED - DNS-ONLY SPLIT-TUNNEL VPN
${GREEN}============================================================${NC}

  WireGuard endpoint   : ${PUB_IP}:${WG_PORT}
  Tunnel DNS (Pi-hole) : ${VPN_GW}
  Dashboard (VPN only) : http://${VPN_GW}/admin
  Dashboard password   : ${WEB_PASSWORD}

  Connect your devices
  --------------------
  phone   : wireguard app -> scan QR:   pivpn -qr ${CLIENTS[0]}
  laptop  : wireguard app -> import ${INSTALL_HOME}/configs/*.conf

  Handy commands
  --------------------
  pivpn list             clients
  pivpn add -n NAME      new profile
  pivpn remove NAME      revoke profile
  pivpn -qr NAME         phone QR code
  pihole -up             update pi-hole
  pivpn -up              update pivpn scripts
  pihole -g              update adlists (gravity)

  Docs : https://docs.pi-hole.net  |  https://pivpn.io
${NC}
SUMMARY

log "Done. Log: ${LOG_FILE}"
exit 0
