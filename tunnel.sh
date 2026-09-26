#!/bin/bash

# ============================================================
# tunnel.sh
# GOST + GRE Tunnel Manager
# ============================================================

set -u

BASE_DIR="/etc/tunnel-core"
CONFIG_DIR="${BASE_DIR}/configs"

GOST_VERSION="2.11.5"
GOST_BIN="/usr/local/bin/gost"

mkdir -p "$CONFIG_DIR"

# ============================================================
# Colors
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info() {
    echo -e "${CYAN}[*]${NC} $1"
}

success() {
    echo -e "${GREEN}[+]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[!]${NC} $1"
}

pause_screen() {
    echo
    read -rp "Press Enter to continue..."
}

# ============================================================
# Root check
# ============================================================

if [[ $EUID -ne 0 ]]; then
    error "Run this script as root."
    exit 1
fi

# ============================================================
# Dependencies
# ============================================================

install_dependencies() {

    info "Checking dependencies..."

    local packages=(
        curl
        wget
        iptables
        iproute2
        net-tools
        iputils-ping
        dnsutils
        gzip
    )

    apt-get update -y >/dev/null 2>&1

    for package in "${packages[@]}"; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            info "Installing $package..."
            apt-get install -y "$package" >/dev/null 2>&1
        fi
    done

    modprobe ip_gre 2>/dev/null || true

    success "Dependencies are ready."
}

# ============================================================
# System settings
# ============================================================

configure_system() {

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null 2>&1 || true
}

# ============================================================
# GOST
# ============================================================

install_gost() {

    if [[ -x "$GOST_BIN" ]]; then
        success "GOST is already installed."
        return
    fi

    info "Installing GOST ${GOST_VERSION}..."

    local arch
    arch="$(uname -m)"

    local gost_arch

    case "$arch" in
        x86_64)
            gost_arch="amd64"
            ;;
        aarch64|arm64)
            gost_arch="arm64"
            ;;
        armv7l)
            gost_arch="armv7"
            ;;
        *)
            error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    local url="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${gost_arch}.tar.gz"

    local tmp="/tmp/gost.tar.gz"

    wget -q --show-progress "$url" -O "$tmp"

    if [[ ! -s "$tmp" ]]; then
        error "Failed to download GOST."
        return 1
    fi

    rm -rf /tmp/gost-install
    mkdir -p /tmp/gost-install

    tar -xzf "$tmp" -C /tmp/gost-install

    local gost_file
    gost_file="$(find /tmp/gost-install -type f -name gost | head -n1)"

    if [[ -z "$gost_file" ]]; then
        error "GOST binary was not found."
        return 1
    fi

    install -m 0755 "$gost_file" "$GOST_BIN"

    rm -rf /tmp/gost-install "$tmp"

    success "GOST installed."
}

# ============================================================
# Helpers
# ============================================================

valid_ipv4() {
    local ip="$1"

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS=.
    read -r a b c d <<< "$ip"

    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

strip_cidr() {
    echo "${1%%/*}"
}

get_config_files() {
    find "$CONFIG_DIR" -maxdepth 1 -type f -name "gre-*.conf" -print 2>/dev/null | sort
}

config_exists() {
    local name="$1"
    [[ -f "$CONFIG_DIR/gre-${name}.conf" ]]
}

get_local_ip() {
    local ip="$1"

    ip -4 addr show | grep -qE "inet ${ip}/"
}

# ============================================================
# GRE validation
# ============================================================

validate_gre_ips() {

    local local_ip="$1"
    local remote_ip="$2"

    if ! valid_ipv4 "$local_ip"; then
        error "Invalid local tunnel IP: $local_ip"
        return 1
    fi

    if ! valid_ipv4 "$remote_ip"; then
        error "Invalid remote tunnel IP: $remote_ip"
        return 1
    fi

    if [[ "$local_ip" == "$remote_ip" ]]; then
        error "Local and remote tunnel IP cannot be the same."
        return 1
    fi

    return 0
}

# ============================================================
# Check duplicate GRE network
# ============================================================

gre_network_in_use() {

    local new_local="$1"
    local new_remote="$2"

    local new_local_ip="${new_local%/*}"

    local new_network
    new_network="$(ipcalc -n "$new_local" 2>/dev/null | cut -d= -f2)"

    # ipcalc may not exist.
    # Fallback for /30 networks.
    if [[ -z "$new_network" ]]; then

        local IFS=.
        read -r a b c d <<< "$new_local_ip"

        d=$((d / 4 * 4))

        new_network="${a}.${b}.${c}.${d}"
    fi

    while read -r file; do

        [[ -z "$file" ]] && continue

        # Do not compare against a tunnel being created
        local cfg_name
        cfg_name="$(basename "$file" .conf)"
        cfg_name="${cfg_name#gre-}"

        local cfg_local
        local cfg_remote

        cfg_local="$(grep '^LOCAL_TUN_IP=' "$file" | cut -d= -f2- | tr -d '"')"
        cfg_remote="$(grep '^REMOTE_TUN_IP=' "$file" | cut -d= -f2- | tr -d '"')"

        [[ -z "$cfg_local" ]] && continue

        local cfg_ip="${cfg_local%/*}"

        local IFS=.
        read -r a b c d <<< "$cfg_ip" 2>/dev/null || continue

        d=$((d / 4 * 4))

        local cfg_network="${a}.${b}.${c}.${d}"

        if [[ "$new_network" == "$cfg_network" ]]; then
            return 0
        fi

    done < <(get_config_files)

    return 1
}

# ============================================================
# Firewall
# ============================================================

configure_gre_firewall() {

    local tun_name="$1"

    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null ||
        iptables -I INPUT -p gre -j ACCEPT

    iptables -C INPUT -i "$tun_name" -j ACCEPT 2>/dev/null ||
        iptables -I INPUT -i "$tun_name" -j ACCEPT

    iptables -C FORWARD -i "$tun_name" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$tun_name" -j ACCEPT

    iptables -C FORWARD -o "$tun_name" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -o "$tun_name" -j ACCEPT
}

# ============================================================
# GRE creation
# ============================================================

create_gre_interface() {

    local tun_name="$1"
    local local_pub="$2"
    local remote_pub="$3"
    local local_tun="$4"
    local remote_tun="$5"
    local mtu="$6"

    modprobe ip_gre 2>/dev/null || true

    # If the interface already exists, leave it alone.
    if ip link show "$tun_name" >/dev/null 2>&1; then

        ip addr show dev "$tun_name" | grep -qE "inet ${local_tun%/*}/" ||
            ip addr add "$local_tun" dev "$tun_name" 2>/dev/null || true

        ip link set dev "$tun_name" mtu "$mtu" 2>/dev/null || true
        ip link set "$tun_name" up 2>/dev/null || true

    else

        # IMPORTANT:
        # Explicitly create the requested interface name.
        # This prevents accidental gre0 creation.
        if ! ip link add name "$tun_name" type gre \
            local "$local_pub" \
            remote "$remote_pub" \
            ttl 255; then

            error "Failed to create GRE interface: $tun_name"
            return 1
        fi

        if ! ip addr add "$local_tun" dev "$tun_name"; then
            error "Failed to assign $local_tun to $tun_name"
            ip link del "$tun_name" 2>/dev/null || true
            return 1
        fi

        ip link set dev "$tun_name" mtu "$mtu"
        ip link set "$tun_name" up
    fi

    # Explicit /32 route to remote tunnel IP.
    ip route replace "${remote_tun%/*}/32" \
        dev "$tun_name" \
        src "${local_tun%/*}" 2>/dev/null || true

    configure_gre_firewall "$tun_name"

    return 0
}

# ============================================================
# GRE watchdog
# ============================================================

create_gre_watchdog() {

    local tun_name="$1"

    local config_file="$CONFIG_DIR/gre-${tun_name}.conf"
    local watchdog="/usr/local/sbin/tunnel-gre-${tun_name}.sh"

    cat > "$watchdog" <<EOF
#!/bin/bash

CONFIG_FILE="$config_file"

if [[ ! -f "\$CONFIG_FILE" ]]; then
    exit 1
fi

source "\$CONFIG_FILE"

modprobe ip_gre 2>/dev/null || true

while true; do

    # --------------------------------------------------------
    # Make sure local public IP is present
    # --------------------------------------------------------

    if ! ip -4 addr show | grep -qE "inet \${LOCAL_PUB_IP}/"; then
        sleep 5
        continue
    fi

    # --------------------------------------------------------
    # Create GRE if missing
    # --------------------------------------------------------

    if ! ip link show "\$TUN_NAME" >/dev/null 2>&1; then

        ip link add name "\$TUN_NAME" type gre \
            local "\$LOCAL_PUB_IP" \
            remote "\$REMOTE_PUB_IP" \
            ttl 255 2>/dev/null || true

    fi

    # --------------------------------------------------------
    # Configure interface
    # --------------------------------------------------------

    if ip link show "\$TUN_NAME" >/dev/null 2>&1; then

        if ! ip addr show dev "\$TUN_NAME" | grep -qE "inet \${LOCAL_TUN_IP%/*}/"; then
            ip addr add "\$LOCAL_TUN_IP" dev "\$TUN_NAME" 2>/dev/null || true
        fi

        ip link set dev "\$TUN_NAME" mtu "\$MTU" 2>/dev/null || true
        ip link set "\$TUN_NAME" up 2>/dev/null || true

        # Force traffic to the remote tunnel IP through this GRE.
        ip route replace "\${REMOTE_TUN_IP%/*}/32" \
            dev "\$TUN_NAME" \
            src "\${LOCAL_TUN_IP%/*}" 2>/dev/null || true

        # GRE protocol 47 + interface rules.
        iptables -C INPUT -p gre -j ACCEPT 2>/dev/null ||
            iptables -I INPUT -p gre -j ACCEPT

        iptables -C INPUT -i "\$TUN_NAME" -j ACCEPT 2>/dev/null ||
            iptables -I INPUT -i "\$TUN_NAME" -j ACCEPT

        iptables -C FORWARD -i "\$TUN_NAME" -j ACCEPT 2>/dev/null ||
            iptables -I FORWARD -i "\$TUN_NAME" -j ACCEPT

        iptables -C FORWARD -o "\$TUN_NAME" -j ACCEPT 2>/dev/null ||
            iptables -I FORWARD -o "\$TUN_NAME" -j ACCEPT

    fi

    sleep 5

done
EOF

    chmod 0755 "$watchdog"
}

# ============================================================
# Create GRE systemd service
# ============================================================

create_gre_service() {

    local tun_name="$1"

    local service="/etc/systemd/system/tunnel-${tun_name}.service"
    local watchdog="/usr/local/sbin/tunnel-gre-${tun_name}.sh"

    cat > "$service" <<EOF
[Unit]
Description=Persistent GRE Tunnel - ${tun_name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${watchdog}
Restart=always
RestartSec=3
TimeoutStartSec=0
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable "tunnel-${tun_name}.service" >/dev/null 2>&1

    systemctl restart "tunnel-${tun_name}.service"
}

# ============================================================
# Create GRE
# ============================================================

create_gre() {

    echo
    echo "=============================="
    echo "       Create GRE Tunnel"
    echo "=============================="
    echo

    read -rp "Tunnel name: " TUN_NAME

    if [[ ! "$TUN_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Invalid tunnel name."
        return
    fi

    if config_exists "$TUN_NAME"; then
        error "A GRE with this name already exists."
        return
    fi

    read -rp "Local public IP: " LOCAL_PUB_IP
    read -rp "Remote public IP: " REMOTE_PUB_IP

    if ! valid_ipv4 "$LOCAL_PUB_IP"; then
        error "Invalid local public IP."
        return
    fi

    if ! valid_ipv4 "$REMOTE_PUB_IP"; then
        error "Invalid remote public IP."
        return
    fi

    if ! get_local_ip "$LOCAL_PUB_IP"; then
        error "Local public IP $LOCAL_PUB_IP is not assigned to this server."
        return
    fi

    echo
    echo "Example:"
    echo "  10.10.10.1/30 <-> 10.10.10.2"
    echo "  10.11.11.1/30 <-> 10.11.11.2"
    echo "  20.20.20.1/30 <-> 20.20.20.2"
    echo

    read -rp "Local tunnel IP/CIDR: " LOCAL_TUN_IP
    read -rp "Remote tunnel IP: " REMOTE_TUN_IP

    local local_tun_ip="${LOCAL_TUN_IP%/*}"

    if [[ "$LOCAL_TUN_IP" != */30 ]]; then
        error "Tunnel network must use /30."
        return
    fi

    if ! valid_ipv4 "$local_tun_ip"; then
        error "Invalid local tunnel IP."
        return
    fi

    if ! valid_ipv4 "$REMOTE_TUN_IP"; then
        error "Invalid remote tunnel IP."
        return
    fi

    if ! validate_gre_ips "$local_tun_ip" "$REMOTE_TUN_IP"; then
        return
    fi

    # Check that both addresses belong to the same /30.
    local IFS=.
    read -r a b c d <<< "$local_tun_ip"
    local local_network="${a}.${b}.${c}.$((d / 4 * 4))"

    read -r a b c d <<< "$REMOTE_TUN_IP"
    local remote_network="${a}.${b}.${c}.$((d / 4 * 4))"

    if [[ "$local_network" != "$remote_network" ]]; then
        error "Local and remote tunnel IPs are not in the same /30."
        return
    fi

    # /30 network address cannot be used.
    if [[ "$local_tun_ip" == "$local_network" ||
          "$REMOTE_TUN_IP" == "$local_network" ]]; then
        error "Network address cannot be used as tunnel IP."
        return
    fi

    # /30 broadcast address cannot be used.
    local broadcast="${a}.${b}.${c}.$((d / 4 * 4 + 3))"

    if [[ "$local_tun_ip" == "$broadcast" ||
          "$REMOTE_TUN_IP" == "$broadcast" ]]; then
        error "Broadcast address cannot be used as tunnel IP."
        return
    fi

    # Check existing configs for overlapping /30.
    while read -r file; do

        [[ -z "$file" ]] && continue

        local cfg_local
        cfg_local="$(grep '^LOCAL_TUN_IP=' "$file" 2>/dev/null |
            cut -d= -f2- | tr -d '"')"

        [[ -z "$cfg_local" ]] && continue

        local cfg_ip="${cfg_local%/*}"

        IFS=. read -r ca cb cc cd <<< "$cfg_ip"

        local cfg_network="${ca}.${cb}.${cc}.$((cd / 4 * 4))"

        if [[ "$cfg_network" == "$local_network" ]]; then
            error "GRE network ${local_network}/30 is already used by:"
            echo "  $file"
            return
        fi

    done < <(get_config_files)

    read -rp "MTU [1400]: " MTU
    MTU="${MTU:-1400}"

    if ! [[ "$MTU" =~ ^[0-9]+$ ]]; then
        error "Invalid MTU."
        return
    fi

    # --------------------------------------------------------
    # Save config
    # --------------------------------------------------------

    cat > "$CONFIG_DIR/gre-${TUN_NAME}.conf" <<EOF
TUN_NAME="$TUN_NAME"
LOCAL_PUB_IP="$LOCAL_PUB_IP"
REMOTE_PUB_IP="$REMOTE_PUB_IP"
LOCAL_TUN_IP="$LOCAL_TUN_IP"
REMOTE_TUN_IP="$REMOTE_TUN_IP"
MTU="$MTU"
EOF

    # --------------------------------------------------------
    # Create watchdog + service
    # --------------------------------------------------------

    create_gre_watchdog "$TUN_NAME"
    create_gre_service "$TUN_NAME"

    sleep 2

    if ip link show "$TUN_NAME" >/dev/null 2>&1; then

        success "GRE ${TUN_NAME} created successfully."

        echo
        echo "Interface:"
        ip -br addr show "$TUN_NAME"

        echo
        echo "Route:"
        ip route get "$REMOTE_TUN_IP"

    else

        error "GRE interface was not created."
        echo
        systemctl status "tunnel-${TUN_NAME}.service" --no-pager

    fi
}

# ============================================================
# GOST create
# ============================================================

create_gost() {

    echo
    echo "=============================="
    echo "       Create GOST Tunnel"
    echo "=============================="
    echo

    install_gost || return

    read -rp "Tunnel name: " TUN_NAME

    if [[ ! "$TUN_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Invalid tunnel name."
        return
    fi

    read -rp "Listen port: " LISTEN_PORT
    read -rp "Remote address: " REMOTE_ADDR
    read -rp "Remote port: " REMOTE_PORT

    if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]]; then
        error "Invalid listen port."
        return
    fi

    if ! [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]]; then
        error "Invalid remote port."
        return
    fi

    local service="/etc/systemd/system/tunnel-${TUN_NAME}.service"

    if [[ -f "$service" ]]; then
        error "A service with this name already exists."
        return
    fi

    cat > "$service" <<EOF
[Unit]
Description=GOST Tunnel - ${TUN_NAME}
After=network.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -L=tcp://:${LISTEN_PORT}/${REMOTE_ADDR}:${REMOTE_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "tunnel-${TUN_NAME}.service" >/dev/null 2>&1
    systemctl restart "tunnel-${TUN_NAME}.service"

    success "GOST tunnel created."
}

# ============================================================
# List tunnels
# ============================================================

list_tunnels() {

    echo
    echo "=============================="
    echo "          Tunnels"
    echo "=============================="
    echo

    local found=0

    # GRE configs
    while read -r file; do

        [[ -z "$file" ]] && continue

        found=1

        source "$file"

        echo "GRE: $TUN_NAME"
        echo "  Local public : $LOCAL_PUB_IP"
        echo "  Remote public: $REMOTE_PUB_IP"
        echo "  Local tunnel : $LOCAL_TUN_IP"
        echo "  Remote tunnel: $REMOTE_TUN_IP"
        echo "  MTU          : $MTU"

        if ip link show "$TUN_NAME" >/dev/null 2>&1; then
            echo "  Status       : UP/EXISTS"
            ip -br addr show "$TUN_NAME"
        else
            echo "  Status       : DOWN/MISSING"
        fi

        echo

    done < <(get_config_files)

    # GOST services
    echo "GOST services:"

    local gost_found=0

    while read -r service; do

        [[ -z "$service" ]] && continue

        gost_found=1
        found=1

        local name
        name="$(basename "$service" .service)"
        name="${name#tunnel-}"

        echo "  GOST: $name"
        systemctl is-active "$service" 2>/dev/null || true

    done < <(
        find /etc/systemd/system \
            -maxdepth 1 \
            -type f \
            -name "tunnel-*.service" \
            ! -name "tunnel-gre-*.service" \
            -print 2>/dev/null
    )

    if [[ "$found" -eq 0 ]]; then
        echo "No tunnels found."
    fi
}

# ============================================================
# GRE ping test
# ============================================================

test_gre() {

    echo
    echo "=============================="
    echo "          GRE Ping"
    echo "=============================="
    echo

    local configs=()
    local names=()

    while read -r file; do

        [[ -z "$file" ]] && continue

        configs+=("$file")

        local name
        name="$(basename "$file" .conf)"
        name="${name#gre-}"

        names+=("$name")

    done < <(get_config_files)

    if [[ "${#configs[@]}" -eq 0 ]]; then
        warn "No GRE tunnels found."
        return
    fi

    local i

    for i in "${!names[@]}"; do
        echo "$((i + 1))) ${names[$i]}"
    done

    echo

    read -rp "Select GRE: " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] ||
       (( selection < 1 || selection > ${#configs[@]} )); then
        error "Invalid selection."
        return
    fi

    local config="${configs[$((selection - 1))]}"

    source "$config"

    echo
    info "GRE interface status:"

    if ! ip link show "$TUN_NAME" >/dev/null 2>&1; then
        error "Interface $TUN_NAME does not exist."
        return
    fi

    ip -br addr show "$TUN_NAME"

    echo
    info "Route:"

    local route
    route="$(ip route get "$REMOTE_TUN_IP" 2>/dev/null || true)"

    echo "$route"

    if ! grep -q "dev $TUN_NAME" <<< "$route"; then
        error "Route to $REMOTE_TUN_IP is NOT using $TUN_NAME."
        return
    fi

    echo
    info "Sending 4 packets to $REMOTE_TUN_IP via $TUN_NAME..."

    ping -I "$TUN_NAME" -c 4 -W 3 "$REMOTE_TUN_IP"
}

# ============================================================
# Delete tunnel
# ============================================================

delete_tunnel() {

    echo
    echo "=============================="
    echo "         Delete Tunnel"
    echo "=============================="
    echo

    local services=()
    local names=()
    local types=()

    # --------------------------------------------------------
    # GRE
    # --------------------------------------------------------

    while read -r file; do

        [[ -z "$file" ]] && continue

        local name
        name="$(basename "$file" .conf)"
        name="${name#gre-}"

        names+=("$name")
        types+=("GRE")
        services+=("tunnel-${name}.service")

    done < <(get_config_files)

    # --------------------------------------------------------
    # GOST
    # --------------------------------------------------------

    while read -r service; do

        [[ -z "$service" ]] && continue

        local name
        name="$(basename "$service" .service)"
        name="${name#tunnel-}"

        names+=("$name")
        types+=("GOST")
        services+=("$service")

    done < <(
        find /etc/systemd/system \
            -maxdepth 1 \
            -type f \
            -name "tunnel-*.service" \
            ! -name "tunnel-gre-*.service" \
            -print 2>/dev/null
    )

    if [[ "${#names[@]}" -eq 0 ]]; then
        warn "No tunnels found."
        return
    fi

    local i

    for i in "${!names[@]}"; do
        echo "$((i + 1))) ${types[$i]} - ${names[$i]}"
    done

    echo

    read -rp "Select tunnel to delete: " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] ||
       (( selection < 1 || selection > ${#names[@]} )); then
        error "Invalid selection."
        return
    fi

    local index=$((selection - 1))
    local name="${names[$index]}"
    local type="${types[$index]}"
    local service="${services[$index]}"

    echo

    read -rp "Delete ${type} tunnel '${name}'? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || return

    if [[ "$type" == "GRE" ]]; then

        systemctl disable --now "$service" >/dev/null 2>&1 || true

        # Delete ONLY the selected GRE.
        ip link del "$name" 2>/dev/null || true

        rm -f "/usr/local/sbin/tunnel-gre-${name}.sh"
        rm -f "$CONFIG_DIR/gre-${name}.conf"
        rm -f "/etc/systemd/system/${service}"

        systemctl daemon-reload

        success "GRE ${name} deleted."

    else

        # GOST logic remains isolated from GRE.
        systemctl disable --now "$service" >/dev/null 2>&1 || true

        rm -f "/etc/systemd/system/${service}"

        systemctl daemon-reload

        success "GOST ${name} deleted."
    fi
}

# ============================================================
# BBR
# ============================================================

enable_bbr() {

    info "Enabling BBR..."

    if grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf; then
        :
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi

    if grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        :
    else
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null 2>&1

    success "BBR configuration applied."

    echo
    sysctl net.ipv4.tcp_congestion_control
}

# ============================================================
# Main menu
# ============================================================

main_menu() {

    install_dependencies
    configure_system

    while true; do

        clear

        echo "=========================================="
        echo "          GOST + GRE TUNNEL"
        echo "=========================================="
        echo
        echo "1) Create GOST tunnel"
        echo "2) Create GRE tunnel"
        echo "3) List tunnels"
        echo "4) Test GRE ping"
        echo "5) Delete tunnel"
        echo "6) Enable BBR"
        echo "0) Exit"
        echo
        echo "=========================================="
        echo

        read -rp "Select an option: " choice

        case "$choice" in

            1)
                create_gost
                pause_screen
                ;;

            2)
                create_gre
                pause_screen
                ;;

            3)
                list_tunnels
                pause_screen
                ;;

            4)
                test_gre
                pause_screen
                ;;

            5)
                delete_tunnel
                pause_screen
                ;;

            6)
                enable_bbr
                pause_screen
                ;;

            0)
                exit 0
                ;;

            *)
                error "Invalid option."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Start
# ============================================================

main_menu
