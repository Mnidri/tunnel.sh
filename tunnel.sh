#!/bin/bash

# ============================================================
# Tunnel Core - GOST + Multi GRE Manager
# ============================================================

BASE_DIR="/etc/tunnel-core"
CONFIG_DIR="${BASE_DIR}/configs"
GOST_VERSION="2.11.5"
GOST_BIN="/usr/local/bin/gost"

mkdir -p "${CONFIG_DIR}"

# ============================================================
# Colors
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# Check Root
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Please run this script as root.${NC}"
    exit 1
fi

# ============================================================
# Install Dependencies
# ============================================================

install_dependencies() {

    echo -e "${BLUE}[*] Installing dependencies...${NC}"

    apt-get update -y >/dev/null 2>&1

    apt-get install -y \
        curl \
        wget \
        iptables \
        iproute2 \
        net-tools \
        iputils-ping \
        dnsutils \
        gzip \
        kmod \
        ca-certificates \
        >/dev/null 2>&1

    echo -e "${GREEN}[+] Dependencies installed.${NC}"
}

# ============================================================
# Enable IP Forwarding
# ============================================================

enable_ip_forward() {

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi

    # Loose reverse path filtering is safer for routed tunnels.
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1

    if ! grep -q "^net.ipv4.conf.all.rp_filter=2" /etc/sysctl.conf; then
        echo "net.ipv4.conf.all.rp_filter=2" >> /etc/sysctl.conf
    fi

    if ! grep -q "^net.ipv4.conf.default.rp_filter=2" /etc/sysctl.conf; then
        echo "net.ipv4.conf.default.rp_filter=2" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null 2>&1
}

# ============================================================
# GOST
# ============================================================

install_gost() {

    echo -e "${BLUE}[*] Installing GOST ${GOST_VERSION}...${NC}"

    if command -v gost >/dev/null 2>&1; then
        echo -e "${GREEN}[+] GOST is already installed.${NC}"
        return
    fi

    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64)
            GOST_ARCH="amd64"
            ;;
        aarch64)
            GOST_ARCH="arm64"
            ;;
        armv7l)
            GOST_ARCH="armv7"
            ;;
        *)
            echo -e "${RED}[!] Unsupported architecture: ${ARCH}${NC}"
            return 1
            ;;
    esac

    TMP_DIR=$(mktemp -d)

    wget -q \
        "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${GOST_ARCH}.tar.gz" \
        -O "${TMP_DIR}/gost.tar.gz"

    if [ ! -f "${TMP_DIR}/gost.tar.gz" ]; then
        echo -e "${RED}[!] Failed to download GOST.${NC}"
        rm -rf "${TMP_DIR}"
        return 1
    fi

    tar -xzf "${TMP_DIR}/gost.tar.gz" -C "${TMP_DIR}"

    if [ -f "${TMP_DIR}/gost" ]; then
        mv "${TMP_DIR}/gost" "${GOST_BIN}"
        chmod +x "${GOST_BIN}"
    else
        echo -e "${RED}[!] GOST binary not found.${NC}"
        rm -rf "${TMP_DIR}"
        return 1
    fi

    rm -rf "${TMP_DIR}"

    echo -e "${GREEN}[+] GOST installed successfully.${NC}"
}

# ============================================================
# Create GOST Port Forward
# ============================================================

create_gost_forward() {

    echo
    echo "======================================"
    echo "        Create GOST Forward"
    echo "======================================"

    read -rp "Enter tunnel name: " TUN_NAME
    read -rp "Enter listen port: " LISTEN_PORT
    read -rp "Enter remote address: " REMOTE_ADDR
    read -rp "Enter remote port: " REMOTE_PORT

    if [ -z "$TUN_NAME" ] || [ -z "$LISTEN_PORT" ] || \
       [ -z "$REMOTE_ADDR" ] || [ -z "$REMOTE_PORT" ]; then
        echo -e "${RED}[!] Invalid input.${NC}"
        return 1
    fi

    CONFIG_FILE="${CONFIG_DIR}/${TUN_NAME}.conf"

    cat > "${CONFIG_FILE}" <<EOF
TYPE="GOST"
TUN_NAME="${TUN_NAME}"
LISTEN_PORT="${LISTEN_PORT}"
REMOTE_ADDR="${REMOTE_ADDR}"
REMOTE_PORT="${REMOTE_PORT}"
EOF

    cat > "/etc/systemd/system/tunnel-${TUN_NAME}.service" <<EOF
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
    systemctl enable --now "tunnel-${TUN_NAME}.service"

    echo -e "${GREEN}[+] GOST tunnel created: ${TUN_NAME}${NC}"
}

# ============================================================
# IPv4 Functions
# ============================================================

valid_ipv4() {

    local IP="$1"

    [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r A B C D <<< "$IP"

    [ "$A" -le 255 ] &&
    [ "$B" -le 255 ] &&
    [ "$C" -le 255 ] &&
    [ "$D" -le 255 ]
}

ip_to_int() {

    local IP="$1"

    IFS='.' read -r A B C D <<< "$IP"

    echo $(( (A << 24) + (B << 16) + (C << 8) + D ))
}

int_to_ip() {

    local IP="$1"

    echo "$(( (IP >> 24) & 255 )).$(( (IP >> 16) & 255 )).$(( (IP >> 8) & 255 )).$(( IP & 255 ))"
}

# ============================================================
# Validate GRE /30
# ============================================================

validate_gre_ips() {

    local LOCAL_IP="$1"
    local REMOTE_IP="$2"

    LOCAL_IP="${LOCAL_IP%/*}"

    if ! valid_ipv4 "$LOCAL_IP"; then
        return 1
    fi

    if ! valid_ipv4 "$REMOTE_IP"; then
        return 1
    fi

    local LOCAL_INT
    local REMOTE_INT

    LOCAL_INT=$(ip_to_int "$LOCAL_IP")
    REMOTE_INT=$(ip_to_int "$REMOTE_IP")

    # /30 network
    local LOCAL_NET=$(( LOCAL_INT & 4294967292 ))
    local REMOTE_NET=$(( REMOTE_INT & 4294967292 ))

    # Both addresses must belong to the same /30.
    if [ "$LOCAL_NET" -ne "$REMOTE_NET" ]; then
        return 1
    fi

    # They cannot be the same.
    if [ "$LOCAL_INT" -eq "$REMOTE_INT" ]; then
        return 1
    fi

    # Network address cannot be used.
    if [ "$LOCAL_INT" -eq "$LOCAL_NET" ] || \
       [ "$REMOTE_INT" -eq "$LOCAL_NET" ]; then
        return 1
    fi

    # Broadcast address cannot be used.
    local BROADCAST=$(( LOCAL_NET + 3 ))

    if [ "$LOCAL_INT" -eq "$BROADCAST" ] || \
       [ "$REMOTE_INT" -eq "$BROADCAST" ]; then
        return 1
    fi

    return 0
}

# ============================================================
# Check GRE Network Collision
# ============================================================

check_gre_network_collision() {

    local LOCAL_IP="$1"
    local CONFIG_FILE="$2"

    LOCAL_IP="${LOCAL_IP%/*}"

    local LOCAL_INT
    LOCAL_INT=$(ip_to_int "$LOCAL_IP")

    local NEW_NET=$(( LOCAL_INT & 4294967292 ))

    for FILE in "${CONFIG_DIR}"/*.conf; do

        [ -f "$FILE" ] || continue

        [ "$FILE" = "$CONFIG_FILE" ] && continue

        grep -q '^TYPE="GRE"' "$FILE" || continue

        OLD_LOCAL=$(grep '^LOCAL_TUN_IP=' "$FILE" | cut -d'"' -f2)
        OLD_LOCAL="${OLD_LOCAL%/*}"

        [ -z "$OLD_LOCAL" ] && continue

        if ! valid_ipv4 "$OLD_LOCAL"; then
            continue
        fi

        OLD_INT=$(ip_to_int "$OLD_LOCAL")
        OLD_NET=$(( OLD_INT & 4294967292 ))

        if [ "$NEW_NET" -eq "$OLD_NET" ]; then
            echo -e "${RED}[!] GRE network collision detected.${NC}"
            echo -e "${YELLOW}    Existing network: $(int_to_ip "$OLD_NET")/30${NC}"
            echo -e "${YELLOW}    New network:      $(int_to_ip "$NEW_NET")/30${NC}"
            return 1
        fi
    done

    return 0
}

# ============================================================
# GRE Firewall
# ============================================================

setup_gre_firewall() {

    local TUN_NAME="$1"

    # GRE protocol = 47
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p gre -j ACCEPT

    iptables -C INPUT -i "$TUN_NAME" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -i "$TUN_NAME" -j ACCEPT

    iptables -C FORWARD -i "$TUN_NAME" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "$TUN_NAME" -j ACCEPT

    iptables -C FORWARD -o "$TUN_NAME" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -o "$TUN_NAME" -j ACCEPT
}

# ============================================================
# Remove GRE Firewall
# ============================================================

remove_gre_firewall() {

    local TUN_NAME="$1"

    while iptables -C INPUT -i "$TUN_NAME" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -i "$TUN_NAME" -j ACCEPT
    done

    while iptables -C FORWARD -i "$TUN_NAME" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "$TUN_NAME" -j ACCEPT
    done

    while iptables -C FORWARD -o "$TUN_NAME" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -o "$TUN_NAME" -j ACCEPT
    done
}

# ============================================================
# GRE Watchdog
# ============================================================

create_gre_watchdog() {

    local TUN_NAME="$1"
    local LOCAL_PUB_IP="$2"
    local REMOTE_PUB_IP="$3"
    local LOCAL_TUN_IP="$4"
    local REMOTE_TUN_IP="$5"
    local MTU="$6"

    local LOCAL_TUN_IP_ONLY="${LOCAL_TUN_IP%/*}"

    local WATCHDOG="/usr/local/sbin/tunnel-gre-${TUN_NAME}.sh"

    cat > "$WATCHDOG" <<EOF
#!/bin/bash

TUN_NAME="${TUN_NAME}"
LOCAL_PUB_IP="${LOCAL_PUB_IP}"
REMOTE_PUB_IP="${REMOTE_PUB_IP}"
LOCAL_TUN_IP="${LOCAL_TUN_IP}"
LOCAL_TUN_IP_ONLY="${LOCAL_TUN_IP_ONLY}"
REMOTE_TUN_IP="${REMOTE_TUN_IP}"
MTU="${MTU}"

cleanup() {
    ip link set "\${TUN_NAME}" down 2>/dev/null || true
    ip tunnel del "\${TUN_NAME}" 2>/dev/null || true
}

trap cleanup TERM INT EXIT

ensure_tunnel() {

    # Local public IP must exist on this server.
    if ! ip addr show | grep -q "inet \${LOCAL_PUB_IP}/"; then
        return 1
    fi

    # Make sure GRE kernel module exists.
    modprobe ip_gre 2>/dev/null || return 1

    # Create tunnel if it does not exist.
    if ! ip link show "\${TUN_NAME}" >/dev/null 2>&1; then

        ip tunnel add "\${TUN_NAME}" \
            mode gre \
            remote "\${REMOTE_PUB_IP}" \
            local "\${LOCAL_PUB_IP}" \
            ttl 255 2>/dev/null || return 1

        ip addr add "\${LOCAL_TUN_IP}" dev "\${TUN_NAME}" 2>/dev/null || true

        ip link set dev "\${TUN_NAME}" mtu "\${MTU}" 2>/dev/null || true

        ip link set "\${TUN_NAME}" up 2>/dev/null || return 1
    fi

    # Make sure address exists.
    if ! ip addr show dev "\${TUN_NAME}" | grep -q "inet \${LOCAL_TUN_IP_ONLY}/"; then
        ip addr add "\${LOCAL_TUN_IP}" dev "\${TUN_NAME}" 2>/dev/null || true
    fi

    # MTU
    ip link set dev "\${TUN_NAME}" mtu "\${MTU}" 2>/dev/null || true

    # UP
    ip link set "\${TUN_NAME}" up 2>/dev/null || true

    # Explicit route to remote GRE address.
    ip route replace "\${REMOTE_TUN_IP}/32" \
        dev "\${TUN_NAME}" \
        src "\${LOCAL_TUN_IP_ONLY}" \
        2>/dev/null || true

    # Firewall.
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p gre -j ACCEPT

    iptables -C INPUT -i "\${TUN_NAME}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -i "\${TUN_NAME}" -j ACCEPT

    iptables -C FORWARD -i "\${TUN_NAME}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "\${TUN_NAME}" -j ACCEPT

    iptables -C FORWARD -o "\${TUN_NAME}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -o "\${TUN_NAME}" -j ACCEPT

    return 0
}

while true; do

    if ! ensure_tunnel; then

        # If underlying network/public IP is unavailable,
        # wait and retry instead of killing the service.
        sleep 5
        continue
    fi

    # Verify the interface is still alive.
    if ! ip link show "\${TUN_NAME}" >/dev/null 2>&1; then
        sleep 2
        continue
    fi

    # Verify route.
    if ! ip route show "\${REMOTE_TUN_IP}/32" | grep -q "\${TUN_NAME}"; then
        ip route replace "\${REMOTE_TUN_IP}/32" \
            dev "\${TUN_NAME}" \
            src "\${LOCAL_TUN_IP_ONLY}" \
            2>/dev/null || true
    fi

    sleep 5
done
EOF

    chmod +x "$WATCHDOG"

    echo "$WATCHDOG"
}

# ============================================================
# Create GRE Tunnel
# ============================================================

create_gre_tunnel() {

    echo
    echo "======================================"
    echo "          Create GRE Tunnel"
    echo "======================================"

    echo
    echo "Select role:"
    echo "1) Foreign"
    echo "2) Iran"
    echo

    read -rp "Enter choice [1-2]: " ROLE_CHOICE

    case "$ROLE_CHOICE" in

        1)
            ROLE="FOREIGN"

            DEFAULT_LOCAL_TUN_IP="10.20.20.1/30"
            DEFAULT_REMOTE_TUN_IP="10.20.20.2"
            ;;

        2)
            ROLE="IRAN"

            DEFAULT_LOCAL_TUN_IP="10.20.20.2/30"
            DEFAULT_REMOTE_TUN_IP="10.20.20.1"
            ;;

        *)
            echo -e "${RED}[!] Invalid choice.${NC}"
            return 1
            ;;
    esac

    echo

    read -rp "Enter tunnel name: " TUN_NAME

    if [ -z "$TUN_NAME" ]; then
        echo -e "${RED}[!] Tunnel name cannot be empty.${NC}"
        return 1
    fi

    # Only safe Linux interface names.
    if [[ ! "$TUN_NAME" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]; then
        echo -e "${RED}[!] Invalid tunnel name.${NC}"
        return 1
    fi

    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] A configuration with this name already exists.${NC}"
        return 1
    fi

    if ip link show "$TUN_NAME" >/dev/null 2>&1; then
        echo -e "${RED}[!] Interface ${TUN_NAME} already exists.${NC}"
        return 1
    fi

    # Detect public/local IP.
    DETECTED_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)

    echo
    read -rp "Enter local public IP [${DETECTED_IP}]: " LOCAL_PUB_IP

    LOCAL_PUB_IP="${LOCAL_PUB_IP:-$DETECTED_IP}"

    read -rp "Enter remote public IP: " REMOTE_PUB_IP

    if ! valid_ipv4 "$LOCAL_PUB_IP"; then
        echo -e "${RED}[!] Invalid local public IP.${NC}"
        return 1
    fi

    if ! valid_ipv4 "$REMOTE_PUB_IP"; then
        echo -e "${RED}[!] Invalid remote public IP.${NC}"
        return 1
    fi

    echo
    echo "Tunnel IP addresses must use a unique /30 network."
    echo "Example:"
    echo "  Local : 10.10.10.1/30"
    echo "  Remote: 10.10.10.2"
    echo

    read -rp "Enter local tunnel IP [${DEFAULT_LOCAL_TUN_IP}]: " LOCAL_TUN_IP
    LOCAL_TUN_IP="${LOCAL_TUN_IP:-$DEFAULT_LOCAL_TUN_IP}"

    read -rp "Enter remote tunnel IP [${DEFAULT_REMOTE_TUN_IP}]: " REMOTE_TUN_IP
    REMOTE_TUN_IP="${REMOTE_TUN_IP:-$DEFAULT_REMOTE_TUN_IP}"

    read -rp "Enter MTU [1400]: " MTU
    MTU="${MTU:-1400}"

    # Validate local tunnel address.
    if [[ ! "$LOCAL_TUN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/30$ ]]; then
        echo -e "${RED}[!] Local tunnel IP must be IPv4 with /30.${NC}"
        return 1
    fi

    LOCAL_TUN_IP_ONLY="${LOCAL_TUN_IP%/*}"

    if ! validate_gre_ips "$LOCAL_TUN_IP" "$REMOTE_TUN_IP"; then
        echo -e "${RED}[!] Invalid GRE /30 addresses.${NC}"
        echo
        echo "Both addresses must:"
        echo "  - Be in the same /30 network"
        echo "  - Be different"
        echo "  - Not be network/broadcast addresses"
        echo
        return 1
    fi

    CONFIG_FILE="${CONFIG_DIR}/${TUN_NAME}.conf"

    # Check network collision with existing GRE tunnels.
    if ! check_gre_network_collision "$LOCAL_TUN_IP" "$CONFIG_FILE"; then
        echo -e "${RED}[!] This GRE network is already in use.${NC}"
        echo -e "${YELLOW}[!] Choose another /30 network.${NC}"
        return 1
    fi

    # Make sure local public IP actually exists.
    if ! ip addr show | grep -q "inet ${LOCAL_PUB_IP}/"; then
        echo -e "${RED}[!] Local public IP ${LOCAL_PUB_IP} is not assigned to this server.${NC}"
        return 1
    fi

    # Check MTU.
    if ! [[ "$MTU" =~ ^[0-9]+$ ]] || [ "$MTU" -lt 576 ] || [ "$MTU" -gt 9000 ]; then
        echo -e "${RED}[!] Invalid MTU.${NC}"
        return 1
    fi

    # Load GRE kernel module.
    if ! modprobe ip_gre 2>/dev/null; then
        echo -e "${RED}[!] Could not load ip_gre kernel module.${NC}"
        return 1
    fi

    # Save configuration.
    cat > "${CONFIG_FILE}" <<EOF
TYPE="GRE"
ROLE="${ROLE}"
TUN_NAME="${TUN_NAME}"
LOCAL_PUB_IP="${LOCAL_PUB_IP}"
REMOTE_PUB_IP="${REMOTE_PUB_IP}"
LOCAL_TUN_IP="${LOCAL_TUN_IP}"
REMOTE_TUN_IP="${REMOTE_TUN_IP}"
MTU="${MTU}"
EOF

    WATCHDOG=$(create_gre_watchdog \
        "$TUN_NAME" \
        "$LOCAL_PUB_IP" \
        "$REMOTE_PUB_IP" \
        "$LOCAL_TUN_IP" \
        "$REMOTE_TUN_IP" \
        "$MTU")

    # ========================================================
    # systemd
    # ========================================================

    cat > "/etc/systemd/system/tunnel-${TUN_NAME}.service" <<EOF
[Unit]
Description=GRE Tunnel - ${TUN_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WATCHDOG}
Restart=always
RestartSec=3
TimeoutStartSec=0
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    # Start service.
    systemctl enable "tunnel-${TUN_NAME}.service" >/dev/null 2>&1

    systemctl restart "tunnel-${TUN_NAME}.service"

    sleep 2

    # Firewall.
    setup_gre_firewall "$TUN_NAME"

    echo

    if ip link show "$TUN_NAME" >/dev/null 2>&1; then

        echo -e "${GREEN}[+] GRE tunnel created successfully.${NC}"
        echo
        echo "Tunnel Name : ${TUN_NAME}"
        echo "Role        : ${ROLE}"
        echo "Local Public: ${LOCAL_PUB_IP}"
        echo "Remote Pub. : ${REMOTE_PUB_IP}"
        echo "Local Tunnel: ${LOCAL_TUN_IP}"
        echo "Remote Tun. : ${REMOTE_TUN_IP}"
        echo "MTU         : ${MTU}"
        echo

        ip -d tunnel show "$TUN_NAME" 2>/dev/null
        echo
        ip route show "${REMOTE_TUN_IP}/32" 2>/dev/null

    else

        echo -e "${RED}[!] GRE interface was not created.${NC}"
        echo
        echo "Service status:"
        systemctl --no-pager --full status "tunnel-${TUN_NAME}.service" 2>/dev/null

        return 1
    fi
}

# ============================================================
# Test Ping
# ============================================================

test_ping() {

    echo
    echo "======================================"
    echo "             GRE Ping Test"
    echo "======================================"

    GRE_FILES=()

    for CONFIG_FILE in "${CONFIG_DIR}"/*.conf; do

        [ -f "$CONFIG_FILE" ] || continue

        if grep -q '^TYPE="GRE"' "$CONFIG_FILE"; then
            GRE_FILES+=("$CONFIG_FILE")
        fi
    done

    if [ "${#GRE_FILES[@]}" -eq 0 ]; then
        echo -e "${YELLOW}[!] No GRE tunnels found.${NC}"
        read -rp "Press Enter to return..."
        return
    fi

    echo

    for i in "${!GRE_FILES[@]}"; do
        FILE="${GRE_FILES[$i]}"

        TUN_NAME=$(grep '^TUN_NAME=' "$FILE" | cut -d'"' -f2)
        LOCAL_TUN_IP=$(grep '^LOCAL_TUN_IP=' "$FILE" | cut -d'"' -f2)
        REMOTE_TUN_IP=$(grep '^REMOTE_TUN_IP=' "$FILE" | cut -d'"' -f2)

        echo "$((i+1))) ${TUN_NAME} - ${LOCAL_TUN_IP} -> ${REMOTE_TUN_IP}"
    done

    echo

    read -rp "Select GRE tunnel: " SEL

    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || \
       [ "$SEL" -lt 1 ] || \
       [ "$SEL" -gt "${#GRE_FILES[@]}" ]; then

        echo -e "${RED}[!] Invalid selection.${NC}"
        read -rp "Press Enter to return..."
        return
    fi

    CONFIG_FILE="${GRE_FILES[$((SEL-1))]}"

    source "$CONFIG_FILE"

    echo
    echo "[*] Interface status:"

    if ! ip link show "$TUN_NAME" >/dev/null 2>&1; then

        echo -e "${RED}[!] Interface ${TUN_NAME} does not exist.${NC}"
        echo
        echo "[*] Service status:"
        systemctl --no-pager --full status \
            "tunnel-${TUN_NAME}.service" 2>/dev/null

        read -rp "Press Enter to return..."
        return
    fi

    ip -br addr show "$TUN_NAME"

    echo
    echo "[*] Route:"

    ip route get "$REMOTE_TUN_IP" 2>/dev/null

    if ! ip route get "$REMOTE_TUN_IP" 2>/dev/null | grep -q "$TUN_NAME"; then
        echo
        echo -e "${RED}[!] Route to ${REMOTE_TUN_IP} is NOT going through ${TUN_NAME}.${NC}"
        echo
        read -rp "Press Enter to return..."
        return
    fi

    echo
    echo "[*] Sending 4 packets to ${REMOTE_TUN_IP} via ${TUN_NAME}..."

    ping -I "$TUN_NAME" -c 4 -W 3 "$REMOTE_TUN_IP"

    echo
    echo "[+] Ping test finished."

    read -rp "Press Enter to return..."
}

# ============================================================
# List Tunnels
# ============================================================

list_tunnels() {

    echo
    echo "======================================"
    echo "             Tunnel List"
    echo "======================================"

    FOUND=0

    for CONFIG_FILE in "${CONFIG_DIR}"/*.conf; do

        [ -f "$CONFIG_FILE" ] || continue

        TYPE=$(grep '^TYPE=' "$CONFIG_FILE" | cut -d'"' -f2)
        TUN_NAME=$(grep '^TUN_NAME=' "$CONFIG_FILE" | cut -d'"' -f2)

        [ -z "$TYPE" ] && continue

        FOUND=1

        echo
        echo "--------------------------------------"
        echo "Name : ${TUN_NAME}"
        echo "Type : ${TYPE}"

        if [ "$TYPE" = "GRE" ]; then

            ROLE=$(grep '^ROLE=' "$CONFIG_FILE" | cut -d'"' -f2)
            LOCAL_PUB_IP=$(grep '^LOCAL_PUB_IP=' "$CONFIG_FILE" | cut -d'"' -f2)
            REMOTE_PUB_IP=$(grep '^REMOTE_PUB_IP=' "$CONFIG_FILE" | cut -d'"' -f2)
            LOCAL_TUN_IP=$(grep '^LOCAL_TUN_IP=' "$CONFIG_FILE" | cut -d'"' -f2)
            REMOTE_TUN_IP=$(grep '^REMOTE_TUN_IP=' "$CONFIG_FILE" | cut -d'"' -f2)

            echo "Role : ${ROLE}"
            echo "Local Public : ${LOCAL_PUB_IP}"
            echo "Remote Public: ${REMOTE_PUB_IP}"
            echo "Local Tunnel : ${LOCAL_TUN_IP}"
            echo "Remote Tunnel: ${REMOTE_TUN_IP}"

            if ip link show "$TUN_NAME" >/dev/null 2>&1; then
                echo -e "Status       : ${GREEN}UP${NC}"
            else
                echo -e "Status       : ${RED}DOWN${NC}"
            fi

        elif [ "$TYPE" = "GOST" ]; then

            LISTEN_PORT=$(grep '^LISTEN_PORT=' "$CONFIG_FILE" | cut -d'"' -f2)
            REMOTE_ADDR=$(grep '^REMOTE_ADDR=' "$CONFIG_FILE" | cut -d'"' -f2)
            REMOTE_PORT=$(grep '^REMOTE_PORT=' "$CONFIG_FILE" | cut -d'"' -f2)

            echo "Listen Port  : ${LISTEN_PORT}"
            echo "Remote       : ${REMOTE_ADDR}:${REMOTE_PORT}"

            if systemctl is-active --quiet "tunnel-${TUN_NAME}.service"; then
                echo -e "Status       : ${GREEN}RUNNING${NC}"
            else
                echo -e "Status       : ${RED}STOPPED${NC}"
            fi
        fi
    done

    if [ "$FOUND" -eq 0 ]; then
        echo
        echo -e "${YELLOW}[!] No tunnels found.${NC}"
    fi

    echo
    read -rp "Press Enter to return..."
}

# ============================================================
# Delete Tunnel
# ============================================================

delete_tunnel() {

    echo
    echo "======================================"
    echo "            Delete Tunnel"
    echo "======================================"

    FILES=()

    for CONFIG_FILE in "${CONFIG_DIR}"/*.conf; do

        [ -f "$CONFIG_FILE" ] || continue

        FILES+=("$CONFIG_FILE")
    done

    if [ "${#FILES[@]}" -eq 0 ]; then
        echo -e "${YELLOW}[!] No tunnels found.${NC}"
        read -rp "Press Enter to return..."
        return
    fi

    echo

    for i in "${!FILES[@]}"; do

        FILE="${FILES[$i]}"

        TYPE=$(grep '^TYPE=' "$FILE" | cut -d'"' -f2)
        TUN_NAME=$(grep '^TUN_NAME=' "$FILE" | cut -d'"' -f2)

        echo "$((i+1))) ${TUN_NAME} [${TYPE}]"
    done

    echo

    read -rp "Select tunnel to delete: " SEL

    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || \
       [ "$SEL" -lt 1 ] || \
       [ "$SEL" -gt "${#FILES[@]}" ]; then

        echo -e "${RED}[!] Invalid selection.${NC}"
        read -rp "Press Enter to return..."
        return
    fi

    CONFIG_FILE="${FILES[$((SEL-1))]}"

    TYPE=$(grep '^TYPE=' "$CONFIG_FILE" | cut -d'"' -f2)
    TUN_NAME=$(grep '^TUN_NAME=' "$CONFIG_FILE" | cut -d'"' -f2)

    echo
    read -rp "Are you sure you want to delete ${TUN_NAME}? [y/N]: " CONFIRM

    [[ "$CONFIRM" =~ ^[Yy]$ ]] || return

    if [ "$TYPE" = "GRE" ]; then

        systemctl stop "tunnel-${TUN_NAME}.service" >/dev/null 2>&1
        systemctl disable "tunnel-${TUN_NAME}.service" >/dev/null 2>&1

        remove_gre_firewall "$TUN_NAME"

        ip link set "$TUN_NAME" down 2>/dev/null || true
        ip tunnel del "$TUN_NAME" 2>/dev/null || true

        rm -f "/etc/systemd/system/tunnel-${TUN_NAME}.service"
        rm -f "/usr/local/sbin/tunnel-gre-${TUN_NAME}.sh"
        rm -f "$CONFIG_FILE"

        systemctl daemon-reload

        echo -e "${GREEN}[+] GRE tunnel ${TUN_NAME} deleted.${NC}"

    elif [ "$TYPE" = "GOST" ]; then

        systemctl stop "tunnel-${TUN_NAME}.service" >/dev/null 2>&1
        systemctl disable "tunnel-${TUN_NAME}.service" >/dev/null 2>&1

        rm -f "/etc/systemd/system/tunnel-${TUN_NAME}.service"
        rm -f "$CONFIG_FILE"

        systemctl daemon-reload

        echo -e "${GREEN}[+] GOST tunnel ${TUN_NAME} deleted.${NC}"
    fi

    read -rp "Press Enter to return..."
}

# ============================================================
# BBR
# ============================================================

enable_bbr() {

    echo
    echo "======================================"
    echo "             BBR Optimizer"
    echo "======================================"

    if ! grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi

    if ! grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null 2>&1

    echo
    echo -e "${GREEN}[+] BBR configuration applied.${NC}"

    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc

    read -rp "Press Enter to return..."
}

# ============================================================
# Main Menu
# ============================================================

install_dependencies
enable_ip_forward

while true; do

    clear

    echo "======================================"
    echo "          TUNNEL CORE MANAGER"
    echo "======================================"
    echo
    echo "1) Install / Create GOST"
    echo "2) Create GRE Tunnel"
    echo "3) List Tunnels"
    echo "4) Test GRE Ping"
    echo "5) Delete Tunnel"
    echo "6) Enable BBR"
    echo "0) Exit"
    echo
    read -rp "Select an option [0-6]: " OPTION

    case "$OPTION" in

        1)
            install_gost
            create_gost_forward
            ;;

        2)
            create_gre_tunnel
            ;;

        3)
            list_tunnels
            ;;

        4)
            test_ping
            ;;

        5)
            delete_tunnel
            ;;

        6)
            enable_bbr
            ;;

        0)
            echo
            echo "Goodbye."
            exit 0
            ;;

        *)
            echo
            echo -e "${RED}[!] Invalid option.${NC}"
            sleep 2
            ;;
    esac

done
